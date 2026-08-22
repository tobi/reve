//! Typed register values: lane state, operation metadata, and the operation
//! state machine's **program counter** (`docs/harness.md` §2.3, §3).
//!
//! `op.state/{operationId}` holds one total [`OperationState`]. Every
//! transition overwrites the whole register; the terminal transaction deletes
//! it. There is no finished member of the union — an ended operation has no
//! state at all, and its outcome lives in `lane.lastResult`.
//!
//! Everything here is plain data. The transitions live in [`crate::lane`].

use serde::{Deserialize, Serialize};
use serde_json::Value;

use crate::ids::{EntryId, OpId, UsageId};

// ── lane registers ───────────────────────────────────────────────────────

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct ModelRef {
    pub provider: String,
    pub model_id: String,
}

/// Total lane configuration. A setter overwrites the whole register.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct LaneConfiguration {
    pub model: ModelRef,
    pub thinking_level: String,
    pub active_tool_names: Vec<String>,
}

#[derive(Debug, Clone, Default, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct LaneState {
    #[serde(default)]
    pub current_operation_id: Option<OpId>,
    /// Reserved entry ids; payloads in `pending.entry` registers.
    #[serde(default)]
    pub pending_next_run: Vec<EntryId>,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum OpKind {
    Run,
    Compaction,
    Navigation,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum Outcome {
    Completed,
    Aborted,
    Failed,
    Declined,
}

impl Outcome {
    pub fn as_str(self) -> &'static str {
        match self {
            Self::Completed => "completed",
            Self::Aborted => "aborted",
            Self::Failed => "failed",
            Self::Declined => "declined",
        }
    }
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct OperationError {
    pub code: String,
    pub message: String,
}

impl OperationError {
    pub fn new(code: &str, message: impl Into<String>) -> Self {
        Self {
            code: code.into(),
            message: message.into(),
        }
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum RunCompletion {
    Assistant,
    TerminatedTools,
}

/// Terminal outcome of the lane's most recent operation. Written only by
/// terminal transactions; never a recovery input.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct LaneLastResult {
    pub operation_id: OpId,
    pub kind: OpKind,
    pub outcome: Outcome,
    #[serde(default)]
    pub leaf_id: Option<EntryId>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub final_assistant_entry_id: Option<EntryId>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub error: Option<OperationError>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub run_completion: Option<RunCompletion>,
}

// ── operation metadata ───────────────────────────────────────────────────

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(tag = "kind", rename_all = "snake_case")]
pub enum Intent {
    #[serde(rename_all = "camelCase")]
    Run {
        prompt_entry_ids: Vec<EntryId>,
        #[serde(default, skip_serializing_if = "Option::is_none")]
        system_prompt_override: Option<String>,
    },
    #[serde(rename_all = "camelCase")]
    Compaction {
        #[serde(default, skip_serializing_if = "Option::is_none")]
        custom_instructions: Option<String>,
    },
    #[serde(rename_all = "camelCase")]
    Navigation {
        target_id: Option<EntryId>,
        summarize: bool,
        #[serde(default, skip_serializing_if = "Option::is_none")]
        label: Option<String>,
    },
}

impl Intent {
    pub fn kind(&self) -> OpKind {
        match self {
            Self::Run { .. } => OpKind::Run,
            Self::Compaction { .. } => OpKind::Compaction,
            Self::Navigation { .. } => OpKind::Navigation,
        }
    }
}

/// Acceptance data. Written once, never overwritten.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct Operation {
    pub operation_id: OpId,
    pub lane: String,
    pub source_leaf_id: Option<EntryId>,
    pub started_at: i64,
    pub intent: Intent,
}

// ── operation state ──────────────────────────────────────────────────────

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(tag = "status", rename_all = "snake_case")]
pub enum Control {
    Running,
    #[serde(rename_all = "camelCase")]
    CancelRequested {
        requested_at: i64,
        /// Drained queue ids. Their `pending.entry` registers survive the
        /// drain and die in the terminal transaction.
        drained_steer: Vec<EntryId>,
        drained_follow_up: Vec<EntryId>,
    },
}

