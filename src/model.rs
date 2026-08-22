//! What the lane asks for a turn.
//!
//! The seam every provider implements. A scripted model makes the durability
//! tests deterministic; `crate::provider::HttpModel` is the real one.

use std::future::Future;
use std::pin::Pin;

use serde::{Deserialize, Serialize};
use serde_json::{Map, Value};

use crate::entry::Entry;
pub use crate::entry::Usage;

pub type BoxFuture<'a, T> = Pin<Box<dyn Future<Output = T> + Send + 'a>>;

/// A provider failure. `retryable` is the transport's opinion — a 5xx, a
/// timeout, a stream that ended early — and the lane's retry policy decides
/// how many times to believe it.
#[derive(Debug, Clone, thiserror::Error)]
#[error("model error: {message}")]
pub struct ModelError {
    pub message: String,
    pub retryable: bool,
}

impl ModelError {
    pub fn terminal(message: impl Into<String>) -> Self {
        Self {
            message: message.into(),
            retryable: false,
        }
    }
    pub fn retryable(message: impl Into<String>) -> Self {
        Self {
            message: message.into(),
            retryable: true,
        }
    }
}

pub type Result<T, E = ModelError> = std::result::Result<T, E>;

/// One tool invocation the model asked for.
#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
pub struct ToolCall {
    pub id: String,
    pub name: String,
    #[serde(default)]
    pub arguments: Map<String, Value>,
}

/// Why the model stopped.
#[derive(Debug, Clone, Copy, Default, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub enum StopReason {
    /// The turn is over.
    #[default]
    Stop,
    /// The model wants tools run, then to be asked again.
    ToolUse,
    /// The output limit cut the response short.
    Length,
    /// The request failed; `error_message` says how. Committed, then dropped
    /// from context by projection.
    Error,
    /// The harness's own abort signal fired. Only the harness writes this.
    Aborted,
}

impl StopReason {
    pub fn as_str(self) -> &'static str {
        match self {
            Self::Stop => "stop",
            Self::ToolUse => "toolUse",
            Self::Length => "length",
            Self::Error => "error",
            Self::Aborted => "aborted",
        }
    }
}

/// One settled assistant turn.
#[derive(Debug, Clone, Default, Serialize, Deserialize, PartialEq)]
pub struct Assistant {
    #[serde(default)]
    pub text: String,
    #[serde(default)]
    pub tool_calls: Vec<ToolCall>,
    pub stop_reason: StopReason,
    #[serde(default)]
    pub usage: Usage,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub error_message: Option<String>,
}

impl Assistant {
    pub fn text(text: impl Into<String>) -> Self {
        Self {
            text: text.into(),
            ..Default::default()
        }
    }

    pub fn call(name: &str, arguments: Value) -> Self {
        Self::calls(vec![(name.to_string(), arguments)])
    }

    pub fn calls(calls: Vec<(String, Value)>) -> Self {
        Self {
            text: String::new(),
            tool_calls: calls
                .into_iter()
                .map(|(name, arguments)| ToolCall {
                    id: format!("tc_{}", &crate::ids::uuid_v7(crate::ids::now_ms())[..8]),
                    name,
                    arguments: arguments.as_object().cloned().unwrap_or_default(),
                })
                .collect(),
            stop_reason: StopReason::ToolUse,
            usage: Usage::default(),
            error_message: None,
        }
    }

    /// A failed request, as the transcript records it.
    pub fn error(message: impl Into<String>) -> Self {
        Self {
            stop_reason: StopReason::Error,
            error_message: Some(message.into()),
            ..Default::default()
        }
    }

