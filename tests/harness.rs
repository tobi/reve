//! The durable-operation state machine, exercised through the public surface.
//!
//! Every test here works on a real JSONL session on disk. Recovery is tested
//! the only way that means anything: the `Harness` and its `Session` are
//! **dropped** mid-operation — which is what a crash leaves behind, minus the
//! torn line — and a fresh one opens the same file and has to continue.
//!
//! The crash sites are the ones named in `docs/harness.md` §3.10: a tool with
//! no record, a tool with an intent and no result, a tool with a result.

use std::sync::Arc;
use std::sync::atomic::{AtomicUsize, Ordering};

use reve::entry::{MAIN_LANE, Namespace};
use reve::events::Kind;
use reve::harness::{Harness, HarnessConfig, HarnessError};
use reve::hooks::{AfterToolResult, BeforeToolResult, Block, Hooks};
use reve::model::{
    Assistant, BoxFuture, Deltas, Model, ModelError, Request, ScriptedModel, ToolCall, ToolSchema,
};
use reve::sandbox::tokio_util_lite::CancelRx;
use reve::session::Session;
use reve::state::{
    LaneConfiguration, ModelRef, OperationState, Outcome, Replay, RetryPolicy, RunSettings,
};
use reve::storage::Storage;
use reve::tools::Tools;
use serde_json::{Map, Value, json};

// ── scaffolding ──────────────────────────────────────────────────────────

fn configuration() -> LaneConfiguration {
    LaneConfiguration {
        model: ModelRef {
            provider: "test".into(),
            model_id: "scripted".into(),
        },
        thinking_level: "off".into(),
        active_tool_names: vec![],
    }
}

/// A tool set defined by closures, with a per-name replay declaration and a
/// call counter — which is how we prove a `never` tool was not re-run.
#[allow(clippy::type_complexity)]
struct FakeTools {
    replay: Vec<(String, Replay)>,
    calls: Arc<AtomicUsize>,
    /// `None` means the tool never returns. Hanging *asynchronously* matters:
    /// blocking the thread would stall the very runtime that has to observe
    /// the committed intent and then drop the driver.
    behaviour:
        Box<dyn Fn(&str, Map<String, Value>) -> Option<Result<String, String>> + Send + Sync>,
}

impl FakeTools {
    fn new(
        replay: &[(&str, Replay)],
        behaviour: impl Fn(&str, Map<String, Value>) -> Result<String, String> + Send + Sync + 'static,
    ) -> (Arc<Self>, Arc<AtomicUsize>) {
        Self::build(replay, move |name, args| Some(behaviour(name, args)))
    }

    /// Tools whose named calls never return, so the process can be dropped
    /// with the effect genuinely in flight.
    fn hanging(
        replay: &[(&str, Replay)],
        hangs: &'static [&'static str],
    ) -> (Arc<Self>, Arc<AtomicUsize>) {
        Self::build(replay, move |name, _| {
            if hangs.contains(&name) {
                return None;
            }
            Some(Ok(format!("{name} ran")))
        })
    }

    fn build(
        replay: &[(&str, Replay)],
        behaviour: impl Fn(&str, Map<String, Value>) -> Option<Result<String, String>>
        + Send
        + Sync
        + 'static,
    ) -> (Arc<Self>, Arc<AtomicUsize>) {
        let calls = Arc::new(AtomicUsize::new(0));
        (
            Arc::new(Self {
                replay: replay.iter().map(|(n, r)| (n.to_string(), *r)).collect(),
                calls: calls.clone(),
                behaviour: Box::new(behaviour),
            }),
            calls,
        )
    }
}

impl Tools for FakeTools {
    fn replay(&self, name: &str) -> Option<Replay> {
        self.replay.iter().find(|(n, _)| n == name).map(|(_, r)| *r)
    }

    fn schemas(&self) -> Vec<ToolSchema> {
        self.replay
            .iter()
            .map(|(name, _)| ToolSchema {
                name: name.clone(),
                description: "a test tool".into(),
                schema: json!({"type": "object", "properties": {}}),
            })
            .collect()
    }

