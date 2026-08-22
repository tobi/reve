//! The three durable forms and the wire format that carries them.
//!
//! Everything durable is one of (`docs/harness.md` §0.3):
//!
//! ```text
//! entries        the conversation tree — write-once, append-only
//! registers      current mutable state — namespaced typed cells, set or delete
//! usage ledger   cost history — append-only rows
//! ```
//!
//! A **transaction** is a list of writes committed all-or-none with strictly
//! increasing `seq`. It is the only write primitive. One JSONL line per commit:
//! a single write as an object, several as one array line — so a torn tail is
//! discarded *whole* and no crash state exists inside a transaction.
//!
//! The envelope is typed; entry payloads stay `serde_json::Value` because
//! providers extend message shapes and forcing every field through an enum
//! would turn each of them into a change here.

use serde::{Deserialize, Serialize};
use serde_json::{Map, Value};

use crate::ids::{EntryId, UsageId};

/// The format this build reads and writes. There is no v3 compatibility: reve
/// is new, and there is nothing to be compatible with.
pub const FORMAT_VERSION: u32 = 4;
/// Schema version of the register values (`docs/harness.md` Part 7).
pub const STORAGE_VERSION: u32 = 1;

/// The default lane. Every session has one; others are created on demand.
pub const MAIN_LANE: &str = "main";

/// Envelope field names of an entry line. A payload key with one of these
/// names would be emitted twice, so payloads are sanitised on the way in.
pub const RESERVED_KEYS: &[&str] = &[
    "kind",
    "id",
    "parentId",
    "seq",
    "type",
    "customType",
    "timestamp",
];

fn sanitize(mut payload: Map<String, Value>) -> Map<String, Value> {
    for key in RESERVED_KEYS {
        if let Some(value) = payload.remove(*key) {
            payload.insert(format!("payload_{key}"), value);
        }
    }
    payload
}

// ── header ───────────────────────────────────────────────────────────────

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
#[serde(rename_all = "camelCase")]
pub struct Header {
    pub v: u32,
    pub id: String,
    pub storage_version: u32,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub cwd: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub created_at: Option<i64>,
}

impl Header {
    pub fn new(id: impl Into<String>, cwd: Option<String>) -> Self {
        Self {
            v: FORMAT_VERSION,
            id: id.into(),
            storage_version: STORAGE_VERSION,
            cwd,
            created_at: Some(crate::ids::now_ms()),
        }
    }
}

// ── entries ──────────────────────────────────────────────────────────────

/// A node in the conversation tree: placement and payload in one row.
///
/// Write-once. `parent_id` is what makes it a tree rather than a log, and it
/// never changes.
#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
#[serde(rename_all = "camelCase")]
pub struct Entry {
    pub id: EntryId,
    #[serde(default)]
    pub parent_id: Option<EntryId>,
    #[serde(default)]
    pub seq: u64,
    #[serde(rename = "type")]
    pub entry_type: String,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub custom_type: Option<String>,
    #[serde(default)]
    pub timestamp: i64,
    /// `message` for conversation turns, `summary`/`retainedTail`/… for a
    /// compaction, `data` for custom entries.
    #[serde(flatten)]
    pub payload: Map<String, Value>,
}

impl Entry {
    fn base(entry_type: &str, payload: Map<String, Value>) -> Self {
        Self {
            id: EntryId::new(),
            parent_id: None,
            seq: 0,
            entry_type: entry_type.into(),
            custom_type: None,
            timestamp: 0,
            payload: sanitize(payload),
        }
    }

    /// A message entry. `message` is an AgentMessage-shaped JSON object with a
    /// `role`.
    pub fn message(message: Value) -> Self {
        let mut payload = Map::new();
        payload.insert("message".into(), message);
        Self::base("message", payload)
    }

