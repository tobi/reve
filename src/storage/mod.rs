//! Session storage: entries, registers, usage rows, one monotonic `seq`.
//!
//! Storage knows nothing about agents, lanes, or conversations. It commits
//! transactions and answers a small fixed set of queries (`docs/harness.md`
//! Part 1). The in-memory maps *are* the state; the JSONL file, when there is
//! one, is the replay recipe for them.
//!
//! This type is deliberately *not* thread-safe and deliberately not shared.
//! Exactly one task owns it (see [`crate::session`]), which is how reve gets
//! the single-writer guarantee structurally instead of by convention.

pub mod jsonl;

use std::collections::{BTreeMap, HashMap, HashSet};

use serde_json::Value;
use thiserror::Error;

use crate::entry::{
    CommitResult, Entry, Header, Line, Namespace, Register, RegisterWrite, Transaction, Usage,
    UsageRow, Write,
};
use crate::ids::EntryId;

#[derive(Debug, Error)]
pub enum StorageError {
    #[error("io error: {0}")]
    Io(#[from] std::io::Error),
    /// A malformed line that is *not* the last one. A crash can truncate the
    /// tail; it cannot corrupt the middle, so this is real damage and we
    /// refuse to open rather than silently drop history.
    #[error("corrupt session at line {line}: {reason}")]
    Corrupt { line: usize, reason: String },
    #[error("unsupported session format version {0} (this build reads {1})")]
    Version(u32, u32),
    #[error("session storage version {0} is newer than this build ({1})")]
    StorageVersion(u32, u32),
    #[error("session {0} is open in another process")]
    Locked(String),
    /// Entries and usage rows are write-once; writing under an existing id is
    /// corruption, not an update.
    #[error("duplicate id {0}")]
    DuplicateId(String),
    #[error("entry {child} names a parent {parent} that does not exist")]
    MissingParent { child: String, parent: String },
    #[error("invalid transaction: {0}")]
    Invalid(String),
}

pub type Result<T, E = StorageError> = std::result::Result<T, E>;

/// Ordering for scans.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Default)]
pub enum Order {
    OldestFirst,
    #[default]
    NewestFirst,
}

/// Bounds of a branch scan (`docs/harness.md` §2.5).
#[derive(Debug, Clone, Default)]
pub struct BranchScan {
    /// Where the scan starts; `None` is an empty branch.
    pub start: Option<EntryId>,
    /// Scan ends after the first entry of this type, inclusive.
    pub stop_at_type: Option<String>,
    pub stop_at_id: Option<EntryId>,
    pub entry_type: Option<String>,
    pub custom_type: Option<String>,
    pub order: Order,
    pub limit: Option<usize>,
}

#[derive(Debug, Clone, Copy, Default, PartialEq, Eq)]
pub struct Stats {
    pub message_count: u64,
    pub usage: Usage,
}

#[derive(Debug)]
pub struct Storage {
    header: Header,
    seq: u64,
    entries: HashMap<EntryId, Entry>,
    entry_order: Vec<EntryId>,
    registers: BTreeMap<(Namespace, String), Register>,
    usage: Vec<UsageRow>,
    usage_ids: HashSet<String>,
    stats: Stats,
    sink: Option<jsonl::Sink>,
}

impl Storage {
    /// An in-memory session. Nothing is written anywhere.
    pub fn memory(id: impl Into<String>) -> Self {
        Self::with_header(Header::new(id, None), None)
    }

    pub(crate) fn with_header(header: Header, sink: Option<jsonl::Sink>) -> Self {
        Self {
            header,
            seq: 0,
            entries: HashMap::new(),
            entry_order: Vec::new(),
            registers: BTreeMap::new(),
            usage: Vec::new(),
            usage_ids: HashSet::new(),
            stats: Stats::default(),
            sink,
        }
    }

    pub fn header(&self) -> &Header {
        &self.header
    }