    fn invoke<'a>(
        &'a self,
        name: &'a str,
        arguments: Map<String, Value>,
        _cancel: Option<CancelRx>,
    ) -> BoxFuture<'a, Result<String, String>> {
        self.calls.fetch_add(1, Ordering::SeqCst);
        let result = (self.behaviour)(name, arguments);
        Box::pin(async move {
            match result {
                Some(result) => result,
                None => std::future::pending().await,
            }
        })
    }
}

/// A model that fails a fixed number of times before deferring to a script.
struct FlakyModel {
    failures: AtomicUsize,
    remaining: usize,
    retryable: bool,
    then: ScriptedModel,
}

impl Model for FlakyModel {
    fn respond<'a>(
        &'a self,
        request: Request<'a>,
        on_text: Deltas<'a>,
    ) -> BoxFuture<'a, reve::model::Result<Assistant>> {
        let seen = self.failures.fetch_add(1, Ordering::SeqCst);
        if seen < self.remaining {
            let message = format!("simulated failure {}", seen + 1);
            return Box::pin(async move {
                Err(if self.retryable {
                    ModelError::retryable(message)
                } else {
                    ModelError::terminal(message)
                })
            });
        }
        self.then.respond(request, on_text)
    }
}

struct World {
    _dir: tempfile::TempDir,
    path: std::path::PathBuf,
    cursor: std::path::PathBuf,
    /// One cursor file per model. A `ScriptedModel`'s cursor is deliberately
    /// durable, so two scripts sharing a file would have the second one start
    /// wherever the first left off -- which is exactly wrong for a recovery
    /// test, where the resuming process brings a fresh script of its own.
    scripts: AtomicUsize,
}

impl World {
    fn new() -> Self {
        let dir = tempfile::tempdir().unwrap();
        Self {
            path: dir.path().join("session.jsonl"),
            cursor: dir.path().join("cursor"),
            scripts: AtomicUsize::new(0),
            _dir: dir,
        }
    }

    fn session(&self) -> Session {
        Session::spawn(Storage::open(&self.path, "test", None).unwrap())
    }

    /// A harness over a freshly opened session. Dropping it is a crash.
    fn harness(
        &self,
        session: &Session,
        model: Arc<dyn Model>,
        tools: Arc<dyn Tools>,
        hooks: Hooks,
    ) -> Arc<Harness> {
        Harness::new(
            session.clone(),
            HarnessConfig {
                model,
                tools,
                hooks,
                system_prompt: Arc::new(|| "you are a test".to_string()),
                settings: RunSettings::default(),
                retry: RetryPolicy {
                    max_attempts: 3,
                    base_delay_ms: 1,
                },
                configuration: configuration(),
                event_capacity: 256,
            },
        )
    }

    fn scripted(&self, script: Vec<Assistant>) -> Arc<dyn Model> {
        let n = self.scripts.fetch_add(1, Ordering::SeqCst);
        Arc::new(ScriptedModel::new(
            script,
            self.cursor.with_extension(n.to_string()),
        ))
    }

    /// Every message entry on the lane's current branch, as role/text pairs.
    async fn transcript(&self, session: &Session) -> Vec<(String, String)> {
        Self::pairs(session.transcript(MAIN_LANE).await.unwrap())
    }

    /// What the model would actually be shown.
    async fn context(&self, session: &Session) -> Vec<(String, String)> {
        Self::pairs(session.context(MAIN_LANE).await.unwrap())
    }

    fn pairs(entries: Vec<reve::entry::Entry>) -> Vec<(String, String)> {
        entries
            .into_iter()
            .filter_map(|e| {
                let message = e.message_value()?;
                let role = message.get("role")?.as_str()?.to_string();
                Some((role, text_of(message)))
            })
            .collect()
    }
}

fn text_of(message: &Value) -> String {
    if let Some(text) = message.get("content").and_then(Value::as_str) {
        return text.to_string();
    }
    let mut out = String::new();
    if let Some(blocks) = message.get("content").and_then(Value::as_array) {
        for block in blocks {
            match block.get("type").and_then(Value::as_str) {
                Some("text") => {
                    out.push_str(block.get("text").and_then(Value::as_str).unwrap_or(""))
                }
                Some("toolResult") => {
                    out.push_str(block.get("content").and_then(Value::as_str).unwrap_or(""))
                }
                _ => {}
            }
        }
    }
    out
}

