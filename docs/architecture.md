# Reve: the specification, mapped onto Rust

[`docs/harness.md`](harness.md) is the authority. This document is the map: how that
design lands in Rust modules, which parts exist, what was deliberately cut, and where
each invariant is actually tested. When the two disagree, the specification wins unless a
cut is recorded here.

Reve is one Rust crate (edition 2024, version 0.1.0) with Lua for scripting.

## 0. Why Rust, and what the type system is doing for us

The specification's central structural claim is **one writer per session**. In most
languages that is a rule the serving layer has to keep. Here it is the type system:
`Storage` (`src/storage/mod.rs`) is not `Sync`, is never wrapped in a mutex, and is moved
into a single owner task by `Session::spawn`. Everyone else holds a clonable `Session`
handle and sends commands. You cannot get a `&mut Storage` from a handle, so "two writers"
is not a bug you can write.

The second claim is **explicit state, not inferred state**. There is no code anywhere that
reconstructs what an operation was doing by replaying its history. `op.state/{id}` holds
one total value — a program counter — and every transition overwrites the whole register.
Recovery is five point lookups and a bounded validation of exactly what those lookups
name (`session::restore`). An operation that has ended has no state at all: there is no
`finished` member of the union, and the terminal transaction deletes the register.

Concurrency is tokio tasks. Cancellation is a one-bit watch channel (`tokio_util_lite`),
and it is only ever an *accelerator* — the durable meaning of an abort is a committed
`Control::CancelRequested`, so an abort that races a crash still ends the operation
aborted.

## 1. Module map

```
src/
  ids.rs              UUIDv7 minting, EntryId / UsageId / OpId, follower ids
  entry.rs            JSONL v4 wire format: Entry, Usage, Namespace, Write,
                      Transaction, Line (header | object | array batch)
  state.rs            every typed register value, including OperationState —
                      the program counter — and its phases
  storage/mod.rs      in-memory projection; all-or-none commit, branch scans
  storage/jsonl.rs    one file, one writer, torn-tail-safe replay, file lock
  session.rs          the owner task, the Session handle, conditional commits
                      (Expect / CAS), typed reads, restore(), context projection
  lane.rs             the Driver: one step of the state machine per commit
  harness.rs          the public surface: prompt / steer / followUp / nextRun /
                      abort / compact / navigate / resume, and the lane claim
  hooks.rs            before_run, before_tool (fails closed), after_tool,
                      before_run_end, before_compaction, transform_context
  events.rs           the passive event stream
  compaction.rs       threshold arithmetic, tail selection, summary request
  model.rs            Model trait, streaming callback, ScriptedModel, StopReason
  provider/           models.yml, SSE decoder, OpenAI + Anthropic adapters
  sandbox.rs          mandatory microsandbox VM, deny-by-default egress
  lua.rs              agent.lua, sandbox.lua, tools/*.lua; host door closed
  tools.rs            the Tools trait plus seven built-ins, replay declarations
  skills.rs           recursive SKILL.md catalog
  heartbeat.rs        schedule reload and response-contract validation
  channels.rs         inbox broadcast and namespaced durable KV
  project.rs          agent directory and `reve init`
  tui/                inline ratatui renderer and the terminal session
  main.rs             init / info / exec / tool / bare `reve`
tests/{harness,crash,microvm,provider_http}.rs
```

## 2. The specification's concepts, in Rust

| Specification | Rust |
|---|---|
| Session: entries, registers, usage, one `seq` | `Storage`, owned by the `Session` task |
| One writer | structural: `Storage` is moved into the task; handles send commands |
| Register | `Namespace` + key → `Register { value, seq }` |
| The program counter `op.state/{id}` | `state::OperationState` (`Run` / `Compaction` / `Navigation`) |
| Atomic transaction | `Transaction` of `Write`s; `Storage::commit` validates all-or-none |
| Conditional commit | `Session::commit_if` with `Expect { namespace, key, seq }` |
| Lane claim (one operation per lane) | `Expect` on `lane.state`; the loser gets `HarnessError::Busy` |
| Intent before effect | commit `EffectPending` (+ `op.tool_args`), *then* invoke |
| Recovery | `Session::restore` → `Restored::Suspended(Current)` → `Driver::drive` |
| Terminal transaction | `Driver::terminal`: delete everything the operation owned, write `lane.lastResult`, clear the claim |
| Queued input | `pending.entry/{id}` payload + the id in the running operation's inbox |
| Abort | committed `Control::CancelRequested`; the watch channel only wakes the effect |
| Hooks (intercept) | `hooks.rs`, sequential, chained, `before_tool` fails closed |
| Events (observe) | `events::Event` on a broadcast channel; nothing can change execution |
| Tools | seven Rust built-ins plus Lua tools; every effect goes through `Sandbox` |

