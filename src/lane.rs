//! The interpreter: one operation, driven from its total durable state.
//!
//! `op.state/{operationId}` is the program counter (`docs/harness.md` §3.2).
//! The driver loads it, plans the next action purely from it, performs at most
//! one effect, and commits the next total state — every edge of the graph in
//! §3.5 is exactly one conditional commit. Live calls and `resume()` run the
//! *same* loop: there is no separate recovery procedure, only the §4.5 policy
//! for an `effect_pending` state whose effect is not running in this process.
//!
//! Every transition is conditional on the `op.state` register still carrying
//! the `seq` the driver read. When it has moved — a `steer()` landed, an
//! `abort()` flipped control — the commit is rejected, the driver reloads, and
//! replans. When the operation's registers are *gone*, someone finalised it
//! externally: the driver stops without writing (§4.9).

use std::sync::Arc;

use serde_json::Value;
use tokio::sync::broadcast;

use crate::entry::{Entry, Namespace, Transaction, UsageRow, Write};
use crate::events::{Event, Kind};
use crate::hooks::{
    AfterToolEvent, BeforeCompactionEvent, BeforeRunEndEvent, BeforeToolEvent, Hooks,
    TransformContextEvent,
};
use crate::ids::{EntryId, OpId, UsageId};
use crate::model::{Assistant, Model, Request, StopReason, ToolCall};
use crate::sandbox::tokio_util_lite::CancelRx;
use crate::session::{Current, Expect, Restored, Session, SessionError};
use crate::state::{
    CheckpointPhase, CompactionPreparation, CompactionReason, CompactionState, Continuation,
    Control, FailureProvenance, Generation, GenerationContext, LaneLastResult, OpKind,
    OperationError, OperationState, Outcome, QueueMode, Replay, RetryPolicy, RunCompletion,
    RunPhase, RunState, StructuralDecision, StructuralStatus, SummaryContext, SummaryGeneration,
    ToolBatch, ToolCallState,
};
use crate::tools::Tools;

pub type Result<T, E = SessionError> = std::result::Result<T, E>;

/// Marks an error message whose transport called it retryable, between the
/// request and classification. Stripped before anything is committed.
const RETRYABLE_PREFIX: &str = "\u{0}retryable\u{0}";

/// What an operation ended with. The same value the caller receives and the
/// terminal transaction records as `lane.lastResult`.
#[derive(Debug, Clone, PartialEq)]
pub struct OperationResult {
    pub operation_id: OpId,
    pub kind: OpKind,
    pub outcome: Outcome,
    pub leaf_id: Option<EntryId>,
    pub final_assistant_entry_id: Option<EntryId>,
    pub final_text: Option<String>,
    pub error: Option<OperationError>,
    /// For compaction: the compaction entry.
    pub result_entry_id: Option<EntryId>,
    pub old_leaf_id: Option<EntryId>,
}

impl OperationResult {
    pub fn from_last_result(last: &LaneLastResult, final_text: Option<String>) -> Self {
        Self {
            operation_id: last.operation_id.clone(),
            kind: last.kind,
            outcome: last.outcome,
            leaf_id: last.leaf_id.clone(),
            final_assistant_entry_id: last.final_assistant_entry_id.clone(),
            final_text,
            error: last.error.clone(),
            result_entry_id: None,
            old_leaf_id: None,
        }
    }
}

/// Everything a driver needs that is not durable state.
pub struct Driver {
    pub session: Session,
    pub model: Arc<dyn Model>,
    pub tools: Arc<dyn Tools>,
    pub hooks: Hooks,
    pub events: broadcast::Sender<Event>,
    /// Evaluated per request unless the operation carries an override.
    pub system_prompt: Arc<dyn Fn() -> String + Send + Sync>,
    pub retry: RetryPolicy,
    /// The harness-owned abort signal for this operation.
    pub cancel: CancelRx,
}

/// Either the driver still owns the operation, or it was finalised elsewhere.
enum Reload {
    Current(Box<Current>),
    Finalized(OperationResult),
}

enum Step {
    Continue(Reload),
    Done(OperationResult),
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
enum InboxKind {
    Writes,
    Steer,
    FollowUp,
}

/// Context-limit failures, as providers phrase them. A heuristic, and labelled
/// as one (`docs/harness.md` §3.7).
pub fn is_context_overflow(message: &str) -> bool {
    let m = message.to_ascii_lowercase();
    [
        "context_length_exceeded",
        "context window",
        "context length",
        "maximum context",
        "prompt is too long",
        "too many tokens",
        "input is too long",
        "exceeds the maximum number of tokens",
    ]
    .iter()
    .any(|needle| m.contains(needle))
}

fn tool_result_message(
    call: &ToolCall,
    content: &str,
    is_error: bool,
    terminate: bool,
    synthetic: Option<&str>,
) -> Value {
    let mut message = serde_json::json!({
        "role": "toolResult",
        "toolCallId": call.id,
        "toolName": call.name,
        "content": [{"type": "text", "text": content}],
        "isError": is_error,
    });
    if terminate {
        message["terminate"] = Value::Bool(true);
    }
    if let Some(kind) = synthetic {
        message["synthetic"] = Value::String(kind.into());
    }
    message
}

impl Driver {
    fn emit(&self, lane: &str, op: &OpId, kind: Kind) {
        let _ = self.events.send(Event::new(lane, Some(op.as_str()), kind));
    }

    fn cancelled(&self) -> bool {
        self.cancel.is_cancelled()
    }

    fn report_handler_errors(&self, lane: &str, op: &OpId, errors: &[crate::hooks::HandlerError]) {
        for error in errors {
            self.emit(
                lane,
                op,
                Kind::HandlerError {
                    hook: error.hook.into(),
                    error: error.error.clone(),
                },
            );
        }
    }

    // ── the loop ─────────────────────────────────────────────────────────

    /// Drive the operation until it ends.
    pub async fn drive(&self, mut current: Current) -> Result<OperationResult> {
        loop {
            let step = match &current.state {
                OperationState::Run(_) => self.step_run(&current).await?,
                OperationState::Compaction(_) => self.step_compaction(&current).await?,
                OperationState::Navigation(_) => self.step_navigation(&current).await?,
            };
            match step {
                Step::Continue(Reload::Current(next)) => current = *next,
                Step::Continue(Reload::Finalized(result)) | Step::Done(result) => {
                    return Ok(result);
                }
            }
        }
    }

    // ── commits ──────────────────────────────────────────────────────────

    /// Overwrite `op.state` (plus any accompanying writes) if it is still at
    /// the seq we read. `Ok(Some(_))` carries the reloaded state after a
    /// successful commit; `Ok(None)` means a lane mutation won and the caller
    /// must replan from the reload.
    async fn transition(
        &self,
        current: &Current,
        next: OperationState,
        mut extra: Vec<Write>,
    ) -> Result<(bool, Reload)> {
        let op = current.operation.operation_id.clone();
        let expect = vec![Expect::new(
            Namespace::OpState,
            op.as_str(),
            Some(current.state_seq),
        )];
        extra.push(Write::set(Namespace::OpState, op.as_str(), &next));
        let committed = self
            .session
            .commit_if(expect, Transaction { writes: extra })
            .await?;
        Ok((committed.is_some(), self.reload(current).await?))
    }

    async fn reload(&self, current: &Current) -> Result<Reload> {
        match self.session.restore(&current.operation.lane).await? {
            Restored::Suspended(next)
                if next.operation.operation_id == current.operation.operation_id =>
            {
                Ok(Reload::Current(next))
            }
            _ => {
                // Externally finalised: the only durable word on the outcome
                // is lane.lastResult.
                let last = self
                    .session
                    .last_result(&current.operation.lane)
                    .await?
                    .filter(|r| r.operation_id == current.operation.operation_id)
                    .ok_or_else(|| {
                        SessionError::Corrupt(format!(
                            "operation {} vanished without a lastResult",
                            current.operation.operation_id
                        ))
                    })?;
                let text = self
                    .assistant_text(last.final_assistant_entry_id.as_ref())
                    .await?;
                Ok(Reload::Finalized(OperationResult::from_last_result(
                    &last, text,
                )))
            }
        }
    }

    async fn assistant_text(&self, id: Option<&EntryId>) -> Result<Option<String>> {
        Ok(match id {
            Some(id) => self
                .session
                .entry(id.clone())
                .await?
                .and_then(|e| Assistant::from_message(e.message_value()?))
                .map(|a| a.text),
            None => None,
        })
    }

