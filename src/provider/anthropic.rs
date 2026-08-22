//! The Anthropic Messages API.
//!
//! The stream is a sequence of content blocks, each opened by
//! `content_block_start`, filled by `content_block_delta`, and closed by
//! `content_block_stop`. Text blocks deliver `text_delta`; tool blocks deliver
//! `input_json_delta`, whose payload is a *partial JSON string* that only
//! parses once the block closes.
//!
//! Two details the docs call out and that are easy to get wrong:
//!
//! * usage on `message_delta` is **cumulative**, not incremental, so it is
//!   assigned rather than added;
//! * new event types will appear, so unknown ones are skipped.

use serde_json::{Map, Value, json};

use super::config::Resolved;
use super::sse;
use crate::model::{Assistant, StopReason, ToolCall, ToolSchema, Usage};

/// One open content block.
#[derive(Debug)]
enum Block {
    Text,
    /// A tool call, with its arguments arriving as partial JSON.
    Tool {
        call: ToolCall,
        partial: String,
    },
    /// Thinking, or anything else we do not surface.
    Ignored,
}

#[derive(Debug, Default)]
pub struct StreamState {
    text: String,
    blocks: Vec<Block>,
    calls: Vec<ToolCall>,
    usage: Usage,
    stop: StopReason,
    failure: Option<String>,
}

impl StreamState {
    pub fn new() -> Self {
        Self::default()
    }

    /// Apply one event; returns any newly arrived text.
    pub fn apply(&mut self, event: &sse::Event) -> Option<String> {
        let payload: Value = serde_json::from_str(&event.data).ok()?;
        let kind = payload
            .get("type")
            .and_then(Value::as_str)
            .or(event.name.as_deref())?;

        match kind {
            "message_start" => {
                if let Some(usage) = payload.get("message").and_then(|m| m.get("usage")) {
                    self.usage = read_usage(usage, self.usage);
                }
            }
            "content_block_start" => {
                let index = payload.get("index").and_then(Value::as_u64).unwrap_or(0) as usize;
                let block = payload.get("content_block");
                let new = match block.and_then(|b| b.get("type")).and_then(Value::as_str) {
                    Some("text") => Block::Text,
                    Some("tool_use") => Block::Tool {
                        call: ToolCall {
                            id: block
                                .and_then(|b| b.get("id"))
                                .and_then(Value::as_str)
                                .unwrap_or_default()
                                .to_string(),
                            name: block
                                .and_then(|b| b.get("name"))
                                .and_then(Value::as_str)
                                .unwrap_or_default()
                                .to_string(),
                            arguments: Map::new(),
                        },
                        partial: String::new(),
                    },
                    _ => Block::Ignored,
                };
                // Blocks are addressed by index, and the indices are dense but
                // need not arrive in order.
                while self.blocks.len() <= index {
                    self.blocks.push(Block::Ignored);
                }
                self.blocks[index] = new;
            }
            "content_block_delta" => {
                let index = payload.get("index").and_then(Value::as_u64).unwrap_or(0) as usize;
                let delta = payload.get("delta")?;
                match delta.get("type").and_then(Value::as_str) {
                    Some("text_delta") => {
                        let text = delta.get("text")?.as_str()?.to_string();
                        self.text.push_str(&text);
                        return Some(text);
                    }
                    Some("input_json_delta") => {
                        let chunk = delta.get("partial_json").and_then(Value::as_str)?;
                        if let Some(Block::Tool { partial, .. }) = self.blocks.get_mut(index) {
                            partial.push_str(chunk);
                        }
                    }
                    // thinking_delta and signature_delta are not surfaced.
                    _ => {}
                }
            }
            "content_block_stop" => {
                let index = payload.get("index").and_then(Value::as_u64).unwrap_or(0) as usize;
                if let Some(block) = self.blocks.get_mut(index)
                    && let Block::Tool { call, partial } = block
                {
                    let raw = if partial.trim().is_empty() {
                        "{}"
                    } else {
                        partial.as_str()
                    };
                    call.arguments = serde_json::from_str::<Value>(raw)
                        .ok()
                        .and_then(|v| v.as_object().cloned())
                        .unwrap_or_default();
                    self.calls.push(call.clone());
                    *block = Block::Ignored;
                }
            }
            "message_delta" => {
                if let Some(reason) = payload
                    .get("delta")
                    .and_then(|d| d.get("stop_reason"))
                    .and_then(Value::as_str)
                {
                    self.stop = match reason {
                        "tool_use" => StopReason::ToolUse,
                        _ => StopReason::Stop,
                    };
                }
                if let Some(usage) = payload.get("usage") {
                    // Cumulative: assign, never accumulate.
                    self.usage = read_usage(usage, self.usage);
                }
            }
            "error" => {
                self.failure = payload
                    .get("error")
                    .and_then(|e| e.get("message"))
                    .and_then(Value::as_str)
                    .map(str::to_string)
                    .or_else(|| Some(event.data.clone()));
            }
            _ => {}
        }
        None
    }

