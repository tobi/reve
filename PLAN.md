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
  lib.rs              crate root: pub mod ids, lua, project, records, sandbox, storage
  ids.rs              EntryId / RecordId / RunId — prefixed ids, provisioned before the effect
  records.rs          the durable wire format: Line = Header | Entry | Record; JSONL v4;
                      entries are the conversation tree, records are metadata;
                      Replay::{Safe,Never}, Outcome
  storage/
    mod.rs            single-owner session state: entries, records, lanes, facts, one seq
    jsonl.rs          one file per session, one line per mutation, flush every append,
                      torn-tail truncation on reopen, middle corruption refused
  sandbox.rs          the mandatory microVM: links microsandbox crate directly (pinned =0.6.8),
                      deny-by-default egress, scoped secrets, fingerprint reuse, cancellation
  lua.rs              the scripting surface: agent { }, sandbox { }, tool("name", { });
                      ctx.sh → microVM (only command path), ctx.workdir, ctx.shellescape;
                      params → JSON schema
  project.rs          the agent directory, leve init scaffolding, agent-dir guard,
                      durable paths under .leve/
  main.rs             CLI: leve init / info / exec / tool, --version
  templates/          the files leve init writes: agent.lua, sandbox.lua, example_tool.lua,
                      instructions.md, models.yml, workspace/{AGENTS,SOUL,KNOWLEDGE}.md,
                      HEARTBEAT.yml, gitignore
tests/
  microvm.rs          opt-in integration tests against a real microVM (#[ignore])
```

## 2. Mapping harness-v2 concepts to Rust

| harness-v2 | Rust |
|---|---|
| Session (tree, lanes, logs, facts) | `Storage` owning entries, records, lanes, facts, `seq` |
| single writer | structural: only the owning task holds the `Storage` |
| shared monotonic `seq` | `Storage`-local counter; every write assigns it |
| lane (leaf + op log + queues) | a `LaneState { leaf }` in `Storage`; lane execution is pending |
| lanes run in parallel | tokio tasks, serialized at the owning task — pending |
| `prompt/steer/abort/resume` | commands to the owning task — pending |
| abort signal | `tokio_util_lite::CancelRx` — one bit, delivered once; kills the guest command |
| hooks (awaited) | pending |
| events (passive) | pending (observer hub) |
| `watch()` snapshot + gapless stream | pending |
| tools | Lua `tool("name", {…})`; body on host, `ctx.sh` in the VM; `params` → JSON schema |
| telemetry | pending |

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

### Pending

10. **The agent loop** — streaming assistant turns, tool-call prepare/execute/finalize
    batches.
11. **Providers** — `openai-responses`, `anthropic-messages`, and a `fake` for tests.
    `models.yml` is scaffolded and parsed; no requests are made yet.
12. **Lane execution** — beyond `main` in storage, no concurrent lane runs, queues,
    steering, retry caps.
13. **Recovery / resume** — the invariants are in the format and storage layer; no
    procedure walks them yet.
14. **Abort + reconciliation** — synthetic results, closing message, queue payload return.
15. **Observer hub + snapshots + events.**
16. **Compaction** — branch summarisation, `set_leaf` exists but no summariser.
17. **Hooks** — interception points.
18. **Heartbeats** — `HEARTBEAT.yml` is scaffolded; no scheduler reloads it.
19. **Skills** — `workspace/skills/` exists; no discovery, catalog, or frontmatter parsing.
20. **Channels** — `channels/` is an empty directory; no adapters.
21. **The TUI** — no terminal renderer.

## 4. Scope cuts (explicit)

- No v3 JSONL compatibility: this is a new agent, there is nothing to be compatible with.
  The format is the v4 shape.
- No SQLite backend. Memory + JSONL only.
- Exactly one sandbox transport: the `microsandbox` crate, pinned `=0.6.8`. No second
  transport, no host-shell fallback, ever.
- The microVM tests are opt-in (`#[ignore]`); the unit suite must not provision a VM or
  make model requests.

## 5. Invariants we test

- One writer: any append from outside the owning task is impossible by construction.
- Intent before effect: for every `tool_started` there is either a result entry with the
  provisioned id, or recovery produces one (recovery itself is pending; the format upholds
  it).
- Append-only context: mid-step writes never land before the in-flight assistant entry.
- Deleting every record leaves a valid conversation tree.
- Re-running recovery is idempotent (the `append_entry_if_missing` path).