    /// A compaction: a self-contained checkpoint. Context never reads past it.
    pub fn compaction(
        summary: &str,
        retained_tail: Vec<Value>,
        tokens_before: u64,
        from_hook: bool,
    ) -> Self {
        let mut payload = Map::new();
        payload.insert("summary".into(), Value::String(summary.into()));
        payload.insert("retainedTail".into(), Value::Array(retained_tail));
        payload.insert("tokensBefore".into(), Value::from(tokens_before));
        payload.insert("fromHook".into(), Value::Bool(from_hook));
        Self::base("compaction", payload)
    }

    pub fn custom(custom_type: impl Into<String>, data: Option<Value>) -> Self {
        let mut payload = Map::new();
        if let Some(data) = data {
            payload.insert("data".into(), data);
        }
        let mut entry = Self::base("custom", payload);
        entry.custom_type = Some(custom_type.into());
        entry
    }

    pub fn with_id(mut self, id: EntryId) -> Self {
        self.id = id;
        self
    }

    pub fn with_parent(mut self, parent: Option<EntryId>) -> Self {
        self.parent_id = parent;
        self
    }

    pub fn message_value(&self) -> Option<&Value> {
        self.payload.get("message")
    }

    /// The `role` of a message entry, if it is one.
    pub fn role(&self) -> Option<&str> {
        self.message_value()?.get("role")?.as_str()
    }

    /// The `stopReason` of an assistant message entry.
    pub fn stop_reason(&self) -> Option<&str> {
        self.message_value()?.get("stopReason")?.as_str()
    }

    pub fn is_compaction(&self) -> bool {
        self.entry_type == "compaction"
    }
}

// ── usage ledger ─────────────────────────────────────────────────────────

/// What a turn cost.
///
/// `cached_input` drives the cache-miss warning: a normal request whose prefix
/// mostly missed the cache means something invalidated it, and that is worth
/// saying out loud rather than paying for quietly.
#[derive(Debug, Clone, Copy, Default, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct Usage {
    #[serde(default)]
    pub input: u64,
    #[serde(default)]
    pub output: u64,
    #[serde(default)]
    pub cached_input: u64,
}

impl Usage {
    /// Fraction of the input that had to be re-read, 0.0 to 1.0.
    pub fn uncached_fraction(&self) -> f32 {
        if self.input == 0 {
            return 0.0;
        }
        1.0 - (self.cached_input as f32 / self.input as f32)
    }

    pub fn add(&mut self, other: &Usage) {
        self.input += other.input;
        self.output += other.output;
        self.cached_input += other.cached_input;
    }
}

/// Append-only cost row. Never modified, never deleted.
#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
#[serde(rename_all = "camelCase")]
pub struct UsageRow {
    pub id: UsageId,
    #[serde(default)]
    pub seq: u64,
    pub usage: Usage,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub entry_id: Option<EntryId>,
    #[serde(default)]
    pub adjustment: bool,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub details: Option<Value>,
}

impl UsageRow {
    pub fn new(id: UsageId, usage: Usage, entry_id: Option<EntryId>) -> Self {
        Self {
            id,
            seq: 0,
            usage,
            entry_id,
            adjustment: false,
            details: None,
        }
    }
}

// ── registers ────────────────────────────────────────────────────────────

/// Register namespaces (`docs/harness.md` §1.3). That is the complete set.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, PartialOrd, Ord, Serialize, Deserialize)]
pub enum Namespace {
    #[serde(rename = "lane.leaf")]
    LaneLeaf,
    #[serde(rename = "lane.config")]
    LaneConfig,
    #[serde(rename = "lane.state")]
    LaneState,
    #[serde(rename = "lane.lastResult")]
    LaneLastResult,
    #[serde(rename = "op.meta")]
    OpMeta,
    #[serde(rename = "op.state")]
    OpState,
    #[serde(rename = "op.tool_args")]
    OpToolArgs,
    #[serde(rename = "op.preparation")]
    OpPreparation,
    #[serde(rename = "pending.entry")]
    PendingEntry,
    #[serde(rename = "fact.name")]
    FactName,
    #[serde(rename = "fact.label")]
    FactLabel,
    #[serde(rename = "fact.custom")]
    FactCustom,
}

