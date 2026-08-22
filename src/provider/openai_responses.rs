//! The OpenAI Responses API.
//!
//! Only the streaming path is implemented, because that is the one reve uses:
//! text arrives as `response.output_text.delta`, tool calls are announced by
//! `response.output_item.added` and then filled in by
//! `response.function_call_arguments.delta`, and `response.completed` carries
//! the usage.
//!
//! Unknown event types are ignored on purpose — the vendor adds them, and an
//! agent that fell over because a new event appeared would be worse than one
//! that skips it.

use serde_json::{Map, Value, json};

use super::config::Resolved;
use super::sse;
use crate::model::{Assistant, StopReason, ToolCall, ToolSchema, Usage};

/// Accumulates a streamed response.
///
/// Separated from the HTTP so it can be driven by recorded bytes: the wire
/// format is where the bugs are, and it should be testable without a network
/// or a key.
#[derive(Debug, Default)]
pub struct StreamState {
    text: String,
    /// Keyed by item id, because argument deltas arrive by item and several
    /// calls can be open at once.
    calls: Vec<(String, ToolCall)>,
    /// Argument JSON as it streams in, one buffer per open call.
    partial: Vec<String>,
    usage: Usage,
    failure: Option<String>,
}

impl StreamState {
    pub fn new() -> Self {
        Self::default()
    }

    /// Apply one event; returns any newly arrived text.
    pub fn apply(&mut self, event: &sse::Event) -> Option<String> {
        let payload: Value = serde_json::from_str(&event.data).ok()?;
        let kind = event
            .name
            .as_deref()
            .or_else(|| payload.get("type").and_then(Value::as_str))?;

        match kind {
            "response.output_text.delta" => {
                let delta = payload.get("delta")?.as_str()?.to_string();
                self.text.push_str(&delta);
                return Some(delta);
            }
            "response.output_item.added" => {
                let item = payload.get("item")?;
                if item.get("type").and_then(Value::as_str) == Some("function_call") {
                    let id = item.get("id").and_then(Value::as_str).unwrap_or_default();
                    self.calls.push((
                        id.to_string(),
                        ToolCall {
                            id: item
                                .get("call_id")
                                .and_then(Value::as_str)
                                .unwrap_or(id)
                                .to_string(),
                            name: item
                                .get("name")
                                .and_then(Value::as_str)
                                .unwrap_or_default()
                                .to_string(),
                            arguments: Map::new(),
                        },
                    ));
                    // Arguments arrive as a partial JSON string; parked here
                    // until the call is done.
                    self.partial.push(String::new());
                }
            }
            "response.function_call_arguments.delta" => {
                let id = payload
                    .get("item_id")
                    .and_then(Value::as_str)
                    .unwrap_or_default();
                let delta = payload
                    .get("delta")
                    .and_then(Value::as_str)
                    .unwrap_or_default();
                if let Some(index) = self.calls.iter().position(|(k, _)| k == id) {
                    self.partial[index].push_str(delta);
                }
            }
            "response.completed" | "response.incomplete" => {
                if let Some(usage) = payload.get("response").and_then(|r| r.get("usage")) {
                    self.usage = read_usage(usage);
                }
            }
            "response.failed" => {
                self.failure = payload
                    .get("response")
                    .and_then(|r| r.get("error"))
                    .and_then(|e| e.get("message"))
                    .and_then(Value::as_str)
                    .map(str::to_string)
                    .or_else(|| Some("the provider reported a failed response".into()));
            }
            "error" => {
                self.failure = payload
                    .get("message")
                    .and_then(Value::as_str)
                    .map(str::to_string)
                    .or_else(|| Some(event.data.clone()));
            }
            _ => {}
        }
        None
    }

    /// The finished turn.
    pub fn finish(mut self) -> Result<Assistant, String> {
        if let Some(failure) = self.failure {
            return Err(failure);
        }
        for (index, (_, call)) in self.calls.iter_mut().enumerate() {
            let raw = self.partial.get(index).map(String::as_str).unwrap_or("{}");
            // A truncated stream can leave partial JSON; an empty object is a
            // better answer than failing the whole turn.
            call.arguments = serde_json::from_str::<Value>(if raw.is_empty() { "{}" } else { raw })
                .ok()
                .and_then(|v| v.as_object().cloned())
                .unwrap_or_default();
        }
        let tool_calls: Vec<ToolCall> = self.calls.into_iter().map(|(_, c)| c).collect();
        let stop_reason = if tool_calls.is_empty() {
            StopReason::Stop
        } else {
            StopReason::ToolUse
        };
        Ok(Assistant {
            text: self.text,
            tool_calls,
            stop_reason,
            usage: self.usage,
            error_message: None,
        })
    }
}