    /// The terminal transaction (§3.13): delete every register the operation
    /// owns, record `lane.lastResult`, clear `currentOperationId`.
    async fn terminal(
        &self,
        current: &Current,
        outcome: Outcome,
        error: Option<OperationError>,
        publication: Vec<Write>,
        new_leaf: Option<Option<EntryId>>,
        result_entry_id: Option<EntryId>,
    ) -> Result<Step> {
        let op = current.operation.operation_id.clone();
        let lane = current.operation.lane.clone();
        let leaf_id = match &new_leaf {
            Some(leaf) => leaf.clone(),
            None => current.leaf.clone(),
        };

        let (final_assistant, run_completion) = match &current.state {
            OperationState::Run(run) => {
                let include = match (&run.phase, outcome) {
                    (RunPhase::Checkpoint(cp), Outcome::Completed) => match cp.continuation {
                        Continuation::MayFinish {
                            include_final_assistant,
                        } => include_final_assistant,
                        _ => true,
                    },
                    _ => true,
                };
                let completion = match outcome {
                    Outcome::Completed if include => Some(RunCompletion::Assistant),
                    Outcome::Completed => Some(RunCompletion::TerminatedTools),
                    _ => None,
                };
                (
                    include
                        .then(|| run.latest_assistant_entry_id.clone())
                        .flatten(),
                    completion,
                )
            }
            _ => (None, None),
        };
        let final_text = self.assistant_text(final_assistant.as_ref()).await?;

        // Everything the operation owns.
        let op_key = op.as_str().to_string();
        let (tool_args, preparations) = self
            .session
            .read(move |s| {
                let keys = |ns| {
                    s.list_registers(ns, &format!("{op_key}:"))
                        .into_iter()
                        .map(|r| r.key.clone())
                        .collect::<Vec<_>>()
                };
                (keys(Namespace::OpToolArgs), keys(Namespace::OpPreparation))
            })
            .await?;
        let mut writes = publication;
        if let Some(leaf) = &new_leaf {
            writes.push(Write::set(Namespace::LaneLeaf, &lane, leaf));
        }
        writes.push(Write::delete(Namespace::OpMeta, op.as_str()));
        writes.push(Write::delete(Namespace::OpState, op.as_str()));
        for key in tool_args {
            writes.push(Write::delete(Namespace::OpToolArgs, key));
        }
        for key in preparations {
            writes.push(Write::delete(Namespace::OpPreparation, key));
        }
        if let OperationState::Run(run) = &current.state {
            let mut owned: Vec<EntryId> = Vec::new();
            owned.extend(run.inbox.steer.iter().cloned());
            owned.extend(run.inbox.follow_up.iter().cloned());
            owned.extend(run.inbox.writes.iter().cloned());
            if let Control::CancelRequested {
                drained_steer,
                drained_follow_up,
                ..
            } = &run.control
            {
                owned.extend(drained_steer.iter().cloned());
                owned.extend(drained_follow_up.iter().cloned());
            }
            for id in owned {
                writes.push(Write::delete(Namespace::PendingEntry, id.as_str()));
            }
        }
        let last = LaneLastResult {
            operation_id: op.clone(),
            kind: current.operation.intent.kind(),
            outcome,
            leaf_id: leaf_id.clone(),
            final_assistant_entry_id: final_assistant.clone(),
            error: error.clone(),
            run_completion,
        };
        writes.push(Write::set(Namespace::LaneLastResult, &lane, &last));
        // The latest lane.state (CAS-protected below); clear only our field.
        let mut lane_state = current.lane_state.clone();
        lane_state.current_operation_id = None;
        writes.push(Write::set(Namespace::LaneState, &lane, &lane_state));

        let expect = vec![
            Expect::new(Namespace::OpState, op.as_str(), Some(current.state_seq)),
            Expect::new(Namespace::LaneState, &lane, Some(current.lane_state_seq)),
        ];
        let committed = self
            .session
            .commit_if(expect, Transaction { writes })
            .await?;
        if committed.is_none() {
            return Ok(Step::Continue(self.reload(current).await?));
        }
        let result = OperationResult {
            operation_id: op.clone(),
            kind: last.kind,
            outcome,
            leaf_id,
            final_assistant_entry_id: final_assistant,
            final_text,
            error,
            result_entry_id,
            old_leaf_id: current.operation.source_leaf_id.clone(),
        };
        match last.kind {
            OpKind::Run => self.emit(
                &lane,
                &op,
                Kind::RunEnd {
                    outcome,
                    leaf_id: result.leaf_id.clone(),
                    final_entry_id: result.final_assistant_entry_id.clone(),
                    final_text: result.final_text.clone(),
                    error: result.error.clone(),
                },
            ),
            OpKind::Compaction => self.emit(
                &lane,
                &op,
                Kind::CompactionEnd {
                    reason: CompactionReason::Manual,
                    outcome,
                    entry_id: result.result_entry_id.clone(),
                },
            ),
            OpKind::Navigation => self.emit(
                &lane,
                &op,
                Kind::NavigationEnd {
                    outcome,
                    old_leaf_id: result.old_leaf_id.clone(),
                    new_leaf_id: result.leaf_id.clone(),
                },
            ),
        }
        Ok(Step::Done(result))
    }

    // ── runs ─────────────────────────────────────────────────────────────

    async fn step_run(&self, current: &Current) -> Result<Step> {
        let OperationState::Run(run) = &current.state else {
            unreachable!()
        };
        match &run.phase {
            RunPhase::Checkpoint(cp) => self.checkpoint(current, run, cp).await,
            RunPhase::Assistant { generation } => self.assistant(current, run, generation).await,
            RunPhase::Tools { batch } => self.tools(current, run, batch).await,
            RunPhase::Compaction {
                reason,
                structural,
                resume_after,
            } => {
                self.in_run_compaction(current, run, *reason, structural, resume_after)
                    .await
            }
            RunPhase::FailureDrain { error, .. } => {
                self.failure_drain(current, run, error.clone()).await
            }
        }
    }

    fn run_with(&self, run: &RunState, phase: RunPhase) -> OperationState {
        OperationState::Run(RunState {
            phase,
            ..run.clone()
        })
    }

    /// Place pending content: entries from the registers, registers deleted,
    /// leaf moved. Returns the writes, the newest entry id, and the entries.
    async fn placement_writes(
        &self,
        lane: &str,
        leaf: Option<EntryId>,
        ids: &[EntryId],
    ) -> Result<(Vec<Write>, Option<EntryId>, Vec<Entry>)> {
        let mut writes = Vec::new();
        let mut parent = leaf;
        let mut placed = Vec::new();
        for id in ids {
            let pending =
                self.session.pending(id.clone()).await?.ok_or_else(|| {
                    SessionError::Corrupt(format!("pending {id} has no register"))
                })?;
            let entry = pending.into_entry(id.clone()).with_parent(parent.clone());
            parent = Some(entry.id.clone());
            writes.push(Write::entry(entry.clone()));
            writes.push(Write::delete(Namespace::PendingEntry, id.as_str()));
            placed.push(entry);
        }
        if !ids.is_empty() {
            writes.push(Write::set(Namespace::LaneLeaf, lane, &parent));
        }
        Ok((writes, parent, placed))
    }

    fn take(mode: QueueMode, queue: &[EntryId]) -> Vec<EntryId> {
        match mode {
            QueueMode::All => queue.to_vec(),
            QueueMode::OneAtATime => queue.iter().take(1).cloned().collect(),
        }
    }