impl Namespace {
    pub fn as_str(self) -> &'static str {
        match self {
            Self::LaneLeaf => "lane.leaf",
            Self::LaneConfig => "lane.config",
            Self::LaneState => "lane.state",
            Self::LaneLastResult => "lane.lastResult",
            Self::OpMeta => "op.meta",
            Self::OpState => "op.state",
            Self::OpToolArgs => "op.tool_args",
            Self::OpPreparation => "op.preparation",
            Self::PendingEntry => "pending.entry",
            Self::FactName => "fact.name",
            Self::FactLabel => "fact.label",
            Self::FactCustom => "fact.custom",
        }
    }

    /// Operation-lived namespaces, deleted by the terminal transaction.
    pub fn is_operation_scoped(self) -> bool {
        matches!(
            self,
            Self::OpMeta | Self::OpState | Self::OpToolArgs | Self::OpPreparation
        )
    }
}

/// A namespaced cell holding its current value directly.
#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
pub struct Register {
    pub namespace: Namespace,
    pub key: String,
    pub value: Value,
    /// `seq` of the write that last set this register — the CAS token.
    pub seq: u64,
}

// ── transactions ─────────────────────────────────────────────────────────

/// One write inside a transaction. Also one element of a JSONL line.
#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
#[serde(tag = "kind", rename_all = "lowercase")]
pub enum Write {
    Entry(Entry),
    Usage(UsageRow),
    Register(RegisterWrite),
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
#[serde(tag = "op", rename_all = "lowercase")]
pub enum RegisterWrite {
    Set {
        #[serde(default)]
        seq: u64,
        namespace: Namespace,
        key: String,
        value: Value,
    },
    Delete {
        #[serde(default)]
        seq: u64,
        namespace: Namespace,
        key: String,
    },
}

impl Write {
    pub fn entry(entry: Entry) -> Self {
        Self::Entry(entry)
    }
    pub fn usage(row: UsageRow) -> Self {
        Self::Usage(row)
    }
    pub fn set(namespace: Namespace, key: impl Into<String>, value: impl Serialize) -> Self {
        Self::Register(RegisterWrite::Set {
            seq: 0,
            namespace,
            key: key.into(),
            value: serde_json::to_value(value).expect("register values serialise"),
        })
    }
    pub fn delete(namespace: Namespace, key: impl Into<String>) -> Self {
        Self::Register(RegisterWrite::Delete {
            seq: 0,
            namespace,
            key: key.into(),
        })
    }

    pub fn seq(&self) -> u64 {
        match self {
            Self::Entry(e) => e.seq,
            Self::Usage(u) => u.seq,
            Self::Register(RegisterWrite::Set { seq, .. })
            | Self::Register(RegisterWrite::Delete { seq, .. }) => *seq,
        }
    }

    pub(crate) fn set_seq(&mut self, value: u64) {
        match self {
            Self::Entry(e) => e.seq = value,
            Self::Usage(u) => u.seq = value,
            Self::Register(RegisterWrite::Set { seq, .. })
            | Self::Register(RegisterWrite::Delete { seq, .. }) => *seq = value,
        }
    }
}

/// A set of writes committed all-or-none.
#[derive(Debug, Clone, Default, PartialEq)]
pub struct Transaction {
    pub writes: Vec<Write>,
}

impl Transaction {
    pub fn new() -> Self {
        Self::default()
    }
    pub fn with(mut self, write: Write) -> Self {
        self.writes.push(write);
        self
    }
    pub fn push(&mut self, write: Write) -> &mut Self {
        self.writes.push(write);
        self
    }
    pub fn is_empty(&self) -> bool {
        self.writes.is_empty()
    }
}

/// What a commit assigned.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct CommitResult {
    pub first_seq: u64,
    pub last_seq: u64,
    pub timestamp: i64,
}

// ── wire ─────────────────────────────────────────────────────────────────

