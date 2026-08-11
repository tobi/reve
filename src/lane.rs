//! The run procedure, and the recovery that finishes what a crash interrupted.
//!
//! Every mutation follows one sequence: **record the intent, perform the
//! effect, append the result under the id the intent named.** A crash therefore
//! leaves either a completed operation or an incomplete one that says exactly
//! what it was going to do — never an ambiguous one.
//!
//! Concretely, one run writes:
//!
//! ```text
//! record operation_started  { runId, kind: "run" }
//! entry  user
//! record task_attempt       { runId, attempt }
//! entry  assistant
//! record tool_started       { runId, toolName, resultEntryId, replay }   <- intent
//! entry  toolResult                                                      <- effect, that id
//! record operation_finished { runId, outcome }
//! ```
//!
//! `Storage` is taken as `&mut`, not shared behind a lock. That is the single
//! writer guarantee: there is no handle through which a second task could
//! append, because there is no second handle.

use serde_json::{Map, Value};

use crate::ids::{EntryId, RunId};
use crate::model::{Model, Request, StopReason, ToolSchema};
use crate::records::{Entry, Outcome, Record, Replay};
use crate::sandbox::tokio_util_lite::CancelRx;
use crate::storage::Storage;

/// How many assistant turns one run may take before we stop.
///
/// A model that keeps calling tools without converging is a bug, and an agent
/// that loops forever costs money and trust.
pub const MAX_ATTEMPTS: u32 = 24;

#[derive(Debug, thiserror::Error)]
pub enum LaneError {
    #[error(transparent)]
    Storage(#[from] crate::storage::StorageError),
    #[error(transparent)]
    Model(#[from] crate::model::ModelError),
}

pub type Result<T, E = LaneError> = std::result::Result<T, E>;

/// What a lane can run. Implemented over Lua tools plus the built-ins.
pub trait Tools: Send + Sync {
    /// Whether this tool may be re-executed during recovery. A tool that is not
    /// declared, or no longer exists, is never replayable.
    fn replay(&self, name: &str) -> Replay;

    /// Run it. `Err` is a tool failure, which is a normal result the model
    /// gets to see — not a lane failure.
    fn invoke<'a>(
        &'a self,
        name: &'a str,
        arguments: Map<String, Value>,
    ) -> crate::model::BoxFuture<'a, std::result::Result<String, String>>;

    /// Cancellation-aware invocation. Existing tools inherit the non-cancel
    /// path; the production toolbox overrides it for guest commands.
    fn invoke_cancelled<'a>(
        &'a self,
        name: &'a str,
        arguments: Map<String, Value>,
        _cancel: Option<CancelRx>,
    ) -> crate::model::BoxFuture<'a, std::result::Result<String, String>> {
        self.invoke(name, arguments)
    }
}

/// One run's report.
#[derive(Debug, Clone, PartialEq)]
pub struct RunReport {
    pub run_id: RunId,
    pub outcome: Outcome,
    pub attempts: u32,
}

/// Passive updates emitted while a run proceeds. The observer/TUI can consume
/// these without owning or mutating storage.
#[derive(Debug, Clone)]
pub enum RunEvent {
    AssistantDelta(String),
    /// One model response is complete. Any following delta belongs to a new
    /// assistant turn and must not be appended to this one in the renderer.
    AssistantFinished,
    ToolStarted {
        name: String,
        arguments: Map<String, Value>,
    },
    ToolFinished {
        name: String,
        success: bool,
        text: String,
    },
}

pub struct Lane<'a> {
    pub name: String,
    pub storage: &'a mut Storage,
    pub model: &'a dyn Model,
    pub tools: &'a dyn Tools,
}

