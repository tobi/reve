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
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub enum StopReason {
    /// The turn is over.
    Stop,
    /// The model wants tools run, then to be asked again.
    ToolUse,
}

/// One assistant turn.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct Assistant {
    #[serde(default)]
    pub text: String,
    #[serde(default)]
    pub tool_calls: Vec<ToolCall>,
    pub stop_reason: StopReason,
}

impl Assistant {
    pub fn text(text: impl Into<String>) -> Self {
        Self {
            text: text.into(),
            tool_calls: Vec::new(),
            stop_reason: StopReason::Stop,
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

pub trait Model: Send + Sync {
    fn respond<'a>(&'a self, context: &'a [Entry]) -> BoxFuture<'a, Result<Assistant>>;
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
    fn respond<'a>(&'a self, _context: &'a [Entry]) -> BoxFuture<'a, Result<Assistant>> {
        Box::pin(async move {
            let index = self.cursor();
            let turn = self
                .script
                .get(index)
                .cloned()
                .ok_or_else(|| ModelError(format!("script exhausted at turn {index}")))?;
            self.advance(index + 1);
            Ok(turn)
        })
    }
}
