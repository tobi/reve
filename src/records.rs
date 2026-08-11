//! The durable wire format.
//!
//! One session is one JSONL file, one line per mutation, in exactly three
//! shapes:
//!
//! ```jsonl
//! {"kind":"header","version":4,"id":"...","cwd":"workspace"}
//! {"kind":"record","type":"operation_started","lane":"main","intent":{"kind":"run"}}
//! {"kind":"entry","lane":"main","type":"message","message":{"role":"user"}}
//! ```
//!
//! **Entries are the conversation tree; records are metadata.** Deleting every
//! record must still leave a valid conversation — that invariant is what lets
//! compaction and recovery rewrite bookkeeping without touching history.
//!
//! The envelope is typed; the payload stays `serde_json::Value`. Providers,
//! tools, and channels all extend the payload, and forcing every future field
//! through this enum would turn each of them into a change here.

use serde::{Deserialize, Serialize};
use serde_json::{Map, Value};

use crate::ids::{EntryId, RecordId};

/// The format this build reads and writes. There is no v3 compatibility: reve
/// is new, and there is nothing to be compatible with.
pub const FORMAT_VERSION: u32 = 4;

/// The default lane. Every session has one; others are created on demand.
pub const MAIN_LANE: &str = "main";

/// Envelope field names.
///
/// Payloads are flattened into the line, so a payload key with one of these
/// names would be emitted twice and the line would no longer parse. Rather
/// than trust every caller to remember that, payloads are sanitised on the way
/// in: a reserved key is moved aside under a `payload` prefix.
pub const RESERVED_KEYS: &[&str] = &[
    "kind",
    "id",
    "parentId",
    "lane",
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

/// A single line of a session file.
#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(tag = "kind", rename_all = "lowercase")]
pub enum Line {
    Header(Header),
    Entry(Entry),
    Record(Record),
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct Header {
    pub version: u32,
    pub id: String,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub cwd: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub created: Option<i64>,
}

impl Header {
    pub fn new(id: impl Into<String>, cwd: Option<String>) -> Self {
        Self {
            version: FORMAT_VERSION,
            id: id.into(),
            cwd,
            created: Some(crate::ids::now_ms()),
        }
    }
}

/// A node in the conversation tree.
///
/// `parent_id` is what makes it a tree rather than a log: compaction and
/// branching re-parent instead of deleting, so history is never destroyed.
#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct Entry {
    pub id: EntryId,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub parent_id: Option<EntryId>,
    pub lane: String,
    pub seq: u64,
    #[serde(rename = "type")]
    pub entry_type: String,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub custom_type: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub timestamp: Option<i64>,
    /// Payload: `message` for conversation turns, `data` for custom entries.
    #[serde(flatten)]
    pub payload: Map<String, Value>,
}

impl Entry {
    pub fn message(lane: impl Into<String>, message: Value) -> Self {
        let mut payload = Map::new();
        payload.insert("message".into(), message);
        let payload = sanitize(payload);
        Self {
            id: EntryId::new(),
            parent_id: None,
            lane: lane.into(),
            seq: 0,
            entry_type: "message".into(),
            custom_type: None,
            timestamp: Some(crate::ids::now_ms()),
            payload,
        }
    }

    pub fn custom(lane: impl Into<String>, custom_type: impl Into<String>, data: Value) -> Self {
        let mut payload = Map::new();
        payload.insert("data".into(), data);
        let payload = sanitize(payload);
        Self {
            id: EntryId::new(),
            parent_id: None,
            lane: lane.into(),
            seq: 0,
            entry_type: "custom".into(),
            custom_type: Some(custom_type.into()),
            timestamp: Some(crate::ids::now_ms()),
            payload,
        }
    }

    /// The `role` of a message entry, if it is one.
    pub fn role(&self) -> Option<&str> {
        self.payload.get("message")?.get("role")?.as_str()
    }
}

/// Metadata about what the harness intended and what happened.
#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct Record {
    pub id: RecordId,
    pub lane: String,
    pub seq: u64,
    #[serde(rename = "type")]
    pub record_type: String,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub timestamp: Option<i64>,
    #[serde(flatten)]
    pub payload: Map<String, Value>,
}

