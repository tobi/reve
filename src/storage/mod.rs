//! Session state: entries, records, lanes, facts, and one monotonic `seq`.
//!
//! This type is deliberately *not* thread-safe and deliberately not shared.
//! Exactly one task owns it (see [`crate::store`]), which is how leve gets the
//! single-writer guarantee structurally instead of by convention.

pub mod jsonl;

use std::collections::HashMap;

use serde_json::{Map, Value};
use thiserror::Error;

use crate::ids::{EntryId, RecordId};
use crate::records::{Entry, Header, Line, MAIN_LANE, Record};

#[derive(Debug, Error)]
pub enum StorageError {
    #[error("io error: {0}")]
    Io(#[from] std::io::Error),
    /// A malformed line that is *not* the last one. A crash can truncate the
    /// tail; it cannot corrupt the middle, so this is real damage and we refuse
    /// to open rather than silently drop history.
    #[error("corrupt session at line {line}: {source}")]
    Corrupt {
        line: usize,
        #[source]
        source: serde_json::Error,
    },
    #[error("unsupported session format version {0} (this build reads {1})")]
    Version(u32, u32),
    #[error("no such entry {0}")]
    NoSuchEntry(EntryId),
}

pub type Result<T, E = StorageError> = std::result::Result<T, E>;

/// Where a lane currently is in the tree.
#[derive(Debug, Clone, Default)]
pub struct LaneState {
    pub leaf: Option<EntryId>,
}

/// Ordering for [`Storage::find_entries`].
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Order {
    OldestFirst,
    NewestFirst,
}

#[derive(Debug)]
pub struct Storage {
    header: Header,
    seq: u64,
    order: Vec<EntryId>,
    entries: HashMap<EntryId, Entry>,
    records: Vec<Record>,
    lanes: HashMap<String, LaneState>,
    facts: Map<String, Value>,
    sink: Option<jsonl::Sink>,
}

impl Storage {
    /// An in-memory session. Nothing is written anywhere.
    pub fn memory(id: impl Into<String>) -> Self {
        Self::with_header(Header::new(id, None), None)
    }

    pub(crate) fn with_sink(header: Header, sink: jsonl::Sink) -> Self {
        Self::with_header(header, Some(sink))
    }

    /// Write the header line of a brand-new session file.
    pub(crate) fn write_header(&mut self) -> Result<()> {
        let header = self.header.clone();
        self.write(&Line::Header(header))
    }

    fn with_header(header: Header, sink: Option<jsonl::Sink>) -> Self {
        let mut lanes = HashMap::new();
        lanes.insert(MAIN_LANE.to_string(), LaneState::default());
        Self {
            header,
            seq: 0,
            order: Vec::new(),
            entries: HashMap::new(),
            records: Vec::new(),
            lanes,
            facts: Map::new(),
            sink,
        }
    }

    pub fn header(&self) -> &Header {
        &self.header
    }

    pub fn seq(&self) -> u64 {
        self.seq
    }

    fn next_seq(&mut self) -> u64 {
        self.seq += 1;
        self.seq
    }

    // ── entries ──────────────────────────────────────────────────────────

    /// Append an entry, chaining it to its lane's current leaf and advancing
    /// that leaf. An explicit `parent_id` wins, which is how a branch is made.
    pub fn append_entry(&mut self, mut entry: Entry) -> Result<EntryId> {
        if entry.parent_id.is_none() {
            entry.parent_id = self.leaf(&entry.lane);
        }
        entry.seq = self.next_seq();
        let id = entry.id.clone();

        self.write(&Line::Entry(entry.clone()))?;
        self.lanes.entry(entry.lane.clone()).or_default().leaf = Some(id.clone());
        self.order.push(id.clone());
        self.entries.insert(id.clone(), entry);
        Ok(id)
    }

    /// The durability rule's other half: appending a provisioned id twice is a
    /// no-op rather than a duplicate. Recovery re-runs freely.
    pub fn append_entry_if_missing(&mut self, entry: Entry) -> Result<EntryId> {
        if self.entries.contains_key(&entry.id) {
            return Ok(entry.id);
        }
        self.append_entry(entry)
    }

    pub fn entry(&self, id: &EntryId) -> Option<&Entry> {
        self.entries.get(id)
    }

    pub fn find_entries(&self, lane: Option<&str>, order: Order) -> Vec<&Entry> {
        let mut found: Vec<&Entry> = self
            .order
            .iter()
            .filter_map(|id| self.entries.get(id))
            .filter(|e| lane.is_none_or(|l| e.lane == l))
            .collect();
        if order == Order::NewestFirst {
            found.reverse();
        }
        found
    }