impl Lane<'_> {
    /// Run one operation with the default empty prompt context and no observer.
    pub async fn run(&mut self, prompt: &str, cancel: Option<CancelRx>) -> Result<RunReport> {
        self.run_with(prompt, cancel, "", &[], &|_| {}).await
    }

    /// Run one operation to completion, abort, or the retry cap.
    pub async fn run_with(
        &mut self,
        prompt: &str,
        mut cancel: Option<CancelRx>,
        system: &str,
        schemas: &[ToolSchema],
        on_event: &(dyn Fn(RunEvent) + Send + Sync),
    ) -> Result<RunReport> {
        let run_id = RunId::new();
        // Intent first: if the process dies after this line, recovery knows an
        // operation was open and what it was.
        self.record(
            "operation_started",
            serde_json::json!({
                "runId": run_id.as_str(),
                "intent": {"kind": "run"},
            }),
        )?;

        self.storage.append_entry(Entry::message(
            &self.name,
            serde_json::json!({"role": "user", "content": prompt}),
        ))?;

        let mut attempts = 0;
        let outcome = loop {
            if cancelled(&mut cancel) {
                break Outcome::Aborted;
            }
            attempts += 1;
            if attempts > MAX_ATTEMPTS {
                break Outcome::Failed;
            }
            self.record(
                "task_attempt",
                serde_json::json!({
                    "runId": run_id.as_str(),
                    "attempt": attempts,
                }),
            )?;

            let context: Vec<Entry> = self
                .storage
                .path_entries(&self.name)
                .into_iter()
                .cloned()
                .collect();
            let request = Request {
                context: &context,
                system,
                tools: schemas,
            };
            let assistant = match self
                .model
                .respond(request, &|delta| {
                    on_event(RunEvent::AssistantDelta(delta.to_string()));
                })
                .await
            {
                Ok(assistant) => assistant,
                Err(e) => {
                    self.record(
                        "task_failed",
                        serde_json::json!({
                            "runId": run_id.as_str(),
                            "error": e.to_string(),
                        }),
                    )?;
                    break Outcome::Failed;
                }
            };
            on_event(RunEvent::AssistantFinished);

            // The assistant entry lands before any tool result, so context
            // stays append-only: a result can never precede the turn that
            // asked for it.
            self.storage
                .append_entry(Entry::message(&self.name, assistant.message()))?;

            if assistant.stop_reason == StopReason::Stop || assistant.tool_calls.is_empty() {
                break Outcome::Completed;
            }

            let mut aborted = false;
            for call in &assistant.tool_calls {
                // Provision the id the result will use, then declare it.
                let result_id = EntryId::new();
                let replay = self.tools.replay(&call.name);
                on_event(RunEvent::ToolStarted {
                    name: call.name.clone(),
                    arguments: call.arguments.clone(),
                });
                self.record(
                    "tool_started",
                    serde_json::json!({
                        "runId": run_id.as_str(),
                        "toolCallId": call.id,
                        "toolName": call.name,
                        "resultEntryId": result_id.as_str(),
                        "replay": replay.as_str(),
                    }),
                )?;

                if cancelled(&mut cancel) {
                    // Reconciliation: an interrupted tool still gets its result
                    // under the promised id, or the conversation has a hole.
                    self.append_result(&result_id, call, interrupted_text(), true)?;
                    aborted = true;
                    break;
                }

                let text = match self
                    .tools
                    .invoke_cancelled(&call.name, call.arguments.clone(), cancel.clone())
                    .await
                {
                    Ok(text) => text,
                    Err(message) => format!("tool {} failed: {message}", call.name),
                };
                on_event(RunEvent::ToolFinished {
                    name: call.name.clone(),
                    success: !text.starts_with("tool ") || !text.contains(" failed:"),
                    text: text.clone(),
                });
                self.append_result(&result_id, call, text, false)?;
            }
            if aborted {
                break Outcome::Aborted;
            }
        };

        self.record(
            "operation_finished",
            serde_json::json!({
                "runId": run_id.as_str(),
                "outcome": outcome.as_str(),
            }),
        )?;
        Ok(RunReport {
            run_id,
            outcome,
            attempts,
        })
    }

    fn append_result(
        &mut self,
        id: &EntryId,
        call: &crate::model::ToolCall,
        text: String,
        interrupted: bool,
    ) -> Result<()> {
        let mut entry = Entry::message(
            &self.name,
            serde_json::json!({
                "role": "toolResult",
                "toolCallId": call.id,
                "content": [{"type": "text", "text": text}],
                "interrupted": interrupted,
            }),
        );
        entry.id = id.clone();
        self.storage.append_entry_if_missing(entry)?;
        Ok(())
    }

    fn record(&mut self, kind: &str, payload: Value) -> Result<()> {
        self.storage
            .append_record(Record::new(&self.name, kind, payload))?;
        Ok(())
    }
}