    pub fn seq(&self) -> u64 {
        self.seq
    }

    pub fn stats(&self) -> Stats {
        self.stats
    }

    // ── the write primitive ───────────────────────────────────────────────

    /// Commit a transaction: all-or-none, strictly increasing `seq`.
    ///
    /// Validation happens against the state *with earlier writes of the same
    /// transaction applied*, so an entry may name a parent created a line
    /// earlier. Nothing is applied to the live maps until the whole
    /// transaction is valid and — when there is a file — flushed.
    pub fn commit(&mut self, tx: Transaction) -> Result<CommitResult> {
        if tx.writes.is_empty() {
            return Err(StorageError::Invalid("empty transaction".into()));
        }
        let timestamp = crate::ids::now_ms();
        let first_seq = self.seq + 1;
        let mut seq = self.seq;
        let mut writes = tx.writes;

        // Validate with in-transaction visibility.
        let mut new_entries: HashSet<String> = HashSet::new();
        let mut new_usage: HashSet<String> = HashSet::new();
        for write in writes.iter_mut() {
            seq += 1;
            write.set_seq(seq);
            match write {
                Write::Entry(entry) => {
                    entry.timestamp = timestamp;
                    let id = entry.id.as_str();
                    if self.entries.contains_key(&entry.id)
                        || self.usage_ids.contains(id)
                        || !new_entries.insert(id.to_string())
                        || new_usage.contains(id)
                    {
                        return Err(StorageError::DuplicateId(id.to_string()));
                    }
                    if let Some(parent) = &entry.parent_id
                        && !self.entries.contains_key(parent)
                        && !new_entries.contains(parent.as_str())
                    {
                        return Err(StorageError::MissingParent {
                            child: id.to_string(),
                            parent: parent.to_string(),
                        });
                    }
                    if entry.entry_type.is_empty() {
                        return Err(StorageError::Invalid(format!("entry {id} has no type")));
                    }
                    if (entry.entry_type == "custom") != entry.custom_type.is_some() {
                        return Err(StorageError::Invalid(format!(
                            "entry {id}: customType is set exactly on custom entries"
                        )));
                    }
                }
                Write::Usage(row) => {
                    let id = row.id.as_str();
                    if self.usage_ids.contains(id)
                        || self.entries.contains_key(&EntryId::from(id))
                        || !new_usage.insert(id.to_string())
                        || new_entries.contains(id)
                    {
                        return Err(StorageError::DuplicateId(id.to_string()));
                    }
                }
                Write::Register(_) => {}
            }
        }

        // Durable first, then visible.
        if let Some(sink) = self.sink.as_mut() {
            sink.append(&Line::commit(&writes))?;
        }
        for write in writes {
            self.apply(write);
        }
        Ok(CommitResult {
            first_seq,
            last_seq: seq,
            timestamp,
        })
    }

    /// Apply one already-validated write to the live maps. Shared by commit
    /// and replay; assigns nothing.
    fn apply(&mut self, write: Write) {
        let seq = write.seq();
        self.seq = self.seq.max(seq);
        match write {
            Write::Entry(entry) => {
                if entry.entry_type == "message" {
                    self.stats.message_count += 1;
                }
                self.entry_order.push(entry.id.clone());
                self.entries.insert(entry.id.clone(), entry);
            }
            Write::Usage(row) => {
                self.stats.usage.add(&row.usage);
                self.usage_ids.insert(row.id.as_str().to_string());
                self.usage.push(row);
            }
            Write::Register(RegisterWrite::Set {
                seq,
                namespace,
                key,
                value,
            }) => {
                self.registers.insert(
                    (namespace, key.clone()),
                    Register {
                        namespace,
                        key,
                        value,
                        seq,
                    },
                );
            }
            Write::Register(RegisterWrite::Delete { namespace, key, .. }) => {
                self.registers.remove(&(namespace, key));
            }
        }
    }

