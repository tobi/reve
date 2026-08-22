//! The owning task for one durable session, and the typed reads over it.
//!
//! `Storage` never leaves this task. Everyone else — every lane's driver, the
//! harness surface, the TUI — holds a [`Session`] handle and sends it work:
//! a transaction to commit, or a closure to run against the storage. That is
//! the structural single-writer guarantee, and it is also the **lane mutation
//! line** (`docs/harness.md` §4.3): every state-dependent mutation is one
//! message, validated and committed before the next one starts.
//!
//! Conditional commits carry *expectations* — register `seq` tokens the
//! caller read — and are rejected without writing when any token moved. That
//! is how two lanes, or a lane and an `abort()`, race safely: the loser
//! replans from the state the winner committed.
//!
//! A failed storage commit **faults** the session: every later command is
//! rejected, nothing partial is visible, and reopening restores each lane
//! from its registers.

use std::collections::HashMap;
use std::sync::Arc;
use std::sync::atomic::{AtomicBool, Ordering};

use serde_json::Value;
use tokio::sync::{mpsc, oneshot};

use crate::entry::{CommitResult, Entry, MAIN_LANE, Namespace, Transaction, Write};
use crate::ids::EntryId;
#[cfg(test)]
use crate::ids::OpId;
use crate::state::{
    LaneConfiguration, LaneLastResult, LaneState, Operation, OperationState, PendingEntry,
    RunPhase, StructuralDecision, ToolBatch, ToolCallState,
};
use crate::storage::{BranchScan, Order, Stats, Storage, StorageError};

#[derive(Debug, thiserror::Error)]
pub enum SessionError {
    #[error(transparent)]
    Storage(#[from] StorageError),
    #[error("session is closed")]
    Closed,
    /// A storage write failed. The harness is dead until reopened.
    #[error("session faulted: {0}")]
    Faulted(String),
    /// Restore found state a single writer could not have produced.
    #[error("corrupt session state: {0}")]
    Corrupt(String),
}

pub type Result<T, E = SessionError> = std::result::Result<T, E>;

/// A register `seq` the caller read, which a conditional commit requires to
/// be unchanged. `seq: None` means the register must be absent.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Expect {
    pub namespace: Namespace,
    pub key: String,
    pub seq: Option<u64>,
}

impl Expect {
    pub fn new(namespace: Namespace, key: impl Into<String>, seq: Option<u64>) -> Self {
        Self {
            namespace,
            key: key.into(),
            seq,
        }
    }
}

type ReadFn = Box<dyn FnOnce(&Storage) + Send>;

enum Command {
    Commit {
        tx: Transaction,
        expect: Vec<Expect>,
        reply: oneshot::Sender<Result<Option<CommitResult>>>,
    },
    Read(ReadFn),
    /// Stop owning the storage. The ack fires *after* the file — and its
    /// exclusive lock — has been dropped, so a caller that awaits `close`
    /// can reopen the session immediately.
    Close(oneshot::Sender<()>),
}

/// A clonable handle to the session's owner task.
#[derive(Clone)]
pub struct Session {
    tx: mpsc::Sender<Command>,
    id: String,
    faulted: Arc<AtomicBool>,
}

impl Session {
    /// Move the storage into its owner task and return the handle.
    pub fn spawn(storage: Storage) -> Self {
        let (tx, mut rx) = mpsc::channel::<Command>(64);
        let id = storage.header().id.clone();
        let faulted = Arc::new(AtomicBool::new(false));
        let fault_flag = faulted.clone();
        tokio::spawn(async move {
            let mut storage = storage;
            let mut fault: Option<String> = None;
            let mut ack = None;
            while let Some(command) = rx.recv().await {
                match command {
                    Command::Commit { tx, expect, reply } => {
                        if let Some(why) = &fault {
                            let _ = reply.send(Err(SessionError::Faulted(why.clone())));
                            continue;
                        }
                        let current = expect
                            .iter()
                            .all(|e| storage.register(e.namespace, &e.key).map(|r| r.seq) == e.seq);
                        if !current {
                            let _ = reply.send(Ok(None));
                            continue;
                        }
                        let result = match storage.commit(tx) {
                            Ok(result) => Ok(Some(result)),
                            Err(StorageError::Io(e)) => {
                                let why = e.to_string();
                                fault = Some(why.clone());
                                fault_flag.store(true, Ordering::SeqCst);
                                Err(SessionError::Faulted(why))
                            }
                            Err(e) => Err(SessionError::Storage(e)),
                        };
                        let _ = reply.send(result);
                    }
                    Command::Read(f) => f(&storage),
                    Command::Close(reply) => {
                        ack = Some(reply);
                        break;
                    }
                }
            }
            drop(storage);
            if let Some(ack) = ack {
                let _ = ack.send(());
            }
        });
        Self { tx, id, faulted }
    }

