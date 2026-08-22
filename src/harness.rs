//! The public surface (`docs/harness.md` §4).
//!
//! Everything a caller can ask a lane to do is one of two shapes:
//!
//! * **Start an operation.** Reserve the ids the operation will produce, write
//!   `op.meta` + `op.state` + the claim on `lane.state` in *one* conditional
//!   transaction, then drive it. The claim is what makes an operation per lane
//!   exclusive: a second starter's `Expect` on `lane.state` fails and it is
//!   told the lane is busy.
//! * **Amend a running operation.** Reserve the entry id, write its payload to
//!   `pending.entry`, and add the id to the running operation's inbox — again
//!   in one conditional transaction against `op.state`. The driver drains the
//!   inbox at its next checkpoint, so a queued input is durable before the
//!   caller is told it landed, and it survives a crash in between.
//!
//! No path here mutates a conversation entry: queued content lands as
//! `pending.entry` and the driver places it. That is the whole reason a steer
//! typed a millisecond before the process died is still there on resume.

use std::collections::HashMap;
use std::sync::{Arc, Mutex};

use tokio::sync::broadcast;

use crate::entry::{MAIN_LANE, Namespace, Transaction, Write};
use crate::events::{Event, Kind};
use crate::hooks::{BeforeRunEvent, Hooks};
use crate::ids::{EntryId, OpId};
use crate::lane::{Driver, OperationResult};
use crate::model::Model;
use crate::sandbox::tokio_util_lite::{CancelRx, CancelTx, channel as cancel_channel};
use crate::session::{Current, Expect, Restored, Session, SessionError};
use crate::state::{
    CheckpointPhase, CompactionState, Control, Intent, LaneConfiguration, LaneState,
    NavigationState, Operation, OperationState, PendingEntry, RetryPolicy, RunPhase, RunSettings,
    RunState, StructuralDecision, StructuralStatus,
};
use crate::tools::Tools;

pub type Result<T, E = HarnessError> = std::result::Result<T, E>;

#[derive(Debug, thiserror::Error)]
pub enum HarnessError {
    #[error(transparent)]
    Session(#[from] SessionError),
    /// The lane already has an operation. Steer, follow up, or queue for the
    /// next run instead.
    #[error("lane {0} is busy")]
    Busy(String),
    /// Nothing is running, so there is nothing to amend or abort.
    #[error("lane {0} is idle")]
    Idle(String),
    #[error("{0}")]
    Invalid(String),
}

/// Everything a lane needs to run, minus the per-operation cancellation.
pub struct Harness {
    session: Session,
    model: Arc<dyn Model>,
    tools: Arc<dyn Tools>,
    hooks: Hooks,
    events: broadcast::Sender<Event>,
    system_prompt: Arc<dyn Fn() -> String + Send + Sync>,
    settings: RunSettings,
    retry: RetryPolicy,
    seed: LaneConfiguration,
    /// One cancel channel per *running* operation. Purely an accelerator: the
    /// durable `Control::CancelRequested` is what an abort means, and this is
    /// how an in-flight request or tool learns about it without waiting.
    cancels: Mutex<HashMap<String, CancelTx>>,
}

pub struct HarnessConfig {
    pub model: Arc<dyn Model>,
    pub tools: Arc<dyn Tools>,
    pub hooks: Hooks,
    pub system_prompt: Arc<dyn Fn() -> String + Send + Sync>,
    pub settings: RunSettings,
    pub retry: RetryPolicy,
    pub configuration: LaneConfiguration,
    pub event_capacity: usize,
}

impl Harness {
    pub fn new(session: Session, config: HarnessConfig) -> Arc<Self> {
        let (events, _) = broadcast::channel(config.event_capacity.max(16));
        Arc::new(Self {
            session,
            model: config.model,
            tools: config.tools,
            hooks: config.hooks,
            events,
            system_prompt: config.system_prompt,
            settings: config.settings,
            retry: config.retry,
            seed: config.configuration,
            cancels: Mutex::new(HashMap::new()),
        })
    }

    pub fn session(&self) -> &Session {
        &self.session
    }

    pub fn subscribe(&self) -> broadcast::Receiver<Event> {
        self.events.subscribe()
    }

    fn emit(&self, lane: &str, op: Option<&str>, kind: Kind) {
        let _ = self.events.send(Event::new(lane, op, kind));
    }

    // ── starting operations ──────────────────────────────────────────────