    /// The conversation as the model sees it: leaf back to root, then reversed.
    /// Entries on other branches are invisible here — that is the point.
    pub fn path_entries(&self, lane: &str) -> Vec<&Entry> {
        let mut path = Vec::new();
        let mut cursor = self.lanes.get(lane).and_then(|l| l.leaf.clone());
        while let Some(id) = cursor {
            let Some(entry) = self.entries.get(&id) else {
                break;
            };
            path.push(entry);
            cursor = entry.parent_id.clone();
        }
        path.reverse();
        path
    }

    // ── records ──────────────────────────────────────────────────────────

    pub fn append_record(&mut self, mut record: Record) -> Result<RecordId> {
        record.seq = self.next_seq();
        let id = record.id.clone();
        self.write(&Line::Record(record.clone()))?;
        self.records.push(record);
        Ok(id)
    }

    pub fn find_records(&self, lane: Option<&str>) -> Vec<&Record> {
        self.records
            .iter()
            .filter(|r| lane.is_none_or(|l| r.lane == l))
            .collect()
    }

    // ── lanes and facts ──────────────────────────────────────────────────

    pub fn lanes(&self) -> Vec<String> {
        let mut names: Vec<String> = self.lanes.keys().cloned().collect();
        names.sort();
        names
    }

    pub fn leaf(&self, lane: &str) -> Option<EntryId> {
        self.lanes.get(lane).and_then(|l| l.leaf.clone())
    }

    /// Move a lane's leaf. Compaction uses this to swap in a summarised head
    /// without rewriting a single historical entry.
    pub fn set_leaf(&mut self, lane: &str, leaf: Option<EntryId>) -> Result<()> {
        if let Some(id) = &leaf
            && !self.entries.contains_key(id)
        {
            return Err(StorageError::NoSuchEntry(id.clone()));
        }
        let seq = self.next_seq();
        let record = {
            let mut r = Record::new(
                lane,
                "lane_leaf_set",
                serde_json::json!({ "leafId": leaf.as_ref().map(|l| l.0.clone()) }),
            );
            r.seq = seq;
            r
        };
        self.write(&Line::Record(record.clone()))?;
        self.records.push(record);
        self.lanes.entry(lane.to_string()).or_default().leaf = leaf;
        Ok(())
    }

    pub fn fact(&self, key: &str) -> Option<&Value> {
        self.facts.get(key)
    }

    pub fn set_fact(&mut self, key: impl Into<String>, value: Value) -> Result<()> {
        let key = key.into();
        let seq = self.next_seq();
        let mut record = Record::new(
            MAIN_LANE,
            "fact_set",
            serde_json::json!({ "key": key, "value": value }),
        );
        record.seq = seq;
        self.write(&Line::Record(record.clone()))?;
        self.records.push(record);
        self.facts.insert(key, value);
        Ok(())
    }

    fn write(&mut self, line: &Line) -> Result<()> {
        if let Some(sink) = self.sink.as_mut() {
            sink.append(line)?;
        }
        Ok(())
    }