fn assistant_text(text: &str) -> Assistant {
    Assistant::text(text)
}

fn assistant_call(name: &str, args: Value) -> Assistant {
    let mut a = Assistant {
        text: String::new(),
        tool_calls: vec![ToolCall {
            id: format!("call_{name}"),
            name: name.into(),
            arguments: args.as_object().cloned().unwrap_or_default(),
        }],
        stop_reason: reve::model::StopReason::ToolUse,
        usage: Default::default(),
        error_message: None,
    };
    a.usage.input = 10;
    a.usage.output = 5;
    a
}

fn no_tools() -> Arc<dyn Tools> {
    let (tools, _) = FakeTools::new(&[], |name, _| panic!("unexpected tool {name}"));
    tools
}

// ── the happy paths ──────────────────────────────────────────────────────

#[tokio::test]
async fn a_prompt_becomes_a_user_entry_and_an_assistant_reply() {
    let world = World::new();
    let session = world.session();
    let harness = world.harness(
        &session,
        world.scripted(vec![assistant_text("hello back")]),
        no_tools(),
        Hooks::new(),
    );

    let result = harness.prompt(MAIN_LANE, "hello").await.unwrap();
    assert_eq!(result.outcome, Outcome::Completed);
    assert_eq!(result.final_text.as_deref(), Some("hello back"));
    assert_eq!(
        world.transcript(&session).await,
        vec![
            ("user".to_string(), "hello".to_string()),
            ("assistant".to_string(), "hello back".to_string()),
        ]
    );

    // The operation owns no registers once it has ended.
    let leftovers = session
        .read(|s| {
            s.list_registers(Namespace::OpState, "").len()
                + s.list_registers(Namespace::OpMeta, "").len()
                + s.list_registers(Namespace::PendingEntry, "").len()
        })
        .await
        .unwrap();
    assert_eq!(leftovers, 0, "a finished operation leaves nothing behind");
    session.close().await;
}

#[tokio::test]
async fn a_tool_call_runs_and_the_model_is_asked_again() {
    let world = World::new();
    let session = world.session();
    let (tools, calls) = FakeTools::new(&[("look", Replay::Safe)], |_, args| {
        Ok(format!("looked at {}", args["at"].as_str().unwrap()))
    });
    let harness = world.harness(
        &session,
        world.scripted(vec![
            assistant_call("look", json!({"at": "the sky"})),
            assistant_text("it is blue"),
        ]),
        tools,
        Hooks::new(),
    );

    let result = harness.prompt(MAIN_LANE, "what colour").await.unwrap();
    assert_eq!(result.final_text.as_deref(), Some("it is blue"));
    assert_eq!(calls.load(Ordering::SeqCst), 1);
    let transcript = world.transcript(&session).await;
    assert_eq!(
        transcript.len(),
        4,
        "user, call, result, reply: {transcript:?}"
    );
    assert_eq!(transcript[2].1, "looked at the sky");
    session.close().await;
}

#[tokio::test]
async fn a_second_operation_on_a_busy_lane_is_refused() {
    let world = World::new();
    let session = world.session();
    let harness = world.harness(
        &session,
        world.scripted(vec![assistant_text("one")]),
        no_tools(),
        Hooks::new(),
    );
    // Claim the lane by hand, the way a run does, and leave it claimed.
    let started = harness.prompt(MAIN_LANE, "first").await.unwrap();
    assert_eq!(started.outcome, Outcome::Completed);

    // Now a *stuck* operation: start one and abandon the driver.
    let world2 = World::new();
    let session2 = world2.session();
    let stuck = world2.harness(&session2, Arc::new(NeverAnswers), no_tools(), Hooks::new());
    let running = {
        let stuck = stuck.clone();
        tokio::spawn(async move { stuck.prompt(MAIN_LANE, "hangs").await })
    };
    wait_until(|| async { current_operation(&session2).await.is_some() }).await;
    let refused = stuck.prompt(MAIN_LANE, "again").await;
    assert!(matches!(refused, Err(HarnessError::Busy(_))), "{refused:?}");
    stuck.abort(MAIN_LANE).await.unwrap();
    let ended = running.await.unwrap().unwrap();
    assert_eq!(ended.outcome, Outcome::Aborted);
    session.close().await;
    session2.close().await;
}

