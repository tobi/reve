# Leve coding agent in Rust, with Lua scripting

Implementation plan. The durable-harness design it follows is documented by Pi at
[harness-v2.md](https://github.com/earendil-works/pi/blob/main/packages/agent/docs/harness-v2.md);
this document maps it onto Rust modules and records what was built and what is pending.

Leve is a Rust crate (edition 2024) with Lua for scripting, written as a fresh 0.1.0.

## 0. Why Rust and single-owner state

harness-v2's central structural claim is **single writer per session**. In Rust that is not
an assertion the serving layer must uphold — it is the type system. `Storage`
(`src/storage/mod.rs`) is deliberately not thread-safe and not shared: it owns the session's
entries, records, lanes, facts, and one monotonic `seq`, and exactly one task owns the
`Storage`. There is no `Arc<Mutex<Storage>>`; concurrent work is serialized through the
owning task. Every other invariant — lanes owning their own queues, records never shared
across lanes, hooks awaited at interception points, tools as isolated effects — maps onto
"one task, one owner, channels in between".

Concurrency is tokio tasks. The sandbox holds a live microVM handle behind a
`tokio::sync::Mutex`, cloned out before any `await` so a long command never blocks `stop` or
the next `exec`. Cancellation is a hand-rolled one-bit watch channel
(`tokio_util_lite`), delivered once.

## 1. Module map

What actually exists in `src/` today:

```
src/
  ids.rs              EntryId / RecordId / RunId
  records.rs          JSONL v4 wire format; entries, records, Replay, Outcome
  storage/{mod,jsonl}.rs  single-owner state and torn-tail-safe persistence
  model.rs            Model trait, streaming callback, ScriptedModel, Usage
  lane.rs             durable run procedure, abort reconciliation, recovery
  session.rs          SessionTask owner, command channel, snapshots, events
  observer.rs         broadcast observer hub
  hooks.rs            awaited before/after tool hooks
  compaction.rs       summary entry and durable leaf move
  provider/
    config.rs         models.yml, $ENV enforcement, compat resolution
    sse.rs            chunk-safe SSE decoder
    openai_responses.rs / anthropic.rs  streaming adapters
    mod.rs            reqwest transport, retry and diagnostics
  sandbox.rs          mandatory microsandbox VM, deny-by-default egress
  lua.rs              agent.lua, sandbox.lua, tools/*.lua, JSON schemas
  tools.rs            bash/read/write/edit/ls/glob/grep, replay declarations
  skills.rs           recursive SKILL.md catalog and validation
  heartbeat.rs        schedule reload and response-contract validation
  channels.rs         inbox broadcast and namespaced durable KV
  project.rs          agent directory and leve init
  tui/{app,item,markdown,stream,complete,run,session}.rs
                       inline ratatui renderer and terminal session
  main.rs              init / info / exec / tool / bare leve TUI
tests/{crash,microvm,provider_http}.rs
```

## 2. Mapping harness-v2 concepts to Rust

| harness-v2 | Rust |
|---|---|
| Session (tree, lanes, logs, facts) | `Storage` owned by `SessionTask` |
| single writer | structural: only the session task holds `Storage` |
| shared monotonic `seq` | `Storage`-local counter; every write assigns it |
| lane (leaf + op log + queues) | `LaneState { leaf }` plus `Lane::run_with` |
| lanes run in parallel | session tasks can run independently; one owner per session |
| `prompt/steer/abort/resume` | `SessionHandle` commands; abort carries `CancelRx` |
| abort signal | `tokio_util_lite::CancelRx`; kills guest commands through `Toolbox` |
| hooks (awaited) | `Hooks::run_before_tool` / `run_after_tool` |
| events (passive) | `SessionTask` event broadcast plus `Observer` |
| `watch()` snapshot + gapless stream | broadcast `Event::Snapshot` after each command |
| tools | Lua plus seven Rust built-ins; all effects use `Sandbox` |
| telemetry | provider usage and cache-miss diagnostics; exporters pending |

## 3. Implementation sequence

### Done

1. **Ids.** `EntryId`/`RecordId`/`RunId`, prefixed (`e_`/`r_`/`run_`), 16 chars of base-36,
   provisioned before the effect they name (`src/ids.rs`).
2. **The durable wire format.** `Line = Header | Entry | Record`, JSONL version 4. Entries
   are the conversation tree (`parent_id`); records are metadata. `Replay::{Safe,Never}`,
   `Outcome`. The envelope is typed; the payload is `serde_json::Value`
   (`src/records.rs`).
3. **Single-owner session state.** Entries, records, lanes, facts, one `seq`. Append,
   find, path-to-leaf, lane leaf moves, facts. `append_entry_if_missing` makes provisioned
   ids idempotent (`src/storage/mod.rs`).
4. **JSONL backend.** One file per session, one line per mutation, flush every append.
   Torn-tail truncation on reopen; a malformed line in the middle refused as corruption;
   version check on reopen (`src/storage/jsonl.rs`).
5. **The mandatory sandbox.** Links `microsandbox =0.6.8` directly. Deny-by-default egress
   from `NetworkPolicy::none()` + gateway-DNS + one allow per host. Scoped secrets with
   placeholders. Fingerprint-based VM reuse (secrets hashed, not stored). Cancellation via
   the exec control channel. Workspace bind mount at `/workspace` (`src/sandbox.rs`).
6. **The scripting surface.** `agent { }`, `sandbox { }`, `tool("name", { })`. Params →
   JSON schema; defaults applied, required enforced. `ctx.sh` → microVM (only command
   path); `ctx.workdir`; `ctx.shellescape`. Runtime owns the Lua VM and all declared tools
   (`src/lua.rs`).
7. **The agent directory.** `leve init` scaffolds the real templates idempotently. Agent-dir
   guard. Durable paths under `.leve/` (`src/project.rs`).
8. **The CLI.** `leve init [dir]`, `leve info`, `leve exec <cmd...>`, `leve tool [name]
   [--args JSON]`, `--version` (`src/main.rs`).
9. **Opt-in microVM tests.** `tests/microvm.rs`: a Lua tool's `ctx.sh` in the guest with
   the workspace mount read/write; `github.com` reachable, unlisted host blocked;
   cancellation kills the guest command, VM still usable. `#[ignore]` by default.
10. **The model seam.** `Model` trait plus `ScriptedModel`, whose cursor lives in a file so
    a killed-and-restarted process resumes at the turn it had reached (`src/model.rs`).
11. **The run procedure.** Intent before effect, end to end: `operation_started` →
    `task_attempt` → assistant entry → `tool_started` (which provisions the result id and
    records the replay declaration) → result entry under exactly that id →
    `operation_finished`. Retry cap, tool failures returned to the model as results rather
    than faulting the lane (`src/lane.rs`).
12. **Abort + reconciliation.** A cancelled run still writes the promised result entry — a
    synthetic interrupted one — and still closes its operation. An abort before any work
    promises nothing and closes cleanly (`src/lane.rs`).
13. **Recovery.** The reduction from two bounded reads: which operations were opened and
    never finished, and which of their declared results never landed. Every missing result
    is produced — replayed only when the recorded *and* current declarations both say
    `safe`, otherwise synthesised. Closing every operation it touches makes re-running a
    no-op (`recover` in `src/lane.rs`).
14. **Crash-site test.** `tests/crash.rs` spawns `src/bin/crash_child.rs`, waits until it is
    inside the tool, SIGKILLs it, and reduces what the dead process left on disk. Nothing
    is simulated.

### Done

15. **Providers.** OpenAI Responses and Anthropic Messages thin `reqwest` adapters:
    SSE streaming, tool-call deltas, cumulative usage, transient retries, provider
    diagnostics, and compat-specific request bodies.
16. **Lane execution as a task.** `SessionTask` owns `Storage`; commands cross its
    channel and replies return via oneshots. TUI turns reopen the same JSONL session.
17. **Observer hub + snapshots + events.** Broadcast subscribers receive ordered
    run and snapshot events without storage access.
18. **Compaction.** Summary entry, lane leaf move, durable start/finish records.
19. **Hooks.** Awaited sequential before-tool hooks with fail-closed errors.
20. **Heartbeats.** Reload fingerprints and strict response-contract parser.
21. **Skills.** Recursive SKILL.md discovery and frontmatter catalog injection.
22. **Channels.** Ordered inbox hub and namespaced durable KV store.
23. **The TUI.** Ratatui inline renderer, checkpointed Markdown streaming,
    slash completion, subagent/inbox/steer/follow-up states, and startup spinner.

## 4. Scope cuts (explicit)

- No v3 JSONL compatibility: this is a new agent, there is nothing to be compatible with.
  The format is the v4 shape.
- No SQLite backend. Memory + JSONL only.
- Exactly one sandbox transport: the `microsandbox` crate, pinned `=0.6.8`. No second
  transport, no host-shell fallback, ever.
- The microVM tests are opt-in (`#[ignore]`); the unit suite must not provision a VM or
  make model requests.

## 5. Invariants, and where each is actually tested

Every row names a test. A claim without one is marked as such rather than listed as if it
were covered.

| Invariant | Test |
|---|---|
| Deleting every record leaves a valid conversation tree | `storage::tests::deleting_every_record_leaves_a_valid_tree` |
| A provisioned id may be appended twice without duplicating | `storage::tests::provisioned_ids_can_be_appended_twice_without_duplicating` |
| `seq` is shared and monotonic across entries and records | `storage::tests::seq_is_shared_and_monotonic_across_entries_and_records` |
| A torn tail truncates; a malformed line elsewhere is corruption | `storage::jsonl::tests::{a_torn_tail_is_truncated_and_the_prefix_survives, a_malformed_line_in_the_middle_is_corruption}` |
| A payload can never collide with the envelope | `records::tests::a_payload_cannot_collide_with_the_envelope` |
| Intent before effect: `tool_started` names the id the result uses | `lane::tests::a_run_writes_intent_before_effect` |
| Append-only context: a result never precedes the turn that asked for it | `lane::tests::the_assistant_turn_lands_before_its_tool_result` |
| An aborted tool still gets its promised result | `lane::tests::aborting_mid_run_still_produces_the_promised_result_entry` |
| An effectful tool is never replayed by recovery | `lane::tests::recovery_replays_a_tool_only_when_both_declarations_say_safe` |
| Recovery is idempotent | `lane::tests::recovery_closes_the_operation_and_is_idempotent` |
| A really-killed process leaves a recoverable session | `tests/crash.rs` (spawns and SIGKILLs a real child) |
| Deny-by-default egress | `tests/microvm.rs` (opt-in, real VM) |

**Not yet enforced.** "Single writer" is currently true only because nothing shares a
`Storage` — there is no owning task yet, so any holder of `&mut Storage` can append. It
becomes structural when item 16 lands; until then it is a convention, not a guarantee.
