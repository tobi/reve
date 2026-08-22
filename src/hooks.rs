//! Awaited interception points (`docs/harness.md` §5.6).
//!
//! Hooks intercept execution and can change it; events (see
//! [`crate::harness::Event`]) only observe. Handlers run sequentially in
//! registration order, each seeing the prior output. A throwing handler is
//! skipped and reported — **except `before_tool`, which fails closed**: a
//! policy handler that cannot run must not allow a tool it might have
//! blocked.
//!
//! Hook outputs that feed durable state are committed before execution
//! continues: `before_run` output lands in the operation's metadata and
//! prompt entries, `before_tool`'s effective arguments in `op.tool_args`.

use std::sync::Arc;

use futures::future::BoxFuture;
use serde_json::{Map, Value};

use crate::entry::Entry;
use crate::state::CompactionPreparation;

pub type Handler<E, R> = Arc<dyn Fn(E) -> BoxFuture<'static, Result<R, String>> + Send + Sync>;

#[derive(Debug, Clone, PartialEq)]
pub struct BeforeRunEvent {
    pub lane: String,
    pub run_id: String,
    /// The normalised prompt messages.
    pub prompt: Vec<Value>,
    pub system_prompt: String,
}

#[derive(Debug, Clone, Default, PartialEq)]
pub struct BeforeRunResult {
    /// Appended after the prompt, as entries of the run.
    pub messages: Vec<Value>,
    /// Fixed for the whole run when present.
    pub system_prompt: Option<String>,
}

#[derive(Debug, Clone, PartialEq)]
pub struct BeforeToolEvent {
    pub lane: String,
    pub run_id: String,
    pub tool_call_id: String,
    pub tool_name: String,
    pub args: Map<String, Value>,
}

#[derive(Debug, Clone, PartialEq)]
pub struct Block {
    pub reason: String,
    pub terminate: bool,
}

#[derive(Debug, Clone, Default, PartialEq)]
pub struct BeforeToolResult {
    pub args: Option<Map<String, Value>>,
    pub block: Option<Block>,
}

#[derive(Debug, Clone, PartialEq)]
pub struct AfterToolEvent {
    pub lane: String,
    pub run_id: String,
    pub tool_call_id: String,
    pub tool_name: String,
    pub args: Map<String, Value>,
    pub content: String,
    pub is_error: bool,
}

#[derive(Debug, Clone, Default, PartialEq)]
pub struct AfterToolResult {
    pub content: Option<String>,
    pub is_error: Option<bool>,
    pub terminate: Option<bool>,
}

#[derive(Debug, Clone, PartialEq)]
pub struct BeforeRunEndEvent {
    pub lane: String,
    pub run_id: String,
    /// The run's entries so far, as message payloads.
    pub messages: Vec<Value>,
}

#[derive(Debug, Clone, Default, PartialEq)]
pub struct BeforeRunEndResult {
    pub follow_up: Option<String>,
}

#[derive(Debug, Clone, PartialEq)]
pub struct BeforeCompactionEvent {
    pub lane: String,
    pub run_id: String,
    pub reason: crate::state::CompactionReason,
    pub preparation: CompactionPreparation,
}

#[derive(Debug, Clone, Default, PartialEq)]
pub struct BeforeCompactionResult {
    pub decline: bool,
    /// A hook-supplied summary skips generation.
    pub summary: Option<String>,
}

#[derive(Debug, Clone, PartialEq)]
pub struct TransformContextEvent {
    pub lane: String,
    pub run_id: String,
    pub messages: Vec<Entry>,
}

/// One handler failure, reported as a `handler_error` event.
#[derive(Debug, Clone, PartialEq)]
pub struct HandlerError {
    pub hook: &'static str,
    pub error: String,
}