    pub fn id(&self) -> &str {
        &self.id
    }

    pub fn is_faulted(&self) -> bool {
        self.faulted.load(Ordering::SeqCst)
    }

    /// Commit unconditionally.
    pub async fn commit(&self, tx: Transaction) -> Result<CommitResult> {
        self.commit_if(Vec::new(), tx)
            .await?
            .ok_or(SessionError::Closed)
    }

    /// Commit only if every expectation still holds. `Ok(None)` means a
    /// token moved and nothing was written.
    pub async fn commit_if(
        &self,
        expect: Vec<Expect>,
        tx: Transaction,
    ) -> Result<Option<CommitResult>> {
        let (reply, result) = oneshot::channel();
        self.tx
            .send(Command::Commit { tx, expect, reply })
            .await
            .map_err(|_| SessionError::Closed)?;
        result.await.map_err(|_| SessionError::Closed)?
    }

    /// Run a read against the storage inside the owner task.
    pub async fn read<R, F>(&self, f: F) -> Result<R>
    where
        R: Send + 'static,
        F: FnOnce(&Storage) -> R + Send + 'static,
    {
        let (reply, result) = oneshot::channel::<R>();
        let job: ReadFn = Box::new(move |storage| {
            let _ = reply.send(f(storage));
        });
        self.tx
            .send(Command::Read(job))
            .await
            .map_err(|_| SessionError::Closed)?;
        result.await.map_err(|_| SessionError::Closed)
    }

    /// Give up ownership of the session file and wait for it to be released.
    pub async fn close(&self) {
        let (reply, released) = oneshot::channel();
        if self.tx.send(Command::Close(reply)).await.is_ok() {
            let _ = released.await;
        }
    }

    // ── typed reads ──────────────────────────────────────────────────────

    pub async fn entry(&self, id: EntryId) -> Result<Option<Entry>> {
        self.read(move |s| s.entry(&id).cloned()).await
    }

    pub async fn entries(&self, ids: Vec<EntryId>) -> Result<HashMap<EntryId, Entry>> {
        self.read(move |s| s.entries(&ids)).await
    }