    /// Send a prompt and run to completion.
    ///
    /// `before_run` runs *before* the intent is committed, so its rewritten
    /// prompt and settings are what `op.meta` records — recovery replays the
    /// hook's decision, not the raw input, and never re-runs the hook.
    pub async fn prompt(self: &Arc<Self>, lane: &str, text: &str) -> Result<OperationResult> {
        self.run(lane, vec![user_message(text)]).await
    }

    /// Start a run from arbitrary prompt content (one or more entries).
    pub async fn run(
        self: &Arc<Self>,
        lane: &str,
        prompts: Vec<PendingEntry>,
    ) -> Result<OperationResult> {
        let current = self.start_run(lane, prompts).await?;
        self.drive(current).await
    }

    /// Compact this lane as its own operation.
    pub async fn compact(
        self: &Arc<Self>,
        lane: &str,
        custom_instructions: Option<String>,
    ) -> Result<OperationResult> {
        let context = self.session.context(lane).await?;
        let preparation = crate::compaction::prepare(&context, &self.settings.compaction)
            .ok_or_else(|| {
                HarnessError::Invalid(
                    "there is not enough history to compact: the retained tail is everything"
                        .into(),
                )
            })?;
        let task_id = crate::ids::short_id("t");
        let state = OperationState::Compaction(CompactionState {
            control: Control::Running,
            custom_instructions: custom_instructions.clone(),
            structural: StructuralDecision {
                task_id: task_id.clone(),
                status: StructuralStatus::Deciding,
            },
        });
        let op = OpId::new();
        let extra = vec![Write::set(
            Namespace::OpPreparation,
            StructuralDecision::preparation_key(&op, &task_id),
            &preparation,
        )];
        let current = self
            .start(
                lane,
                op,
                Intent::Compaction {
                    custom_instructions,
                },
                state,
                extra,
            )
            .await?;
        self.emit(
            lane,
            Some(current.operation.operation_id.as_str()),
            Kind::CompactionStart {
                reason: crate::state::CompactionReason::Manual,
            },
        );
        self.drive(current).await
    }

    /// Move the lane's leaf. `target` of `None` rewinds to an empty
    /// conversation, which is a legitimate place to be.
    pub async fn navigate(
        self: &Arc<Self>,
        lane: &str,
        target: Option<EntryId>,
        label: Option<String>,
    ) -> Result<OperationResult> {
        if let Some(target) = &target
            && self.session.entry(target.clone()).await?.is_none()
        {
            return Err(HarnessError::Invalid(format!(
                "navigation target {target} does not exist"
            )));
        }
        let state = OperationState::Navigation(NavigationState {
            control: Control::Running,
            target_id: target.clone(),
            label: label.clone(),
        });
        let current = self
            .start(
                lane,
                OpId::new(),
                Intent::Navigation {
                    target_id: target,
                    summarize: false,
                    label,
                },
                state,
                vec![],
            )
            .await?;
        self.drive(current).await
    }

    // ── amending a running operation ─────────────────────────────────────

    /// Inject a message the run should see at its next checkpoint.
    pub async fn steer(&self, lane: &str, text: &str) -> Result<EntryId> {
        self.enqueue(lane, Queue::Steer, user_message(text)).await
    }

    /// Queue a message for after the model would have stopped, extending the
    /// same run.
    pub async fn follow_up(&self, lane: &str, text: &str) -> Result<EntryId> {
        self.enqueue(lane, Queue::FollowUp, user_message(text))
            .await
    }

    /// Add an entry to the conversation without asking for a response.
    /// Applied even when the run is being cancelled: a deferred write is a
    /// record of something that happened, not a request.
    pub async fn write_entry(&self, lane: &str, entry: PendingEntry) -> Result<EntryId> {
        self.enqueue(lane, Queue::Writes, entry).await
    }

    /// Queue a prompt for the lane's *next* run. Unlike the others this is
    /// legal while the lane is idle, and `lane.state` is where it waits.
    pub async fn next_run(&self, lane: &str, text: &str) -> Result<EntryId> {
        self.session.ensure_lane(lane, None, &self.seed).await?;
        let content = user_message(text);
        loop {
            let (state, seq) = self
                .session
                .lane_state(lane)
                .await?
                .ok_or_else(|| SessionError::Corrupt(format!("lane {lane} vanished")))?;
            let id = EntryId::new();
            let mut next = state.clone();
            next.pending_next_run.push(id.clone());
            let tx = Transaction::new()
                .with(Write::set(Namespace::PendingEntry, id.as_str(), &content))
                .with(Write::set(Namespace::LaneState, lane, &next));
            let committed = self
                .session
                .commit_if(vec![Expect::new(Namespace::LaneState, lane, Some(seq))], tx)
                .await?;
            if committed.is_some() {
                self.emit(
                    lane,
                    state.current_operation_id.as_ref().map(OpId::as_str),
                    Kind::QueueUpdate {
                        steer: vec![],
                        follow_up: vec![],
                        next_run: next.pending_next_run,
                    },
                );
                return Ok(id);
            }
        }
    }