/// One physical line of a session file.
#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(untagged)]
pub enum Line {
    /// The first line.
    Header(HeaderLine),
    /// A transaction of several writes.
    Batch(Vec<Write>),
    /// A transaction of one write.
    Single(Write),
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct HeaderLine {
    pub kind: HeaderKind,
    #[serde(flatten)]
    pub header: Header,
}

#[derive(Debug, Clone, Copy, Serialize, Deserialize, PartialEq, Eq)]
#[serde(rename_all = "lowercase")]
pub enum HeaderKind {
    Header,
}

impl Line {
    pub fn header(header: Header) -> Self {
        Self::Header(HeaderLine {
            kind: HeaderKind::Header,
            header,
        })
    }

    pub fn commit(writes: &[Write]) -> Self {
        if writes.len() == 1 {
            Self::Single(writes[0].clone())
        } else {
            Self::Batch(writes.to_vec())
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;

    #[test]
    fn header_lines_round_trip() {
        let line = Line::header(Header::new("s1", Some("workspace".into())));
        let text = serde_json::to_string(&line).unwrap();
        assert!(text.contains(r#""kind":"header""#), "{text}");
        assert!(text.contains(r#""v":4"#), "{text}");
        assert!(text.contains(r#""storageVersion":1"#), "{text}");
        assert!(matches!(
            serde_json::from_str::<Line>(&text).unwrap(),
            Line::Header(_)
        ));
    }

    #[test]
    fn a_batch_is_one_array_line_and_a_single_write_is_one_object() {
        let a = Write::entry(Entry::message(json!({"role": "user", "content": "x"})));
        let b = Write::set(Namespace::LaneLeaf, "main", "e1");
        let batch = serde_json::to_string(&Line::commit(&[a.clone(), b])).unwrap();
        assert!(batch.starts_with('['), "{batch}");
        let single = serde_json::to_string(&Line::commit(&[a])).unwrap();
        assert!(single.starts_with('{'), "{single}");
        assert!(matches!(
            serde_json::from_str::<Line>(&batch).unwrap(),
            Line::Batch(w) if w.len() == 2
        ));
        assert!(matches!(
            serde_json::from_str::<Line>(&single).unwrap(),
            Line::Single(Write::Entry(_))
        ));
    }

    #[test]
    fn an_entry_keeps_unknown_payload_fields() {
        let raw = json!({
            "kind": "entry", "id": "e_1", "seq": 3, "timestamp": 5,
            "type": "message", "message": {"role": "user"}, "somethingNew": 42
        });
        let write: Write = serde_json::from_value(raw).unwrap();
        let Write::Entry(entry) = write else {
            panic!("expected an entry")
        };
        assert_eq!(entry.role(), Some("user"));
        assert_eq!(entry.payload.get("somethingNew").unwrap(), 42);
        let back = serde_json::to_value(Write::Entry(entry)).unwrap();
        assert_eq!(back.get("somethingNew").unwrap(), 42);
    }

    #[test]
    fn a_payload_cannot_collide_with_the_envelope() {
        let mut payload = Map::new();
        payload.insert("type".into(), json!("x"));
        payload.insert("seq".into(), json!(9));
        let entry = Entry::base("message", payload);
        let text = serde_json::to_string(&Write::Entry(entry)).unwrap();
        let parsed: Write = serde_json::from_str(&text).expect("must round-trip");
        let Write::Entry(back) = parsed else {
            panic!("expected an entry")
        };
        assert_eq!(back.entry_type, "message", "the envelope wins");
        assert_eq!(back.payload.get("payload_type").unwrap(), "x");
    }

    #[test]
    fn register_writes_carry_their_namespace_by_name() {
        let text =
            serde_json::to_string(&Write::set(Namespace::OpState, "op1", json!({"a": 1}))).unwrap();
        assert!(text.contains(r#""namespace":"op.state""#), "{text}");
        assert!(text.contains(r#""op":"set""#), "{text}");
        let del = serde_json::to_string(&Write::delete(Namespace::PendingEntry, "e1")).unwrap();
        assert!(del.contains(r#""op":"delete""#), "{del}");
    }
}