    pub async fn register<T: serde::de::DeserializeOwned + Send + 'static>(
        &self,
        namespace: Namespace,
        key: impl Into<String>,
    ) -> Result<Option<(T, u64)>> {
        let key = key.into();
        self.read(move |s| s.register_value::<T>(namespace, &key))
            .await
    }

    pub async fn register_json(
        &self,
        namespace: Namespace,
        key: impl Into<String>,
    ) -> Result<Option<(Value, u64)>> {
        let key = key.into();
        self.read(move |s| {
            s.register(namespace, &key)
                .map(|r| (r.value.clone(), r.seq))
        })
        .await
    }

    pub async fn leaf(&self, lane: &str) -> Result<Option<EntryId>> {
        Ok(self
            .register::<Option<EntryId>>(Namespace::LaneLeaf, lane)
            .await?
            .and_then(|(leaf, _)| leaf))
    }

    pub async fn lane_state(&self, lane: &str) -> Result<Option<(LaneState, u64)>> {
        self.register::<LaneState>(Namespace::LaneState, lane).await
    }

    pub async fn lane_config(&self, lane: &str) -> Result<Option<(LaneConfiguration, u64)>> {
        self.register::<LaneConfiguration>(Namespace::LaneConfig, lane)
            .await
    }

    pub async fn last_result(&self, lane: &str) -> Result<Option<LaneLastResult>> {
        Ok(self
            .register::<LaneLastResult>(Namespace::LaneLastResult, lane)
            .await?
            .map(|(r, _)| r))
    }

    pub async fn pending(&self, id: EntryId) -> Result<Option<PendingEntry>> {
        Ok(self
            .register::<PendingEntry>(Namespace::PendingEntry, id.as_str())
            .await?
            .map(|(p, _)| p))
    }

    pub async fn stats(&self) -> Result<Stats> {
        self.read(|s| s.stats()).await
    }

    /// Lane names, from their `lane.state` registers. Always includes `main`
    /// once it has been seeded.
    pub async fn lanes(&self) -> Result<Vec<String>> {
        self.read(|s| {
            s.list_registers(Namespace::LaneState, "")
                .into_iter()
                .map(|r| r.key.clone())
                .collect()
        })
        .await
    }

    /// The lane's context window as the model sees it: oldest first, nothing
    /// past the newest compaction.
    pub async fn context(&self, lane: &str) -> Result<Vec<Entry>> {
        let lane = lane.to_string();
        self.read(move |s| {
            let leaf = s
                .register_value::<Option<EntryId>>(Namespace::LaneLeaf, &lane)
                .and_then(|(l, _)| l);
            project_context(s, leaf)
        })
        .await
    }

    /// The lane's transcript: the same window, raw entries, oldest first.
    pub async fn transcript(&self, lane: &str) -> Result<Vec<Entry>> {
        let lane = lane.to_string();
        self.read(move |s| {
            let leaf = s
                .register_value::<Option<EntryId>>(Namespace::LaneLeaf, &lane)
                .and_then(|(l, _)| l);
            s.scan_branch(&BranchScan {
                start: leaf,
                stop_at_type: Some("compaction".into()),
                order: Order::OldestFirst,
                ..Default::default()
            })
            .into_iter()
            .cloned()
            .collect()
        })
        .await
    }

    // ── lanes ────────────────────────────────────────────────────────────

    /// Seed a lane's registers if they do not exist. Existing configuration is
    /// never overridden by the seed.
    pub async fn ensure_lane(
        &self,
        lane: &str,
        at: Option<EntryId>,
        seed: &LaneConfiguration,
    ) -> Result<()> {
        let existing = self.lane_state(lane).await?;
        if existing.is_some() {
            if self.lane_config(lane).await?.is_none() {
                self.commit(Transaction::new().with(Write::set(Namespace::LaneConfig, lane, seed)))
                    .await?;
            }
            return Ok(());
        }
        if let Some(anchor) = &at
            && self.entry(anchor.clone()).await?.is_none()
        {
            return Err(SessionError::Corrupt(format!(
                "lane anchor {anchor} does not exist"
            )));
        }
        let tx = Transaction::new()
            .with(Write::set(Namespace::LaneConfig, lane, seed))
            .with(Write::set(Namespace::LaneLeaf, lane, at))
            .with(Write::set(Namespace::LaneState, lane, LaneState::default()));
        // Two callers may race to create the same lane; the loser's commit is
        // rejected by the absence expectation and the lane exists either way.
        let _ = self
            .commit_if(vec![Expect::new(Namespace::LaneState, lane, None)], tx)
            .await?;
        Ok(())
    }

    // ── facts ────────────────────────────────────────────────────────────

    pub async fn set_fact(
        &self,
        namespace: Namespace,
        key: &str,
        value: Option<Value>,
    ) -> Result<()> {
        let write = match value {
            Some(v) => Write::set(namespace, key, v),
            None => Write::delete(namespace, key),
        };
        self.commit(Transaction::new().with(write)).await?;
        Ok(())
    }

    // ── restore ──────────────────────────────────────────────────────────

    /// Restore one lane: five register point-lookups, then bounded
    /// validation of exactly what they name. Reads; never appends.
    pub async fn restore(&self, lane: &str) -> Result<Restored> {
        let lane = lane.to_string();
        self.read(move |s| restore(s, &lane)).await?
    }
}

/// Everything the driver needs to continue an open operation.
#[derive(Debug, Clone)]
pub struct Current {
    pub operation: Operation,
    pub state: OperationState,
    pub state_seq: u64,
    pub lane_state: LaneState,
    pub lane_state_seq: u64,
    pub leaf: Option<EntryId>,
    pub configuration: LaneConfiguration,
    pub configuration_seq: u64,
}

#[derive(Debug, Clone)]
pub enum Restored {
    Idle { lane: String },
    Suspended(Box<Current>),
}