    async fn checkpoint(
        &self,
        current: &Current,
        run: &RunState,
        cp: &CheckpointPhase,
    ) -> Result<Step> {
        let lane = current.operation.lane.clone();
        let op = current.operation.operation_id.clone();

        // Deferred writes are applied even under cancellation (§3.12).
        if !run.inbox.writes.is_empty() && (!cp.skip_inbox_once || run.control.is_cancelled()) {
            return self
                .apply_inbox(current, run, run.inbox.writes.clone(), InboxKind::Writes)
                .await;
        }
        if run.control.is_cancelled() {
            return self.abort_finish(current).await;
        }
        if !cp.skip_inbox_once {
            let steer = Self::take(run.settings.steering_mode, &run.inbox.steer);
            if !steer.is_empty() {
                return self
                    .apply_inbox(current, run, steer, InboxKind::Steer)
                    .await;
            }
        }

        // Threshold compaction, at most once per trigger boundary.
        let need_assistant = matches!(cp.continuation, Continuation::NeedAssistant { .. });
        if need_assistant
            && run.settings.compaction.enabled
            && cp.threshold_checked_trigger_entry_id.as_ref() != Some(&cp.trigger_entry_id)
        {
            let context = self.session.context(&lane).await?;
            let tokens = crate::session::estimate_tokens(&context);
            let mut checked = cp.clone();
            checked.threshold_checked_trigger_entry_id = Some(cp.trigger_entry_id.clone());
            if crate::compaction::over_threshold(
                tokens,
                run.settings.context_window,
                &run.settings.compaction,
            ) && let Some(preparation) =
                crate::compaction::prepare(&context, &run.settings.compaction)
            {
                let task_id = crate::ids::short_id("t");
                let key = StructuralDecision::preparation_key(&op, &task_id);
                let next = self.run_with(
                    run,
                    RunPhase::Compaction {
                        reason: CompactionReason::Threshold,
                        structural: StructuralDecision {
                            task_id,
                            status: StructuralStatus::Deciding,
                        },
                        resume_after: checked,
                    },
                );
                let extra = vec![Write::set(Namespace::OpPreparation, key, &preparation)];
                let (ok, reload) = self.transition(current, next, extra).await?;
                if ok {
                    self.emit(
                        &lane,
                        &op,
                        Kind::CompactionStart {
                            reason: CompactionReason::Threshold,
                        },
                    );
                }
                return Ok(Step::Continue(reload));
            }
            let next = self.run_with(run, RunPhase::Checkpoint(checked));
            return Ok(Step::Continue(
                self.transition(current, next, vec![]).await?.1,
            ));
        }

        // Start generation.
        if let Continuation::NeedAssistant {
            overflow_recovery_used,
        } = cp.continuation
        {
            let context = GenerationContext {
                step_id: crate::ids::short_id("s"),
                trigger_entry_id: cp.trigger_entry_id.clone(),
                configuration: current.configuration.clone(),
                retry_policy: self.retry,
                overflow_recovery_used,
            };
            let next = self.run_with(
                run,
                RunPhase::Assistant {
                    generation: Generation::Ready {
                        context,
                        next_attempt: 1,
                    },
                },
            );
            return Ok(Step::Continue(
                self.transition(current, next, vec![]).await?.1,
            ));
        }

        // Follow-ups, once assistant and tool continuation are exhausted.
        let follow_up = Self::take(run.settings.follow_up_mode, &run.inbox.follow_up);
        if !follow_up.is_empty() {
            return self
                .apply_inbox(current, run, follow_up, InboxKind::FollowUp)
                .await;
        }

        // before_run_end may add one more follow-up, born placed.
        let transcript = self.session.transcript(&lane).await?;
        let messages: Vec<Value> = transcript
            .iter()
            .filter_map(|e| e.message_value().cloned())
            .collect();
        let outcome = self
            .hooks
            .before_run_end(BeforeRunEndEvent {
                lane: lane.clone(),
                run_id: op.as_str().into(),
                messages,
            })
            .await;
        self.report_handler_errors(&lane, &op, &outcome.errors);
        if let Some(text) = outcome.value.follow_up {
            let entry = Entry::message(serde_json::json!({"role": "user", "content": text}))
                .with_parent(current.leaf.clone());
            let mut next_cp = CheckpointPhase::need_assistant(entry.id.clone());
            next_cp.skip_inbox_once = true;
            let next = self.run_with(run, RunPhase::Checkpoint(next_cp));
            let extra = vec![
                Write::entry(entry.clone()),
                Write::set(Namespace::LaneLeaf, &lane, Some(entry.id.clone())),
            ];
            let (ok, reload) = self.transition(current, next, extra).await?;
            if ok {
                self.emit(&lane, &op, Kind::EntryAdded { entry });
            }
            return Ok(Step::Continue(reload));
        }

        self.terminal(current, Outcome::Completed, None, vec![], None, None)
            .await
    }

    async fn apply_inbox(
        &self,
        current: &Current,
        run: &RunState,
        ids: Vec<EntryId>,
        kind: InboxKind,
    ) -> Result<Step> {
        let lane = current.operation.lane.clone();
        let op = current.operation.operation_id.clone();
        let (writes, newest, placed) = self
            .placement_writes(&lane, current.leaf.clone(), &ids)
            .await?;
        let mut next = run.clone();
        let remove = |queue: &mut Vec<EntryId>| queue.retain(|id| !ids.contains(id));
        match kind {
            InboxKind::Writes => remove(&mut next.inbox.writes),
            InboxKind::Steer => remove(&mut next.inbox.steer),
            InboxKind::FollowUp => remove(&mut next.inbox.follow_up),
        }
        let projects = placed.iter().any(|e| e.entry_type == "message");
        if projects
            && !run.control.is_cancelled()
            && let Some(newest) = newest.clone()
        {
            let mut cp = CheckpointPhase::need_assistant(newest);
            cp.skip_inbox_once = true;
            next.phase = RunPhase::Checkpoint(cp);
        } else if let RunPhase::Checkpoint(cp) = &next.phase {
            // An unprojected write preserves the continuation; a cancelled
            // drain keeps the phase and heads for the aborted finish.
            let mut cp = cp.clone();
            cp.skip_inbox_once = true;
            next.phase = RunPhase::Checkpoint(cp);
        }
        let (ok, reload) = self
            .transition(current, OperationState::Run(next.clone()), writes)
            .await?;
        if ok {
            for entry in placed {
                self.emit(&lane, &op, Kind::EntryAdded { entry });
            }
            self.emit(
                &lane,
                &op,
                Kind::QueueUpdate {
                    steer: next.inbox.steer.clone(),
                    follow_up: next.inbox.follow_up.clone(),
                    next_run: current.lane_state.pending_next_run.clone(),
                },
            );
        }
        Ok(Step::Continue(reload))
    }

    /// Cancelled control with writes drained: finish aborted.
    async fn abort_finish(&self, current: &Current) -> Result<Step> {
        self.terminal(current, Outcome::Aborted, None, vec![], None, None)
            .await
    }

    async fn failure_drain(
        &self,
        current: &Current,
        run: &RunState,
        error: OperationError,
    ) -> Result<Step> {
        if !run.inbox.writes.is_empty() {
            return self
                .apply_inbox(current, run, run.inbox.writes.clone(), InboxKind::Writes)
                .await;
        }
        if run.control.is_cancelled() {
            return self.abort_finish(current).await;
        }
        let steer = Self::take(run.settings.steering_mode, &run.inbox.steer);
        if !steer.is_empty() {
            return self
                .apply_inbox(current, run, steer, InboxKind::Steer)
                .await;
        }
        let follow_up = Self::take(run.settings.follow_up_mode, &run.inbox.follow_up);
        if !follow_up.is_empty() {
            return self
                .apply_inbox(current, run, follow_up, InboxKind::FollowUp)
                .await;
        }
        self.terminal(current, Outcome::Failed, Some(error), vec![], None, None)
            .await
    }

    // ── assistant generation ─────────────────────────────────────────────

