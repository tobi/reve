//! Durable branch compaction.

use crate::records::{Entry, Record};
use crate::storage::{Storage, StorageError};
use serde_json::json;

#[derive(Debug, Clone)]
pub struct CompactionReport {
    pub removed_from_context: usize,
    pub summary_id: String,
}

pub fn compact(
    storage: &mut Storage,
    lane: &str,
    keep_recent: usize,
    summary: &str,
) -> Result<CompactionReport, StorageError> {
    let path = storage
        .path_entries(lane)
        .into_iter()
        .cloned()
        .collect::<Vec<_>>();
    if path.len() <= keep_recent {
        return Ok(CompactionReport {
            removed_from_context: 0,
            summary_id: path.first().map(|e| e.id.to_string()).unwrap_or_default(),
        });
    }
    let cut = path.len() - keep_recent;
    storage.append_record(Record::new(
        lane,
        "compaction_started",
        json!({ "keepRecent": keep_recent, "cut": cut }),
    ))?;
    let mut entry = Entry::custom(
        lane,
        "compaction_summary",
        json!({ "summary": summary, "firstKeptEntryId": path[cut].id }),
    );
    entry.parent_id = path[cut].parent_id.clone();
    let id = storage.append_entry(entry)?;
    storage.set_leaf(lane, Some(id.clone()))?;
    storage.append_record(Record::new(
        lane,
        "compaction_finished",
        json!({ "summaryEntryId": id, "removed": cut }),
    ))?;
    Ok(CompactionReport {
        removed_from_context: cut,
        summary_id: id.to_string(),
    })
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::records::MAIN_LANE;
    #[test]
    fn compaction_adds_a_summary_and_moves_the_leaf_atomically() {
        let mut s = Storage::memory("s");
        for i in 0..5 {
            s.append_entry(Entry::message(
                MAIN_LANE,
                json!({"role":"user", "content": format!("{i}")}),
            ))
            .unwrap();
        }
        let report = compact(&mut s, MAIN_LANE, 2, "old work summarized").unwrap();
        assert_eq!(report.removed_from_context, 3);
        assert_eq!(
            s.path_entries(MAIN_LANE)
                .last()
                .unwrap()
                .custom_type
                .as_deref(),
            Some("compaction_summary")
        );
        assert!(
            s.find_records(Some(MAIN_LANE))
                .iter()
                .any(|r| r.record_type == "compaction_finished")
        );
    }
    #[test]
    fn small_context_is_not_compacted() {
        let mut s = Storage::memory("s");
        s.append_entry(Entry::message(MAIN_LANE, json!({"role":"user"})))
            .unwrap();
        assert_eq!(
            compact(&mut s, MAIN_LANE, 3, "none")
                .unwrap()
                .removed_from_context,
            0
        );
    }
}