fn cancelled(cancel: &mut Option<CancelRx>) -> bool {
    cancel.as_mut().is_some_and(|rx| rx.is_cancelled())
}

fn interrupted_text() -> String {
    "Interrupted: reve aborted this operation before the tool finished.".to_string()
}

// ── recovery ─────────────────────────────────────────────────────────────

/// What recovery did to one interrupted operation.
#[derive(Debug, Clone, PartialEq)]
pub struct Recovered {
    pub run_id: String,
    pub lane: String,
    /// Tools that were re-run because both declarations said `safe`.
    pub replayed: Vec<String>,
    /// Tools that got a synthetic interrupted result instead.
    pub reconciled: Vec<String>,
}

/// Finish what a dead process started.
///
/// The reduction is two bounded reads: which operations were opened and never
/// finished, and which of their declared tool results never landed. Every
/// missing result is produced — replayed when, and only when, the recorded
/// declaration *and* the current one both say `safe`; otherwise synthesised.
///
/// Re-running this is a no-op, because it closes every operation it touches and
/// results are appended by provisioned id.
pub async fn recover(
    storage: &mut Storage,
    lane: &str,
    tools: &dyn Tools,
) -> Result<Vec<Recovered>> {
    // Read 1: which runs are still open.
    let mut open: Vec<String> = Vec::new();
    let mut finished: Vec<String> = Vec::new();
    for record in storage.find_records(Some(lane)) {
        let Some(run_id) = record.str("runId").map(str::to_string) else {
            continue;
        };
        match record.record_type.as_str() {
            "operation_started" => open.push(run_id),
            "operation_finished" => finished.push(run_id),
            _ => {}
        }
    }
    open.retain(|id| !finished.contains(id));
    if open.is_empty() {
        return Ok(Vec::new());
    }

    // Read 2: the tool intents belonging to those runs, and whether each result
    // landed. Collected up front so the borrow ends before we append.
    struct Pending {
        run_id: String,
        tool_name: String,
        tool_call_id: String,
        result_id: EntryId,
        replay: Replay,
    }
    let mut pending: Vec<Pending> = Vec::new();
    for record in storage.find_records(Some(lane)) {
        if record.record_type != "tool_started" {
            continue;
        }
        let Some(run_id) = record.str("runId") else {
            continue;
        };
        if !open.contains(&run_id.to_string()) {
            continue;
        }
        let Some(result_id) = record.str("resultEntryId").map(EntryId::from) else {
            continue;
        };
        if storage.entry(&result_id).is_some() {
            continue; // the effect completed; nothing to reconcile
        }
        pending.push(Pending {
            run_id: run_id.to_string(),
            tool_name: record.str("toolName").unwrap_or_default().to_string(),
            tool_call_id: record.str("toolCallId").unwrap_or_default().to_string(),
            result_id,
            replay: Replay::parse(record.str("replay").unwrap_or("never")),
        });
    }

    let mut reports: Vec<Recovered> = open
        .iter()
        .map(|run_id| Recovered {
            run_id: run_id.clone(),
            lane: lane.to_string(),
            replayed: Vec::new(),
            reconciled: Vec::new(),
        })
        .collect();

    for item in pending {
        // Both declarations must agree. A tool that has since become effectful
        // must not be replayed on the strength of an old record.
        let replayable =
            item.replay == Replay::Safe && tools.replay(&item.tool_name) == Replay::Safe;
        let (text, interrupted) = if replayable {
            match tools.invoke(&item.tool_name, Map::new()).await {
                Ok(text) => (text, false),
                Err(message) => (format!("tool {} failed: {message}", item.tool_name), false),
            }
        } else {
            (interrupted_text(), true)
        };

        let mut entry = Entry::message(
            lane,
            serde_json::json!({
                "role": "toolResult",
                "toolCallId": item.tool_call_id,
                "content": [{"type": "text", "text": text}],
                "interrupted": interrupted,
                "recovered": true,
            }),
        );
        entry.id = item.result_id.clone();
        storage.append_entry_if_missing(entry)?;

        if let Some(report) = reports.iter_mut().find(|r| r.run_id == item.run_id) {
            if replayable {
                report.replayed.push(item.tool_name);
            } else {
                report.reconciled.push(item.tool_name);
            }
        }
    }

    for run_id in &open {
        storage.append_record(Record::new(
            lane,
            "operation_finished",
            serde_json::json!({
                "runId": run_id,
                "outcome": Outcome::Aborted.as_str(),
                "reason": "recovered",
            }),
        ))?;
    }
    Ok(reports)
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::model::{Assistant, ScriptedModel};
    use crate::records::MAIN_LANE;
    use crate::storage::Order;
    use parking_lot::Mutex;

    /// Records what it was asked to run, so tests can assert on replay.
    struct TestTools {
        replay: Replay,
        calls: Mutex<Vec<String>>,
        fail: bool,
    }

    impl TestTools {
        fn new(replay: Replay) -> Self {
            Self {
                replay,
                calls: Mutex::new(Vec::new()),
                fail: false,
            }
        }
        fn failing() -> Self {
            Self {
                replay: Replay::Never,
                calls: Mutex::new(Vec::new()),
                fail: true,
            }
        }
        fn calls(&self) -> Vec<String> {
            self.calls.lock().clone()
        }
    }

    impl Tools for TestTools {
        fn replay(&self, _name: &str) -> Replay {
            self.replay
        }
        fn invoke<'a>(
            &'a self,
            name: &'a str,
            _arguments: Map<String, Value>,
        ) -> crate::model::BoxFuture<'a, std::result::Result<String, String>> {
            self.calls.lock().push(name.to_string());
            Box::pin(async move {
                if self.fail {
                    Err("boom".to_string())
                } else {
                    Ok(format!("{name} ran"))
                }
            })
        }
    }

    fn scripted(turns: Vec<Assistant>) -> (tempfile::TempDir, ScriptedModel) {
        let dir = tempfile::tempdir().unwrap();
        let cursor = dir.path().join("cursor");
        (dir, ScriptedModel::new(turns, cursor))
    }

    fn kinds(storage: &Storage) -> Vec<String> {
        let mut out = Vec::new();
        for record in storage.find_records(Some(MAIN_LANE)) {
            out.push(format!("record:{}", record.record_type));
        }
        out
    }

    /// The whole point: intent, then effect, then result under the promised id.
    #[tokio::test]
    async fn a_run_writes_intent_before_effect() {
        let (_d, model) = scripted(vec![
            Assistant::call("probe", serde_json::json!({})),
            Assistant::text("done"),
        ]);
        let tools = TestTools::new(Replay::Safe);
        let mut storage = Storage::memory("s1");
        let report = Lane {
            name: MAIN_LANE.into(),
            storage: &mut storage,
            model: &model,
            tools: &tools,
        }
        .run("go", None)
        .await
        .unwrap();

        assert_eq!(report.outcome, Outcome::Completed);
        assert_eq!(
            kinds(&storage),
            vec![
                "record:operation_started",
                "record:task_attempt",
                "record:tool_started",
                "record:task_attempt",
                "record:operation_finished",
            ]
        );

        // The tool_started names the id the result actually used.
        let intent = storage
            .find_records(Some(MAIN_LANE))
            .into_iter()
            .find(|r| r.record_type == "tool_started")
            .unwrap();
        let promised = EntryId::from(intent.str("resultEntryId").unwrap());
        let result = storage.entry(&promised).expect("the promised entry exists");
        assert_eq!(result.role(), Some("toolResult"));
    }

    #[tokio::test]
    async fn every_model_response_emits_its_own_turn_boundary() {
        let (_d, model) = scripted(vec![
            Assistant::call("probe", serde_json::json!({})),
            Assistant::text("done"),
        ]);
        let tools = TestTools::new(Replay::Safe);
        let mut storage = Storage::memory("s1");
        let events = Mutex::new(Vec::new());
        Lane {
            name: MAIN_LANE.into(),
            storage: &mut storage,
            model: &model,
            tools: &tools,
        }
        .run_with("go", None, "", &[], &|event| {
            events.lock().push(match event {
                RunEvent::AssistantDelta(_) => "delta",
                RunEvent::AssistantFinished => "assistant_finished",
                RunEvent::ToolStarted { .. } => "tool_started",
                RunEvent::ToolFinished { .. } => "tool_finished",
            });
        })
        .await
        .unwrap();

        assert_eq!(
            *events.lock(),
            [
                "assistant_finished",
                "tool_started",
                "tool_finished",
                "delta",
                "assistant_finished",
            ]
        );
    }

    /// Append-only context: a tool result can never precede the turn that asked
    /// for it.
    #[tokio::test]
    async fn the_assistant_turn_lands_before_its_tool_result() {
        let (_d, model) = scripted(vec![
            Assistant::call("probe", serde_json::json!({})),
            Assistant::text("done"),
        ]);
        let tools = TestTools::new(Replay::Safe);
        let mut storage = Storage::memory("s1");
        Lane {
            name: MAIN_LANE.into(),
            storage: &mut storage,
            model: &model,
            tools: &tools,
        }
        .run("go", None)
        .await
        .unwrap();

        let roles: Vec<&str> = storage
            .path_entries(MAIN_LANE)
            .iter()
            .filter_map(|e| e.role())
            .collect();
        assert_eq!(roles, vec!["user", "assistant", "toolResult", "assistant"]);
    }

    #[tokio::test]
    async fn a_failing_tool_is_a_result_not_a_lane_failure() {
        let (_d, model) = scripted(vec![
            Assistant::call("probe", serde_json::json!({})),
            Assistant::text("recovered"),
        ]);
        let tools = TestTools::failing();
        let mut storage = Storage::memory("s1");
        let report = Lane {
            name: MAIN_LANE.into(),
            storage: &mut storage,
            model: &model,
            tools: &tools,
        }
        .run("go", None)
        .await
        .unwrap();

        assert_eq!(
            report.outcome,
            Outcome::Completed,
            "the model gets to see the failure"
        );
        let text = storage
            .path_entries(MAIN_LANE)
            .iter()
            .filter(|e| e.role() == Some("toolResult"))
            .map(|e| serde_json::to_string(&e.payload).unwrap())
            .collect::<String>();
        assert!(text.contains("boom"), "{text}");
    }

    #[tokio::test]
    async fn a_model_error_fails_the_operation_and_still_closes_it() {
        let (_d, model) = scripted(vec![]); // exhausted immediately
        let tools = TestTools::new(Replay::Never);
        let mut storage = Storage::memory("s1");
        let report = Lane {
            name: MAIN_LANE.into(),
            storage: &mut storage,
            model: &model,
            tools: &tools,
        }
        .run("go", None)
        .await
        .unwrap();

        assert_eq!(report.outcome, Outcome::Failed);
        assert!(kinds(&storage).contains(&"record:operation_finished".to_string()));
    }

    /// A model that trips the abort the moment it is asked, so the run is
    /// already cancelling by the time the tool comes up — the real shape of
    /// hitting ctrl-c while a tool is in flight.
    struct CancellingModel {
        tx: crate::sandbox::tokio_util_lite::CancelTx,
    }

    impl Model for CancellingModel {
        fn respond<'a>(
            &'a self,
            _request: crate::model::Request<'a>,
            _on_text: crate::model::Deltas<'a>,
        ) -> crate::model::BoxFuture<'a, crate::model::Result<Assistant>> {
            Box::pin(async move {
                self.tx.cancel();
                Ok(Assistant::call("slow", serde_json::json!({})))
            })
        }
    }

    #[tokio::test]
    async fn aborting_mid_run_still_produces_the_promised_result_entry() {
        let tools = TestTools::new(Replay::Never);
        let mut storage = Storage::memory("s1");
        let (tx, rx) = crate::sandbox::tokio_util_lite::channel();
        let model = CancellingModel { tx };

        let report = Lane {
            name: MAIN_LANE.into(),
            storage: &mut storage,
            model: &model,
            tools: &tools,
        }
        .run("go", Some(rx))
        .await
        .unwrap();

        assert_eq!(report.outcome, Outcome::Aborted);
        assert!(tools.calls().is_empty(), "the tool never ran");

        let intent = storage
            .find_records(Some(MAIN_LANE))
            .into_iter()
            .find(|r| r.record_type == "tool_started")
            .expect("the intent was recorded before the abort");
        let promised = EntryId::from(intent.str("resultEntryId").unwrap());
        assert!(
            storage.entry(&promised).is_some(),
            "an aborted tool still gets its result, or the conversation has a hole"
        );
        assert!(
            storage
                .find_records(Some(MAIN_LANE))
                .iter()
                .any(|r| r.record_type == "operation_finished"),
            "and the operation is closed, not left dangling"
        );
    }

    #[tokio::test]
    async fn aborting_before_any_work_closes_the_operation_cleanly() {
        let (_d, model) = scripted(vec![Assistant::text("never reached")]);
        let tools = TestTools::new(Replay::Never);
        let mut storage = Storage::memory("s1");
        let (tx, rx) = crate::sandbox::tokio_util_lite::channel();
        tx.cancel();

        let report = Lane {
            name: MAIN_LANE.into(),
            storage: &mut storage,
            model: &model,
            tools: &tools,
        }
        .run("go", Some(rx))
        .await
        .unwrap();

        assert_eq!(report.outcome, Outcome::Aborted);
        assert_eq!(report.attempts, 0, "no turn was attempted");
        // Nothing was promised, so there is nothing to reconcile.
        assert!(!kinds(&storage).contains(&"record:tool_started".to_string()));
        assert!(kinds(&storage).contains(&"record:operation_finished".to_string()));
    }

    // ── recovery ─────────────────────────────────────────────────────────

    /// Build a session that looks like a process died between intent and effect.
    fn interrupted_session(replay: Replay) -> (Storage, EntryId) {
        let mut storage = Storage::memory("s1");
        let run_id = RunId::new();
        storage
            .append_record(Record::new(
                MAIN_LANE,
                "operation_started",
                serde_json::json!({
                    "runId": run_id.as_str(), "intent": {"kind": "run"}
                }),
            ))
            .unwrap();
        storage
            .append_entry(Entry::message(
                MAIN_LANE,
                serde_json::json!({"role": "user"}),
            ))
            .unwrap();
        storage
            .append_entry(Entry::message(
                MAIN_LANE,
                serde_json::json!({"role": "assistant"}),
            ))
            .unwrap();
        let result_id = EntryId::new();
        storage
            .append_record(Record::new(
                MAIN_LANE,
                "tool_started",
                serde_json::json!({
                    "runId": run_id.as_str(),
                    "toolCallId": "tc1",
                    "toolName": "probe",
                    "resultEntryId": result_id.as_str(),
                    "replay": replay.as_str(),
                }),
            ))
            .unwrap();
        // ... and then the process died. No result entry, no operation_finished.
        (storage, result_id)
    }

    #[tokio::test]
    async fn recovery_synthesises_a_result_for_an_effectful_tool() {
        let (mut storage, promised) = interrupted_session(Replay::Never);
        let tools = TestTools::new(Replay::Never);
        let reports = recover(&mut storage, MAIN_LANE, &tools).await.unwrap();

        assert_eq!(reports.len(), 1);
        assert_eq!(reports[0].reconciled, vec!["probe".to_string()]);
        assert!(
            tools.calls().is_empty(),
            "an effectful tool must never be re-run"
        );
        let entry = storage
            .entry(&promised)
            .expect("the promised id is filled in");
        let text = serde_json::to_string(&entry.payload).unwrap();
        assert!(text.contains("Interrupted"), "{text}");
    }

    #[tokio::test]
    async fn recovery_replays_a_tool_only_when_both_declarations_say_safe() {
        // Recorded safe, still safe -> replayed.
        let (mut storage, _) = interrupted_session(Replay::Safe);
        let tools = TestTools::new(Replay::Safe);
        let reports = recover(&mut storage, MAIN_LANE, &tools).await.unwrap();
        assert_eq!(reports[0].replayed, vec!["probe".to_string()]);
        assert_eq!(tools.calls(), vec!["probe".to_string()]);

        // Recorded safe, but the tool has since become effectful -> not replayed.
        let (mut storage, _) = interrupted_session(Replay::Safe);
        let tools = TestTools::new(Replay::Never);
        let reports = recover(&mut storage, MAIN_LANE, &tools).await.unwrap();
        assert!(reports[0].replayed.is_empty());
        assert_eq!(reports[0].reconciled, vec!["probe".to_string()]);
        assert!(tools.calls().is_empty());
    }

    #[tokio::test]
    async fn recovery_closes_the_operation_and_is_idempotent() {
        let (mut storage, _) = interrupted_session(Replay::Never);
        let tools = TestTools::new(Replay::Never);

        let first = recover(&mut storage, MAIN_LANE, &tools).await.unwrap();
        assert_eq!(first.len(), 1);
        let entries_after_first = storage.find_entries(None, Order::OldestFirst).len();

        let second = recover(&mut storage, MAIN_LANE, &tools).await.unwrap();
        assert!(second.is_empty(), "nothing is left open");
        assert_eq!(
            storage.find_entries(None, Order::OldestFirst).len(),
            entries_after_first,
            "and no duplicate results were appended"
        );
    }

    #[tokio::test]
    async fn recovery_leaves_a_completed_session_alone() {
        let (_d, model) = scripted(vec![Assistant::text("done")]);
        let tools = TestTools::new(Replay::Safe);
        let mut storage = Storage::memory("s1");
        Lane {
            name: MAIN_LANE.into(),
            storage: &mut storage,
            model: &model,
            tools: &tools,
        }
        .run("go", None)
        .await
        .unwrap();

        let before = storage.seq();
        let reports = recover(&mut storage, MAIN_LANE, &tools).await.unwrap();
        assert!(reports.is_empty());
        assert_eq!(
            storage.seq(),
            before,
            "a finished session is not touched at all"
        );
    }

    #[tokio::test]
    async fn a_tool_whose_result_did_land_is_not_reconciled_twice() {
        let (mut storage, promised) = interrupted_session(Replay::Never);
        // The effect completed; only `operation_finished` was lost.
        let mut entry = Entry::message(
            MAIN_LANE,
            serde_json::json!({"role": "toolResult", "content": [{"type": "text", "text": "real output"}]}),
        );
        entry.id = promised.clone();
        storage.append_entry(entry).unwrap();

        let tools = TestTools::new(Replay::Never);
        let reports = recover(&mut storage, MAIN_LANE, &tools).await.unwrap();
        assert_eq!(reports[0].reconciled.len(), 0, "the real result is kept");
        let text = serde_json::to_string(&storage.entry(&promised).unwrap().payload).unwrap();
        assert!(text.contains("real output"), "{text}");
    }
}