fn restore(s: &Storage, lane: &str) -> Result<Restored> {
    let corrupt = |m: String| SessionError::Corrupt(format!("lane {lane}: {m}"));
    let (lane_state, lane_state_seq) = s
        .register_value::<LaneState>(Namespace::LaneState, lane)
        .ok_or_else(|| corrupt("missing lane.state".into()))?;
    let (leaf, _) = s
        .register_value::<Option<EntryId>>(Namespace::LaneLeaf, lane)
        .ok_or_else(|| corrupt("missing lane.leaf".into()))?;
    if let Some(leaf) = &leaf
        && s.entry(leaf).is_none()
    {
        return Err(corrupt(format!("leaf {leaf} does not exist")));
    }
    for id in &lane_state.pending_next_run {
        if s.register_value::<PendingEntry>(Namespace::PendingEntry, id.as_str())
            .is_none()
        {
            return Err(corrupt(format!("nextRun {id} has no pending.entry")));
        }
    }
    let Some(op_id) = &lane_state.current_operation_id else {
        return Ok(Restored::Idle { lane: lane.into() });
    };
    let (configuration, configuration_seq) = s
        .register_value::<LaneConfiguration>(Namespace::LaneConfig, lane)
        .ok_or_else(|| corrupt("open operation on an unconfigured lane".into()))?;
    let (operation, _) = s
        .register_value::<Operation>(Namespace::OpMeta, op_id.as_str())
        .ok_or_else(|| corrupt(format!("op.meta/{op_id} missing")))?;
    let (state, state_seq) = s
        .register_value::<OperationState>(Namespace::OpState, op_id.as_str())
        .ok_or_else(|| corrupt(format!("op.state/{op_id} missing")))?;
    if operation.lane != lane {
        return Err(corrupt(format!(
            "op.meta/{op_id} belongs to {}",
            operation.lane
        )));
    }
    if operation.intent.kind() != state.kind() {
        return Err(corrupt(format!(
            "op.state/{op_id} kind does not match its intent"
        )));
    }
    validate_current(s, &operation, &state).map_err(corrupt)?;
    Ok(Restored::Suspended(Box::new(Current {
        operation,
        state,
        state_seq,
        lane_state,
        lane_state_seq,
        leaf,
        configuration,
        configuration_seq,
    })))
}

