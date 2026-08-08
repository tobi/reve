//! Crash-site recovery, against a really-killed process.
//!
//! Nothing here is simulated. A child process opens a real JSONL session,
//! records a tool intent, and is SIGKILLed while the tool is in flight. Then
//! this process reopens the file and has to reduce what it finds.

use std::path::{Path, PathBuf};
use std::process::{Command, Stdio};
use std::time::{Duration, Instant};

use leve::ids::EntryId;
use leve::lane::{Tools, recover};
use leve::model::BoxFuture;
use leve::records::{MAIN_LANE, Replay};
use leve::storage::{Order, Storage};
use serde_json::{Map, Value};

struct NeverReplay;

impl Tools for NeverReplay {
    fn replay(&self, _name: &str) -> Replay {
        Replay::Never
    }
    fn invoke<'a>(
        &'a self,
        name: &'a str,
        _arguments: Map<String, Value>,
    ) -> BoxFuture<'a, Result<String, String>> {
        panic!("an effectful tool must never be re-run during recovery (got {name})")
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

#[tokio::test(flavor = "multi_thread")]
async fn a_killed_process_leaves_an_operation_recovery_can_finish() {
    let bin = crash_child_bin();
    if !bin.exists() {
        // `cargo test` builds bins before integration tests; if that changes,
        // say so rather than passing silently.
        panic!(
            "crash_child binary missing at {}; run `cargo build` first",
            bin.display()
        );
    }

    let dir = tempfile::tempdir().unwrap();
    let session = dir.path().join("session.jsonl");
    let ready = dir.path().join("ready");

    let mut child = Command::new(&bin)
        .arg(&session)
        .arg(&ready)
        .stdout(Stdio::null())
        .stderr(Stdio::null())
        .spawn()
        .expect("spawn the crash child");

    assert!(
        wait_for(&ready, Duration::from_secs(30)),
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

    // ── what the crash left ──────────────────────────────────────────────
    let mut storage = Storage::open(&session, "crash", None).expect("the session still opens");
    let records = storage.find_records(Some(MAIN_LANE));
    let intent = records
        .iter()
        .find(|r| r.record_type == "tool_started")
        .expect("the intent was flushed before the effect");
    let promised = EntryId::from(
        intent
            .str("resultEntryId")
            .expect("intent names its result"),
    );
    assert!(
        !records
            .iter()
            .any(|r| r.record_type == "operation_finished"),
        "the operation is open"
    );
    assert!(
        storage.entry(&promised).is_none(),
        "and its promised result never landed — this is the ambiguous-looking case"
    );

    // ── the reduction ────────────────────────────────────────────────────
    let reports = recover(&mut storage, MAIN_LANE, &NeverReplay)
        .await
        .unwrap();
    assert_eq!(reports.len(), 1, "exactly one interrupted operation");
    assert_eq!(reports[0].reconciled, vec!["hang".to_string()]);

    let result = storage
        .entry(&promised)
        .expect("recovery produced the promised entry");
    assert_eq!(result.role(), Some("toolResult"));
    let text = serde_json::to_string(&result.payload).unwrap();
    assert!(text.contains("Interrupted"), "{text}");
    assert!(text.contains("\"recovered\":true"), "{text}");
    assert!(
        storage
            .find_records(Some(MAIN_LANE))
            .iter()
            .any(|r| r.record_type == "operation_finished"),
        "and the operation is closed"
    );

    // ── it survives a restart, and re-running is a no-op ─────────────────
    drop(storage);
    let mut reopened = Storage::open(&session, "crash", None).expect("reopen after recovery");
    assert!(
        reopened.entry(&promised).is_some(),
        "the recovery is durable"
    );
    let before = reopened.find_entries(None, Order::OldestFirst).len();
    let again = recover(&mut reopened, MAIN_LANE, &NeverReplay)
        .await
        .unwrap();
    assert!(again.is_empty(), "nothing is left open");
    assert_eq!(
        reopened.find_entries(None, Order::OldestFirst).len(),
        before,
        "and recovery is idempotent"
    );
}