/// A model that never returns until cancelled.
struct NeverAnswers;

impl Model for NeverAnswers {
    fn respond<'a>(
        &'a self,
        _request: Request<'a>,
        _on_text: Deltas<'a>,
    ) -> BoxFuture<'a, reve::model::Result<Assistant>> {
        Box::pin(async move {
            std::future::pending::<()>().await;
            unreachable!()
        })
    }
}

async fn current_operation(session: &Session) -> Option<reve::ids::OpId> {
    session
        .lane_state(MAIN_LANE)
        .await
        .ok()
        .flatten()
        .and_then(|(s, _)| s.current_operation_id)
}

async fn wait_until<F, Fut>(mut check: F)
where
    F: FnMut() -> Fut,
    Fut: std::future::Future<Output = bool>,
{
    for _ in 0..500 {
        if check().await {
            return;
        }
        tokio::time::sleep(std::time::Duration::from_millis(5)).await;
    }
    panic!("condition never became true");
}

// ── queued input ─────────────────────────────────────────────────────────

#[tokio::test]
async fn a_steer_is_placed_before_the_next_generation() {
    let world = World::new();
    let session = world.session();
    // The first turn calls a tool; while the tool runs we steer, so the steer
    // must land after the tool result and before the second generation.
    let steered = Arc::new(tokio::sync::Notify::new());
    let (tools, _) = FakeTools::new(&[("slow", Replay::Safe)], |_, _| Ok("done".into()));
    let harness = world.harness(
        &session,
        world.scripted(vec![
            assistant_call("slow", json!({})),
            assistant_text("acknowledged"),
        ]),
        tools,
        Hooks::new(),
    );
    let _ = steered;
    // Queue the steer before the run starts by using nextRun, then steer
    // during the run through the inbox.
    let queued = harness
        .next_run(MAIN_LANE, "read this first")
        .await
        .unwrap();
    assert!(
        session.pending(queued).await.unwrap().is_some(),
        "a queued prompt is durable before the call returns"
    );
    let result = harness.prompt(MAIN_LANE, "go").await.unwrap();
    assert_eq!(result.outcome, Outcome::Completed);
    let transcript = world.transcript(&session).await;
    assert_eq!(
        transcript[0].1, "read this first",
        "the next-run queue is adopted ahead of the prompt: {transcript:?}"
    );
    assert_eq!(transcript[1].1, "go");
    session.close().await;
}

#[tokio::test]
async fn an_abort_ends_the_run_aborted_and_drops_queued_input() {
    let world = World::new();
    let session = world.session();
    let harness = world.harness(&session, Arc::new(NeverAnswers), no_tools(), Hooks::new());
    let mut events = harness.subscribe();
    let running = {
        let harness = harness.clone();
        tokio::spawn(async move { harness.prompt(MAIN_LANE, "hang").await })
    };
    wait_until(|| async { current_operation(&session).await.is_some() }).await;
    let steer = harness.steer(MAIN_LANE, "never seen").await.unwrap();
    harness.abort(MAIN_LANE).await.unwrap();
    let result = running.await.unwrap().unwrap();
    assert_eq!(result.outcome, Outcome::Aborted);
    assert!(
        session.pending(steer).await.unwrap().is_none(),
        "the terminal transaction deletes the dropped steer's payload"
    );
    let mut saw_abort = false;
    while let Ok(event) = events.try_recv() {
        if let Kind::RunAbort { steer, .. } = event.kind {
            saw_abort = true;
            assert_eq!(steer.len(), 1, "the abort event reports what it dropped");
        }
    }
    assert!(saw_abort, "an abort is announced");
    session.close().await;
}

// ── hooks ────────────────────────────────────────────────────────────────