impl Record {
    pub fn new(lane: impl Into<String>, record_type: impl Into<String>, payload: Value) -> Self {
        Self {
            id: RecordId::new(),
            lane: lane.into(),
            seq: 0,
            record_type: record_type.into(),
            timestamp: Some(crate::ids::now_ms()),
            payload: sanitize(match payload {
                Value::Object(map) => map,
                Value::Null => Map::new(),
                other => {
                    let mut map = Map::new();
                    map.insert("value".into(), other);
                    map
                }
            }),
        }
    }

    pub fn get(&self, key: &str) -> Option<&Value> {
        self.payload.get(key)
    }

    pub fn str(&self, key: &str) -> Option<&str> {
        self.payload.get(key)?.as_str()
    }
}

/// Whether a tool may be re-executed during recovery.
///
/// Replay is only safe when the recorded declaration *and* the current one both
/// say so: a tool that became effectful must not be replayed on the strength of
/// an old record.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "lowercase")]
pub enum Replay {
    Safe,
    Never,
}

impl Replay {
    pub fn parse(value: &str) -> Self {
        match value {
            "safe" => Self::Safe,
            _ => Self::Never,
        }
    }

    pub fn as_str(self) -> &'static str {
        match self {
            Self::Safe => "safe",
            Self::Never => "never",
        }
    }
}

/// How an operation ended.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum Outcome {
    Completed,
    Aborted,
    Failed,
    Rejected,
}

impl Outcome {
    pub fn as_str(self) -> &'static str {
        match self {
            Self::Completed => "completed",
            Self::Aborted => "aborted",
            Self::Failed => "failed",
            Self::Rejected => "rejected",
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;

    #[test]
    fn lines_round_trip_through_their_kind_tag() {
        let header = Line::Header(Header::new("s1", Some("workspace".into())));
        let text = serde_json::to_string(&header).unwrap();
        assert!(text.contains(r#""kind":"header""#), "{text}");
        assert!(text.contains(r#""version":4"#), "{text}");
        matches!(
            serde_json::from_str::<Line>(&text).unwrap(),
            Line::Header(_)
        );
    }

    #[test]
    fn an_entry_keeps_unknown_payload_fields() {
        // Providers and tools extend the payload; a round trip must not drop
        // fields this build does not know about.
        let raw = json!({
            "kind": "entry", "id": "e_1", "lane": "main", "seq": 3,
            "type": "message", "message": {"role": "user"}, "somethingNew": 42
        });
        let line: Line = serde_json::from_value(raw).unwrap();
        let Line::Entry(entry) = line else {
            panic!("expected an entry")
        };
        assert_eq!(entry.role(), Some("user"));
        assert_eq!(entry.payload.get("somethingNew").unwrap(), 42);
        let back = serde_json::to_value(Line::Entry(entry)).unwrap();
        assert_eq!(back.get("somethingNew").unwrap(), 42);
    }

    #[test]
    fn replay_defaults_to_never_for_anything_unrecognised() {
        assert_eq!(Replay::parse("safe"), Replay::Safe);
        assert_eq!(Replay::parse("never"), Replay::Never);
        assert_eq!(Replay::parse("mostly"), Replay::Never);
        assert_eq!(Replay::parse(""), Replay::Never);
    }

    #[test]
    fn a_payload_cannot_collide_with_the_envelope() {
        // Regression: `operation_started` carried a payload key named `kind`,
        // which is the envelope's own tag. The line was written with `kind`
        // twice and refused to parse on reopen — a session that could be
        // written but never read back.
        let record = Record::new(
            "main",
            "operation_started",
            json!({"kind": "run", "type": "x", "seq": 9, "runId": "run_1"}),
        );
        let text = serde_json::to_string(&Line::Record(record)).unwrap();
        let parsed: Line = serde_json::from_str(&text).expect("the line must round-trip");
        let Line::Record(back) = parsed else {
            panic!("expected a record")
        };
        assert_eq!(back.record_type, "operation_started", "the envelope wins");
        assert_eq!(back.str("runId"), Some("run_1"));
        assert_eq!(
            back.get("payload_kind").unwrap(),
            "run",
            "the payload is kept, moved aside"
        );
        assert_eq!(back.get("payload_type").unwrap(), "x");
    }

    #[test]
    fn a_record_payload_is_addressable() {
        let record = Record::new("main", "tool_started", json!({"resultEntryId": "e_9"}));
        assert_eq!(record.str("resultEntryId"), Some("e_9"));
        assert_eq!(record.record_type, "tool_started");
    }
}