impl Control {
    pub fn is_cancelled(&self) -> bool {
        matches!(self, Self::CancelRequested { .. })
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "kebab-case")]
pub enum QueueMode {
    All,
    OneAtATime,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct CompactionSettings {
    pub enabled: bool,
    /// Context tokens held back for the response; compaction triggers when
    /// `context_window - reserve_tokens` would be exceeded.
    pub reserve_tokens: u64,
    /// How much of the recent conversation survives as the retained tail.
    pub keep_recent_tokens: u64,
}

impl Default for CompactionSettings {
    fn default() -> Self {
        Self {
            enabled: true,
            reserve_tokens: 16_384,
            keep_recent_tokens: 20_000,
        }
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct RetryPolicy {
    pub max_attempts: u32,
    pub base_delay_ms: u64,
}

impl Default for RetryPolicy {
    fn default() -> Self {
        Self {
            max_attempts: 3,
            base_delay_ms: 1_000,
        }
    }
}

impl RetryPolicy {
    /// Exponential backoff, saturating.
    pub fn delay_ms(&self, attempt: u32) -> u64 {
        self.base_delay_ms
            .saturating_mul(1u64 << attempt.saturating_sub(1).min(20))
    }
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct RunSettings {
    pub compaction: CompactionSettings,
    pub steering_mode: QueueMode,
    pub follow_up_mode: QueueMode,
    pub context_window: u64,
}

impl Default for RunSettings {
    fn default() -> Self {
        Self {
            compaction: CompactionSettings::default(),
            steering_mode: QueueMode::All,
            follow_up_mode: QueueMode::All,
            context_window: 200_000,
        }
    }
}

#[derive(Debug, Clone, Default, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct Inbox {
    #[serde(default)]
    pub steer: Vec<EntryId>,
    #[serde(default)]
    pub follow_up: Vec<EntryId>,
    #[serde(default)]
    pub writes: Vec<EntryId>,
}

impl Inbox {
    pub fn is_empty(&self) -> bool {
        self.steer.is_empty() && self.follow_up.is_empty() && self.writes.is_empty()
    }
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(tag = "kind", rename_all = "snake_case")]
pub enum Continuation {
    #[serde(rename_all = "camelCase")]
    NeedAssistant { overflow_recovery_used: bool },
    #[serde(rename_all = "camelCase")]
    MayFinish { include_final_assistant: bool },
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct CheckpointPhase {
    pub continuation: Continuation,
    /// Durable correlation source for the next generation step.
    pub trigger_entry_id: EntryId,
    /// Threshold compaction is attempted at most once per trigger boundary.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub threshold_checked_trigger_entry_id: Option<EntryId>,
    /// Generate before draining another queued input after a one-at-a-time
    /// drain.
    #[serde(default)]
    pub skip_inbox_once: bool,
}

impl CheckpointPhase {
    pub fn need_assistant(trigger: EntryId) -> Self {
        Self {
            continuation: Continuation::NeedAssistant {
                overflow_recovery_used: false,
            },
            trigger_entry_id: trigger,
            threshold_checked_trigger_entry_id: None,
            skip_inbox_once: false,
        }
    }

    pub fn may_finish(trigger: EntryId, include_final_assistant: bool) -> Self {
        Self {
            continuation: Continuation::MayFinish {
                include_final_assistant,
            },
            trigger_entry_id: trigger,
            threshold_checked_trigger_entry_id: None,
            skip_inbox_once: false,
        }
    }
}

/// Inline snapshot of everything a generation needs, so recovery resolves
/// nothing.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct GenerationContext {
    pub step_id: String,
    pub trigger_entry_id: EntryId,
    pub configuration: LaneConfiguration,
    pub retry_policy: RetryPolicy,
    pub overflow_recovery_used: bool,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(tag = "status", rename_all = "snake_case")]
pub enum Generation {
    #[serde(rename_all = "camelCase")]
    Ready {
        context: GenerationContext,
        next_attempt: u32,
    },
    #[serde(rename_all = "camelCase")]
    EffectPending {
        context: GenerationContext,
        attempt: u32,
        response_entry_id: EntryId,
        usage_id: UsageId,
    },
    #[serde(rename_all = "camelCase")]
    RetryWait {
        context: GenerationContext,
        next_attempt: u32,
        not_before: i64,
        error_message: String,
    },
}

impl Generation {
    pub fn context(&self) -> &GenerationContext {
        match self {
            Self::Ready { context, .. }
            | Self::EffectPending { context, .. }
            | Self::RetryWait { context, .. } => context,
        }
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "lowercase")]
pub enum Replay {
    Safe,
    Never,
}

impl Replay {
    pub fn parse(value: &str) -> Self {
        match value {
            "safe" => Self::Safe,
            _ => Self::Never,
        }
    }
    pub fn as_str(self) -> &'static str {
        match self {
            Self::Safe => "safe",
            Self::Never => "never",
        }
    }
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(tag = "status", rename_all = "snake_case")]
pub enum ToolCallState {
    #[serde(rename_all = "camelCase")]
    Planned {
        source_index: usize,
        result_entry_id: EntryId,
    },
    #[serde(rename_all = "camelCase")]
    EffectPending {
        source_index: usize,
        result_entry_id: EntryId,
        replay: Replay,
    },
    #[serde(rename_all = "camelCase")]
    Completed {
        source_index: usize,
        result_entry_id: EntryId,
        terminate: bool,
    },
}

impl ToolCallState {
    pub fn source_index(&self) -> usize {
        match self {
            Self::Planned { source_index, .. }
            | Self::EffectPending { source_index, .. }
            | Self::Completed { source_index, .. } => *source_index,
        }
    }
    pub fn result_entry_id(&self) -> &EntryId {
        match self {
            Self::Planned {
                result_entry_id, ..
            }
            | Self::EffectPending {
                result_entry_id, ..
            }
            | Self::Completed {
                result_entry_id, ..
            } => result_entry_id,
        }
    }
    pub fn is_completed(&self) -> bool {
        matches!(self, Self::Completed { .. })
    }
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct ToolBatch {
    pub assistant_entry_id: EntryId,
    pub configuration: LaneConfiguration,
    /// The producing generation's step id; recovered tool events use it.
    pub turn_id: String,
    pub calls: Vec<ToolCallState>,
}

impl ToolBatch {
    pub fn args_key(operation_id: &OpId, step_id: &str, source_index: usize) -> String {
        format!("{operation_id}:{step_id}:{source_index}")
    }
    pub fn args_prefix(operation_id: &OpId, step_id: &str) -> String {
        format!("{operation_id}:{step_id}:")
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum CompactionReason {
    Manual,
    Threshold,
    Overflow,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct SummaryContext {
    pub task_id: String,
    pub result_entry_id: EntryId,
    pub configuration: LaneConfiguration,
    pub retry_policy: RetryPolicy,
    pub reason: CompactionReason,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(tag = "status", rename_all = "snake_case")]
pub enum SummaryGeneration {
    #[serde(rename_all = "camelCase")]
    Ready {
        context: SummaryContext,
        next_attempt: u32,
    },
    #[serde(rename_all = "camelCase")]
    EffectPending {
        context: SummaryContext,
        attempt: u32,
        usage_id: UsageId,
    },
    #[serde(rename_all = "camelCase")]
    RetryWait {
        context: SummaryContext,
        next_attempt: u32,
        not_before: i64,
        error_message: String,
    },
}

impl SummaryGeneration {
    pub fn context(&self) -> &SummaryContext {
        match self {
            Self::Ready { context, .. }
            | Self::EffectPending { context, .. }
            | Self::RetryWait { context, .. } => context,
        }
    }
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(tag = "status", rename_all = "snake_case")]
// The union is the program counter; boxing a phase to even out its size would
// buy a pointer chase on every state read.
#[allow(clippy::large_enum_variant)]
pub enum StructuralStatus {
    Deciding,
    Generating { generation: SummaryGeneration },
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct StructuralDecision {
    pub task_id: String,
    #[serde(flatten)]
    pub status: StructuralStatus,
}

impl StructuralDecision {
    pub fn preparation_key(operation_id: &OpId, task_id: &str) -> String {
        format!("{operation_id}:{task_id}")
    }
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(tag = "kind", rename_all = "snake_case")]
pub enum FailureProvenance {
    #[serde(rename_all = "camelCase")]
    Response { entry_id: EntryId },
    #[serde(rename_all = "camelCase")]
    Structural { task_id: String },
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(tag = "kind", rename_all = "snake_case")]
pub enum RunPhase {
    Checkpoint(CheckpointPhase),
    Assistant {
        generation: Generation,
    },
    Tools {
        batch: ToolBatch,
    },
    #[serde(rename_all = "camelCase")]
    Compaction {
        reason: CompactionReason,
        structural: StructuralDecision,
        resume_after: CheckpointPhase,
    },
    #[serde(rename_all = "camelCase")]
    FailureDrain {
        error: OperationError,
        provenance: FailureProvenance,
    },
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct RunState {
    pub control: Control,
    pub settings: RunSettings,
    pub phase: RunPhase,
    #[serde(default)]
    pub inbox: Inbox,
    #[serde(default)]
    pub latest_assistant_entry_id: Option<EntryId>,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct CompactionState {
    pub control: Control,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub custom_instructions: Option<String>,
    pub structural: StructuralDecision,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct NavigationState {
    pub control: Control,
    pub target_id: Option<EntryId>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub label: Option<String>,
}

/// The program counter.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(tag = "kind", rename_all = "snake_case")]
pub enum OperationState {
    Run(RunState),
    Compaction(CompactionState),
    Navigation(NavigationState),
}

impl OperationState {
    pub fn kind(&self) -> OpKind {
        match self {
            Self::Run(_) => OpKind::Run,
            Self::Compaction(_) => OpKind::Compaction,
            Self::Navigation(_) => OpKind::Navigation,
        }
    }

    pub fn control(&self) -> &Control {
        match self {
            Self::Run(s) => &s.control,
            Self::Compaction(s) => &s.control,
            Self::Navigation(s) => &s.control,
        }
    }

    pub fn control_mut(&mut self) -> &mut Control {
        match self {
            Self::Run(s) => &mut s.control,
            Self::Compaction(s) => &mut s.control,
            Self::Navigation(s) => &mut s.control,
        }
    }
}

// ── pending content ──────────────────────────────────────────────────────

/// Unplaced content: current mutable state until the placement transaction
/// writes the complete entry and deletes this register.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct PendingEntry {
    #[serde(rename = "type")]
    pub entry_type: String,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub custom_type: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub payload: Option<Value>,
}

impl PendingEntry {
    pub fn message(message: Value) -> Self {
        Self {
            entry_type: "message".into(),
            custom_type: None,
            payload: Some(message),
        }
    }

    /// The entry this content becomes when placed, under the reserved id.
    pub fn into_entry(self, id: EntryId) -> crate::entry::Entry {
        match self.entry_type.as_str() {
            "custom" => crate::entry::Entry::custom(
                self.custom_type.unwrap_or_else(|| "custom".into()),
                self.payload,
            ),
            _ => crate::entry::Entry::message(self.payload.unwrap_or(Value::Null)),
        }
        .with_id(id)
    }
}

/// Durable structural preparation: what the summary request will see.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct CompactionPreparation {
    pub messages_to_summarize: Vec<Value>,
    pub retained_tail: Vec<Value>,
    pub tokens_before: u64,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub previous_summary: Option<String>,
}

#[cfg(test)]
mod tests {
    use super::*;

    fn config() -> LaneConfiguration {
        LaneConfiguration {
            model: ModelRef {
                provider: "openai".into(),
                model_id: "gpt".into(),
            },
            thinking_level: "off".into(),
            active_tool_names: vec!["bash".into()],
        }
    }

    #[test]
    fn operation_state_round_trips_with_tagged_unions() {
        let state = OperationState::Run(RunState {
            control: Control::CancelRequested {
                requested_at: 5,
                drained_steer: vec![EntryId::from("a")],
                drained_follow_up: vec![],
            },
            settings: RunSettings::default(),
            phase: RunPhase::Tools {
                batch: ToolBatch {
                    assistant_entry_id: EntryId::from("asst"),
                    configuration: config(),
                    turn_id: "s1".into(),
                    calls: vec![
                        ToolCallState::Completed {
                            source_index: 0,
                            result_entry_id: EntryId::from("r0"),
                            terminate: false,
                        },
                        ToolCallState::EffectPending {
                            source_index: 1,
                            result_entry_id: EntryId::from("r1"),
                            replay: Replay::Never,
                        },
                    ],
                },
            },
            inbox: Inbox::default(),
            latest_assistant_entry_id: Some(EntryId::from("asst")),
        });
        let json = serde_json::to_value(&state).unwrap();
        assert_eq!(json["kind"], "run");
        assert_eq!(json["phase"]["kind"], "tools");
        assert_eq!(json["control"]["status"], "cancel_requested");
        assert_eq!(
            json["phase"]["batch"]["calls"][1]["status"],
            "effect_pending"
        );
        assert_eq!(json["phase"]["batch"]["calls"][1]["replay"], "never");
        let back: OperationState = serde_json::from_value(json).unwrap();
        assert_eq!(back, state);
    }

    #[test]
    fn checkpoint_and_generation_states_round_trip() {
        let phase = RunPhase::Assistant {
            generation: Generation::RetryWait {
                context: GenerationContext {
                    step_id: "s".into(),
                    trigger_entry_id: EntryId::from("t"),
                    configuration: config(),
                    retry_policy: RetryPolicy::default(),
                    overflow_recovery_used: false,
                },
                next_attempt: 2,
                not_before: 99,
                error_message: "boom".into(),
            },
        };
        let json = serde_json::to_value(&phase).unwrap();
        assert_eq!(json["generation"]["status"], "retry_wait");
        let back: RunPhase = serde_json::from_value(json).unwrap();
        assert_eq!(back, phase);

        let cp = CheckpointPhase::need_assistant(EntryId::from("t"));
        let json = serde_json::to_value(RunPhase::Checkpoint(cp.clone())).unwrap();
        assert_eq!(json["kind"], "checkpoint");
        assert_eq!(json["continuation"]["kind"], "need_assistant");
    }

    #[test]
    fn pending_entries_place_under_their_reserved_id() {
        let pending = PendingEntry::message(serde_json::json!({"role": "user", "content": "x"}));
        let entry = pending.into_entry(EntryId::from("reserved"));
        assert_eq!(entry.id.as_str(), "reserved");
        assert_eq!(entry.role(), Some("user"));
    }

    #[test]
    fn retry_delay_grows_and_saturates() {
        let policy = RetryPolicy {
            max_attempts: 5,
            base_delay_ms: 100,
        };
        assert_eq!(policy.delay_ms(1), 100);
        assert_eq!(policy.delay_ms(2), 200);
        assert_eq!(policy.delay_ms(4), 800);
        let huge = RetryPolicy {
            max_attempts: 99,
            base_delay_ms: u64::MAX / 2,
        };
        assert_eq!(huge.delay_ms(40), u64::MAX);
    }
}