### The shape of one step

`Driver::drive` is a loop, and every iteration is: read the phase, do at most one
irreversible thing, commit the next phase conditionally, reload. Because the commit is
conditional on the `op.state` seq the step was planned against, anything that landed in
between — an `abort`, a `steer` — makes the commit fail, and the driver replans from the
reloaded state instead of writing something it decided under stale assumptions.

## 3. What is built

- **Storage and format.** JSONL v4. Three line shapes: header, single object, array batch
  (one physical line per transaction, so a transaction cannot be half-read). Entries are
  write-once and form the conversation tree; registers are mutable state with no history;
  usage rows are separate. Payloads are flattened with reserved keys sanitised to
  `payload_*`. Flush every append; a torn last line is discarded whole on reopen; a
  malformed line anywhere else is corruption and we refuse to open. Snapshot compaction
  rewrites through a temp file and a rename. Cross-process exclusion via `File::try_lock`.
- **The session.** Owner task, `Commit` / `Read` / `Close` commands, CAS tokens, typed
  register reads, `ensure_lane`, `restore` with the specification's bounded validation, and
  `project_context` — which stops at a compaction, expands its summary plus retained tail,
  and drops error and aborted assistant turns so a failed attempt never reaches the model.
- **The driver.** Checkpoint (queue drain, threshold compaction, finish decision),
  assistant generation with durable retry state, the tool batch, in-run compaction, failure
  drain, and the terminal transaction. Structural work (compaction) shares one
  `deciding → generating → published` machine between the in-run and standalone paths.
- **The harness.** Every public entry point either claims a lane or amends a running
  operation, both as one conditional transaction, so a caller is never told something
  landed that is not on disk.
- **Recovery.** A resumed run continues; it does not abort. A tool interrupted mid-effect
  is re-executed only when the recorded *and* current replay declarations both say `safe`,
  and otherwise gets a synthetic result that admits the effect may or may not have
  happened. A prompt that was still a reservation is placed exactly once.
- **The sandbox.** Links `microsandbox =0.6.8` directly. The default guest is a
  pre-provisioned Arch image (`ghcr.io/tobi/wrap:latest`) whose toolchain lives at absolute
  paths under `/opt`, so the first command runs at boot instead of after minutes of package
  installation; provisioning is therefore off by default and exists for agents that point
  at a bare distro. Deny-by-default egress, scoped source-backed secrets, fail-closed boot,
  idle shutdown, workspace bind mount at `/workspace`.
- **The scripting surface.** `agent { }`, `sandbox { }`, `tool("name", { })`. `ctx.sh` is
  the only command path and it goes to the VM. The host command path — `os.execute`,
  `io.popen`, `os.exit`, `package.loadlib` — is deleted from the Lua VM before any script
  runs, so "the microVM is the only way to run anything" is structural rather than a
  convention to re-check.
- **The terminal.** Ratatui inline renderer driven by the passive event stream. A run is a
  spawned task, so a steer typed mid-run is a conditional commit rather than a message the
  loop has to be free to receive.

## 4. Deliberate cuts

The specification describes more than this crate implements. These are choices, not gaps:

- **No deferred provider requests.** A generation is attempted when the driver reaches it.
- **No summarised navigation.** `navigate()` moves the leaf; it does not generate a summary
  of what it skipped.
- **Sequential tool execution only.** A batch runs one call at a time, in order.
- **No "missing identities" concept.** An unknown tool produces a synthetic error result
  the model can read, not a distinct state.
- **No SQLite backend, no v3 compatibility.** Memory plus JSONL, v4 only. This is a new
  agent; there is nothing to be compatible with.
- **Exactly one sandbox transport**, pinned `=0.6.8`. No second transport and no host-shell
  fallback, ever.
- **The microVM tests are opt-in** (`#[ignore]`). The unit suite provisions no VM and makes
  no model request.

## 5. Invariants, and the test that holds each one

Every row names a real test. A claim with no test says so instead of appearing covered.