    pub fn finish(self) -> Result<Assistant, String> {
        if let Some(failure) = self.failure {
            return Err(failure);
        }
        // Trust the model's own stop_reason, but a call with no reason is still
        // a call.
        let stop_reason = if !self.calls.is_empty() {
            StopReason::ToolUse
        } else {
            self.stop
        };
        Ok(Assistant {
            text: self.text,
            tool_calls: self.calls,
            stop_reason,
            usage: self.usage,
            error_message: None,
        })
    }
}

/// Fields are reported piecemeal across events, so anything absent keeps its
/// previous value instead of resetting to zero.
fn read_usage(usage: &Value, previous: Usage) -> Usage {
    let get = |key: &str, fallback: u64| usage.get(key).and_then(Value::as_u64).unwrap_or(fallback);
    let cache_read = get("cache_read_input_tokens", 0);
    Usage {
        input: get("input_tokens", previous.input),
        output: get("output_tokens", previous.output),
        cached_input: if cache_read > 0 {
            cache_read
        } else {
            previous.cached_input
        },
    }
}

pub fn build_body(
    resolved: &Resolved,
    system: &str,
    messages: Vec<Value>,
    tools: &[ToolSchema],
) -> Value {
    let mut body = json!({
        "model": resolved.model.id,
        "messages": messages,
        "stream": true,
    });
    let map = body.as_object_mut().expect("object");
    // Anthropic always calls it max_tokens, but the name still comes from the
    // compat block so there is exactly one place it is decided.
    map.insert(
        resolved.compat.max_tokens_field.clone(),
        json!(resolved.model.max_tokens),
    );
    if !system.is_empty() {
        map.insert("system".into(), json!(system));
    }
    if resolved.model.reasoning && resolved.compat.supports_reasoning_effort {
        map.insert(
            "thinking".into(),
            json!({ "type": "enabled", "budget_tokens": resolved.model.max_tokens / 2 }),
        );
    }
    if !tools.is_empty() {
        map.insert(
            "tools".into(),
            Value::Array(
                tools
                    .iter()
                    .map(|t| {
                        json!({
                            "name": t.name,
                            "description": t.description,
                            "input_schema": t.schema,
                        })
                    })
                    .collect(),
            ),
        );
    }
    body
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::provider::config::{Api, Compat, ModelSpec};

    fn drive(stream: &str) -> (String, Assistant) {
        let mut decoder = sse::Decoder::new();
        let mut state = StreamState::new();
        let mut streamed = String::new();
        for event in decoder.push(stream) {
            if let Some(delta) = state.apply(&event) {
                streamed.push_str(&delta);
            }
        }
        (streamed, state.finish().expect("a good stream"))
    }

    /// Straight from the streaming docs.
    #[test]
    fn text_blocks_stream_and_accumulate() {
        let stream = "\
event: message_start\ndata: {\"type\":\"message_start\",\"message\":{\"usage\":{\"input_tokens\":25}}}\n\n\
event: content_block_start\ndata: {\"type\":\"content_block_start\",\"index\":0,\"content_block\":{\"type\":\"text\",\"text\":\"\"}}\n\n\
event: content_block_delta\ndata: {\"type\":\"content_block_delta\",\"index\":0,\"delta\":{\"type\":\"text_delta\",\"text\":\"ello frien\"}}\n\n\
event: content_block_delta\ndata: {\"type\":\"content_block_delta\",\"index\":0,\"delta\":{\"type\":\"text_delta\",\"text\":\"d\"}}\n\n\
event: content_block_stop\ndata: {\"type\":\"content_block_stop\",\"index\":0}\n\n\
event: message_delta\ndata: {\"type\":\"message_delta\",\"delta\":{\"stop_reason\":\"end_turn\"},\"usage\":{\"output_tokens\":15}}\n\n\
event: message_stop\ndata: {\"type\":\"message_stop\"}\n\n";
        let (streamed, turn) = drive(stream);
        assert_eq!(streamed, "ello friend");
        assert_eq!(turn.text, "ello friend");
        assert_eq!(turn.stop_reason, StopReason::Stop);
        assert_eq!(turn.usage.input, 25);
        assert_eq!(turn.usage.output, 15);
    }

    #[test]
    fn a_tool_block_parses_only_once_it_closes() {
        let stream = "\
event: content_block_start\ndata: {\"type\":\"content_block_start\",\"index\":1,\"content_block\":{\"type\":\"tool_use\",\"id\":\"toolu_1\",\"name\":\"get_weather\"}}\n\n\
event: content_block_delta\ndata: {\"type\":\"content_block_delta\",\"index\":1,\"delta\":{\"type\":\"input_json_delta\",\"partial_json\":\"{\\\"location\\\": \\\"San Fra\"}}\n\n\
event: content_block_delta\ndata: {\"type\":\"content_block_delta\",\"index\":1,\"delta\":{\"type\":\"input_json_delta\",\"partial_json\":\"ncisco\\\"}\"}}\n\n\
event: content_block_stop\ndata: {\"type\":\"content_block_stop\",\"index\":1}\n\n\
event: message_delta\ndata: {\"type\":\"message_delta\",\"delta\":{\"stop_reason\":\"tool_use\"}}\n\n";
        let (_, turn) = drive(stream);
        assert_eq!(turn.stop_reason, StopReason::ToolUse);
        assert_eq!(turn.tool_calls.len(), 1);
        let call = &turn.tool_calls[0];
        assert_eq!(call.id, "toolu_1");
        assert_eq!(call.name, "get_weather");
        assert_eq!(call.arguments.get("location").unwrap(), "San Francisco");
    }

    #[test]
    fn usage_on_message_delta_is_cumulative_not_additive() {
        // The docs warn about this: adding these up would double-count.
        let stream = "\
event: message_start\ndata: {\"type\":\"message_start\",\"message\":{\"usage\":{\"input_tokens\":100,\"output_tokens\":1}}}\n\n\
event: message_delta\ndata: {\"type\":\"message_delta\",\"usage\":{\"output_tokens\":10}}\n\n\
event: message_delta\ndata: {\"type\":\"message_delta\",\"usage\":{\"output_tokens\":25}}\n\n";
        let (_, turn) = drive(stream);
        assert_eq!(turn.usage.output, 25, "the last value wins");
        assert_eq!(
            turn.usage.input, 100,
            "and a field absent from a later event is kept"
        );
    }

    #[test]
    fn a_cache_read_is_recorded_for_the_cache_miss_warning() {
        let stream = "event: message_start\ndata: {\"type\":\"message_start\",\"message\":\
{\"usage\":{\"input_tokens\":1000,\"cache_read_input_tokens\":900}}}\n\n";
        let (_, turn) = drive(stream);
        assert_eq!(turn.usage.cached_input, 900);
    }

    #[test]
    fn thinking_deltas_are_not_surfaced_as_answer_text() {
        let stream = "\
event: content_block_start\ndata: {\"type\":\"content_block_start\",\"index\":0,\"content_block\":{\"type\":\"thinking\"}}\n\n\
event: content_block_delta\ndata: {\"type\":\"content_block_delta\",\"index\":0,\"delta\":{\"type\":\"thinking_delta\",\"thinking\":\"hmm\"}}\n\n\
event: content_block_delta\ndata: {\"type\":\"content_block_delta\",\"index\":0,\"delta\":{\"type\":\"signature_delta\",\"signature\":\"abc\"}}\n\n\
event: content_block_stop\ndata: {\"type\":\"content_block_stop\",\"index\":0}\n\n";
        let (streamed, turn) = drive(stream);
        assert!(streamed.is_empty(), "{streamed:?}");
        assert!(turn.text.is_empty(), "the raw trace is not the answer");
    }

    #[test]
    fn text_and_a_tool_call_in_one_message_both_survive() {
        let stream = "\
event: content_block_start\ndata: {\"type\":\"content_block_start\",\"index\":0,\"content_block\":{\"type\":\"text\"}}\n\n\
event: content_block_delta\ndata: {\"type\":\"content_block_delta\",\"index\":0,\"delta\":{\"type\":\"text_delta\",\"text\":\"Looking it up.\"}}\n\n\
event: content_block_stop\ndata: {\"type\":\"content_block_stop\",\"index\":0}\n\n\
event: content_block_start\ndata: {\"type\":\"content_block_start\",\"index\":1,\"content_block\":{\"type\":\"tool_use\",\"id\":\"t1\",\"name\":\"bash\"}}\n\n\
event: content_block_delta\ndata: {\"type\":\"content_block_delta\",\"index\":1,\"delta\":{\"type\":\"input_json_delta\",\"partial_json\":\"{}\"}}\n\n\
event: content_block_stop\ndata: {\"type\":\"content_block_stop\",\"index\":1}\n\n";
        let (_, turn) = drive(stream);
        assert_eq!(turn.text, "Looking it up.");
        assert_eq!(turn.tool_calls.len(), 1);
        assert_eq!(turn.stop_reason, StopReason::ToolUse);
    }

    #[test]
    fn ping_and_unknown_events_are_skipped() {
        let stream = "\
event: ping\ndata: {\"type\":\"ping\"}\n\n\
event: some_future_event\ndata: {\"type\":\"some_future_event\"}\n\n\
event: content_block_start\ndata: {\"type\":\"content_block_start\",\"index\":0,\"content_block\":{\"type\":\"text\"}}\n\n\
event: content_block_delta\ndata: {\"type\":\"content_block_delta\",\"index\":0,\"delta\":{\"type\":\"text_delta\",\"text\":\"ok\"}}\n\n";
        let (streamed, _) = drive(stream);
        assert_eq!(streamed, "ok");
    }

    #[test]
    fn an_overloaded_error_fails_the_turn_with_its_message() {
        let mut decoder = sse::Decoder::new();
        let mut state = StreamState::new();
        let raw = "event: error\ndata: {\"type\":\"error\",\"error\":\
{\"type\":\"overloaded_error\",\"message\":\"Overloaded\"}}\n\n";
        for event in decoder.push(raw) {
            state.apply(&event);
        }
        assert_eq!(state.finish().unwrap_err(), "Overloaded");
    }

    fn resolved(reasoning: bool) -> Resolved {
        Resolved {
            provider: "anthropic".into(),
            api: Api::AnthropicMessages,
            base_url: "https://api.anthropic.com".into(),
            api_key: Some("k".into()),
            model: ModelSpec {
                id: "claude-opus-5".into(),
                reasoning,
                context_window: 200_000,
                max_tokens: 8192,
            },
            compat: Compat {
                max_tokens_field: "max_tokens".into(),
                ..Default::default()
            },
        }
    }

    #[test]
    fn the_body_uses_anthropics_shapes() {
        let tools = vec![ToolSchema {
            name: "bash".into(),
            description: "run".into(),
            schema: json!({"type": "object"}),
        }];
        let body = build_body(&resolved(false), "be terse", vec![], &tools);
        assert_eq!(body["max_tokens"], 8192);
        assert_eq!(
            body["system"], "be terse",
            "system is top-level, not a message"
        );
        assert_eq!(body["tools"][0]["input_schema"]["type"], "object");
        assert!(
            body["tools"][0].get("parameters").is_none(),
            "that is OpenAI's spelling"
        );
        assert_eq!(body["stream"], true);
    }

    #[test]
    fn a_reasoning_model_gets_a_thinking_budget() {
        let body = build_body(&resolved(true), "", vec![], &[]);
        assert_eq!(body["thinking"]["type"], "enabled");
        assert_eq!(body["thinking"]["budget_tokens"], 4096);
    }
}