#[tokio::test]
async fn before_tool_rewrites_the_arguments_that_get_persisted() {
    let world = World::new();
    let session = world.session();
    let (tools, _) = FakeTools::new(&[("echo", Replay::Safe)], |_, args| {
        Ok(args["text"].as_str().unwrap().to_string())
    });
    let hooks = Hooks::new().on_before_tool(Arc::new(|event: reve::hooks::BeforeToolEvent| {
        Box::pin(async move {
            let mut args = event.args.clone();
            args.insert("text".into(), json!("rewritten"));
            Ok(Some(BeforeToolResult {
                args: Some(args),
                ..Default::default()
            }))
        })
    }));
    let harness = world.harness(
        &session,
        world.scripted(vec![
            assistant_call("echo", json!({"text": "original"})),
            assistant_text("ok"),
        ]),
        tools,
        hooks,
    );
    harness.prompt(MAIN_LANE, "go").await.unwrap();
    let transcript = world.transcript(&session).await;
    assert_eq!(
        transcript[2].1, "rewritten",
        "the hook's arguments are the ones that ran: {transcript:?}"
    );
    session.close().await;
}

#[tokio::test]
async fn a_blocked_tool_never_executes_but_still_answers_the_model() {
    let world = World::new();
    let session = world.session();
    let (tools, calls) = FakeTools::new(&[("danger", Replay::Never)], |_, _| {
        panic!("a blocked tool must not run")
    });
    let hooks = Hooks::new().on_before_tool(Arc::new(|_: reve::hooks::BeforeToolEvent| {
        Box::pin(async move {
            Ok(Some(BeforeToolResult {
                block: Some(Block {
                    reason: "not allowed".into(),
                    terminate: false,
                }),
                ..Default::default()
            }))
        })
    }));
    let harness = world.harness(
        &session,
        world.scripted(vec![
            assistant_call("danger", json!({})),
            assistant_text("fine"),
        ]),
        tools,
        hooks,
    );
    let result = harness.prompt(MAIN_LANE, "go").await.unwrap();
    assert_eq!(result.outcome, Outcome::Completed);
    assert_eq!(calls.load(Ordering::SeqCst), 0);
    let transcript = world.transcript(&session).await;
    assert!(
        transcript[2].1.contains("not allowed"),
        "the model is told why: {transcript:?}"
    );
    session.close().await;
}

#[tokio::test]
async fn a_throwing_before_tool_hook_fails_the_call_closed() {
    let world = World::new();
    let session = world.session();
    let (tools, calls) = FakeTools::new(&[("danger", Replay::Never)], |_, _| {
        panic!("a tool whose gate failed must not run")
    });
    let hooks = Hooks::new().on_before_tool(Arc::new(|_: reve::hooks::BeforeToolEvent| {
        Box::pin(async move { Err("the policy service is down".to_string()) })
    }));
    let harness = world.harness(
        &session,
        world.scripted(vec![
            assistant_call("danger", json!({})),
            assistant_text("fine"),
        ]),
        tools,
        hooks,
    );
    harness.prompt(MAIN_LANE, "go").await.unwrap();
    assert_eq!(
        calls.load(Ordering::SeqCst),
        0,
        "before_tool is the one hook that fails closed"
    );
    session.close().await;
}

#[tokio::test]
async fn after_tool_rewrites_the_result_that_gets_persisted() {
    let world = World::new();
    let session = world.session();
    let (tools, _) = FakeTools::new(&[("secret", Replay::Safe)], |_, _| Ok("hunter2".into()));
    let hooks = Hooks::new().on_after_tool(Arc::new(|_: reve::hooks::AfterToolEvent| {
        Box::pin(async move {
            Ok(Some(AfterToolResult {
                content: Some("[redacted]".into()),
                ..Default::default()
            }))
        })
    }));
    let harness = world.harness(
        &session,
        world.scripted(vec![
            assistant_call("secret", json!({})),
            assistant_text("ok"),
        ]),
        tools,
        hooks,
    );
    harness.prompt(MAIN_LANE, "go").await.unwrap();
    let transcript = world.transcript(&session).await;
    assert_eq!(transcript[2].1, "[redacted]");
    session.close().await;
}

// ── failures and retries ─────────────────────────────────────────────────

#[tokio::test]
async fn a_retryable_provider_failure_is_retried_then_succeeds() {
    let world = World::new();
    let session = world.session();
    let model = Arc::new(FlakyModel {
        failures: AtomicUsize::new(0),
        remaining: 2,
        retryable: true,
        then: ScriptedModel::new(vec![assistant_text("eventually")], &world.cursor),
    });
    let harness = world.harness(&session, model, no_tools(), Hooks::new());
    let result = harness.prompt(MAIN_LANE, "go").await.unwrap();
    assert_eq!(result.outcome, Outcome::Completed);
    assert_eq!(result.final_text.as_deref(), Some("eventually"));
    session.close().await;
}