    /// Rebuild a turn from the entry payload `message()` produced.
    pub fn from_message(message: &Value) -> Option<Self> {
        if message.get("role")?.as_str()? != "assistant" {
            return None;
        }
        let mut text = String::new();
        let mut tool_calls = Vec::new();
        for part in message.get("content")?.as_array()? {
            match part.get("type").and_then(Value::as_str) {
                Some("text") => {
                    text.push_str(part.get("text").and_then(Value::as_str).unwrap_or(""))
                }
                Some("toolCall") => tool_calls.push(ToolCall {
                    id: part
                        .get("id")
                        .and_then(Value::as_str)
                        .unwrap_or("")
                        .to_string(),
                    name: part
                        .get("name")
                        .and_then(Value::as_str)
                        .unwrap_or("")
                        .to_string(),
                    arguments: part
                        .get("arguments")
                        .and_then(Value::as_object)
                        .cloned()
                        .unwrap_or_default(),
                }),
                _ => {}
            }
        }
        let stop_reason = message
            .get("stopReason")
            .and_then(|v| serde_json::from_value(v.clone()).ok())
            .unwrap_or_default();
        Some(Self {
            text,
            tool_calls,
            stop_reason,
            usage: message
                .get("usage")
                .and_then(|v| serde_json::from_value(v.clone()).ok())
                .unwrap_or_default(),
            error_message: message
                .get("errorMessage")
                .and_then(Value::as_str)
                .map(str::to_string),
        })
    }

    /// The entry payload this turn becomes.
    pub fn message(&self) -> Value {
        let mut content = Vec::new();
        if !self.text.is_empty() {
            content.push(serde_json::json!({"type": "text", "text": self.text}));
        }
        for call in &self.tool_calls {
            content.push(serde_json::json!({
                "type": "toolCall",
                "id": call.id,
                "name": call.name,
                "arguments": Value::Object(call.arguments.clone()),
            }));
        }
        let mut message = serde_json::json!({
            "role": "assistant",
            "content": content,
            "stopReason": self.stop_reason,
            "usage": self.usage,
        });
        if let Some(error) = &self.error_message {
            message["errorMessage"] = Value::String(error.clone());
        }
        message
    }
}

/// What the lane is asking for.
pub struct Request<'a> {
    /// The conversation, oldest first.
    pub context: &'a [Entry],
    /// The stable system prefix.
    pub system: &'a str,
    /// Tools the model may call, as JSON schemas.
    pub tools: &'a [ToolSchema],
}

/// A tool as the model sees it.
#[derive(Debug, Clone)]
pub struct ToolSchema {
    pub name: String,
    pub description: String,
    pub schema: Value,
}

/// Where streamed text goes as it arrives.
///
/// A callback rather than a channel so a caller that does not care about
/// streaming can pass a no-op and ignore the whole concern.
pub type Deltas<'a> = &'a (dyn Fn(&str) + Send + Sync);

pub trait Model: Send + Sync {
    fn respond<'a>(
        &'a self,
        request: Request<'a>,
        on_text: Deltas<'a>,
    ) -> BoxFuture<'a, Result<Assistant>>;
}

/// A model that reads its turns from a script.
///
/// The cursor lives in a file, not in memory, so a process that is killed
/// mid-run and restarted resumes at the turn it had reached — which is exactly
/// what a crash-site recovery test needs.
pub struct ScriptedModel {
    script: Vec<Assistant>,
    cursor_path: std::path::PathBuf,
}

impl ScriptedModel {
    pub fn new(script: Vec<Assistant>, cursor_path: impl Into<std::path::PathBuf>) -> Self {
        Self {
            script,
            cursor_path: cursor_path.into(),
        }
    }

    /// How many turns have been consumed so far.
    pub fn consumed(&self) -> usize {
        self.cursor()
    }

    fn cursor(&self) -> usize {
        std::fs::read_to_string(&self.cursor_path)
            .ok()
            .and_then(|t| t.trim().parse().ok())
            .unwrap_or(0)
    }

    fn advance(&self, next: usize) {
        if let Some(parent) = self.cursor_path.parent() {
            let _ = std::fs::create_dir_all(parent);
        }
        let _ = std::fs::write(&self.cursor_path, next.to_string());
    }
}

impl Model for ScriptedModel {
    fn respond<'a>(
        &'a self,
        _request: Request<'a>,
        on_text: Deltas<'a>,
    ) -> BoxFuture<'a, Result<Assistant>> {
        Box::pin(async move {
            let index = self.cursor();
            let turn =
                self.script.get(index).cloned().ok_or_else(|| {
                    ModelError::terminal(format!("script exhausted at turn {index}"))
                })?;
            self.advance(index + 1);
            if !turn.text.is_empty() {
                on_text(&turn.text);
            }
            Ok(turn)
        })
    }
}
