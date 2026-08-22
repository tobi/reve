//! Crash-site recovery, against a really-killed process.
//!
//! Nothing here is simulated. A child process opens a real JSONL session,
//! commits a tool intent, and is SIGKILLed while the tool is in flight. Then
//! this process reopens the file and has to continue the operation — with an
//! effectful tool that panics if recovery is ever tempted to re-run it.

use std::path::{Path, PathBuf};
use std::process::{Command, Stdio};
use std::sync::Arc;
use std::sync::atomic::{AtomicUsize, Ordering};
use std::time::{Duration, Instant};

use reve::entry::{MAIN_LANE, Namespace};
use reve::harness::{Harness, HarnessConfig};
use reve::hooks::Hooks;
use reve::model::{Assistant, BoxFuture, ScriptedModel, ToolSchema};
use reve::sandbox::tokio_util_lite::CancelRx;
use reve::session::Session;
use reve::state::{
    LaneConfiguration, ModelRef, OperationState, Outcome, Replay, RetryPolicy, RunPhase,
    RunSettings, ToolCallState,
};
use reve::storage::Storage;
use reve::tools::Tools;
use serde_json::{Map, Value, json};

/// A tool set whose invocation is a test failure, or a counted re-run.
struct RecoveryTools {
    replay: Replay,
    calls: Arc<AtomicUsize>,
    reply: Option<&'static str>,
}

impl Tools for RecoveryTools {
    fn replay(&self, _name: &str) -> Option<Replay> {
        Some(self.replay)
    }

    fn schemas(&self) -> Vec<ToolSchema> {
        vec![ToolSchema {
            name: "hang".into(),
            description: "blocks forever".into(),
            schema: json!({"type": "object", "properties": {}}),
        }]
    }

    fn invoke<'a>(
        &'a self,
        name: &'a str,
        arguments: Map<String, Value>,
        _cancel: Option<CancelRx>,
    ) -> BoxFuture<'a, Result<String, String>> {
        self.calls.fetch_add(1, Ordering::SeqCst);
        let reply = self.reply.unwrap_or_else(|| {
            panic!("an effectful tool must never be re-run during recovery (got {name})")
        });
        assert_eq!(
            arguments.get("marker").and_then(Value::as_str),
            Some("persisted"),
            "a re-run uses the arguments the intent persisted"
        );
        Box::pin(async move { Ok(reply.to_string()) })
    }
}

fn crash_child_bin() -> PathBuf {
    // The integration test binary lives next to the other build artifacts.
    let mut dir = std::env::current_exe().expect("test binary path");
    dir.pop();
    if dir.ends_with("deps") {
        dir.pop();
    }
    dir.join("crash_child")
}

fn wait_for(path: &Path, limit: Duration) -> bool {
    let started = Instant::now();
    while started.elapsed() < limit {
        if path.exists() {
            return true;
        }
        std::thread::sleep(Duration::from_millis(20));
    }
    false
}

/// Run the child until its tool is in flight, then SIGKILL it.
fn crash(session: &Path, ready: &Path, replay: &str) {
    let bin = crash_child_bin();
    if !bin.exists() {
        // `cargo test` builds bins before integration tests; if that changes,
        // say so rather than passing silently.
        panic!(
            "crash_child binary missing at {}; run `cargo build` first",
            bin.display()
        );
    }
    let mut child = Command::new(&bin)
        .arg(session)
        .arg(ready)
        .arg(replay)
        .stdout(Stdio::null())
        .stderr(Stdio::null())
        .spawn()
        .expect("spawn the crash child");
    assert!(
        wait_for(ready, Duration::from_secs(60)),
        "child never reached the tool"
    );
    // Kill it outright. No unwinding, no flush on the way out — whatever is on
    // disk is what a real crash would have left.
    child.kill().expect("kill the child");
    let status = child.wait().expect("reap the child");
    assert!(
        !status.success(),
        "the child must have died, not exited cleanly"
    );
}

fn harness(session: &Session, tools: Arc<dyn Tools>, cursor: PathBuf) -> Arc<Harness> {
    Harness::new(
        session.clone(),
        HarnessConfig {
            model: Arc::new(ScriptedModel::new(
                vec![Assistant::text("carrying on")],
                cursor,
            )),
            tools,
            hooks: Hooks::new(),
            system_prompt: Arc::new(|| "you are a crash test".to_string()),
            settings: RunSettings::default(),
            retry: RetryPolicy::default(),
            configuration: LaneConfiguration {
                model: ModelRef {
                    provider: "test".into(),
                    model_id: "scripted".into(),
                },
                thinking_level: "off".into(),
                active_tool_names: vec!["hang".into()],
            },
            event_capacity: 16,
        },
    )
}