    /// Replay one decoded line during open. Decoding, not recovery logic.
    pub(crate) fn replay(&mut self, write: Write) {
        self.apply(write);
    }

    // ── queries ──────────────────────────────────────────────────────────

    pub fn entry(&self, id: &EntryId) -> Option<&Entry> {
        self.entries.get(id)
    }

    pub fn entries(&self, ids: &[EntryId]) -> HashMap<EntryId, Entry> {
        ids.iter()
            .filter_map(|id| self.entries.get(id).map(|e| (id.clone(), e.clone())))
            .collect()
    }

    pub fn entry_count(&self) -> usize {
        self.entries.len()
    }

    pub fn register(&self, namespace: Namespace, key: &str) -> Option<&Register> {
        self.registers.get(&(namespace, key.to_string()))
    }

    /// Indexed prefix listing over `(namespace, key)`.
    pub fn list_registers(&self, namespace: Namespace, key_prefix: &str) -> Vec<&Register> {
        self.registers
            .range((namespace, key_prefix.to_string())..)
            .take_while(|((ns, key), _)| *ns == namespace && key.starts_with(key_prefix))
            .map(|(_, r)| r)
            .collect()
    }

    pub fn register_count(&self) -> usize {
        self.registers.len()
    }

    /// Take the path from `start` toward the root, order it, stop inclusively
    /// at the first `stop_at` match, filter, limit.
    pub fn scan_branch(&self, scan: &BranchScan) -> Vec<&Entry> {
        let mut path: Vec<&Entry> = Vec::new();
        let mut cursor = scan.start.clone();
        while let Some(id) = cursor {
            let Some(entry) = self.entries.get(&id) else {
                break;
            };
            path.push(entry);
            let stop_type = scan
                .stop_at_type
                .as_deref()
                .is_some_and(|t| entry.entry_type == t);
            let stop_id = scan.stop_at_id.as_ref().is_some_and(|s| *s == entry.id);
            if stop_type || stop_id {
                break;
            }
            cursor = entry.parent_id.clone();
        }
        if scan.order == Order::OldestFirst {
            path.reverse();
        }
        let filtered = path.into_iter().filter(|e| {
            scan.entry_type.as_deref().is_none_or(|t| e.entry_type == t)
                && scan
                    .custom_type
                    .as_deref()
                    .is_none_or(|c| e.custom_type.as_deref() == Some(c))
        });
        match scan.limit {
            Some(limit) => filtered.take(limit).collect(),
            None => filtered.collect(),
        }
    }

    /// Session-wide inventory in sequence order.
    pub fn scan_entries(&self, order: Order) -> Vec<&Entry> {
        let mut all: Vec<&Entry> = self
            .entry_order
            .iter()
            .filter_map(|id| self.entries.get(id))
            .collect();
        if order == Order::NewestFirst {
            all.reverse();
        }
        all
    }

    pub fn scan_usage(&self, from_seq: u64) -> Vec<&UsageRow> {
        self.usage.iter().filter(|r| r.seq >= from_seq).collect()
    }

    pub fn usage_count(&self) -> usize {
        self.usage.len()
    }

    /// Every live register, for snapshot compaction and debugging.
    pub fn all_registers(&self) -> impl Iterator<Item = &Register> {
        self.registers.values()
    }

    pub fn all_usage(&self) -> &[UsageRow] {
        &self.usage
    }

    /// Typed read of a register value.
    pub fn register_value<T: serde::de::DeserializeOwned>(
        &self,
        namespace: Namespace,
        key: &str,
    ) -> Option<(T, u64)> {
        let register = self.register(namespace, key)?;
        let value: T = serde_json::from_value(register.value.clone()).ok()?;
        Some((value, register.seq))
    }

