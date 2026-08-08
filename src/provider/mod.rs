//! Talking to models.
//!
//! Two wire protocols, written directly against `reqwest` rather than through
//! an SDK. Neither vendor ships an official Rust client, and leve needs a
//! narrow slice of each API — stream text, stream tool calls, count tokens — so
//! a thin adapter is less code than adapting someone else's model of the whole
//! surface, and it keeps the dependency audit small, which matters for a
//! program whose entire premise is a tight boundary.
//!
//! Per-provider differences live in `Compat`, not in conditionals here.

pub mod anthropic;
pub mod config;
pub mod openai_responses;
pub mod sse;

use futures::StreamExt;

use crate::model::{Assistant, BoxFuture, Deltas, Model, ModelError, Request, Result, ToolSchema};
use crate::records::Entry;
use config::{Api, Resolved};
use serde_json::{Value, json};

/// A model reached over HTTP.
pub struct HttpModel {
    resolved: Resolved,
    client: reqwest::Client,
}

impl HttpModel {
    pub fn new(resolved: Resolved) -> Self {
        Self {
            resolved,
            client: reqwest::Client::new(),
        }
    }

    pub fn resolved(&self) -> &Resolved {
        &self.resolved
    }

    fn endpoint(&self) -> String {
        let base = self.resolved.base_url.trim_end_matches('/');
        match self.resolved.api {
            Api::OpenaiResponses => format!("{base}/responses"),
            Api::AnthropicMessages => format!("{base}/v1/messages"),
            Api::Fake => base.to_string(),
        }
    }
}

impl Model for HttpModel {
    fn respond<'a>(
        &'a self,
        request: Request<'a>,
        on_text: Deltas<'a>,
    ) -> BoxFuture<'a, Result<Assistant>> {
        Box::pin(async move {
            let body = match self.resolved.api {
                Api::OpenaiResponses => openai_responses::build_body(
                    &self.resolved,
                    request.system,
                    openai_input(request.context),
                    request.tools,
                ),
                Api::AnthropicMessages => anthropic::build_body(
                    &self.resolved,
                    request.system,
                    anthropic_messages(request.context),
                    request.tools,
                ),
                Api::Fake => {
                    return Err(ModelError("the fake provider has no endpoint".into()));
                }
            };

            let mut post = self.client.post(self.endpoint()).json(&body);
            // Authentication is spelled differently by each vendor, and this is
            // the only place that difference exists.
            post = match self.resolved.api {
                Api::AnthropicMessages => post.header("anthropic-version", "2023-06-01").header(
                    "x-api-key",
                    self.resolved.api_key.clone().unwrap_or_default(),
                ),
                _ => post.bearer_auth(self.resolved.api_key.clone().unwrap_or_default()),
            };

            let response = post.send().await.map_err(|e| {
                // Say which provider and which URL: "connection refused" on its
                // own has sent people hunting in the wrong place.
                ModelError(format!(
                    "{} ({}): {e}",
                    self.resolved.provider,
                    self.endpoint()
                ))
            })?;

            let status = response.status();
            if !status.is_success() {
                let body = response.text().await.unwrap_or_default();
                return Err(ModelError(format!(
                    "{} returned {status} for {}: {body}",
                    self.resolved.provider, self.resolved.model.id
                )));
            }

            let mut decoder = sse::Decoder::new();
            let mut openai = openai_responses::StreamState::new();
            let mut claude = anthropic::StreamState::new();
            let mut stream = response.bytes_stream();
            while let Some(chunk) = stream.next().await {
                let chunk = chunk.map_err(|e| ModelError(format!("stream ended early: {e}")))?;
                let text = String::from_utf8_lossy(&chunk);
                for event in decoder.push(&text) {
                    let delta = match self.resolved.api {
                        Api::AnthropicMessages => claude.apply(&event),
                        _ => openai.apply(&event),
                    };
                    if let Some(delta) = delta {
                        on_text(&delta);
                    }
                }
            }

            match self.resolved.api {
                Api::AnthropicMessages => claude.finish(),
                _ => openai.finish(),
            }
            .map_err(ModelError)
        })
    }
}

/// Conversation entries as the Responses API wants them.
pub fn openai_input(context: &[Entry]) -> Vec<Value> {
    context.iter().filter_map(entry_to_openai).collect()
}

fn entry_to_openai(entry: &Entry) -> Option<Value> {
    let message = entry.payload.get("message")?;
    match message.get("role")?.as_str()? {
        "user" => Some(json!({"role": "user", "content": text_of(message)})),
        "assistant" => Some(json!({"role": "assistant", "content": text_of(message)})),
        "toolResult" => Some(json!({
            "type": "function_call_output",
            "call_id": message.get("toolCallId").and_then(Value::as_str).unwrap_or_default(),
            "output": text_of(message),
        })),
        _ => None,
    }
}