#[derive(Clone, Default)]
pub struct Hooks {
    before_run: Vec<Handler<BeforeRunEvent, Option<BeforeRunResult>>>,
    before_tool: Vec<Handler<BeforeToolEvent, Option<BeforeToolResult>>>,
    after_tool: Vec<Handler<AfterToolEvent, Option<AfterToolResult>>>,
    before_run_end: Vec<Handler<BeforeRunEndEvent, Option<BeforeRunEndResult>>>,
    before_compaction: Vec<Handler<BeforeCompactionEvent, Option<BeforeCompactionResult>>>,
    transform_context: Vec<Handler<TransformContextEvent, Option<Vec<Entry>>>>,
}

/// What a hook pipeline produced plus the handlers that failed on the way.
#[derive(Debug, Clone, PartialEq)]
pub struct Outcome<T> {
    pub value: T,
    pub errors: Vec<HandlerError>,
}

impl Hooks {
    pub fn new() -> Self {
        Self::default()
    }

    pub fn on_before_run(mut self, h: Handler<BeforeRunEvent, Option<BeforeRunResult>>) -> Self {
        self.before_run.push(h);
        self
    }
    pub fn on_before_tool(mut self, h: Handler<BeforeToolEvent, Option<BeforeToolResult>>) -> Self {
        self.before_tool.push(h);
        self
    }
    pub fn on_after_tool(mut self, h: Handler<AfterToolEvent, Option<AfterToolResult>>) -> Self {
        self.after_tool.push(h);
        self
    }
    pub fn on_before_run_end(
        mut self,
        h: Handler<BeforeRunEndEvent, Option<BeforeRunEndResult>>,
    ) -> Self {
        self.before_run_end.push(h);
        self
    }
    pub fn on_before_compaction(
        mut self,
        h: Handler<BeforeCompactionEvent, Option<BeforeCompactionResult>>,
    ) -> Self {
        self.before_compaction.push(h);
        self
    }
    pub fn on_transform_context(
        mut self,
        h: Handler<TransformContextEvent, Option<Vec<Entry>>>,
    ) -> Self {
        self.transform_context.push(h);
        self
    }

    /// `before_run`: messages append, the latest defined system prompt wins.
    pub async fn before_run(&self, event: BeforeRunEvent) -> Outcome<BeforeRunResult> {
        let mut aggregate = BeforeRunResult::default();
        let mut errors = Vec::new();
        for handler in &self.before_run {
            match handler(event.clone()).await {
                Ok(Some(result)) => {
                    aggregate.messages.extend(result.messages);
                    if result.system_prompt.is_some() {
                        aggregate.system_prompt = result.system_prompt;
                    }
                }
                Ok(None) => {}
                Err(error) => errors.push(HandlerError {
                    hook: "before_run",
                    error,
                }),
            }
        }
        Outcome {
            value: aggregate,
            errors,
        }
    }

    /// `before_tool`: argument replacements chain; the first block is
    /// terminal; **a throwing handler blocks the tool**.
    pub async fn before_tool(&self, mut event: BeforeToolEvent) -> Outcome<BeforeToolResult> {
        let mut errors = Vec::new();
        let mut changed = false;
        for handler in &self.before_tool {
            match handler(event.clone()).await {
                Ok(Some(result)) => {
                    if let Some(block) = result.block {
                        return Outcome {
                            value: BeforeToolResult {
                                args: changed.then(|| event.args.clone()),
                                block: Some(block),
                            },
                            errors,
                        };
                    }
                    if let Some(args) = result.args {
                        event.args = args;
                        changed = true;
                    }
                }
                Ok(None) => {}
                Err(error) => {
                    errors.push(HandlerError {
                        hook: "before_tool",
                        error: error.clone(),
                    });
                    return Outcome {
                        value: BeforeToolResult {
                            args: None,
                            block: Some(Block {
                                reason: format!("before_tool hook failed: {error}"),
                                terminate: false,
                            }),
                        },
                        errors,
                    };
                }
            }
        }
        Outcome {
            value: BeforeToolResult {
                args: changed.then_some(event.args),
                block: None,
            },
            errors,
        }
    }

