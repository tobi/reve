# reve

A durable coding agent. The core is a Rust crate; the scripting surface an agent author
touches — configuration, project tools, sandbox policy — is Lua.

## Read first

- **`docs/harness.md`** — the durable-harness specification Reve implements (vendored from
  Pi's `packages/agent/docs/harness.md`; the upstream `harness-v2.md` link it replaced is
  dead). It is the authority on storage shape, the operation state machine, recovery,
  abort, queues, hooks, and events. When this crate and that document disagree, the
  document wins unless `docs/architecture.md` records a deliberate cut.
- **`docs/architecture.md`** — how the specification maps onto Rust modules, which parts are
  built, which are deliberately cut, and where each invariant is tested. Update it in the
  same change as the code it describes.

## Rules

- **Sandbox or no Reve.** Reve links the `microsandbox` Rust crate directly (pinned
  `=0.6.8` in `Cargo.toml`). There is exactly one transport, no FFI shim, no CLI, no
  daemon, and no host-shell fallback — ever, not for tests, diagnostics, degraded
  operation, or convenience. Every shell command a tool issues — `ctx.sh`, `reve exec` —
  executes inside that VM. Reve must refuse to start if the microVM cannot boot. Never
  retain, add, or silently select a host/local shell fallback.
- **No host command path exposed to Lua.** A tool's Lua body runs on the host, but
  `ctx.sh` is its only command path and it goes to the microVM. There is no `ctx.host_exec`
  or equivalent. The host side orchestrates; it does not authorize host effects.
- **Intent before effect.** Commit the state that names what is about to happen — the
  reserved entry ids, the effective tool arguments — *before* doing it. Every step is: plan
  against a state you read, do at most one irreversible thing, then commit the next state
  conditionally on that same read. If the conditional commit fails, something else landed;
  replan from the reload rather than writing a decision made under stale assumptions.
- **Explicit state, never inferred.** `op.state/{id}` is a total value and a program
  counter. Do not add code that reconstructs what an operation was doing by scanning its
  history — recovery is point lookups plus bounded validation of exactly what they name.
  An ended operation has no state at all; the terminal transaction deletes it and the
  outcome lives in `lane.lastResult`.
- **Single-owner session state.** `Storage` is deliberately not thread-safe and not shared.
  `Session::spawn` moves it into one owner task; everyone else holds a clonable handle and
  sends commands. That is how reve gets the single-writer guarantee structurally instead of
  by convention. Do not wrap it in an `Arc<Mutex>` to "share" it, and do not hand out
  `&mut Storage`.
- **An abort is a commit, not a signal.** The durable meaning of cancellation is
  `Control::CancelRequested` in `op.state`. The watch channel exists only to wake an
  in-flight request or tool early, so an abort that races a crash still ends the operation
  aborted.
- **One JSONL session, one writer, flush every append.** A crash can only tear the last
  line; on reopen we truncate the torn tail and resume. A malformed line in the middle is
  corruption and we refuse to open. An agent that reports work it did not persist is worse
  than one that is slow.
- **Lua is trusted launch code.** `agent.lua`, `sandbox.lua`, and `tools/*.lua` run on the
  host before any work starts, exactly like the Rust they extend. They are not model
  output and they are not sandboxed — they are configuration. What they must never do is
  execute a command on the host: `ctx.sh` goes to the microVM, and it is the only way out
  of a tool. `Runtime::new` deletes `os.execute`, `io.popen`, `os.exit`, and
  `package.loadlib` from the VM before any script runs; keep that list closed.
- **Never silently overwrite files a user has edited.** `reve init` is idempotent: a
  matching file is left `unchanged`, an edited file is reported `changed` and kept, a
  missing file is created.
- Every new behaviour gets a test. Keep `cargo test` green; the microVM tests stay opt-in.

## Commands

    cargo build                              build the crate and the `reve` binary
    cargo test                               run the unit test suite
    cargo test --test microvm -- --ignored   opt-in microVM integration tests
    cargo clippy                             lint
    cargo fmt                                format