    async fn assistant(
        &self,
        current: &Current,
        run: &RunState,
        generation: &Generation,
    ) -> Result<Step> {
        let lane = current.operation.lane.clone();
        let op = current.operation.operation_id.clone();
        match generation {
            Generation::Ready {
                context,
                next_attempt,
            } => {
                if run.control.is_cancelled() {
                    return self.abort_finish(current).await;
                }
                // Intent: reserve the response and usage ids, then dispatch.
                let response_entry_id = EntryId::new();
                let usage_id = UsageId::new();
                let pending = Generation::EffectPending {
                    context: context.clone(),
                    attempt: *next_attempt,
                    response_entry_id: response_entry_id.clone(),
                    usage_id: usage_id.clone(),
                };
                let next = self.run_with(
                    run,
                    RunPhase::Assistant {
                        generation: pending,
                    },
                );
                let (ok, reload) = self.transition(current, next, vec![]).await?;
                let Reload::Current(committed) = reload else {
                    return Ok(Step::Continue(reload));
                };
                if !ok {
                    return Ok(Step::Continue(Reload::Current(committed)));
                }
                if *next_attempt == 1 {
                    self.emit(
                        &lane,
                        &op,
                        Kind::TurnStart {
                            turn_id: context.step_id.clone(),
                        },
                    );
                }
                let assistant = self.request_assistant(&committed, context).await?;
                self.settle_assistant(
                    &committed,
                    context,
                    *next_attempt,
                    response_entry_id,
                    usage_id,
                    assistant,
                )
                .await
            }
            Generation::EffectPending {
                context,
                attempt,
                response_entry_id,
                usage_id,
            } => {
                // Restored: the effect is not running here and its outcome is
                // unknown (§4.5).
                if run.control.is_cancelled() {
                    let aborted = Assistant {
                        stop_reason: StopReason::Aborted,
                        error_message: Some("aborted before the response settled".into()),
                        ..Default::default()
                    };
                    return self
                        .settle_assistant(
                            current,
                            context,
                            *attempt,
                            response_entry_id.clone(),
                            usage_id.clone(),
                            aborted,
                        )
                        .await;
                }
                if *attempt < context.retry_policy.max_attempts {
                    let next = self.run_with(
                        run,
                        RunPhase::Assistant {
                            generation: Generation::Ready {
                                context: context.clone(),
                                next_attempt: attempt + 1,
                            },
                        },
                    );
                    return Ok(Step::Continue(
                        self.transition(current, next, vec![]).await?.1,
                    ));
                }
                let exhausted = Assistant::error(format!(
                    "the process was interrupted during attempt {attempt} and the retry \
                     policy allows no more"
                ));
                self.settle_assistant(
                    current,
                    context,
                    *attempt,
                    response_entry_id.clone(),
                    usage_id.clone(),
                    exhausted,
                )
                .await
            }
            Generation::RetryWait {
                context,
                next_attempt,
                not_before,
                ..
            } => {
                if run.control.is_cancelled() {
                    return self.abort_finish(current).await;
                }
                let now = crate::ids::now_ms();
                if now < *not_before {
                    let wait = std::time::Duration::from_millis((*not_before - now) as u64);
                    let mut cancel = self.cancel.clone();
                    tokio::select! {
                        _ = tokio::time::sleep(wait) => {}
                        _ = cancel.cancelled() => {}
                    }
                    return Ok(Step::Continue(self.reload(current).await?));
                }
                let next = self.run_with(
                    run,
                    RunPhase::Assistant {
                        generation: Generation::Ready {
                            context: context.clone(),
                            next_attempt: *next_attempt,
                        },
                    },
                );
                Ok(Step::Continue(
                    self.transition(current, next, vec![]).await?.1,
                ))
            }
        }
    }

    /// The effect: one provider request, cancellable by the harness signal.
    async fn request_assistant(
        &self,
        current: &Current,
        context: &GenerationContext,
    ) -> Result<Assistant> {
        let lane = current.operation.lane.clone();
        let op = current.operation.operation_id.clone();
        let entries = self.session.context(&lane).await?;
        let transformed = self
            .hooks
            .transform_context(TransformContextEvent {
                lane: lane.clone(),
                run_id: op.as_str().into(),
                messages: entries,
            })
            .await;
        self.report_handler_errors(&lane, &op, &transformed.errors);
        let system = match &current.operation.intent {
            crate::state::Intent::Run {
                system_prompt_override: Some(s),
                ..
            } => s.clone(),
            _ => (self.system_prompt)(),
        };
        let schemas: Vec<_> = self
            .tools
            .schemas()
            .into_iter()
            .filter(|s| context.configuration.active_tool_names.contains(&s.name))
            .collect();
        let request = Request {
            context: &transformed.value,
            system: &system,
            tools: &schemas,
        };
        let events = self.events.clone();
        let (lane_for, op_for) = (lane.clone(), op.clone());
        let on_delta = move |delta: &str| {
            let _ = events.send(Event::new(
                &lane_for,
                Some(op_for.as_str()),
                Kind::MessageUpdate {
                    delta: delta.to_string(),
                },
            ));
        };
        let mut cancel = self.cancel.clone();
        let response = self.model.respond(request, &on_delta);
        let outcome = tokio::select! {
            biased;
            _ = cancel.cancelled() => None,
            response = response => Some(response),
        };
        let assistant = match outcome {
            None => Assistant {
                stop_reason: StopReason::Aborted,
                error_message: Some("aborted by the user".into()),
                ..Default::default()
            },
            Some(Ok(assistant)) => assistant,
            Some(Err(error)) => {
                let mut a = Assistant::error(error.message.clone());
                if error.retryable {
                    a.error_message = Some(format!("{RETRYABLE_PREFIX}{}", error.message));
                }
                a
            }
        };
        self.emit(
            &lane,
            &op,
            Kind::MessageEnd {
                message: assistant.message(),
            },
        );
        Ok(assistant)
    }

    /// Classify (§3.7) and commit response + usage + next state atomically.
    /// Settlement reloads nothing: the state it extends is the one the intent
    /// was committed against, and the conditional commit catches anything —
    /// an `abort()`, a `steer()` — that landed in between.
    async fn settle_assistant(
        &self,
        current: &Current,
        context: &GenerationContext,
        attempt: u32,
        response_entry_id: EntryId,
        usage_id: UsageId,
        mut assistant: Assistant,
    ) -> Result<Step> {
        let OperationState::Run(run) = &current.state else {
            unreachable!()
        };
        let lane = current.operation.lane.clone();
        let op = current.operation.operation_id.clone();
        let cancelled = run.control.is_cancelled() || self.cancelled();
        let retryable = assistant
            .error_message
            .as_deref()
            .is_some_and(|m| m.starts_with(RETRYABLE_PREFIX));
        if let Some(message) = assistant.error_message.as_mut()
            && let Some(stripped) = message.strip_prefix(RETRYABLE_PREFIX)
        {
            *message = stripped.to_string();
        }
        if assistant.stop_reason == StopReason::Aborted && !cancelled {
            // A provider may only say "aborted" for our signal. Anything else
            // is an error and takes the ordinary path.
            assistant.stop_reason = StopReason::Error;
        }

        let overflow = assistant.stop_reason == StopReason::Error
            && assistant
                .error_message
                .as_deref()
                .is_some_and(is_context_overflow);
        let mut extra_writes = Vec::new();
        let phase = if cancelled {
            assistant.stop_reason = StopReason::Aborted;
            RunPhase::Checkpoint(CheckpointPhase::may_finish(response_entry_id.clone(), true))
        } else if overflow {
            let prepared = if context.overflow_recovery_used {
                None
            } else {
                let ctx = self.session.context(&lane).await?;
                crate::compaction::prepare(&ctx, &run.settings.compaction)
            };
            match prepared {
                Some(preparation) => {
                    let task_id = crate::ids::short_id("t");
                    extra_writes.push(Write::set(
                        Namespace::OpPreparation,
                        StructuralDecision::preparation_key(&op, &task_id),
                        &preparation,
                    ));
                    RunPhase::Compaction {
                        reason: CompactionReason::Overflow,
                        structural: StructuralDecision {
                            task_id,
                            status: StructuralStatus::Deciding,
                        },
                        resume_after: CheckpointPhase {
                            continuation: Continuation::NeedAssistant {
                                overflow_recovery_used: true,
                            },
                            trigger_entry_id: context.trigger_entry_id.clone(),
                            threshold_checked_trigger_entry_id: Some(
                                context.trigger_entry_id.clone(),
                            ),
                            skip_inbox_once: false,
                        },
                    }
                }
                None => RunPhase::FailureDrain {
                    error: OperationError::new(
                        "context_overflow",
                        assistant.error_message.clone().unwrap_or_default(),
                    ),
                    provenance: FailureProvenance::Response {
                        entry_id: response_entry_id.clone(),
                    },
                },
            }
        } else if assistant.stop_reason == StopReason::Error {
            if retryable && attempt < context.retry_policy.max_attempts {
                let delay = context.retry_policy.delay_ms(attempt);
                self.emit(
                    &lane,
                    &op,
                    Kind::RetryScheduled {
                        attempt: attempt + 1,
                        max_attempts: context.retry_policy.max_attempts,
                        delay_ms: delay,
                        error_message: assistant.error_message.clone().unwrap_or_default(),
                    },
                );
                RunPhase::Assistant {
                    generation: Generation::RetryWait {
                        context: context.clone(),
                        next_attempt: attempt + 1,
                        not_before: crate::ids::now_ms().saturating_add(delay as i64),
                        error_message: assistant.error_message.clone().unwrap_or_default(),
                    },
                }
            } else {
                RunPhase::FailureDrain {
                    error: OperationError::new(
                        if retryable {
                            "retries_exhausted"
                        } else {
                            "provider_error"
                        },
                        assistant.error_message.clone().unwrap_or_default(),
                    ),
                    provenance: FailureProvenance::Response {
                        entry_id: response_entry_id.clone(),
                    },
                }
            }
        } else if !assistant.tool_calls.is_empty() {
            let calls = (0..assistant.tool_calls.len())
                .map(|index| ToolCallState::Planned {
                    source_index: index,
                    result_entry_id: EntryId::follower_of(response_entry_id.as_str()),
                })
                .collect();
            RunPhase::Tools {
                batch: ToolBatch {
                    assistant_entry_id: response_entry_id.clone(),
                    configuration: context.configuration.clone(),
                    turn_id: context.step_id.clone(),
                    calls,
                },
            }
        } else {
            RunPhase::Checkpoint(CheckpointPhase::may_finish(response_entry_id.clone(), true))
        };

        let entry = Entry::message(assistant.message())
            .with_id(response_entry_id.clone())
            .with_parent(current.leaf.clone());
        let usage_row = UsageRow::new(usage_id, assistant.usage, Some(response_entry_id.clone()));
        let mut next = run.clone();
        next.phase = phase;
        next.latest_assistant_entry_id = Some(response_entry_id.clone());
        let mut writes = vec![
            Write::entry(entry.clone()),
            Write::set(Namespace::LaneLeaf, &lane, Some(response_entry_id.clone())),
            Write::usage(usage_row.clone()),
        ];
        writes.append(&mut extra_writes);
        let (ok, reload) = self
            .transition(current, OperationState::Run(next.clone()), writes)
            .await?;
        if ok {
            self.emit(&lane, &op, Kind::EntryAdded { entry });
            let totals = self.session.stats().await?.usage;
            self.emit(
                &lane,
                &op,
                Kind::Usage {
                    row: usage_row,
                    totals,
                },
            );
            if !matches!(next.phase, RunPhase::Tools { .. }) {
                self.emit(
                    &lane,
                    &op,
                    Kind::TurnEnd {
                        turn_id: context.step_id.clone(),
                    },
                );
            }
            if matches!(next.phase, RunPhase::Compaction { .. }) {
                self.emit(
                    &lane,
                    &op,
                    Kind::CompactionStart {
                        reason: CompactionReason::Overflow,
                    },
                );
            }
        }
        Ok(Step::Continue(reload))
    }