    pub fn register_json(&self, namespace: Namespace, key: &str) -> Option<&Value> {
        self.register(namespace, key).map(|r| &r.value)
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;

    fn user(text: &str) -> Entry {
        Entry::message(json!({"role": "user", "content": text}))
    }

    fn tx(writes: Vec<Write>) -> Transaction {
        Transaction { writes }
    }

    #[test]
    fn a_transaction_assigns_strictly_increasing_seq_across_all_kinds() {
        let mut s = Storage::memory("s1");
        let e = user("one");
        let result = s
            .commit(tx(vec![
                Write::entry(e.clone()),
                Write::set(Namespace::LaneLeaf, "main", e.id.as_str()),
                Write::usage(UsageRow::new(
                    crate::ids::UsageId::new(),
                    Usage::default(),
                    None,
                )),
            ]))
            .unwrap();
        assert_eq!((result.first_seq, result.last_seq), (1, 3));
        assert_eq!(s.seq(), 3);
        assert_eq!(s.register(Namespace::LaneLeaf, "main").unwrap().seq, 2);
        assert_eq!(s.entry(&e.id).unwrap().seq, 1);
    }

    #[test]
    fn a_failing_transaction_applies_nothing() {
        let mut s = Storage::memory("s1");
        let a = user("a");
        s.commit(tx(vec![Write::entry(a.clone())])).unwrap();
        let orphan = user("orphan").with_parent(Some(EntryId::from("nope")));
        let err = s
            .commit(tx(vec![
                Write::set(Namespace::FactName, "", "should not land"),
                Write::entry(orphan),
            ]))
            .unwrap_err();
        assert!(matches!(err, StorageError::MissingParent { .. }), "{err}");
        assert!(s.register(Namespace::FactName, "").is_none(), "all-or-none");
        assert_eq!(s.seq(), 1, "seq is not consumed by a rejected transaction");
    }

    #[test]
    fn entries_and_usage_share_one_write_once_id_namespace() {
        let mut s = Storage::memory("s1");
        let e = user("x");
        s.commit(tx(vec![Write::entry(e.clone())])).unwrap();
        let dup = s.commit(tx(vec![Write::entry(e.clone())])).unwrap_err();
        assert!(matches!(dup, StorageError::DuplicateId(_)), "{dup}");
        let clash = s
            .commit(tx(vec![Write::usage(UsageRow::new(
                crate::ids::UsageId::from(e.id.as_str()),
                Usage::default(),
                None,
            ))]))
            .unwrap_err();
        assert!(matches!(clash, StorageError::DuplicateId(_)), "{clash}");
    }

    #[test]
    fn an_entry_may_name_a_parent_created_earlier_in_the_same_transaction() {
        let mut s = Storage::memory("s1");
        let a = user("a");
        let b = user("b").with_parent(Some(a.id.clone()));
        s.commit(tx(vec![Write::entry(a.clone()), Write::entry(b.clone())]))
            .unwrap();
        assert_eq!(s.entry(&b.id).unwrap().parent_id, Some(a.id));
    }

    #[test]
    fn registers_set_delete_and_recreate_without_history() {
        let mut s = Storage::memory("s1");
        s.commit(tx(vec![Write::set(Namespace::FactName, "", "one")]))
            .unwrap();
        s.commit(tx(vec![Write::set(Namespace::FactName, "", "two")]))
            .unwrap();
        assert_eq!(s.register(Namespace::FactName, "").unwrap().value, "two");
        assert_eq!(s.register_count(), 1, "overwrite keeps no history");
        s.commit(tx(vec![Write::delete(Namespace::FactName, "")]))
            .unwrap();
        assert!(s.register(Namespace::FactName, "").is_none());
        // Deleting an absent key is a legal no-op.
        s.commit(tx(vec![Write::delete(Namespace::FactName, "")]))
            .unwrap();
        s.commit(tx(vec![Write::set(
            Namespace::FactCustom,
            "k",
            Value::Null,
        )]))
        .unwrap();
        assert_eq!(
            s.register(Namespace::FactCustom, "k").unwrap().value,
            Value::Null,
            "JSON null is a value, not a deletion"
        );
    }

    #[test]
    fn prefix_listing_is_scoped_to_one_namespace() {
        let mut s = Storage::memory("s1");
        s.commit(tx(vec![
            Write::set(Namespace::OpToolArgs, "op1:s1:0", json!({})),
            Write::set(Namespace::OpToolArgs, "op1:s1:1", json!({})),
            Write::set(Namespace::OpToolArgs, "op2:s1:0", json!({})),
            Write::set(Namespace::OpPreparation, "op1:t1", json!({})),
        ]))
        .unwrap();
        assert_eq!(s.list_registers(Namespace::OpToolArgs, "op1:").len(), 2);
        assert_eq!(s.list_registers(Namespace::OpToolArgs, "").len(), 3);
        assert_eq!(s.list_registers(Namespace::OpPreparation, "op1").len(), 1);
    }

    #[test]
    fn a_branch_scan_stops_inclusively_at_a_compaction() {
        let mut s = Storage::memory("s1");
        let a = user("a");
        let b = user("b").with_parent(Some(a.id.clone()));
        let c = Entry::compaction("sum", vec![], 10, false).with_parent(Some(b.id.clone()));
        let d = user("d").with_parent(Some(c.id.clone()));
        for e in [&a, &b, &c, &d] {
            s.commit(tx(vec![Write::entry(e.clone())])).unwrap();
        }
        let scan = BranchScan {
            start: Some(d.id.clone()),
            stop_at_type: Some("compaction".into()),
            order: Order::OldestFirst,
            ..Default::default()
        };
        let ids: Vec<_> = s.scan_branch(&scan).iter().map(|e| e.id.clone()).collect();
        assert_eq!(ids, vec![c.id.clone(), d.id.clone()]);

        // A filter applies after the stop.
        let only_messages = BranchScan {
            entry_type: Some("message".into()),
            ..scan.clone()
        };
        let ids: Vec<_> = s
            .scan_branch(&only_messages)
            .iter()
            .map(|e| e.id.clone())
            .collect();
        assert_eq!(ids, vec![d.id.clone()]);

        // No stop: the whole path.
        let whole = BranchScan {
            start: Some(d.id.clone()),
            ..Default::default()
        };
        assert_eq!(s.scan_branch(&whole).len(), 4);
    }

    #[test]
    fn stats_equal_the_ledger_sum_after_every_commit() {
        let mut s = Storage::memory("s1");
        for i in 0..3u64 {
            s.commit(tx(vec![
                Write::entry(user("m")),
                Write::usage(UsageRow::new(
                    crate::ids::UsageId::new(),
                    Usage {
                        input: 10 * (i + 1),
                        output: 1,
                        cached_input: 0,
                    },
                    None,
                )),
            ]))
            .unwrap();
            let sum = s.scan_usage(0).iter().fold(Usage::default(), |mut acc, r| {
                acc.add(&r.usage);
                acc
            });
            assert_eq!(s.stats().usage, sum);
            assert_eq!(s.stats().message_count, i + 1);
        }
    }

    #[test]
    fn deleting_every_register_leaves_a_valid_tree() {
        let mut s = Storage::memory("s1");
        let a = user("a");
        let b = user("b").with_parent(Some(a.id.clone()));
        s.commit(tx(vec![
            Write::entry(a),
            Write::set(Namespace::OpState, "op", json!({"phase": "x"})),
            Write::entry(b),
        ]))
        .unwrap();
        let keys: Vec<_> = s
            .all_registers()
            .map(|r| (r.namespace, r.key.clone()))
            .collect();
        for (ns, key) in keys {
            s.commit(tx(vec![Write::delete(ns, key)])).unwrap();
        }
        for entry in s.scan_entries(Order::OldestFirst) {
            let mut cursor = entry.parent_id.clone();
            while let Some(id) = cursor {
                cursor = s.entry(&id).expect("parent must exist").parent_id.clone();
            }
        }
    }
}