    /// Replay a line during load. Unlike the append path this assigns nothing:
    /// seq, parent, and leaf all come from the file.
    pub(crate) fn replay_line(&mut self, line: Line) {
        match line {
            Line::Header(header) => self.header = header,
            Line::Entry(entry) => {
                self.seq = self.seq.max(entry.seq);
                self.lanes.entry(entry.lane.clone()).or_default().leaf = Some(entry.id.clone());
                self.order.push(entry.id.clone());
                self.entries.insert(entry.id.clone(), entry);
            }
            Line::Record(record) => {
                self.seq = self.seq.max(record.seq);
                self.lanes.entry(record.lane.clone()).or_default();
                match record.record_type.as_str() {
                    "lane_leaf_set" => {
                        let leaf = record
                            .get("leafId")
                            .and_then(|v| v.as_str())
                            .map(EntryId::from);
                        self.lanes.entry(record.lane.clone()).or_default().leaf = leaf;
                    }
                    "fact_set" => {
                        if let Some(key) = record.str("key") {
                            let value = record.get("value").cloned().unwrap_or(Value::Null);
                            self.facts.insert(key.to_string(), value);
                        }
                    }
                    _ => {}
                }
                self.records.push(record);
            }
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;

    fn user(text: &str) -> Entry {
        Entry::message(MAIN_LANE, json!({"role": "user", "content": text}))
    }

    #[test]
    fn entries_chain_into_a_tree_and_advance_the_leaf() {
        let mut s = Storage::memory("s1");
        let a = s.append_entry(user("one")).unwrap();
        let b = s.append_entry(user("two")).unwrap();
        assert_eq!(s.leaf(MAIN_LANE), Some(b.clone()));
        assert_eq!(s.entry(&b).unwrap().parent_id, Some(a.clone()));
        assert_eq!(s.entry(&a).unwrap().parent_id, None);
        let path: Vec<_> = s
            .path_entries(MAIN_LANE)
            .iter()
            .map(|e| e.id.clone())
            .collect();
        assert_eq!(path, vec![a, b], "path runs oldest -> newest");
    }

    #[test]
    fn seq_is_shared_and_monotonic_across_entries_and_records() {
        let mut s = Storage::memory("s1");
        s.append_entry(user("one")).unwrap();
        s.append_record(Record::new(MAIN_LANE, "operation_started", json!({})))
            .unwrap();
        s.append_entry(user("two")).unwrap();
        assert_eq!(s.seq(), 3);
        let seqs: Vec<u64> = s
            .find_entries(None, Order::OldestFirst)
            .iter()
            .map(|e| e.seq)
            .collect();
        assert_eq!(seqs, vec![1, 3]);
    }

    #[test]
    fn a_branch_keeps_the_other_side_out_of_the_path() {
        let mut s = Storage::memory("s1");
        let a = s.append_entry(user("root")).unwrap();
        s.append_entry(user("main line")).unwrap();
        // Branch from `a` rather than the current leaf.
        let mut side = user("side line");
        side.parent_id = Some(a.clone());
        let side_id = s.append_entry(side).unwrap();
        assert_eq!(s.leaf(MAIN_LANE), Some(side_id.clone()));
        let path: Vec<_> = s
            .path_entries(MAIN_LANE)
            .iter()
            .map(|e| e.id.clone())
            .collect();
        assert_eq!(path, vec![a, side_id], "the abandoned branch is invisible");
        assert_eq!(
            s.find_entries(None, Order::OldestFirst).len(),
            3,
            "but nothing was deleted"
        );
    }

    #[test]
    fn provisioned_ids_can_be_appended_twice_without_duplicating() {
        let mut s = Storage::memory("s1");
        let entry = user("result");
        let id = entry.id.clone();
        s.append_entry_if_missing(entry.clone()).unwrap();
        s.append_entry_if_missing(entry).unwrap();
        assert_eq!(
            s.find_entries(None, Order::OldestFirst).len(),
            1,
            "recovery is idempotent"
        );
        assert_eq!(s.leaf(MAIN_LANE), Some(id));
    }

    #[test]
    fn deleting_every_record_leaves_a_valid_tree() {
        let mut s = Storage::memory("s1");
        s.append_entry(user("one")).unwrap();
        s.append_record(Record::new(MAIN_LANE, "tool_started", json!({})))
            .unwrap();
        s.append_entry(user("two")).unwrap();
        // Every entry still chains to a root without consulting any record.
        for entry in s.find_entries(None, Order::OldestFirst) {
            let mut cursor = entry.parent_id.clone();
            let mut hops = 0;
            while let Some(id) = cursor {
                cursor = s.entry(&id).expect("parent must exist").parent_id.clone();
                hops += 1;
                assert!(hops < 100, "parent chain must terminate");
            }
        }
    }

    #[test]
    fn setting_a_leaf_to_an_unknown_entry_is_refused() {
        let mut s = Storage::memory("s1");
        let err = s
            .set_leaf(MAIN_LANE, Some(EntryId::from("e_nope")))
            .unwrap_err();
        assert!(matches!(err, StorageError::NoSuchEntry(_)), "got {err}");
    }

    #[test]
    fn lanes_are_independent() {
        let mut s = Storage::memory("s1");
        s.append_entry(user("main")).unwrap();
        let hb = s
            .append_entry(Entry::message("heartbeat", json!({"role": "user"})))
            .unwrap();
        assert_eq!(s.leaf("heartbeat"), Some(hb));
        assert_eq!(
            s.path_entries("heartbeat").len(),
            1,
            "lanes do not share a chain"
        );
        assert_eq!(s.lanes(), vec!["heartbeat".to_string(), "main".to_string()]);
    }

    #[test]
    fn facts_survive_as_records() {
        let mut s = Storage::memory("s1");
        s.set_fact("name", json!("parity")).unwrap();
        assert_eq!(s.fact("name").unwrap(), "parity");
        assert_eq!(s.find_records(None).len(), 1);
    }
}