    // ── tools ────────────────────────────────────────────────────────────

    async fn tools(&self, current: &Current, run: &RunState, batch: &ToolBatch) -> Result<Step> {
        let lane = current.operation.lane.clone();
        let op = current.operation.operation_id.clone();
        let assistant_entry = self
            .session
            .entry(batch.assistant_entry_id.clone())
            .await?
            .ok_or_else(|| {
                SessionError::Corrupt(format!(
                    "batch assistant {} missing",
                    batch.assistant_entry_id
                ))
            })?;
        let assistant =
            Assistant::from_message(assistant_entry.message_value().unwrap_or(&Value::Null))
                .ok_or_else(|| {
                    SessionError::Corrupt("batch assistant is not an assistant".into())
                })?;

        let mut calls = batch.calls.clone();
        calls.sort_by_key(ToolCallState::source_index);
        let Some(next_call) = calls.iter().find(|c| !c.is_completed()).cloned() else {
            // Batch complete: fold the tool_args cleanup into this transition.
            let all_terminate = calls.iter().all(|c| {
                matches!(
                    c,
                    ToolCallState::Completed {
                        terminate: true,
                        ..
                    }
                )
            });
            let newest = calls
                .last()
                .map(|c| c.result_entry_id().clone())
                .unwrap_or(batch.assistant_entry_id.clone());
            let cp = if all_terminate {
                CheckpointPhase::may_finish(newest, false)
            } else {
                CheckpointPhase::need_assistant(newest)
            };
            let prefix = ToolBatch::args_prefix(&op, &batch.turn_id);
            let keys = self
                .session
                .read(move |s| {
                    s.list_registers(Namespace::OpToolArgs, &prefix)
                        .into_iter()
                        .map(|r| r.key.clone())
                        .collect::<Vec<_>>()
                })
                .await?;
            let extra = keys
                .into_iter()
                .map(|k| Write::delete(Namespace::OpToolArgs, k))
                .collect();
            let next = self.run_with(run, RunPhase::Checkpoint(cp));
            let (ok, reload) = self.transition(current, next, extra).await?;
            if ok {
                self.emit(
                    &lane,
                    &op,
                    Kind::TurnEnd {
                        turn_id: batch.turn_id.clone(),
                    },
                );
            }
            return Ok(Step::Continue(reload));
        };

        let index = next_call.source_index();
        let call = assistant.tool_calls.get(index).cloned().ok_or_else(|| {
            SessionError::Corrupt(format!("tool call {index} missing from the assistant"))
        })?;
        let result_entry_id = next_call.result_entry_id().clone();
        let args_key = ToolBatch::args_key(&op, &batch.turn_id, index);

        match next_call {
            ToolCallState::Planned { .. } => {
                // Cancelled, truncated, unknown, or blocked: a synthetic
                // result with no intent and no effect.
                if run.control.is_cancelled() || self.cancelled() {
                    let text = "Aborted: the user interrupted this run before the tool started.";
                    return self
                        .commit_tool_result(
                            current,
                            run,
                            batch,
                            &call,
                            &result_entry_id,
                            text,
                            true,
                            false,
                            Some("aborted"),
                        )
                        .await;
                }
                if assistant.stop_reason == StopReason::Length {
                    let text = "The response hit the output limit while emitting this call; its \
                                arguments may be truncated, so it was not executed.";
                    return self
                        .commit_tool_result(
                            current,
                            run,
                            batch,
                            &call,
                            &result_entry_id,
                            text,
                            true,
                            false,
                            Some("truncated"),
                        )
                        .await;
                }
                let Some(replay) = self.tools.replay(&call.name) else {
                    let text = format!("no tool named {:?}", call.name);
                    return self
                        .commit_tool_result(
                            current,
                            run,
                            batch,
                            &call,
                            &result_entry_id,
                            &text,
                            true,
                            false,
                            Some("unknown_tool"),
                        )
                        .await;
                };
                let before = self
                    .hooks
                    .before_tool(BeforeToolEvent {
                        lane: lane.clone(),
                        run_id: op.as_str().into(),
                        tool_call_id: call.id.clone(),
                        tool_name: call.name.clone(),
                        args: call.arguments.clone(),
                    })
                    .await;
                self.report_handler_errors(&lane, &op, &before.errors);
                if let Some(block) = before.value.block {
                    let text = format!("Blocked: {}", block.reason);
                    return self
                        .commit_tool_result(
                            current,
                            run,
                            batch,
                            &call,
                            &result_entry_id,
                            &text,
                            true,
                            block.terminate,
                            Some("blocked"),
                        )
                        .await;
                }
                let effective = before.value.args.unwrap_or_else(|| call.arguments.clone());

                // Intent: effective args durable, the call effect_pending.
                let mut next = run.clone();
                let RunPhase::Tools { batch: ref mut b } = next.phase else {
                    unreachable!()
                };
                for c in b.calls.iter_mut() {
                    if c.source_index() == index {
                        *c = ToolCallState::EffectPending {
                            source_index: index,
                            result_entry_id: result_entry_id.clone(),
                            replay,
                        };
                    }
                }
                let extra = vec![Write::set(
                    Namespace::OpToolArgs,
                    &args_key,
                    Value::Object(effective.clone()),
                )];
                let (ok, reload) = self
                    .transition(current, OperationState::Run(next), extra)
                    .await?;
                let Reload::Current(committed) = reload else {
                    return Ok(Step::Continue(reload));
                };
                if !ok {
                    return Ok(Step::Continue(Reload::Current(committed)));
                }
                self.emit(
                    &lane,
                    &op,
                    Kind::ToolStart {
                        turn_id: batch.turn_id.clone(),
                        tool_call_id: call.id.clone(),
                        tool_name: call.name.clone(),
                        args: effective.clone(),
                    },
                );
                let OperationState::Run(committed_run) = &committed.state else {
                    unreachable!()
                };
                self.execute_tool(
                    &committed,
                    committed_run,
                    batch,
                    &call,
                    effective,
                    &result_entry_id,
                )
                .await
            }
            ToolCallState::EffectPending { replay, .. } => {
                // Restored: re-execute only when both declarations say safe.
                if run.control.is_cancelled() || self.cancelled() {
                    let text = "Interrupted: reve aborted this operation before the tool finished.";
                    return self
                        .commit_tool_result(
                            current,
                            run,
                            batch,
                            &call,
                            &result_entry_id,
                            text,
                            true,
                            false,
                            Some("interrupted"),
                        )
                        .await;
                }
                let current_declaration = self.tools.replay(&call.name);
                if replay == Replay::Safe && current_declaration == Some(Replay::Safe) {
                    let args = self
                        .session
                        .register_json(Namespace::OpToolArgs, &args_key)
                        .await?
                        .and_then(|(v, _)| v.as_object().cloned())
                        .ok_or_else(|| {
                            SessionError::Corrupt(format!("op.tool_args/{args_key} missing"))
                        })?;
                    self.emit(
                        &lane,
                        &op,
                        Kind::ToolStart {
                            turn_id: batch.turn_id.clone(),
                            tool_call_id: call.id.clone(),
                            tool_name: call.name.clone(),
                            args: args.clone(),
                        },
                    );
                    return self
                        .execute_tool(current, run, batch, &call, args, &result_entry_id)
                        .await;
                }
                let text = "Interrupted: the process died while this tool was running and it \
                            is not safe to re-run. Its effects may or may not have happened.";
                self.commit_tool_result(
                    current,
                    run,
                    batch,
                    &call,
                    &result_entry_id,
                    text,
                    true,
                    false,
                    Some("interrupted"),
                )
                .await
            }
            ToolCallState::Completed { .. } => unreachable!(),
        }
    }