fn read_usage(usage: &Value) -> Usage {
    let get = |key: &str| usage.get(key).and_then(Value::as_u64).unwrap_or(0);
    Usage {
        input: get("input_tokens"),
        output: get("output_tokens"),
        cached_input: usage
            .get("input_tokens_details")
            .and_then(|d| d.get("cached_tokens"))
            .and_then(Value::as_u64)
            .unwrap_or(0),
    }
}

/// The request body.
pub fn build_body(
    resolved: &Resolved,
    system: &str,
    input: Vec<Value>,
    tools: &[ToolSchema],
) -> Value {
    let mut body = json!({
        "model": resolved.model.id,
        "input": input,
        "stream": true,
    });
    let map = body.as_object_mut().expect("object");

    // The cap is spelled differently by different endpoints, so the name comes
    // from the provider's compat block rather than from a conditional here.
    map.insert(
        resolved.compat.max_tokens_field.clone(),
        json!(resolved.model.max_tokens),
    );
    if !system.is_empty() {
        let role = if resolved.compat.supports_developer_role {
            "developer"
        } else {
            "system"
        };
        map.insert("instructions".into(), json!(system));
        let _ = role; // instructions supersedes a role message on this endpoint
    }
    if resolved.compat.supports_store {
        map.insert("store".into(), json!(false));
    }
    if resolved.model.reasoning && resolved.compat.supports_reasoning_effort {
        map.insert("reasoning".into(), json!({ "effort": "medium" }));
    }
    if !tools.is_empty() {
        map.insert(
            "tools".into(),
            Value::Array(
                tools
                    .iter()
                    .map(|t| {
                        json!({
                            "type": "function",
                            "name": t.name,
                            "description": t.description,
                            "parameters": t.schema,
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

    #[test]
    fn text_arrives_as_deltas_and_adds_up_to_the_message() {
        let stream = "\
event: response.output_text.delta\ndata: {\"item_id\":\"m\",\"delta\":\"Hello \"}\n\n\
event: response.output_text.delta\ndata: {\"item_id\":\"m\",\"delta\":\"world\"}\n\n\
event: response.completed\ndata: {\"response\":{\"usage\":{\"input_tokens\":10,\"output_tokens\":2}}}\n\n";
        let (streamed, turn) = drive(stream);
        assert_eq!(
            streamed, "Hello world",
            "every delta was surfaced as it arrived"
        );
        assert_eq!(turn.text, "Hello world");
        assert_eq!(turn.stop_reason, StopReason::Stop);
        assert_eq!(turn.usage.input, 10);
        assert_eq!(turn.usage.output, 2);
    }

    #[test]
    fn a_tool_call_is_assembled_from_its_argument_deltas() {
        let stream = "\
event: response.output_item.added\ndata: {\"item\":{\"type\":\"function_call\",\"id\":\"fc_1\",\"call_id\":\"call_1\",\"name\":\"bash\"}}\n\n\
event: response.function_call_arguments.delta\ndata: {\"item_id\":\"fc_1\",\"delta\":\"{\\\"command\\\":\"}\n\n\
event: response.function_call_arguments.delta\ndata: {\"item_id\":\"fc_1\",\"delta\":\"\\\"ls\\\"}\"}\n\n\
event: response.completed\ndata: {\"response\":{\"usage\":{}}}\n\n";
        let (_, turn) = drive(stream);
        assert_eq!(turn.stop_reason, StopReason::ToolUse);
        assert_eq!(turn.tool_calls.len(), 1);
        let call = &turn.tool_calls[0];
        assert_eq!(call.name, "bash");
        assert_eq!(
            call.id, "call_1",
            "the call_id is what results are keyed by"
        );
        assert_eq!(call.arguments.get("command").unwrap(), "ls");
    }

    #[test]
    fn two_concurrent_calls_do_not_mix_their_arguments() {
        let stream = "\
event: response.output_item.added\ndata: {\"item\":{\"type\":\"function_call\",\"id\":\"a\",\"call_id\":\"ca\",\"name\":\"read\"}}\n\n\
event: response.output_item.added\ndata: {\"item\":{\"type\":\"function_call\",\"id\":\"b\",\"call_id\":\"cb\",\"name\":\"write\"}}\n\n\
event: response.function_call_arguments.delta\ndata: {\"item_id\":\"a\",\"delta\":\"{\\\"path\\\":\\\"one\\\"}\"}\n\n\
event: response.function_call_arguments.delta\ndata: {\"item_id\":\"b\",\"delta\":\"{\\\"path\\\":\\\"two\\\"}\"}\n\n";
        let (_, turn) = drive(stream);
        assert_eq!(turn.tool_calls.len(), 2);
        assert_eq!(turn.tool_calls[0].arguments.get("path").unwrap(), "one");
        assert_eq!(turn.tool_calls[1].arguments.get("path").unwrap(), "two");
    }

    #[test]
    fn cached_input_is_read_for_the_cache_miss_warning() {
        let stream = "event: response.completed\ndata: {\"response\":{\"usage\":\
{\"input_tokens\":1000,\"output_tokens\":5,\"input_tokens_details\":{\"cached_tokens\":900}}}}\n\n";
        let (_, turn) = drive(stream);
        assert_eq!(turn.usage.cached_input, 900);
        assert!((turn.usage.uncached_fraction() - 0.1).abs() < 0.001);
    }

    #[test]
    fn an_error_event_fails_the_turn_with_its_message() {
        let mut decoder = sse::Decoder::new();
        let mut state = StreamState::new();
        for event in decoder.push("event: error\ndata: {\"message\":\"rate limited\"}\n\n") {
            state.apply(&event);
        }
        assert_eq!(state.finish().unwrap_err(), "rate limited");
    }

    #[test]
    fn unknown_events_are_skipped_rather_than_fatal() {
        let stream = "\
event: response.some_future_thing\ndata: {\"whatever\":1}\n\n\
event: response.output_text.delta\ndata: {\"delta\":\"ok\"}\n\n";
        let (streamed, turn) = drive(stream);
        assert_eq!(streamed, "ok");
        assert_eq!(turn.text, "ok");
    }

    #[test]
    fn truncated_tool_arguments_do_not_fail_the_whole_turn() {
        let stream = "\
event: response.output_item.added\ndata: {\"item\":{\"type\":\"function_call\",\"id\":\"a\",\"call_id\":\"ca\",\"name\":\"bash\"}}\n\n\
event: response.function_call_arguments.delta\ndata: {\"item_id\":\"a\",\"delta\":\"{\\\"command\\\":\"}\n\n";
        let (_, turn) = drive(stream);
        assert_eq!(turn.tool_calls.len(), 1, "the call is still reported");
        assert!(
            turn.tool_calls[0].arguments.is_empty(),
            "with what could be parsed"
        );
    }

    fn resolved(compat: Compat, reasoning: bool) -> Resolved {
        Resolved {
            provider: "openai".into(),
            api: Api::OpenaiResponses,
            base_url: "https://api.openai.com/v1".into(),
            api_key: Some("k".into()),
            model: ModelSpec {
                id: "gpt-5.6-luna".into(),
                reasoning,
                context_window: 200_000,
                max_tokens: 8192,
            },
            compat,
        }
    }

    #[test]
    fn the_token_cap_is_named_by_the_compat_block() {
        let body = build_body(&resolved(Compat::default(), false), "", vec![], &[]);
        assert_eq!(body["max_output_tokens"], 8192);

        let compat = Compat {
            max_tokens_field: "max_tokens".into(),
            ..Default::default()
        };
        let body = build_body(&resolved(compat, false), "", vec![], &[]);
        assert_eq!(
            body["max_tokens"], 8192,
            "an endpoint that spells it differently"
        );
    }

    #[test]
    fn quirks_are_omitted_when_the_provider_does_not_support_them() {
        let compat = Compat {
            supports_store: false,
            supports_reasoning_effort: false,
            ..Default::default()
        };
        let body = build_body(&resolved(compat, true), "", vec![], &[]);
        assert!(body.get("store").is_none(), "{body}");
        assert!(
            body.get("reasoning").is_none(),
            "a reasoning model, but not this endpoint"
        );
    }

    #[test]
    fn tools_become_function_schemas() {
        let tools = vec![ToolSchema {
            name: "bash".into(),
            description: "run a command".into(),
            schema: json!({"type": "object", "properties": {}}),
        }];
        let body = build_body(
            &resolved(Compat::default(), false),
            "be terse",
            vec![],
            &tools,
        );
        assert_eq!(body["instructions"], "be terse");
        assert_eq!(body["tools"][0]["type"], "function");
        assert_eq!(body["tools"][0]["name"], "bash");
        assert_eq!(body["stream"], true);
    }
}