/// §3.3's bounded checks over exactly what the state names.
fn validate_current(
    s: &Storage,
    operation: &Operation,
    state: &OperationState,
) -> std::result::Result<(), String> {
    let must_exist = |id: &EntryId, what: &str| -> std::result::Result<(), String> {
        s.entry(id)
            .map(|_| ())
            .ok_or_else(|| format!("{what} {id} does not exist"))
    };
    let pending_exists = |id: &EntryId| -> std::result::Result<(), String> {
        s.register(Namespace::PendingEntry, id.as_str())
            .map(|_| ())
            .ok_or_else(|| format!("pending {id} has no pending.entry register"))
    };
    // A reserved id is legitimately in one of two places: already placed as an
    // entry, or still waiting as a pending payload. Which one it is depends on
    // whether the crash landed before or after the placing commit, and both
    // are valid states to resume from.
    let placed_or_pending = |id: &EntryId, what: &str| -> std::result::Result<(), String> {
        if s.entry(id).is_some() || s.register(Namespace::PendingEntry, id.as_str()).is_some() {
            return Ok(());
        }
        Err(format!("{what} {id} is neither placed nor pending"))
    };
    if let Some(source) = &operation.source_leaf_id {
        must_exist(source, "sourceLeafId")?;
    }
    match &operation.intent {
        crate::state::Intent::Run {
            prompt_entry_ids, ..
        } => {
            for id in prompt_entry_ids {
                placed_or_pending(id, "prompt entry")?;
            }
        }
        crate::state::Intent::Navigation {
            target_id: Some(target),
            ..
        } => must_exist(target, "navigation target")?,
        _ => {}
    }
    let OperationState::Run(run) = state else {
        if let OperationState::Compaction(c) = state {
            let key =
                StructuralDecision::preparation_key(&operation.operation_id, &c.structural.task_id);
            if s.register(Namespace::OpPreparation, &key).is_none() {
                return Err(format!("op.preparation/{key} missing"));
            }
        }
        return Ok(());
    };
    if let Some(latest) = &run.latest_assistant_entry_id {
        must_exist(latest, "latestAssistantEntryId")?;
    }
    for id in run
        .inbox
        .steer
        .iter()
        .chain(&run.inbox.follow_up)
        .chain(&run.inbox.writes)
    {
        pending_exists(id)?;
    }
    if let crate::state::Control::CancelRequested {
        drained_steer,
        drained_follow_up,
        ..
    } = &run.control
    {
        for id in drained_steer.iter().chain(drained_follow_up) {
            pending_exists(id)?;
        }
    }
    match &run.phase {
        // The first checkpoint's trigger is the prompt, which the run itself
        // has not placed yet.
        RunPhase::Checkpoint(cp) => placed_or_pending(&cp.trigger_entry_id, "triggerEntryId")?,
        RunPhase::Assistant { generation } => {
            placed_or_pending(&generation.context().trigger_entry_id, "triggerEntryId")?;
            if let crate::state::Generation::EffectPending {
                response_entry_id, ..
            } = generation
                && let Some(entry) = s.entry(response_entry_id)
                && entry.role() != Some("assistant")
            {
                return Err(format!(
                    "reserved response {response_entry_id} materialised with other content"
                ));
            }
        }
        RunPhase::Tools { batch } => {
            let assistant = s
                .entry(&batch.assistant_entry_id)
                .ok_or_else(|| format!("batch assistant {} missing", batch.assistant_entry_id))?;
            let calls = crate::model::Assistant::from_message(
                assistant.message_value().unwrap_or(&Value::Null),
            )
            .map(|a| a.tool_calls.len())
            .unwrap_or(0);
            let mut indices: Vec<usize> = batch
                .calls
                .iter()
                .map(ToolCallState::source_index)
                .collect();
            let expected: Vec<usize> = (0..calls).collect();
            indices.sort_unstable();
            if indices != expected {
                return Err(format!(
                    "tool batch indices {indices:?} do not cover the {calls} calls of {}",
                    batch.assistant_entry_id
                ));
            }
            let mut result_ids: Vec<&EntryId> = batch
                .calls
                .iter()
                .map(ToolCallState::result_entry_id)
                .collect();
            result_ids.sort();
            result_ids.dedup();
            if result_ids.len() != batch.calls.len() {
                return Err("tool batch result ids are not unique".into());
            }
            for call in &batch.calls {
                match call {
                    ToolCallState::Completed {
                        result_entry_id, ..
                    } => {
                        let entry = s
                            .entry(result_entry_id)
                            .ok_or_else(|| format!("completed result {result_entry_id} missing"))?;
                        if entry.role() != Some("toolResult") {
                            return Err(format!("{result_entry_id} is not a tool result"));
                        }
                    }
                    ToolCallState::EffectPending { source_index, .. } => {
                        let key = ToolBatch::args_key(
                            &operation.operation_id,
                            &batch.turn_id,
                            *source_index,
                        );
                        if s.register(Namespace::OpToolArgs, &key).is_none() {
                            return Err(format!("op.tool_args/{key} missing"));
                        }
                    }
                    ToolCallState::Planned { .. } => {}
                }
            }
        }
        RunPhase::Compaction {
            structural,
            resume_after,
            ..
        } => {
            must_exist(&resume_after.trigger_entry_id, "resumeAfter trigger")?;
            let key =
                StructuralDecision::preparation_key(&operation.operation_id, &structural.task_id);
            if s.register(Namespace::OpPreparation, &key).is_none() {
                return Err(format!("op.preparation/{key} missing"));
            }
        }
        RunPhase::FailureDrain { provenance, .. } => {
            if let crate::state::FailureProvenance::Response { entry_id } = provenance {
                must_exist(entry_id, "failure provenance")?;
            }
        }
    }
    // A settled `aborted` response always has cancellation durable (invariant 19).
    if let Some(latest) = &run.latest_assistant_entry_id
        && let Some(entry) = s.entry(latest)
        && entry.stop_reason() == Some("aborted")
        && !run.control.is_cancelled()
    {
        return Err(format!(
            "{latest} is an aborted response under running control"
        ));
    }
    Ok(())
}

// ── context projection ───────────────────────────────────────────────────