    /// Ask the lane's operation to stop. Durable: the operation ends aborted
    /// even if the process dies before the driver notices, because the request
    /// is a committed transition of `op.state` and not a signal in memory.
    pub async fn abort(&self, lane: &str) -> Result<()> {
        loop {
            let Restored::Suspended(current) = self.session.restore(lane).await? else {
                return Err(HarnessError::Idle(lane.into()));
            };
            let op = current.operation.operation_id.clone();
            // A drained queue's payloads stay until the terminal transaction;
            // only the queue membership goes, so the abort event can still
            // report what was dropped.
            let Cancelled {
                state,
                steer,
                follow_up,
            } = cancel(&current.state);
            if let Some(next) = state {
                let committed = self
                    .session
                    .commit_if(
                        vec![Expect::new(
                            Namespace::OpState,
                            op.as_str(),
                            Some(current.state_seq),
                        )],
                        Transaction::new().with(Write::set(Namespace::OpState, op.as_str(), &next)),
                    )
                    .await?;
                if committed.is_none() {
                    continue;
                }
                self.emit(
                    lane,
                    Some(op.as_str()),
                    Kind::RunAbort {
                        steer: self.payloads(&steer).await?,
                        follow_up: self.payloads(&follow_up).await?,
                    },
                );
            }
            // Wake anything blocking on a request or a tool.
            if let Some(tx) = self.cancels.lock().unwrap().get(lane) {
                tx.cancel();
            }
            return Ok(());
        }
    }

    async fn payloads(&self, ids: &[EntryId]) -> Result<Vec<serde_json::Value>> {
        let mut out = Vec::with_capacity(ids.len());
        for id in ids {
            if let Some(pending) = self.session.pending(id.clone()).await?
                && let Some(payload) = pending.payload
            {
                out.push(payload);
            }
        }
        Ok(out)
    }

    /// Continue whatever this lane was doing when the process died.
    pub async fn resume(self: &Arc<Self>, lane: &str) -> Result<Option<OperationResult>> {
        match self.session.restore(lane).await? {
            Restored::Idle { .. } => Ok(None),
            Restored::Suspended(current) => {
                let op = current.operation.operation_id.clone();
                self.emit(lane, Some(op.as_str()), Kind::RunResume { recovery: true });
                self.drive(*current).await.map(Some)
            }
        }
    }

    /// Resume every lane that has an open operation. Sequential on purpose:
    /// the session is a single writer, and a resumed lane may immediately want
    /// to commit.
    pub async fn resume_all(self: &Arc<Self>) -> Result<Vec<OperationResult>> {
        let mut results = Vec::new();
        for lane in self.session.lanes().await? {
            if let Some(result) = self.resume(&lane).await? {
                results.push(result);
            }
        }
        Ok(results)
    }

    // ── plumbing ────────────────────────────────────────────────────────

    /// Build the intent for a run: hook first, then reserve the prompt ids,
    /// then one conditional transaction.
    async fn start_run(
        self: &Arc<Self>,
        lane: &str,
        prompts: Vec<PendingEntry>,
    ) -> Result<Current> {
        if prompts.is_empty() {
            return Err(HarnessError::Invalid("a run needs a prompt".into()));
        }
        // The id exists before the hook so the hook can name the run it is
        // deciding about, and so the intent it produces is committed under
        // exactly that id.
        let op = OpId::new();
        let before = self
            .hooks
            .before_run(BeforeRunEvent {
                lane: lane.to_string(),
                run_id: op.as_str().to_string(),
                prompt: prompts.iter().filter_map(|p| p.payload.clone()).collect(),
                system_prompt: (self.system_prompt)(),
            })
            .await;
        for error in &before.errors {
            self.emit(
                lane,
                Some(op.as_str()),
                Kind::HandlerError {
                    hook: error.hook.into(),
                    error: error.error.clone(),
                },
            );
        }
        let mut prompts = prompts;
        prompts.extend(before.value.messages.into_iter().map(PendingEntry::message));

        let ids: Vec<EntryId> = prompts.iter().map(|_| EntryId::new()).collect();
        let payloads: Vec<Write> = ids
            .iter()
            .zip(&prompts)
            .map(|(id, content)| Write::set(Namespace::PendingEntry, id.as_str(), content))
            .collect();
        let trigger = ids.last().cloned().expect("non-empty");
        let intent = Intent::Run {
            prompt_entry_ids: ids.clone(),
            system_prompt_override: before.value.system_prompt,
        };
        let state = OperationState::Run(RunState {
            control: Control::Running,
            settings: self.settings.clone(),
            // The prompts are queued as deferred writes and placed by the
            // driver's first checkpoint, so placement has exactly one
            // implementation and one crash story.
            phase: RunPhase::Checkpoint(CheckpointPhase::need_assistant(trigger)),
            inbox: crate::state::Inbox {
                steer: vec![],
                follow_up: vec![],
                writes: ids,
            },
            latest_assistant_entry_id: None,
        });
        let current = self.start(lane, op, intent, state, payloads).await?;
        self.emit(
            lane,
            Some(current.operation.operation_id.as_str()),
            Kind::RunStart,
        );
        Ok(current)
    }