#[tokio::test]
async fn an_exhausted_retry_budget_fails_the_run_and_keeps_the_prompt() {
    let world = World::new();
    let session = world.session();
    let model = Arc::new(FlakyModel {
        failures: AtomicUsize::new(0),
        remaining: 99,
        retryable: true,
        then: ScriptedModel::new(vec![], &world.cursor),
    });
    let harness = world.harness(&session, model, no_tools(), Hooks::new());
    let result = harness.prompt(MAIN_LANE, "go").await.unwrap();
    assert_eq!(result.outcome, Outcome::Failed);
    assert_eq!(
        result.error.as_ref().map(|e| e.code.as_str()),
        Some("retries_exhausted")
    );
    assert_eq!(
        world.context(&session).await,
        vec![("user".to_string(), "go".to_string())],
        "the prompt survives a failed run; the failed attempts do not project"
    );
    assert_eq!(
        world.transcript(&session).await.len(),
        4,
        "but every attempt is on the record"
    );
    session.close().await;
}

#[tokio::test]
async fn a_terminal_provider_failure_is_not_retried() {
    let world = World::new();
    let session = world.session();
    let model = Arc::new(FlakyModel {
        failures: AtomicUsize::new(0),
        remaining: 1,
        retryable: false,
        then: ScriptedModel::new(vec![assistant_text("never reached")], &world.cursor),
    });
    let harness = world.harness(&session, model, no_tools(), Hooks::new());
    let result = harness.prompt(MAIN_LANE, "go").await.unwrap();
    assert_eq!(result.outcome, Outcome::Failed);
    assert_eq!(
        result.error.as_ref().map(|e| e.code.as_str()),
        Some("provider_error")
    );
    session.close().await;
}

#[tokio::test]
async fn a_truncated_response_never_executes_its_tool_call() {
    let world = World::new();
    let session = world.session();
    let (tools, calls) = FakeTools::new(&[("write", Replay::Never)], |_, _| {
        panic!("truncated arguments must never be executed")
    });
    let mut truncated = assistant_call("write", json!({"path": "/etc/pas"}));
    truncated.stop_reason = reve::model::StopReason::Length;
    let harness = world.harness(
        &session,
        world.scripted(vec![truncated, assistant_text("ok")]),
        tools,
        Hooks::new(),
    );
    harness.prompt(MAIN_LANE, "go").await.unwrap();
    assert_eq!(calls.load(Ordering::SeqCst), 0);
    let transcript = world.transcript(&session).await;
    assert!(
        transcript[2].1.contains("truncated"),
        "the model is told why: {transcript:?}"
    );
    session.close().await;
}

#[tokio::test]
async fn an_unknown_tool_is_answered_not_fatal() {
    let world = World::new();
    let session = world.session();
    let harness = world.harness(
        &session,
        world.scripted(vec![
            assistant_call("nonexistent", json!({})),
            assistant_text("my mistake"),
        ]),
        no_tools(),
        Hooks::new(),
    );
    let result = harness.prompt(MAIN_LANE, "go").await.unwrap();
    assert_eq!(result.outcome, Outcome::Completed);
    let transcript = world.transcript(&session).await;
    assert!(transcript[2].1.contains("nonexistent"), "{transcript:?}");
    session.close().await;
}

// ── recovery ─────────────────────────────────────────────────────────────