/// How a provider request is built (`docs/harness.md` §2.5):
/// branch scan to the newest compaction, its summary and retained tail, then
/// everything after; assistant responses that errored or were aborted are
/// dropped; custom entries never enter context.
pub fn project_context(s: &Storage, leaf: Option<EntryId>) -> Vec<Entry> {
    let path = s.scan_branch(&BranchScan {
        start: leaf,
        stop_at_type: Some("compaction".into()),
        order: Order::OldestFirst,
        ..Default::default()
    });
    let mut context = Vec::new();
    for entry in path {
        if entry.is_compaction() {
            let summary = entry
                .payload
                .get("summary")
                .and_then(Value::as_str)
                .unwrap_or("");
            context.push(
                Entry::message(serde_json::json!({
                    "role": "user",
                    "content": format!(
                        "<summary>\nThe conversation so far was compacted. Summary of the \
                         earlier work:\n\n{summary}\n</summary>"
                    ),
                }))
                .with_id(EntryId::from(format!("{}:summary", entry.id))),
            );
            if let Some(tail) = entry.payload.get("retainedTail").and_then(Value::as_array) {
                for (index, message) in tail.iter().enumerate() {
                    context.push(
                        Entry::message(message.clone())
                            .with_id(EntryId::from(format!("{}:tail:{index}", entry.id))),
                    );
                }
            }
            continue;
        }
        if entry.entry_type != "message" {
            continue;
        }
        if entry.role() == Some("assistant")
            && matches!(entry.stop_reason(), Some("error") | Some("aborted"))
        {
            continue;
        }
        context.push(entry.clone());
    }
    context
}

/// A cheap token estimate for threshold checks: characters / 4.
pub fn estimate_tokens(entries: &[Entry]) -> u64 {
    entries
        .iter()
        .map(|e| {
            serde_json::to_string(&e.payload)
                .map(|s| s.len())
                .unwrap_or(0) as u64
        })
        .sum::<u64>()
        / 4
}