    /// The exclusive claim. One transaction: metadata, program counter,
    /// whatever the operation needs pre-provisioned, and the lane's claim.
    /// The claim is conditional on the `lane.state` we read, so exactly one
    /// starter wins and the loser is told the lane is busy.
    async fn start(
        self: &Arc<Self>,
        lane: &str,
        op: OpId,
        intent: Intent,
        state: OperationState,
        extra: Vec<Write>,
    ) -> Result<Current> {
        self.session.ensure_lane(lane, None, &self.seed).await?;
        let (lane_state, lane_state_seq) = self
            .session
            .lane_state(lane)
            .await?
            .ok_or_else(|| SessionError::Corrupt(format!("lane {lane} vanished")))?;
        if lane_state.current_operation_id.is_some() {
            return Err(HarnessError::Busy(lane.into()));
        }
        let leaf = self.session.leaf(lane).await?;
        let operation = Operation {
            operation_id: op.clone(),
            lane: lane.to_string(),
            source_leaf_id: leaf.clone(),
            started_at: crate::ids::now_ms(),
            intent,
        };
        // A run adopts whatever was queued for the next run, in order, ahead
        // of its own prompt; any other operation leaves the queue alone.
        let mut state = state;
        let mut next_lane_state = LaneState {
            current_operation_id: Some(op.clone()),
            pending_next_run: lane_state.pending_next_run.clone(),
        };
        if let OperationState::Run(run) = &mut state
            && !lane_state.pending_next_run.is_empty()
        {
            let mut writes = lane_state.pending_next_run.clone();
            writes.append(&mut run.inbox.writes);
            run.inbox.writes = writes;
            next_lane_state.pending_next_run.clear();
        }

        let mut tx = Transaction::new()
            .with(Write::set(Namespace::OpMeta, op.as_str(), &operation))
            .with(Write::set(Namespace::OpState, op.as_str(), &state))
            .with(Write::set(Namespace::LaneState, lane, &next_lane_state));
        for write in extra {
            tx = tx.with(write);
        }
        let committed = self
            .session
            .commit_if(
                vec![Expect::new(
                    Namespace::LaneState,
                    lane,
                    Some(lane_state_seq),
                )],
                tx,
            )
            .await?;
        if committed.is_none() {
            return Err(HarnessError::Busy(lane.into()));
        }
        // Read the claim back rather than guessing its seqs: restore is the
        // one definition of "where this operation is", and it is what a
        // resume after a crash would have used.
        match self.session.restore(lane).await? {
            Restored::Suspended(current) if current.operation.operation_id == op => Ok(*current),
            _ => Err(HarnessError::Session(SessionError::Corrupt(format!(
                "operation {op} disappeared as it started"
            )))),
        }
    }

    /// Register a cancel channel, drive to the end, deregister.
    async fn drive(self: &Arc<Self>, current: Current) -> Result<OperationResult> {
        let lane = current.operation.lane.clone();
        let (tx, rx) = cancel_channel();
        // A cancel that arrived before we registered is already durable in
        // `op.state`; pre-arm the channel so an in-flight effect sees it too.
        if cancelled(&current.state) {
            tx.cancel();
        }
        self.cancels.lock().unwrap().insert(lane.clone(), tx);
        let driver = self.driver(rx);
        let result = driver.drive(current).await;
        self.cancels.lock().unwrap().remove(&lane);
        Ok(result?)
    }