    /// Phase two and three: run the tool, apply `after_tool`, commit.
    #[allow(clippy::too_many_arguments)]
    async fn execute_tool(
        &self,
        current: &Current,
        run: &RunState,
        batch: &ToolBatch,
        call: &ToolCall,
        args: serde_json::Map<String, Value>,
        result_entry_id: &EntryId,
    ) -> Result<Step> {
        let lane = current.operation.lane.clone();
        let op = current.operation.operation_id.clone();
        let outcome = self
            .tools
            .invoke(&call.name, args.clone(), Some(self.cancel.clone()))
            .await;
        let (mut content, mut is_error) = match outcome {
            Ok(text) => (text, false),
            Err(message) => (format!("tool {} failed: {message}", call.name), true),
        };
        let mut terminate = false;
        if self.cancelled() {
            is_error = true;
            if content.trim().is_empty() {
                content = "Interrupted: the command was stopped.".into();
            }
        } else {
            let after = self
                .hooks
                .after_tool(AfterToolEvent {
                    lane: lane.clone(),
                    run_id: op.as_str().into(),
                    tool_call_id: call.id.clone(),
                    tool_name: call.name.clone(),
                    args,
                    content: content.clone(),
                    is_error,
                })
                .await;
            self.report_handler_errors(&lane, &op, &after.errors);
            if let Some(patched) = after.value.content {
                content = patched;
            }
            if let Some(patched) = after.value.is_error {
                is_error = patched;
            }
            terminate = after.value.terminate.unwrap_or(false);
        }
        self.commit_tool_result(
            current,
            run,
            batch,
            call,
            result_entry_id,
            &content,
            is_error,
            terminate,
            None,
        )
        .await
    }

    #[allow(clippy::too_many_arguments)]
    async fn commit_tool_result(
        &self,
        current: &Current,
        run: &RunState,
        batch: &ToolBatch,
        call: &ToolCall,
        result_entry_id: &EntryId,
        content: &str,
        is_error: bool,
        terminate: bool,
        synthetic: Option<&str>,
    ) -> Result<Step> {
        let lane = current.operation.lane.clone();
        let op = current.operation.operation_id.clone();
        let entry = Entry::message(tool_result_message(
            call, content, is_error, terminate, synthetic,
        ))
        .with_id(result_entry_id.clone())
        .with_parent(current.leaf.clone());
        let mut next = run.clone();
        let RunPhase::Tools { batch: ref mut b } = next.phase else {
            unreachable!()
        };
        for c in b.calls.iter_mut() {
            if c.result_entry_id() == result_entry_id {
                *c = ToolCallState::Completed {
                    source_index: c.source_index(),
                    result_entry_id: result_entry_id.clone(),
                    terminate,
                };
            }
        }
        let extra = vec![
            Write::entry(entry.clone()),
            Write::set(Namespace::LaneLeaf, &lane, Some(result_entry_id.clone())),
        ];
        let (ok, reload) = self
            .transition(current, OperationState::Run(next), extra)
            .await?;
        if ok {
            self.emit(
                &lane,
                &op,
                Kind::ToolEnd {
                    turn_id: batch.turn_id.clone(),
                    tool_call_id: call.id.clone(),
                    tool_name: call.name.clone(),
                    content: content.to_string(),
                    is_error,
                    terminate,
                },
            );
            self.emit(&lane, &op, Kind::EntryAdded { entry });
        }
        Ok(Step::Continue(reload))
    }

    // ── structural work: compaction ──────────────────────────────────────

    async fn preparation(&self, op: &OpId, task_id: &str) -> Result<CompactionPreparation> {
        let key = StructuralDecision::preparation_key(op, task_id);
        self.session
            .register::<CompactionPreparation>(Namespace::OpPreparation, &key)
            .await?
            .map(|(p, _)| p)
            .ok_or_else(|| SessionError::Corrupt(format!("op.preparation/{key} missing")))
    }

    /// What the compaction produces, once a summary exists.
    fn compaction_publication(
        &self,
        lane: &str,
        leaf: Option<EntryId>,
        preparation: &CompactionPreparation,
        summary: &str,
        from_hook: bool,
        result_entry_id: &EntryId,
    ) -> (Entry, Vec<Write>) {
        let entry = Entry::compaction(
            summary,
            preparation.retained_tail.clone(),
            preparation.tokens_before,
            from_hook,
        )
        .with_id(result_entry_id.clone())
        .with_parent(leaf);
        let writes = vec![
            Write::entry(entry.clone()),
            Write::set(Namespace::LaneLeaf, lane, Some(result_entry_id.clone())),
        ];
        (entry, writes)
    }

    /// Ask the model for a summary. Cancellable.
    async fn request_summary(
        &self,
        preparation: &CompactionPreparation,
        custom_instructions: Option<&str>,
    ) -> std::result::Result<(String, crate::entry::Usage), (String, bool)> {
        let mut scratch = Vec::new();
        let request =
            crate::compaction::summary_request(preparation, custom_instructions, &mut scratch);
        let quiet = |_: &str| {};
        let mut cancel = self.cancel.clone();
        let response = self.model.respond(request, &quiet);
        let outcome = tokio::select! {
            biased;
            _ = cancel.cancelled() => None,
            response = response => Some(response),
        };
        match outcome {
            None => Err(("aborted".into(), false)),
            Some(Err(e)) => Err((e.message, e.retryable)),
            Some(Ok(a)) if a.stop_reason == StopReason::Error => {
                Err((a.error_message.unwrap_or_default(), false))
            }
            Some(Ok(a)) if a.text.trim().is_empty() => {
                Err(("the model returned an empty summary".into(), true))
            }
            Some(Ok(a)) => Ok((a.text, a.usage)),
        }
    }

