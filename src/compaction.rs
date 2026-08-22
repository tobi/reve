//! Compaction preparation and the summary request.
//!
//! A compaction entry is a self-contained checkpoint (`docs/harness.md`
//! §2.1): its `summary` plus a complete `retainedTail` replace everything
//! before it in provider context. Preparation decides the split; generation
//! asks the model for the summary; the lane driver commits the entry and moves
//! the leaf. This module is pure: no storage, no effects.

use serde_json::Value;

use crate::entry::Entry;
use crate::model::{Request, ToolSchema};
use crate::session::estimate_tokens;
use crate::state::{CompactionPreparation, CompactionSettings};

/// Whether the next request would cross the threshold.
pub fn over_threshold(tokens: u64, context_window: u64, settings: &CompactionSettings) -> bool {
    settings.enabled && tokens.saturating_add(settings.reserve_tokens) > context_window
}

/// Split the projected context into what is summarised and what is kept.
///
/// The retained tail is the newest `keep_recent_tokens` worth of messages,
/// widened backwards to the nearest user turn so a tool result never loses
/// the assistant call that asked for it. `None` when there is nothing worth
/// summarising — the tail would be the whole context.
pub fn prepare(context: &[Entry], settings: &CompactionSettings) -> Option<CompactionPreparation> {
    if context.len() < 2 {
        return None;
    }
    let tokens_before = estimate_tokens(context);
    // Find the tail start: walk back accumulating tokens.
    let mut budget = settings.keep_recent_tokens;
    let mut start = context.len();
    while start > 0 {
        let cost = estimate_tokens(&context[start - 1..start]);
        if cost > budget && start < context.len() {
            break;
        }
        budget = budget.saturating_sub(cost);
        start -= 1;
    }
    // Widen to a user turn so the tail is a coherent suffix.
    while start > 0 && start < context.len() && context[start].role() != Some("user") {
        start -= 1;
    }
    if start == 0 {
        return None;
    }
    let (head, tail) = context.split_at(start);
    let previous_summary = head.first().and_then(|e| {
        e.message_value()
            .and_then(|m| m.get("content"))
            .and_then(Value::as_str)
            .filter(|c| c.starts_with("<summary>"))
            .map(str::to_string)
    });
    Some(CompactionPreparation {
        messages_to_summarize: head
            .iter()
            .filter_map(|e| e.message_value().cloned())
            .collect(),
        retained_tail: tail
            .iter()
            .filter_map(|e| e.message_value().cloned())
            .collect(),
        tokens_before,
        previous_summary,
    })
}

pub const SUMMARY_SYSTEM: &str = "You are compacting a coding-agent conversation so it can \
continue in a smaller context. Write a faithful, dense summary of the conversation you are \
given: the user's goals, decisions taken, files and commands touched, what was learned, what \
is still open, and anything the assistant must remember to finish the work. Use plain prose \
and short lists. Do not invent detail and do not address the user.";

/// The request that produces the summary: the messages to summarise, then an
/// instruction turn.
pub fn summary_request<'a>(
    preparation: &CompactionPreparation,
    custom_instructions: Option<&str>,
    scratch: &'a mut Vec<Entry>,
) -> Request<'a> {
    scratch.clear();
    for message in &preparation.messages_to_summarize {
        scratch.push(Entry::message(message.clone()));
    }
    let mut instruction = String::from(
        "Summarise the conversation above for a continuation in a fresh context. \
         Be specific about file paths, commands, errors, and decisions.",
    );
    if let Some(extra) = custom_instructions.filter(|s| !s.trim().is_empty()) {
        instruction.push_str("\n\nAdditional instructions: ");
        instruction.push_str(extra);
    }
    scratch.push(Entry::message(
        serde_json::json!({"role": "user", "content": instruction}),
    ));
    Request {
        context: scratch.as_slice(),
        system: SUMMARY_SYSTEM,
        tools: &[] as &[ToolSchema],
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;

    fn user(text: &str) -> Entry {
        Entry::message(json!({"role": "user", "content": text}))
    }
    fn assistant(text: &str) -> Entry {
        Entry::message(
            json!({"role": "assistant", "content": [{"type": "text", "text": text}], "stopReason": "stop"}),
        )
    }

    #[test]
    fn the_tail_is_widened_to_a_user_turn_and_the_head_is_summarised() {
        let context = vec![
            user("first question"),
            assistant("first answer, which is fairly long to cost tokens ........................"),
            user("second question"),
            assistant("second answer ........................................................"),
        ];
        let settings = CompactionSettings {
            enabled: true,
            reserve_tokens: 0,
            keep_recent_tokens: 25,
        };
        let prep = prepare(&context, &settings).expect("something to summarise");
        assert_eq!(prep.retained_tail.len(), 2, "tail starts at a user turn");
        assert_eq!(prep.retained_tail[0]["content"], "second question");
        assert_eq!(prep.messages_to_summarize.len(), 2);
        assert!(prep.tokens_before > 0);
    }

    #[test]
    fn a_small_context_has_nothing_to_compact() {
        let context = vec![user("hi"), assistant("hello")];
        assert!(prepare(&context, &CompactionSettings::default()).is_none());
        assert!(prepare(&[], &CompactionSettings::default()).is_none());
    }

    #[test]
    fn threshold_respects_the_reserve() {
        let settings = CompactionSettings {
            enabled: true,
            reserve_tokens: 1_000,
            keep_recent_tokens: 10,
        };
        assert!(!over_threshold(8_000, 10_000, &settings));
        assert!(over_threshold(9_500, 10_000, &settings));
        let off = CompactionSettings {
            enabled: false,
            ..settings
        };
        assert!(!over_threshold(99_999, 10_000, &off));
    }

    #[test]
    fn the_summary_request_ends_with_the_instruction() {
        let prep = CompactionPreparation {
            messages_to_summarize: vec![json!({"role": "user", "content": "x"})],
            retained_tail: vec![],
            tokens_before: 1,
            previous_summary: None,
        };
        let mut scratch = Vec::new();
        let request = summary_request(&prep, Some("focus on tests"), &mut scratch);
        assert_eq!(request.context.len(), 2);
        assert_eq!(request.system, SUMMARY_SYSTEM);
        assert!(
            request.context[1].message_value().unwrap()["content"]
                .as_str()
                .unwrap()
                .contains("focus on tests")
        );
    }
}
