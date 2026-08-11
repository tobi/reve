//! The OpenAI Chat Completions API.
//!
//! Text and tool calls arrive as deltas under `choices[0].delta`. Tool-call
//! arguments are partial JSON strings and are assembled by their stable index.
//! Unknown fields are ignored so compatible proxies can add metadata freely.

use serde_json::{Value, json};

use super::config::Resolved;
use super::sse;
use crate::model::{Assistant, StopReason, ToolCall, ToolSchema, Usage};

#[derive(Debug, Default)]
struct PartialCall {
    id: String,
    name: String,
    arguments: String,
}

/// Accumulates one streamed chat completion.
#[derive(Debug, Default)]
pub struct StreamState {
    text: String,
    calls: Vec<PartialCall>,
    usage: Usage,
    stop: StopReason,
    failure: Option<String>,
}

impl StreamState {
    pub fn new() -> Self {
        Self::default()
    }

    /// Apply one SSE event and return newly arrived visible text.
    pub fn apply(&mut self, event: &sse::Event) -> Option<String> {
        if event.data.trim() == "[DONE]" {
            return None;
        }
        let payload: Value = serde_json::from_str(&event.data).ok()?;
        if let Some(message) = payload
            .get("error")
            .and_then(|error| error.get("message"))
            .and_then(Value::as_str)
        {
            self.failure = Some(message.to_string());
            return None;
        }
        if let Some(usage) = payload.get("usage").filter(|usage| !usage.is_null()) {
            self.usage = read_usage(usage);
        }

        let choice = payload.get("choices")?.as_array()?.first()?;
        if let Some(reason) = choice.get("finish_reason").and_then(Value::as_str) {
            self.stop = match reason {
                "tool_calls" | "function_call" => StopReason::ToolUse,
                _ => StopReason::Stop,
            };
        }
        let delta = choice.get("delta")?;
        if let Some(calls) = delta.get("tool_calls").and_then(Value::as_array) {
            for incoming in calls {
                let index = incoming.get("index").and_then(Value::as_u64).unwrap_or(0) as usize;
                while self.calls.len() <= index {
                    self.calls.push(PartialCall::default());
                }
                let call = &mut self.calls[index];
                if let Some(id) = incoming.get("id").and_then(Value::as_str)
                    && !id.is_empty()
                {
                    call.id = id.to_string();
                }
                if let Some(function) = incoming.get("function") {
                    if let Some(name) = function.get("name").and_then(Value::as_str)
                        && call.name.is_empty()
                    {
                        call.name = name.to_string();
                    }
                    if let Some(arguments) = function.get("arguments").and_then(Value::as_str) {
                        call.arguments.push_str(arguments);
                    }
                }
            }
        }
        let text = delta.get("content").and_then(Value::as_str)?;
        self.text.push_str(text);
        Some(text.to_string())
    }

    pub fn finish(self) -> Result<Assistant, String> {
        if let Some(failure) = self.failure {
            return Err(failure);
        }
        let tool_calls = self
            .calls
            .into_iter()
            .enumerate()
            .filter_map(|(index, call)| {
                if call.name.is_empty() {
                    return None;
                }
                Some(ToolCall {
                    id: if call.id.is_empty() {
                        format!("call_{index}")
                    } else {
                        call.id
                    },
                    name: call.name,
                    arguments: serde_json::from_str::<Value>(if call.arguments.trim().is_empty() {
                        "{}"
                    } else {
                        &call.arguments
                    })
                    .ok()
                    .and_then(|value| value.as_object().cloned())
                    .unwrap_or_default(),
                })
            })
            .collect::<Vec<_>>();
        let stop_reason = if tool_calls.is_empty() {
            self.stop
        } else {
            StopReason::ToolUse
        };
        Ok(Assistant {
            text: self.text,
            tool_calls,
            stop_reason,
            usage: self.usage,
        })
    }
}

fn read_usage(usage: &Value) -> Usage {
    let get = |key: &str| usage.get(key).and_then(Value::as_u64).unwrap_or(0) as u32;
    Usage {
        input: get("prompt_tokens"),
        output: get("completion_tokens"),
        cached_input: usage
            .get("prompt_tokens_details")
            .and_then(|details| details.get("cached_tokens"))
            .or_else(|| usage.get("prompt_cache_hit_tokens"))
            .and_then(Value::as_u64)
            .unwrap_or(0) as u32,
    }
}