    /// One step of the shared `deciding → generating → result` machinery.
    /// Returns what happened so the caller (in-run or standalone) can commit
    /// the right transition.
    async fn structural_step(
        &self,
        current: &Current,
        structural: &StructuralDecision,
        reason: CompactionReason,
        custom_instructions: Option<&str>,
        result_entry_id: &EntryId,
        configuration: &crate::state::LaneConfiguration,
    ) -> Result<Structural> {
        let lane = current.operation.lane.clone();
        let op = current.operation.operation_id.clone();
        let preparation = self.preparation(&op, &structural.task_id).await?;
        match &structural.status {
            StructuralStatus::Deciding => {
                let decision = self
                    .hooks
                    .before_compaction(BeforeCompactionEvent {
                        lane: lane.clone(),
                        run_id: op.as_str().into(),
                        reason,
                        preparation: preparation.clone(),
                    })
                    .await;
                self.report_handler_errors(&lane, &op, &decision.errors);
                if decision.value.decline {
                    return Ok(Structural::Declined);
                }
                if let Some(summary) = decision.value.summary {
                    let (entry, writes) = self.compaction_publication(
                        &lane,
                        current.leaf.clone(),
                        &preparation,
                        &summary,
                        true,
                        result_entry_id,
                    );
                    return Ok(Structural::Published { entry, writes });
                }
                Ok(Structural::Next(StructuralDecision {
                    task_id: structural.task_id.clone(),
                    status: StructuralStatus::Generating {
                        generation: SummaryGeneration::Ready {
                            context: SummaryContext {
                                task_id: structural.task_id.clone(),
                                result_entry_id: result_entry_id.clone(),
                                configuration: configuration.clone(),
                                retry_policy: self.retry,
                                reason,
                            },
                            next_attempt: 1,
                        },
                    },
                }))
            }
            StructuralStatus::Generating { generation } => match generation {
                SummaryGeneration::Ready {
                    context,
                    next_attempt,
                } => Ok(Structural::Intent(StructuralDecision {
                    task_id: structural.task_id.clone(),
                    status: StructuralStatus::Generating {
                        generation: SummaryGeneration::EffectPending {
                            context: context.clone(),
                            attempt: *next_attempt,
                            usage_id: UsageId::new(),
                        },
                    },
                })),
                SummaryGeneration::EffectPending {
                    context,
                    attempt,
                    usage_id,
                } => {
                    // Only reached with a live effect (the caller dispatches
                    // right after committing the intent) or restored. The
                    // caller tells us which via `live`.
                    let _ = (context, attempt, usage_id, custom_instructions);
                    Ok(Structural::Unknown)
                }
                SummaryGeneration::RetryWait {
                    context,
                    next_attempt,
                    not_before,
                    ..
                } => {
                    let now = crate::ids::now_ms();
                    if now < *not_before {
                        let wait = std::time::Duration::from_millis((*not_before - now) as u64);
                        let mut cancel = self.cancel.clone();
                        tokio::select! {
                            _ = tokio::time::sleep(wait) => {}
                            _ = cancel.cancelled() => {}
                        }
                        return Ok(Structural::Waited);
                    }
                    Ok(Structural::Next(StructuralDecision {
                        task_id: structural.task_id.clone(),
                        status: StructuralStatus::Generating {
                            generation: SummaryGeneration::Ready {
                                context: context.clone(),
                                next_attempt: *next_attempt,
                            },
                        },
                    }))
                }
            },
        }
    }

    /// After a committed `effect_pending` intent: run the request and decide.
    // Every parameter is a distinct piece of already-committed state this step
    // was planned against; bundling them into a struct would hide that.
    #[allow(clippy::too_many_arguments)]
    async fn summary_effect(
        &self,
        current: &Current,
        op: &OpId,
        task_id: &str,
        context: &SummaryContext,
        attempt: u32,
        usage_id: &UsageId,
        custom_instructions: Option<&str>,
        result_entry_id: &EntryId,
    ) -> Result<Structural> {
        let preparation = self.preparation(op, task_id).await?;
        match self
            .request_summary(&preparation, custom_instructions)
            .await
        {
            Ok((summary, usage)) => {
                let (entry, mut writes) = self.compaction_publication(
                    &current.operation.lane,
                    current.leaf.clone(),
                    &preparation,
                    &summary,
                    false,
                    result_entry_id,
                );
                writes.push(Write::usage(UsageRow::new(
                    usage_id.clone(),
                    usage,
                    Some(result_entry_id.clone()),
                )));
                Ok(Structural::Published { entry, writes })
            }
            Err((message, retryable)) => {
                let usage = Write::usage(UsageRow::new(
                    usage_id.clone(),
                    crate::entry::Usage::default(),
                    None,
                ));
                if retryable && attempt < context.retry_policy.max_attempts && !self.cancelled() {
                    let delay = context.retry_policy.delay_ms(attempt);
                    Ok(Structural::Retry {
                        decision: StructuralDecision {
                            task_id: task_id.to_string(),
                            status: StructuralStatus::Generating {
                                generation: SummaryGeneration::RetryWait {
                                    context: context.clone(),
                                    next_attempt: attempt + 1,
                                    not_before: crate::ids::now_ms().saturating_add(delay as i64),
                                    error_message: message,
                                },
                            },
                        },
                        usage,
                    })
                } else {
                    Ok(Structural::Failed {
                        error: OperationError::new("summary_failed", message),
                        usage: Some(usage),
                    })
                }
            }
        }
    }

    async fn in_run_compaction(
        &self,
        current: &Current,
        run: &RunState,
        reason: CompactionReason,
        structural: &StructuralDecision,
        resume_after: &CheckpointPhase,
    ) -> Result<Step> {
        let lane = current.operation.lane.clone();
        let op = current.operation.operation_id.clone();
        if run.control.is_cancelled() {
            return self.abort_finish(current).await;
        }
        let result_entry_id = match &structural.status {
            StructuralStatus::Generating { generation } => {
                generation.context().result_entry_id.clone()
            }
            StructuralStatus::Deciding => EntryId::follower_of(op.as_str()),
        };
        let outcome = self
            .structural_step(
                current,
                structural,
                reason,
                None,
                &result_entry_id,
                &current.configuration,
            )
            .await?;
        let resume = |resume_after: &CheckpointPhase| RunPhase::Checkpoint(resume_after.clone());
        let failure = |error: OperationError| RunPhase::FailureDrain {
            error,
            provenance: FailureProvenance::Structural {
                task_id: structural.task_id.clone(),
            },
        };
        let finish = |this: &Self, entry_id: Option<EntryId>, outcome: Outcome| {
            this.emit(
                &lane,
                &op,
                Kind::CompactionEnd {
                    reason,
                    outcome,
                    entry_id,
                },
            );
        };
        match outcome {
            Structural::Declined => {
                let phase = match reason {
                    CompactionReason::Threshold => resume(resume_after),
                    _ => failure(OperationError::new(
                        "compaction_declined",
                        "the request did not fit and compaction was declined",
                    )),
                };
                let (ok, reload) = self
                    .transition(current, self.run_with(run, phase), vec![])
                    .await?;
                if ok {
                    finish(self, None, Outcome::Declined);
                }
                Ok(Step::Continue(reload))
            }
            Structural::Published { entry, writes } => {
                let (ok, reload) = self
                    .transition(current, self.run_with(run, resume(resume_after)), writes)
                    .await?;
                if ok {
                    self.emit(
                        &lane,
                        &op,
                        Kind::EntryAdded {
                            entry: entry.clone(),
                        },
                    );
                    finish(self, Some(entry.id), Outcome::Completed);
                }
                Ok(Step::Continue(reload))
            }
            Structural::Next(decision) => {
                let phase = RunPhase::Compaction {
                    reason,
                    structural: decision,
                    resume_after: resume_after.clone(),
                };
                Ok(Step::Continue(
                    self.transition(current, self.run_with(run, phase), vec![])
                        .await?
                        .1,
                ))
            }
            Structural::Waited => Ok(Step::Continue(self.reload(current).await?)),
            Structural::Intent(decision) => {
                let phase = RunPhase::Compaction {
                    reason,
                    structural: decision.clone(),
                    resume_after: resume_after.clone(),
                };
                let (ok, reload) = self
                    .transition(current, self.run_with(run, phase), vec![])
                    .await?;
                let Reload::Current(committed) = reload else {
                    return Ok(Step::Continue(reload));
                };
                if !ok {
                    return Ok(Step::Continue(Reload::Current(committed)));
                }
                let StructuralStatus::Generating {
                    generation:
                        SummaryGeneration::EffectPending {
                            context,
                            attempt,
                            usage_id,
                        },
                } = &decision.status
                else {
                    unreachable!()
                };
                let effect = self
                    .summary_effect(
                        &committed,
                        &op,
                        &decision.task_id,
                        context,
                        *attempt,
                        usage_id,
                        None,
                        &result_entry_id,
                    )
                    .await?;
                let OperationState::Run(committed_run) = &committed.state else {
                    unreachable!()
                };
                self.commit_in_run_structural(
                    &committed,
                    committed_run,
                    reason,
                    &decision,
                    resume_after,
                    effect,
                )
                .await
            }
            Structural::Unknown => {
                // Restored effect_pending: the attempt is wholly uncertain.
                let StructuralStatus::Generating {
                    generation:
                        SummaryGeneration::EffectPending {
                            context, attempt, ..
                        },
                } = &structural.status
                else {
                    unreachable!()
                };
                let phase = if *attempt < context.retry_policy.max_attempts {
                    RunPhase::Compaction {
                        reason,
                        structural: StructuralDecision {
                            task_id: structural.task_id.clone(),
                            status: StructuralStatus::Generating {
                                generation: SummaryGeneration::Ready {
                                    context: context.clone(),
                                    next_attempt: attempt + 1,
                                },
                            },
                        },
                        resume_after: resume_after.clone(),
                    }
                } else {
                    failure(OperationError::new(
                        "summary_failed",
                        "interrupted and the retry policy allows no more",
                    ))
                };
                Ok(Step::Continue(
                    self.transition(current, self.run_with(run, phase), vec![])
                        .await?
                        .1,
                ))
            }
            Structural::Retry { .. } | Structural::Failed { .. } => unreachable!(),
        }
    }