    /// `after_tool`: patches merge field by field.
    pub async fn after_tool(&self, mut event: AfterToolEvent) -> Outcome<AfterToolResult> {
        let mut aggregate = AfterToolResult::default();
        let mut errors = Vec::new();
        for handler in &self.after_tool {
            match handler(event.clone()).await {
                Ok(Some(result)) => {
                    if let Some(content) = result.content {
                        event.content = content.clone();
                        aggregate.content = Some(content);
                    }
                    if let Some(is_error) = result.is_error {
                        event.is_error = is_error;
                        aggregate.is_error = Some(is_error);
                    }
                    if result.terminate.is_some() {
                        aggregate.terminate = result.terminate;
                    }
                }
                Ok(None) => {}
                Err(error) => errors.push(HandlerError {
                    hook: "after_tool",
                    error,
                }),
            }
        }
        Outcome {
            value: aggregate,
            errors,
        }
    }

    /// `before_run_end`: the latest defined follow-up wins.
    pub async fn before_run_end(&self, event: BeforeRunEndEvent) -> Outcome<BeforeRunEndResult> {
        let mut aggregate = BeforeRunEndResult::default();
        let mut errors = Vec::new();
        for handler in &self.before_run_end {
            match handler(event.clone()).await {
                Ok(Some(result)) => {
                    if result.follow_up.is_some() {
                        aggregate.follow_up = result.follow_up;
                    }
                }
                Ok(None) => {}
                Err(error) => errors.push(HandlerError {
                    hook: "before_run_end",
                    error,
                }),
            }
        }
        Outcome {
            value: aggregate,
            errors,
        }
    }

    /// `before_compaction`: stops at the first decline or supplied summary.
    pub async fn before_compaction(
        &self,
        event: BeforeCompactionEvent,
    ) -> Outcome<BeforeCompactionResult> {
        let mut errors = Vec::new();
        for handler in &self.before_compaction {
            match handler(event.clone()).await {
                Ok(Some(result)) => {
                    if result.decline && result.summary.is_some() {
                        errors.push(HandlerError {
                            hook: "before_compaction",
                            error: "returned both decline and a summary".into(),
                        });
                        continue;
                    }
                    if result.decline || result.summary.is_some() {
                        return Outcome {
                            value: result,
                            errors,
                        };
                    }
                }
                Ok(None) => {}
                Err(error) => errors.push(HandlerError {
                    hook: "before_compaction",
                    error,
                }),
            }
        }
        Outcome {
            value: BeforeCompactionResult::default(),
            errors,
        }
    }