/// The state the crash left: an open operation whose tool call is past its
/// intent commit and has no result.
async fn assert_interrupted_tool(session: &Session) {
    let op = session
        .lane_state(MAIN_LANE)
        .await
        .unwrap()
        .expect("the lane exists")
        .0
        .current_operation_id
        .expect("the operation is still open");
    let (state, _) = session
        .register::<OperationState>(Namespace::OpState, op.as_str())
        .await
        .unwrap()
        .expect("the program counter survived");
    let OperationState::Run(run) = state else {
        panic!("expected a run");
    };
    let RunPhase::Tools { batch } = run.phase else {
        panic!("expected the tools phase, got {:?}", run.phase);
    };
    let call = batch.calls.first().expect("one call");
    assert!(
        matches!(call, ToolCallState::EffectPending { .. }),
        "the intent was flushed before the effect: {call:?}"
    );
    assert!(
        session
            .entry(call.result_entry_id().clone())
            .await
            .unwrap()
            .is_none(),
        "and its promised result never landed — this is the ambiguous case"
    );
}

#[tokio::test(flavor = "multi_thread")]
async fn a_killed_effectful_tool_is_reported_interrupted_never_re_run() {
    let dir = tempfile::tempdir().unwrap();
    let path = dir.path().join("session.jsonl");
    crash(&path, &dir.path().join("ready"), "never");

    let session = Session::spawn(Storage::open(&path, "crash", None).expect("the session opens"));
    assert_interrupted_tool(&session).await;

    let calls = Arc::new(AtomicUsize::new(0));
    let tools = Arc::new(RecoveryTools {
        replay: Replay::Never,
        calls: calls.clone(),
        reply: None,
    });
    let harness = harness(&session, tools, path.with_extension("resume-cursor"));
    let result = harness
        .resume(MAIN_LANE)
        .await
        .unwrap()
        .expect("there was something to resume");
    assert_eq!(result.outcome, Outcome::Completed);
    assert_eq!(calls.load(Ordering::SeqCst), 0);

    let transcript = session.transcript(MAIN_LANE).await.unwrap();
    let result_entry = transcript
        .iter()
        .find(|e| {
            e.message_value()
                .and_then(|m| m.get("role"))
                .and_then(Value::as_str)
                == Some("toolResult")
        })
        .expect("recovery produced the promised result entry");
    let text = serde_json::to_string(&result_entry.payload).unwrap();
    assert!(text.contains("Interrupted"), "{text}");
    assert!(
        text.contains("interrupted"),
        "it says it is synthetic: {text}"
    );

    // The operation is closed and stays closed across a reopen.
    assert!(harness.resume(MAIN_LANE).await.unwrap().is_none());
    session.close().await;
    let reopened = Session::spawn(Storage::open(&path, "crash", None).expect("reopen"));
    assert!(
        reopened
            .lane_state(MAIN_LANE)
            .await
            .unwrap()
            .unwrap()
            .0
            .current_operation_id
            .is_none(),
        "the recovery is durable"
    );
    let entries = reopened.transcript(MAIN_LANE).await.unwrap().len();
    assert_eq!(entries, 4, "user, call, synthetic result, reply");
    reopened.close().await;
}

#[tokio::test(flavor = "multi_thread")]
async fn a_killed_replay_safe_tool_is_re_executed_from_its_persisted_arguments() {
    let dir = tempfile::tempdir().unwrap();
    let path = dir.path().join("session.jsonl");
    crash(&path, &dir.path().join("ready"), "safe");

    let session = Session::spawn(Storage::open(&path, "crash", None).expect("the session opens"));
    assert_interrupted_tool(&session).await;

    let calls = Arc::new(AtomicUsize::new(0));
    let tools = Arc::new(RecoveryTools {
        replay: Replay::Safe,
        calls: calls.clone(),
        reply: Some("read it again"),
    });
    let harness = harness(&session, tools, path.with_extension("resume-cursor"));
    let result = harness.resume(MAIN_LANE).await.unwrap().expect("suspended");
    assert_eq!(result.outcome, Outcome::Completed);
    assert_eq!(calls.load(Ordering::SeqCst), 1, "re-executed exactly once");

    let transcript = session.transcript(MAIN_LANE).await.unwrap();
    let text = serde_json::to_string(&transcript[2].payload).unwrap();
    assert!(text.contains("read it again"), "{text}");
    session.close().await;
}

#[tokio::test(flavor = "multi_thread")]
async fn a_second_process_cannot_open_a_live_session() {
    let dir = tempfile::tempdir().unwrap();
    let path = dir.path().join("session.jsonl");
    let _held = Storage::open(&path, "held", None).expect("first open wins");
    let contended = Storage::open(&path, "contended", None);
    assert!(
        contended.is_err(),
        "one writer per session, enforced by the filesystem"
    );
}