    fn driver(&self, cancel: CancelRx) -> Driver {
        Driver {
            session: self.session.clone(),
            model: self.model.clone(),
            tools: self.tools.clone(),
            hooks: self.hooks.clone(),
            events: self.events.clone(),
            system_prompt: self.system_prompt.clone(),
            retry: self.retry,
            cancel,
        }
    }

    /// Reserve an id, persist the payload, and add it to the running
    /// operation's inbox — all conditional on the operation state we read.
    async fn enqueue(&self, lane: &str, queue: Queue, content: PendingEntry) -> Result<EntryId> {
        loop {
            let Restored::Suspended(current) = self.session.restore(lane).await? else {
                return Err(HarnessError::Idle(lane.into()));
            };
            let OperationState::Run(run) = &current.state else {
                return Err(HarnessError::Invalid(format!(
                    "lane {lane} is running a {:?} operation, which takes no input",
                    current.state.kind()
                )));
            };
            if run.control.is_cancelled() && queue != Queue::Writes {
                return Err(HarnessError::Invalid(format!(
                    "lane {lane} is being aborted"
                )));
            }
            let op = current.operation.operation_id.clone();
            let id = EntryId::new();
            let mut next = run.clone();
            match queue {
                Queue::Steer => next.inbox.steer.push(id.clone()),
                Queue::FollowUp => next.inbox.follow_up.push(id.clone()),
                Queue::Writes => next.inbox.writes.push(id.clone()),
            }
            let tx = Transaction::new()
                .with(Write::set(Namespace::PendingEntry, id.as_str(), &content))
                .with(Write::set(
                    Namespace::OpState,
                    op.as_str(),
                    OperationState::Run(next.clone()),
                ));
            let committed = self
                .session
                .commit_if(
                    vec![Expect::new(
                        Namespace::OpState,
                        op.as_str(),
                        Some(current.state_seq),
                    )],
                    tx,
                )
                .await?;
            if committed.is_none() {
                continue;
            }
            self.emit(
                lane,
                Some(op.as_str()),
                Kind::QueueUpdate {
                    steer: next.inbox.steer,
                    follow_up: next.inbox.follow_up,
                    next_run: current.lane_state.pending_next_run.clone(),
                },
            );
            return Ok(id);
        }
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
enum Queue {
    Steer,
    FollowUp,
    Writes,
}

fn cancelled(state: &OperationState) -> bool {
    match state {
        OperationState::Run(r) => r.control.is_cancelled(),
        OperationState::Compaction(c) => c.control.is_cancelled(),
        OperationState::Navigation(n) => n.control.is_cancelled(),
    }
}

/// What an abort turns a state into, plus the queued inputs it dropped.
struct Cancelled {
    /// `None` when the state was already cancelled: an abort is idempotent.
    state: Option<OperationState>,
    steer: Vec<EntryId>,
    follow_up: Vec<EntryId>,
}

/// Queued steers and follow-ups are dropped here — the user asked to stop, so
/// input that was waiting to be *acted on* is not acted on — while deferred
/// writes survive, because they record something that already happened.
fn cancel(state: &OperationState) -> Cancelled {
    let none = Cancelled {
        state: None,
        steer: vec![],
        follow_up: vec![],
    };
    if cancelled(state) {
        return none;
    }
    let requested_at = crate::ids::now_ms();
    let stopped =
        |drained_steer: Vec<EntryId>, drained_follow_up: Vec<EntryId>| Control::CancelRequested {
            requested_at,
            drained_steer,
            drained_follow_up,
        };
    match state {
        OperationState::Run(run) => {
            let mut next = run.clone();
            let steer = std::mem::take(&mut next.inbox.steer);
            let follow_up = std::mem::take(&mut next.inbox.follow_up);
            next.control = stopped(steer.clone(), follow_up.clone());
            Cancelled {
                state: Some(OperationState::Run(next)),
                steer,
                follow_up,
            }
        }
        OperationState::Compaction(c) => {
            let mut next = c.clone();
            next.control = stopped(vec![], vec![]);
            Cancelled {
                state: Some(OperationState::Compaction(next)),
                ..none
            }
        }
        OperationState::Navigation(n) => {
            let mut next = n.clone();
            next.control = stopped(vec![], vec![]);
            Cancelled {
                state: Some(OperationState::Navigation(next)),
                ..none
            }
        }
    }
}

fn user_message(text: &str) -> PendingEntry {
    PendingEntry::message(serde_json::json!({"role": "user", "content": text}))
}

/// The lane a caller means when it does not say.
pub fn main_lane() -> &'static str {
    MAIN_LANE
}