#[tokio::test]
async fn a_run_dropped_before_its_first_generation_resumes_and_finishes() {
    let world = World::new();
    // Crash: claim the lane with a model that never answers, then drop
    // everything without ever committing an assistant.
    {
        let session = world.session();
        let harness = world.harness(&session, Arc::new(NeverAnswers), no_tools(), Hooks::new());
        let running = {
            let harness = harness.clone();
            tokio::spawn(async move { harness.prompt(MAIN_LANE, "hello").await })
        };
        wait_until(|| async { current_operation(&session).await.is_some() }).await;
        running.abort();
        session.close().await;
    }

    let session = world.session();
    // We do not control where in the checkpoint the drop landed, so the prompt
    // may be a reservation or may already be placed. What must not happen is a
    // duplicate, which is what the post-resume transcript below pins down.
    assert!(
        session.transcript(MAIN_LANE).await.unwrap().len() <= 1,
        "a reserved prompt is placed at most once"
    );
    let harness = world.harness(
        &session,
        world.scripted(vec![assistant_text("resumed")]),
        no_tools(),
        Hooks::new(),
    );
    let result = harness.resume(MAIN_LANE).await.unwrap().expect("suspended");
    assert_eq!(result.outcome, Outcome::Completed, "{result:?}");
    assert_eq!(result.final_text.as_deref(), Some("resumed"));
    assert_eq!(
        world.transcript(&session).await,
        vec![
            ("user".to_string(), "hello".to_string()),
            ("assistant".to_string(), "resumed".to_string()),
        ],
        "the queued prompt is placed by the resumed run, exactly once"
    );
    session.close().await;
}

#[tokio::test]
async fn a_safe_tool_interrupted_mid_effect_is_re_executed() {
    let world = World::new();
    // Crash site X3/X4: `op.state` says effect_pending, no result entry.
    {
        let session = world.session();
        // The effect is genuinely in flight when we drop the driver.
        let (tools, _) = FakeTools::hanging(&[("read", Replay::Safe)], &["read"]);
        let harness = world.harness(
            &session,
            world.scripted(vec![assistant_call("read", json!({"path": "a"}))]),
            tools,
            Hooks::new(),
        );
        let running = {
            let harness = harness.clone();
            tokio::spawn(async move { harness.prompt(MAIN_LANE, "go").await })
        };
        wait_until(|| async { tool_is_pending(&session).await }).await;
        running.abort();
        session.close().await;
    }

    let session = world.session();
    let (tools, calls) = FakeTools::new(&[("read", Replay::Safe)], |_, args| {
        Ok(format!("re-read {}", args["path"].as_str().unwrap()))
    });
    let harness = world.harness(
        &session,
        world.scripted(vec![assistant_text("done")]),
        tools,
        Hooks::new(),
    );
    let result = harness.resume(MAIN_LANE).await.unwrap().expect("suspended");
    assert_eq!(result.outcome, Outcome::Completed, "{result:?}");
    assert_eq!(calls.load(Ordering::SeqCst), 1, "re-executed exactly once");
    let transcript = world.transcript(&session).await;
    assert_eq!(
        transcript[2].1, "re-read a",
        "the persisted arguments are what ran again: {transcript:?}"
    );
    session.close().await;
}

#[tokio::test]
async fn an_effectful_tool_interrupted_mid_effect_is_never_re_executed() {
    let world = World::new();
    {
        let session = world.session();
        let (tools, _) = FakeTools::hanging(&[("write", Replay::Never)], &["write"]);
        let harness = world.harness(
            &session,
            world.scripted(vec![assistant_call("write", json!({"path": "a"}))]),
            tools,
            Hooks::new(),
        );
        let running = {
            let harness = harness.clone();
            tokio::spawn(async move { harness.prompt(MAIN_LANE, "go").await })
        };
        wait_until(|| async { tool_is_pending(&session).await }).await;
        running.abort();
        session.close().await;
    }

    let session = world.session();
    let (tools, calls) = FakeTools::new(&[("write", Replay::Never)], |_, _| {
        panic!("an effectful tool must never be re-run after a crash")
    });
    let harness = world.harness(
        &session,
        world.scripted(vec![assistant_text("carrying on")]),
        tools,
        Hooks::new(),
    );
    let result = harness.resume(MAIN_LANE).await.unwrap().expect("suspended");
    assert_eq!(result.outcome, Outcome::Completed, "{result:?}");
    assert_eq!(calls.load(Ordering::SeqCst), 0);
    let transcript = world.transcript(&session).await;
    assert!(
        transcript[2].1.contains("Interrupted"),
        "the model is told the truth: the effect may or may not have happened: {transcript:?}"
    );
    session.close().await;
}