/// Seed configuration for a fresh `main`.
pub fn default_lane_name() -> &'static str {
    MAIN_LANE
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::state::{Control, Inbox, ModelRef, RunSettings, RunState};
    use serde_json::json;

    fn config() -> LaneConfiguration {
        LaneConfiguration {
            model: ModelRef {
                provider: "p".into(),
                model_id: "m".into(),
            },
            thinking_level: "off".into(),
            active_tool_names: vec![],
        }
    }

    fn user(text: &str) -> Entry {
        Entry::message(json!({"role": "user", "content": text}))
    }

    #[tokio::test]
    async fn storage_never_leaves_the_owner_and_reads_see_commits() {
        let session = Session::spawn(Storage::memory("s"));
        let e = user("hi");
        session
            .commit(Transaction::new().with(Write::entry(e.clone())))
            .await
            .unwrap();
        assert_eq!(
            session.entry(e.id.clone()).await.unwrap().unwrap().role(),
            Some("user")
        );
        session.close().await;
        assert!(matches!(
            session.entry(e.id).await,
            Err(SessionError::Closed)
        ));
    }

    #[tokio::test]
    async fn a_conditional_commit_is_rejected_when_its_token_moved() {
        let session = Session::spawn(Storage::memory("s"));
        session
            .commit(Transaction::new().with(Write::set(Namespace::FactName, "", "a")))
            .await
            .unwrap();
        let (_, seq) = session
            .register_json(Namespace::FactName, "")
            .await
            .unwrap()
            .unwrap();
        // Someone else writes first.
        session
            .commit(Transaction::new().with(Write::set(Namespace::FactName, "", "b")))
            .await
            .unwrap();
        let result = session
            .commit_if(
                vec![Expect::new(Namespace::FactName, "", Some(seq))],
                Transaction::new().with(Write::set(Namespace::FactName, "", "c")),
            )
            .await
            .unwrap();
        assert!(result.is_none(), "the stale writer loses");
        let (value, _) = session
            .register_json(Namespace::FactName, "")
            .await
            .unwrap()
            .unwrap();
        assert_eq!(value, "b");
        // Absence expectations work too.
        let result = session
            .commit_if(
                vec![Expect::new(Namespace::FactName, "", None)],
                Transaction::new().with(Write::set(Namespace::FactName, "", "d")),
            )
            .await
            .unwrap();
        assert!(result.is_none());
    }

    #[tokio::test]
    async fn ensure_lane_seeds_once_and_never_overrides_configuration() {
        let session = Session::spawn(Storage::memory("s"));
        session.ensure_lane("main", None, &config()).await.unwrap();
        let mut other = config();
        other.model.model_id = "other".into();
        session.ensure_lane("main", None, &other).await.unwrap();
        let (cfg, _) = session.lane_config("main").await.unwrap().unwrap();
        assert_eq!(cfg.model.model_id, "m", "the seed never overrides");
        assert_eq!(session.lanes().await.unwrap(), vec!["main".to_string()]);
        assert!(matches!(
            session.restore("main").await.unwrap(),
            Restored::Idle { .. }
        ));
    }

    #[tokio::test]
    async fn restore_rejects_an_aborted_response_under_running_control() {
        let session = Session::spawn(Storage::memory("s"));
        session.ensure_lane("main", None, &config()).await.unwrap();
        let prompt = user("go");
        let aborted =
            Entry::message(json!({"role": "assistant", "content": [], "stopReason": "aborted"}))
                .with_parent(Some(prompt.id.clone()));
        let op = OpId::new();
        let state = OperationState::Run(RunState {
            control: Control::Running,
            settings: RunSettings::default(),
            phase: RunPhase::Checkpoint(crate::state::CheckpointPhase::may_finish(
                aborted.id.clone(),
                true,
            )),
            inbox: Inbox::default(),
            latest_assistant_entry_id: Some(aborted.id.clone()),
        });
        let meta = Operation {
            operation_id: op.clone(),
            lane: "main".into(),
            source_leaf_id: None,
            started_at: 0,
            intent: crate::state::Intent::Run {
                prompt_entry_ids: vec![prompt.id.clone()],
                system_prompt_override: None,
            },
        };
        session
            .commit(
                Transaction::new()
                    .with(Write::entry(prompt))
                    .with(Write::entry(aborted.clone()))
                    .with(Write::set(
                        Namespace::LaneLeaf,
                        "main",
                        Some(aborted.id.clone()),
                    ))
                    .with(Write::set(Namespace::OpMeta, op.as_str(), &meta))
                    .with(Write::set(Namespace::OpState, op.as_str(), &state))
                    .with(Write::set(
                        Namespace::LaneState,
                        "main",
                        LaneState {
                            current_operation_id: Some(op.clone()),
                            pending_next_run: vec![],
                        },
                    )),
            )
            .await
            .unwrap();
        let err = session.restore("main").await.unwrap_err();
        assert!(matches!(err, SessionError::Corrupt(_)), "{err}");
    }

    #[test]
    fn context_projection_reads_nothing_past_a_compaction_and_drops_errors() {
        let mut s = Storage::memory("s");
        let old = user("ancient");
        let err =
            Entry::message(json!({"role": "assistant", "content": [], "stopReason": "error"}))
                .with_parent(Some(old.id.clone()));
        let compaction = Entry::compaction(
            "we did things",
            vec![json!({"role": "user", "content": "kept"})],
            500,
            false,
        )
        .with_parent(Some(err.id.clone()));
        let after = user("new").with_parent(Some(compaction.id.clone()));
        let aborted =
            Entry::message(json!({"role": "assistant", "content": [], "stopReason": "aborted"}))
                .with_parent(Some(after.id.clone()));
        let custom = Entry::custom("note", None).with_parent(Some(aborted.id.clone()));
        for e in [&old, &err, &compaction, &after, &aborted, &custom] {
            s.commit(Transaction::new().with(Write::entry(e.clone())))
                .unwrap();
        }
        let context = project_context(&s, Some(custom.id.clone()));
        let roles: Vec<_> = context
            .iter()
            .map(|e| e.role().unwrap().to_string())
            .collect();
        assert_eq!(roles, vec!["user", "user", "user"], "summary, tail, new");
        assert!(
            context[0].message_value().unwrap()["content"]
                .as_str()
                .unwrap()
                .contains("we did things")
        );
        assert_eq!(context[1].message_value().unwrap()["content"], "kept");
        assert_eq!(context[2].id, after.id);
        assert!(estimate_tokens(&context) > 0);
    }
}