/// Build the streaming Chat Completions request body.
pub fn build_body(
    resolved: &Resolved,
    system: &str,
    mut messages: Vec<Value>,
    tools: &[ToolSchema],
) -> Value {
    if !system.is_empty() {
        let role = if resolved.compat.supports_developer_role {
            "developer"
        } else {
            "system"
        };
        messages.insert(0, json!({ "role": role, "content": system }));
    }
    let mut body = json!({
        "model": resolved.model.id,
        "messages": messages,
        "stream": true,
        "stream_options": { "include_usage": true },
    });
    let map = body.as_object_mut().expect("object");
    map.insert(
        resolved.compat.max_tokens_field.clone(),
        json!(resolved.model.max_tokens),
    );
    if resolved.compat.supports_store {
        map.insert("store".into(), json!(false));
    }
    if resolved.model.reasoning && resolved.compat.supports_reasoning_effort {
        map.insert("reasoning_effort".into(), json!("medium"));
    }
    if !tools.is_empty() {
        map.insert(
            "tools".into(),
            Value::Array(
                tools
                    .iter()
                    .map(|tool| {
                        json!({
                            "type": "function",
                            "function": {
                                "name": tool.name,
                                "description": tool.description,
                                "parameters": tool.schema,
                            },
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

    fn resolved() -> Resolved {
        Resolved {
            provider: "proxy".into(),
            api: Api::OpenaiCompletions,
            base_url: "https://example.test/v1".into(),
            api_key: Some("key".into()),
            model: ModelSpec {
                id: "model".into(),
                reasoning: true,
                context_window: 100,
                max_tokens: 42,
            },
            compat: Compat {
                supports_developer_role: false,
                max_tokens_field: "max_completion_tokens".into(),
                ..Default::default()
            },
        }
    }

    #[test]
    fn request_uses_chat_messages_and_nested_tool_schemas() {
        let body = build_body(
            &resolved(),
            "be exact",
            vec![json!({"role": "user", "content": "hi"})],
            &[ToolSchema {
                name: "read".into(),
                description: "read a file".into(),
                schema: json!({"type": "object"}),
            }],
        );
        assert_eq!(body["messages"][0]["role"], "system");
        assert_eq!(body["messages"][1]["content"], "hi");
        assert_eq!(body["max_completion_tokens"], 42);
        assert_eq!(body["reasoning_effort"], "medium");
        assert_eq!(body["store"], false);
        assert_eq!(body["tools"][0]["function"]["name"], "read");
        assert_eq!(body["stream_options"]["include_usage"], true);
    }

    #[test]
    fn streamed_text_tools_and_usage_are_assembled() {
        let events = [
            r#"{"choices":[{"delta":{"content":"hello "},"finish_reason":null}]}"#,
            r#"{"choices":[{"delta":{"content":"there"},"finish_reason":null}]}"#,
            r#"{"choices":[{"delta":{"tool_calls":[{"index":0,"id":"call_1","function":{"name":"read","arguments":"{\"path\":"}}]},"finish_reason":null}]}"#,
            r#"{"choices":[{"delta":{"tool_calls":[{"index":0,"function":{"arguments":"\"AGENTS.md\"}"}}]},"finish_reason":null}]}"#,
            r#"{"choices":[{"delta":{},"finish_reason":"tool_calls"}],"usage":{"prompt_tokens":9,"completion_tokens":4,"prompt_tokens_details":{"cached_tokens":3}}}"#,
        ];
        let mut state = StreamState::new();
        let mut streamed = String::new();
        for data in events {
            if let Some(delta) = state.apply(&sse::Event {
                name: None,
                data: data.into(),
            }) {
                streamed.push_str(&delta);
            }
        }
        let turn = state.finish().unwrap();
        assert_eq!(streamed, "hello there");
        assert_eq!(turn.text, "hello there");
        assert_eq!(turn.stop_reason, StopReason::ToolUse);
        assert_eq!(turn.tool_calls[0].id, "call_1");
        assert_eq!(turn.tool_calls[0].name, "read");
        assert_eq!(turn.tool_calls[0].arguments["path"], "AGENTS.md");
        assert_eq!(turn.usage.input, 9);
        assert_eq!(turn.usage.output, 4);
        assert_eq!(turn.usage.cached_input, 3);
    }

    #[test]
    fn a_streamed_error_is_reported() {
        let mut state = StreamState::new();
        state.apply(&sse::Event {
            name: None,
            data: r#"{"error":{"message":"proxy refused"}}"#.into(),
        });
        assert_eq!(state.finish().unwrap_err(), "proxy refused");
    }
}