    /// `transform_context`: ephemeral; shapes what the provider sees, never
    /// what the session contains.
    pub async fn transform_context(&self, mut event: TransformContextEvent) -> Outcome<Vec<Entry>> {
        let mut errors = Vec::new();
        for handler in &self.transform_context {
            match handler(event.clone()).await {
                Ok(Some(messages)) => event.messages = messages,
                Ok(None) => {}
                Err(error) => errors.push(HandlerError {
                    hook: "transform_context",
                    error,
                }),
            }
        }
        Outcome {
            value: event.messages,
            errors,
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;

    fn tool_event(args: Value) -> BeforeToolEvent {
        BeforeToolEvent {
            lane: "main".into(),
            run_id: "op".into(),
            tool_call_id: "c1".into(),
            tool_name: "bash".into(),
            args: args.as_object().cloned().unwrap_or_default(),
        }
    }

    #[tokio::test]
    async fn before_tool_chains_argument_replacements_in_order() {
        let hooks = Hooks::new()
            .on_before_tool(Arc::new(|mut e| {
                Box::pin(async move {
                    e.args.insert("first".into(), json!(1));
                    Ok(Some(BeforeToolResult {
                        args: Some(e.args),
                        block: None,
                    }))
                })
            }))
            .on_before_tool(Arc::new(|mut e| {
                Box::pin(async move {
                    e.args.insert("second".into(), e.args["first"].clone());
                    Ok(Some(BeforeToolResult {
                        args: Some(e.args),
                        block: None,
                    }))
                })
            }));
        let out = hooks
            .before_tool(tool_event(json!({"command": "ls"})))
            .await;
        let args = out.value.args.unwrap();
        assert_eq!(args["second"], 1);
        assert_eq!(args["command"], "ls");
        assert!(out.value.block.is_none());
    }

    #[tokio::test]
    async fn a_throwing_before_tool_handler_blocks_the_tool() {
        let hooks = Hooks::new()
            .on_before_tool(Arc::new(|_| {
                Box::pin(async { Err("policy service down".into()) })
            }))
            .on_before_tool(Arc::new(|_| {
                panic!("later handlers must not run after a failure")
            }));
        let out = hooks.before_tool(tool_event(json!({}))).await;
        let block = out.value.block.expect("fails closed");
        assert!(block.reason.contains("policy service down"));
        assert_eq!(out.errors.len(), 1);
    }

    #[tokio::test]
    async fn other_hooks_skip_a_throwing_handler_and_continue() {
        let hooks = Hooks::new()
            .on_after_tool(Arc::new(|_| Box::pin(async { Err("oops".into()) })))
            .on_after_tool(Arc::new(|_| {
                Box::pin(async {
                    Ok(Some(AfterToolResult {
                        content: Some("patched".into()),
                        is_error: None,
                        terminate: Some(true),
                    }))
                })
            }));
        let out = hooks
            .after_tool(AfterToolEvent {
                lane: "main".into(),
                run_id: "op".into(),
                tool_call_id: "c".into(),
                tool_name: "t".into(),
                args: Map::new(),
                content: "raw".into(),
                is_error: false,
            })
            .await;
        assert_eq!(out.value.content.as_deref(), Some("patched"));
        assert_eq!(out.value.terminate, Some(true));
        assert_eq!(out.errors.len(), 1);
    }

    #[tokio::test]
    async fn before_run_appends_messages_and_the_latest_system_prompt_wins() {
        let hooks = Hooks::new()
            .on_before_run(Arc::new(|_| {
                Box::pin(async {
                    Ok(Some(BeforeRunResult {
                        messages: vec![json!({"role": "user", "content": "a"})],
                        system_prompt: Some("first".into()),
                    }))
                })
            }))
            .on_before_run(Arc::new(|_| {
                Box::pin(async {
                    Ok(Some(BeforeRunResult {
                        messages: vec![json!({"role": "user", "content": "b"})],
                        system_prompt: Some("second".into()),
                    }))
                })
            }));
        let out = hooks
            .before_run(BeforeRunEvent {
                lane: "main".into(),
                run_id: "op".into(),
                prompt: vec![],
                system_prompt: String::new(),
            })
            .await;
        assert_eq!(out.value.messages.len(), 2);
        assert_eq!(out.value.system_prompt.as_deref(), Some("second"));
    }

    #[tokio::test]
    async fn before_compaction_stops_at_the_first_decision() {
        let hooks = Hooks::new()
            .on_before_compaction(Arc::new(|_| Box::pin(async { Ok(None) })))
            .on_before_compaction(Arc::new(|_| {
                Box::pin(async {
                    Ok(Some(BeforeCompactionResult {
                        decline: true,
                        summary: None,
                    }))
                })
            }))
            .on_before_compaction(Arc::new(|_| panic!("not reached")));
        let out = hooks
            .before_compaction(BeforeCompactionEvent {
                lane: "main".into(),
                run_id: "op".into(),
                reason: crate::state::CompactionReason::Manual,
                preparation: CompactionPreparation {
                    messages_to_summarize: vec![],
                    retained_tail: vec![],
                    tokens_before: 0,
                    previous_summary: None,
                },
            })
            .await;
        assert!(out.value.decline);
    }
}