/// Conversation entries as the Messages API wants them.
pub fn anthropic_messages(context: &[Entry]) -> Vec<Value> {
    context
        .iter()
        .filter_map(|entry| {
            let message = entry.payload.get("message")?;
            match message.get("role")?.as_str()? {
                "user" => Some(json!({"role": "user", "content": text_of(message)})),
                "assistant" => Some(json!({"role": "assistant", "content": text_of(message)})),
                // A tool result is a user-role message on this API.
                "toolResult" => Some(json!({
                    "role": "user",
                    "content": [{
                        "type": "tool_result",
                        "tool_use_id": message.get("toolCallId").and_then(Value::as_str).unwrap_or_default(),
                        "content": text_of(message),
                    }],
                })),
                _ => None,
            }
        })
        .collect()
}

/// The plain text of a message, whatever shape its content is in.
fn text_of(message: &Value) -> String {
    match message.get("content") {
        Some(Value::String(text)) => text.clone(),
        Some(Value::Array(parts)) => parts
            .iter()
            .filter_map(|p| p.get("text").and_then(Value::as_str))
            .collect::<Vec<_>>()
            .join(""),
        _ => String::new(),
    }
}

/// Tool schemas for everything the agent declared in Lua.
pub fn tool_schemas(runtime: &crate::lua::Runtime) -> Vec<ToolSchema> {
    runtime
        .tools
        .iter()
        .map(|t| ToolSchema {
            name: t.name.clone(),
            description: t.description.clone(),
            schema: t.schema(),
        })
        .collect()
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::records::MAIN_LANE;

    fn entry(role: &str, text: &str) -> Entry {
        Entry::message(
            MAIN_LANE,
            json!({"role": role, "content": [{"type": "text", "text": text}]}),
        )
    }

    #[test]
    fn a_conversation_converts_to_each_providers_shape() {
        let context = vec![entry("user", "hello"), entry("assistant", "hi")];
        let openai = openai_input(&context);
        assert_eq!(openai[0]["role"], "user");
        assert_eq!(openai[0]["content"], "hello");

        let claude = anthropic_messages(&context);
        assert_eq!(claude[1]["role"], "assistant");
        assert_eq!(claude[1]["content"], "hi");
    }

    #[test]
    fn a_tool_result_is_shaped_differently_by_each_api() {
        let mut result = Entry::message(
            MAIN_LANE,
            json!({
                "role": "toolResult",
                "toolCallId": "call_1",
                "content": [{"type": "text", "text": "ok"}],
            }),
        );
        result.parent_id = None;
        let context = vec![result];

        let openai = openai_input(&context);
        assert_eq!(openai[0]["type"], "function_call_output");
        assert_eq!(openai[0]["call_id"], "call_1");
        assert_eq!(openai[0]["output"], "ok");

        let claude = anthropic_messages(&context);
        assert_eq!(
            claude[0]["role"], "user",
            "Anthropic carries results as user turns"
        );
        assert_eq!(claude[0]["content"][0]["type"], "tool_result");
        assert_eq!(claude[0]["content"][0]["tool_use_id"], "call_1");
    }

    #[test]
    fn plain_string_content_is_accepted_as_well_as_parts() {
        let entry = Entry::message(MAIN_LANE, json!({"role": "user", "content": "flat"}));
        assert_eq!(openai_input(&[entry])[0]["content"], "flat");
    }

    #[test]
    fn entries_that_are_not_messages_are_skipped() {
        let custom = Entry::custom(MAIN_LANE, "bash_execution", json!({"command": "ls"}));
        assert!(openai_input(std::slice::from_ref(&custom)).is_empty());
        assert!(anthropic_messages(&[custom]).is_empty());
    }

    #[test]
    fn each_api_has_its_own_endpoint() {
        use crate::provider::config::{Compat, ModelSpec};
        let make = |api| HttpModel {
            resolved: Resolved {
                provider: "p".into(),
                api,
                base_url: "https://example.test/v1/".into(),
                api_key: None,
                model: ModelSpec {
                    id: "m".into(),
                    reasoning: false,
                    context_window: 1,
                    max_tokens: 1,
                },
                compat: Compat::default(),
            },
            client: reqwest::Client::new(),
        };
        assert_eq!(
            make(Api::OpenaiResponses).endpoint(),
            "https://example.test/v1/responses"
        );
        assert_eq!(
            make(Api::AnthropicMessages).endpoint(),
            "https://example.test/v1/v1/messages"
        );
    }
}