    async fn commit_in_run_structural(
        &self,
        current: &Current,
        run: &RunState,
        reason: CompactionReason,
        decision: &StructuralDecision,
        resume_after: &CheckpointPhase,
        effect: Structural,
    ) -> Result<Step> {
        let lane = current.operation.lane.clone();
        let op = current.operation.operation_id.clone();
        match effect {
            Structural::Published { entry, writes } => {
                let (ok, reload) = self
                    .transition(
                        current,
                        self.run_with(run, RunPhase::Checkpoint(resume_after.clone())),
                        writes,
                    )
                    .await?;
                if ok {
                    self.emit(
                        &lane,
                        &op,
                        Kind::EntryAdded {
                            entry: entry.clone(),
                        },
                    );
                    self.emit(
                        &lane,
                        &op,
                        Kind::CompactionEnd {
                            reason,
                            outcome: Outcome::Completed,
                            entry_id: Some(entry.id),
                        },
                    );
                }
                Ok(Step::Continue(reload))
            }
            Structural::Retry { decision, usage } => {
                let phase = RunPhase::Compaction {
                    reason,
                    structural: decision,
                    resume_after: resume_after.clone(),
                };
                Ok(Step::Continue(
                    self.transition(current, self.run_with(run, phase), vec![usage])
                        .await?
                        .1,
                ))
            }
            Structural::Failed { error, usage } => {
                let phase = RunPhase::FailureDrain {
                    error,
                    provenance: FailureProvenance::Structural {
                        task_id: decision.task_id.clone(),
                    },
                };
                let (ok, reload) = self
                    .transition(
                        current,
                        self.run_with(run, phase),
                        usage.into_iter().collect(),
                    )
                    .await?;
                if ok {
                    self.emit(
                        &lane,
                        &op,
                        Kind::CompactionEnd {
                            reason,
                            outcome: Outcome::Failed,
                            entry_id: None,
                        },
                    );
                }
                Ok(Step::Continue(reload))
            }
            _ => unreachable!(),
        }
    }

    /// Standalone `compact()`.
    async fn step_compaction(&self, current: &Current) -> Result<Step> {
        let OperationState::Compaction(state) = &current.state else {
            unreachable!()
        };
        if state.control.is_cancelled() {
            return self
                .terminal(current, Outcome::Aborted, None, vec![], None, None)
                .await;
        }
        let op = current.operation.operation_id.clone();
        let result_entry_id = match &state.structural.status {
            StructuralStatus::Generating { generation } => {
                generation.context().result_entry_id.clone()
            }
            StructuralStatus::Deciding => EntryId::follower_of(op.as_str()),
        };
        let custom = state.custom_instructions.as_deref();
        let outcome = self
            .structural_step(
                current,
                &state.structural,
                CompactionReason::Manual,
                custom,
                &result_entry_id,
                &current.configuration,
            )
            .await?;
        let with = |structural: StructuralDecision| {
            OperationState::Compaction(CompactionState {
                structural,
                ..state.clone()
            })
        };
        match outcome {
            Structural::Declined => {
                self.terminal(current, Outcome::Declined, None, vec![], None, None)
                    .await
            }
            Structural::Published { entry, writes } => {
                let id = entry.id.clone();
                let step = self
                    .terminal(
                        current,
                        Outcome::Completed,
                        None,
                        writes,
                        Some(Some(id.clone())),
                        Some(id),
                    )
                    .await?;
                if let Step::Done(_) = &step {
                    self.emit(&current.operation.lane, &op, Kind::EntryAdded { entry });
                }
                Ok(step)
            }
            Structural::Next(decision) => Ok(Step::Continue(
                self.transition(current, with(decision), vec![]).await?.1,
            )),
            Structural::Waited => Ok(Step::Continue(self.reload(current).await?)),
            Structural::Intent(decision) => {
                let (ok, reload) = self
                    .transition(current, with(decision.clone()), vec![])
                    .await?;
                let Reload::Current(committed) = reload else {
                    return Ok(Step::Continue(reload));
                };
                if !ok {
                    return Ok(Step::Continue(Reload::Current(committed)));
                }
                let StructuralStatus::Generating {
                    generation:
                        SummaryGeneration::EffectPending {
                            context,
                            attempt,
                            usage_id,
                        },
                } = &decision.status
                else {
                    unreachable!()
                };
                let effect = self
                    .summary_effect(
                        &committed,
                        &op,
                        &decision.task_id,
                        context,
                        *attempt,
                        usage_id,
                        custom,
                        &result_entry_id,
                    )
                    .await?;
                match effect {
                    Structural::Published { entry, writes } => {
                        let id = entry.id.clone();
                        let step = self
                            .terminal(
                                &committed,
                                Outcome::Completed,
                                None,
                                writes,
                                Some(Some(id.clone())),
                                Some(id),
                            )
                            .await?;
                        if let Step::Done(_) = &step {
                            self.emit(&current.operation.lane, &op, Kind::EntryAdded { entry });
                        }
                        Ok(step)
                    }
                    Structural::Retry { decision, usage } => Ok(Step::Continue(
                        self.transition(&committed, with(decision), vec![usage])
                            .await?
                            .1,
                    )),
                    Structural::Failed { error, usage } => {
                        self.terminal(
                            &committed,
                            Outcome::Failed,
                            Some(error),
                            usage.into_iter().collect(),
                            None,
                            None,
                        )
                        .await
                    }
                    _ => unreachable!(),
                }
            }
            Structural::Unknown => {
                let StructuralStatus::Generating {
                    generation:
                        SummaryGeneration::EffectPending {
                            context, attempt, ..
                        },
                } = &state.structural.status
                else {
                    unreachable!()
                };
                if *attempt < context.retry_policy.max_attempts {
                    let decision = StructuralDecision {
                        task_id: state.structural.task_id.clone(),
                        status: StructuralStatus::Generating {
                            generation: SummaryGeneration::Ready {
                                context: context.clone(),
                                next_attempt: attempt + 1,
                            },
                        },
                    };
                    return Ok(Step::Continue(
                        self.transition(current, with(decision), vec![]).await?.1,
                    ));
                }
                self.terminal(
                    current,
                    Outcome::Failed,
                    Some(OperationError::new(
                        "summary_failed",
                        "interrupted and the retry policy allows no more",
                    )),
                    vec![],
                    None,
                    None,
                )
                .await
            }
            Structural::Retry { .. } | Structural::Failed { .. } => unreachable!(),
        }
    }

    // ── navigation ───────────────────────────────────────────────────────

    /// Unsummarised navigation: one terminal transaction moves the leaf.
    async fn step_navigation(&self, current: &Current) -> Result<Step> {
        let OperationState::Navigation(state) = &current.state else {
            unreachable!()
        };
        if state.control.is_cancelled() {
            return self
                .terminal(current, Outcome::Aborted, None, vec![], None, None)
                .await;
        }
        let mut publication = Vec::new();
        if let (Some(label), Some(target)) = (&state.label, &state.target_id) {
            publication.push(Write::set(Namespace::FactLabel, target.as_str(), label));
        }
        self.terminal(
            current,
            Outcome::Completed,
            None,
            publication,
            Some(state.target_id.clone()),
            None,
        )
        .await
    }
}

/// What one structural step produced.
enum Structural {
    Declined,
    Published {
        entry: Entry,
        writes: Vec<Write>,
    },
    /// Commit this decision and continue.
    Next(StructuralDecision),
    /// Commit this `effect_pending` intent, then run the request.
    Intent(StructuralDecision),
    /// A restored `effect_pending` with no live effect.
    Unknown,
    Waited,
    Retry {
        decision: StructuralDecision,
        usage: Write,
    },
    Failed {
        error: OperationError,
        usage: Option<Write>,
    },
}