#[tokio::test]
async fn a_completed_tool_is_not_run_again_on_resume() {
    let world = World::new();
    // The first tool completes; the second is still planned when we drop.
    {
        let session = world.session();
        let (tools, _) = FakeTools::hanging(
            &[("first", Replay::Never), ("second", Replay::Never)],
            &["second"],
        );
        let mut both = assistant_call("first", json!({}));
        both.tool_calls.push(ToolCall {
            id: "call_second".into(),
            name: "second".into(),
            arguments: Default::default(),
        });
        let harness = world.harness(&session, world.scripted(vec![both]), tools, Hooks::new());
        let running = {
            let harness = harness.clone();
            tokio::spawn(async move { harness.prompt(MAIN_LANE, "go").await })
        };
        // Specifically: the first call is done and the second is in flight.
        wait_until(|| async { tool_progress(&session).await == Some((1, true)) }).await;
        running.abort();
        session.close().await;
    }

    let session = world.session();
    let (tools, calls) = FakeTools::new(
        &[("first", Replay::Never), ("second", Replay::Never)],
        |name, _| {
            assert_ne!(name, "first", "a completed call is never re-run");
            Ok("second ran".into())
        },
    );
    let harness = world.harness(
        &session,
        world.scripted(vec![assistant_text("both handled")]),
        tools,
        Hooks::new(),
    );
    let result = harness.resume(MAIN_LANE).await.unwrap().expect("suspended");
    assert_eq!(result.outcome, Outcome::Completed, "{result:?}");
    assert_eq!(
        calls.load(Ordering::SeqCst),
        0,
        "second is `never`, so it is not re-run either"
    );
    let transcript = world.transcript(&session).await;
    assert_eq!(transcript[2].1, "first ran");
    assert!(transcript[3].1.contains("Interrupted"), "{transcript:?}");
    session.close().await;
}

#[tokio::test]
async fn an_abort_committed_before_the_crash_ends_the_resumed_run_aborted() {
    let world = World::new();
    {
        let session = world.session();
        let harness = world.harness(&session, Arc::new(NeverAnswers), no_tools(), Hooks::new());
        let running = {
            let harness = harness.clone();
            tokio::spawn(async move { harness.prompt(MAIN_LANE, "go").await })
        };
        wait_until(|| async { current_operation(&session).await.is_some() }).await;
        harness.abort(MAIN_LANE).await.unwrap();
        running.abort();
        session.close().await;
    }

    let session = world.session();
    let harness = world.harness(
        &session,
        world.scripted(vec![assistant_text("must not be asked")]),
        no_tools(),
        Hooks::new(),
    );
    let result = harness.resume(MAIN_LANE).await.unwrap().expect("suspended");
    assert_eq!(
        result.outcome,
        Outcome::Aborted,
        "a durable abort survives the crash that raced it"
    );
    session.close().await;
}

#[tokio::test]
async fn an_idle_lane_has_nothing_to_resume() {
    let world = World::new();
    let session = world.session();
    let harness = world.harness(
        &session,
        world.scripted(vec![assistant_text("done")]),
        no_tools(),
        Hooks::new(),
    );
    harness.prompt(MAIN_LANE, "go").await.unwrap();
    assert!(harness.resume(MAIN_LANE).await.unwrap().is_none());
    session.close().await;
}

/// How many calls of the current tool batch are done, and is one in flight?
async fn tool_progress(session: &Session) -> Option<(usize, bool)> {
    let op = current_operation(session).await?;
    let (state, _) = session
        .register::<OperationState>(Namespace::OpState, op.as_str())
        .await
        .ok()??;
    let OperationState::Run(run) = state else {
        return None;
    };
    let reve::state::RunPhase::Tools { batch } = run.phase else {
        return None;
    };
    Some((
        batch.calls.iter().filter(|c| c.is_completed()).count(),
        batch
            .calls
            .iter()
            .any(|c| matches!(c, reve::state::ToolCallState::EffectPending { .. })),
    ))
}

/// Is any tool call in the current operation past its intent commit?
async fn tool_is_pending(session: &Session) -> bool {
    let Some(op) = current_operation(session).await else {
        return false;
    };
    let Ok(Some((state, _))) = session
        .register::<OperationState>(Namespace::OpState, op.as_str())
        .await
    else {
        return false;
    };
    match state {
        OperationState::Run(run) => match run.phase {
            reve::state::RunPhase::Tools { batch } => batch
                .calls
                .iter()
                .any(|c| matches!(c, reve::state::ToolCallState::EffectPending { .. })),
            _ => false,
        },
        _ => false,
    }
}