| Invariant | Test |
|---|---|
| A transaction is all-or-none | `storage::tests::a_failing_transaction_applies_nothing` |
| `seq` is shared and strictly increasing across every kind of write | `storage::tests::a_transaction_assigns_strictly_increasing_seq_across_all_kinds` |
| An entry may name a parent created in the same transaction | `storage::tests::an_entry_may_name_a_parent_created_earlier_in_the_same_transaction` |
| Registers have no history: set, delete, recreate | `storage::tests::registers_set_delete_and_recreate_without_history` |
| Deleting every register still leaves a valid conversation | `storage::tests::deleting_every_register_leaves_a_valid_tree` |
| A branch scan stops inclusively at a compaction | `storage::tests::a_branch_scan_stops_inclusively_at_a_compaction` |
| A torn tail is discarded whole; a malformed line elsewhere is corruption | `storage::jsonl::tests::{a_torn_array_line_is_discarded_whole, a_malformed_line_in_the_middle_is_corruption}` |
| A future format or storage version is refused, not guessed at | `storage::jsonl::tests::{a_future_format_version_is_refused_rather_than_guessed_at, a_newer_storage_version_is_refused}` |
| One writer per session, across processes | `storage::jsonl::tests::a_second_process_cannot_open_a_live_session`, `tests/crash.rs` |
| A payload can never collide with the envelope | `entry::tests::a_payload_cannot_collide_with_the_envelope` |
| A conditional commit is rejected when its token moved | `session::tests::a_conditional_commit_is_rejected_when_its_token_moved` |
| Restore refuses a state that contradicts itself | `session::tests::restore_rejects_an_aborted_response_under_running_control` |
| Context stops at a compaction and drops failed attempts | `session::tests::context_projection_reads_nothing_past_a_compaction_and_drops_errors` |
| A prompt becomes a user entry and an assistant reply, leaving no registers behind | `tests/harness.rs::a_prompt_becomes_a_user_entry_and_an_assistant_reply` |
| One operation per lane; a second is refused | `tests/harness.rs::a_second_operation_on_a_busy_lane_is_refused` |
| `before_tool` decides the arguments that are persisted and run | `tests/harness.rs::before_tool_rewrites_the_arguments_that_get_persisted` |
| `before_tool` fails closed | `tests/harness.rs::a_throwing_before_tool_hook_fails_the_call_closed`, `hooks::tests::a_throwing_before_tool_handler_blocks_the_tool` |
| `after_tool` decides the result that is persisted | `tests/harness.rs::after_tool_rewrites_the_result_that_gets_persisted` |
| A truncated response never executes its tool call | `tests/harness.rs::a_truncated_response_never_executes_its_tool_call` |
| A retryable failure is retried; an exhausted budget fails the run without losing the prompt | `tests/harness.rs::{a_retryable_provider_failure_is_retried_then_succeeds, an_exhausted_retry_budget_fails_the_run_and_keeps_the_prompt}` |
| An abort ends the run aborted and drops queued input | `tests/harness.rs::an_abort_ends_the_run_aborted_and_drops_queued_input` |
| A run dropped before its first generation resumes and places its prompt once | `tests/harness.rs::a_run_dropped_before_its_first_generation_resumes_and_finishes` |
| A replay-safe tool interrupted mid-effect is re-executed from its persisted arguments | `tests/harness.rs::a_safe_tool_interrupted_mid_effect_is_re_executed`, `tests/crash.rs::a_killed_replay_safe_tool_is_re_executed_from_its_persisted_arguments` |
| An effectful tool interrupted mid-effect is never re-executed | `tests/harness.rs::an_effectful_tool_interrupted_mid_effect_is_never_re_executed`, `tests/crash.rs::a_killed_effectful_tool_is_reported_interrupted_never_re_run` |
| A completed tool call is not run again on resume | `tests/harness.rs::a_completed_tool_is_not_run_again_on_resume` |
| An abort committed before the crash survives it | `tests/harness.rs::an_abort_committed_before_the_crash_ends_the_resumed_run_aborted` |
| A really-killed process leaves a resumable session | `tests/crash.rs` (spawns and SIGKILLs a real child) |
| The compaction tail is widened to a user turn | `compaction::tests::the_tail_is_widened_to_a_user_turn_and_the_head_is_summarised` |
| Lua cannot execute a command on the host | `lua::tests::{the_host_command_path_is_gone_before_any_script_runs, a_tool_that_tries_to_shell_out_on_the_host_fails_to_load}` |
| The default guest is pre-provisioned, and git reads its token from the environment | `sandbox::tests::{the_default_policy_boots_a_preprovisioned_guest, git_reads_its_token_from_the_environment_not_a_credential_store}` |
| An unmentioned Lua flag keeps its default | `lua::tests::an_unmentioned_flag_keeps_its_default` |
| Deny-by-default egress | `tests/microvm.rs` (opt-in, real VM) |

**Not covered yet.** Standalone `compact()` and `navigate()` have no end-to-end test — the
machinery is shared with the in-run compaction path, which is exercised only through the
overflow route. Lane concurrency is implemented (a lane claim per operation, drivers as
independent tasks) but there is no test that runs two lanes at once.
