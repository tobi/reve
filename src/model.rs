//! What the lane asks for a turn.
//!
//! Real providers are still pending; this is the seam they will implement. It
//! exists now because the run procedure cannot be written — or tested — against
//! nothing, and a scripted model makes the durability tests deterministic.

use std::future::Future;
use std::pin::Pin;

use serde::{Deserialize, Serialize};
use serde_json::{Map, Value};

use crate::records::Entry;

pub type BoxFuture<'a, T> = Pin<Box<dyn Future<Output = T> + Send + 'a>>;

#[derive(Debug, thiserror::Error)]
#[error("model error: {0}")]
pub struct ModelError(pub String);

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
}

/// What a turn cost.
///
/// `cached_input` drives the cache-miss warning: a normal request whose prefix
/// mostly missed the cache means something invalidated it, and that is worth
/// saying out loud rather than paying for quietly.
#[derive(Debug, Clone, Copy, Default, PartialEq, Eq, Serialize, Deserialize)]
pub struct Usage {
    pub input: u32,
    pub output: u32,
    pub cached_input: u32,
}

impl Usage {
    /// Fraction of the input that had to be re-read, 0.0 to 1.0.
    pub fn uncached_fraction(&self) -> f32 {
        if self.input == 0 {
            return 0.0;
        }
        1.0 - (self.cached_input as f32 / self.input as f32)
    }
}

/// One assistant turn.
#[derive(Debug, Clone, Default, Serialize, Deserialize)]
pub struct Assistant {
    #[serde(default)]
    pub text: String,
    #[serde(default)]
    pub tool_calls: Vec<ToolCall>,
    pub stop_reason: StopReason,
    #[serde(default)]
    pub usage: Usage,
}

impl Assistant {
    pub fn text(text: impl Into<String>) -> Self {
        Self {
            text: text.into(),
            ..Default::default()
        }
    }

    pub fn call(name: &str, arguments: Value) -> Self {
        Self {
            text: String::new(),
            tool_calls: vec![ToolCall {
                id: format!("tc_{}", crate::ids::RunId::new().as_str()),
                name: name.into(),
                arguments: arguments.as_object().cloned().unwrap_or_default(),
            }],
            stop_reason: StopReason::ToolUse,
            usage: Usage::default(),
        }
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
        serde_json::json!({
            "role": "assistant",
            "content": content,
            "stopReason": self.stop_reason,
        })
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
            let turn = self
                .script
                .get(index)
                .cloned()
                .ok_or_else(|| ModelError(format!("script exhausted at turn {index}")))?;
            self.advance(index + 1);
            if !turn.text.is_empty() {
                on_text(&turn.text);
            }
            Ok(turn)
        })
    }
}
