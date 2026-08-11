# reve

A durable coding agent. The core is a Rust crate; the scripting surface an agent author
touches — configuration, project tools, sandbox policy — is Lua. The durable-harness
design it follows is documented in `PLAN.md`, which maps it onto Rust modules and records
what is built and what is pending.

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
- **Intent before effect.** Write the intent record before the effect, name the ids it
  will produce, then append the result with exactly those ids. Ids are provisioned before
  the effect they name. `append_entry_if_missing` makes a provisioned id idempotent, so
  recovery re-runs freely.
- **Single-owner session state.** `Storage` is deliberately not thread-safe and not shared.
  Exactly one task owns it, which is how reve gets the single-writer guarantee
  structurally instead of by convention. Do not wrap it in an `Arc<Mutex>` to "share" it —
  serialize access through the owning task.
- **One JSONL session, one writer, flush every append.** A crash can only tear the last
  line; on reopen we truncate the torn tail and resume. A malformed line in the middle is
  corruption and we refuse to open. An agent that reports work it did not persist is worse
  than one that is slow.
- **Lua is trusted launch code.** `agent.lua`, `sandbox.lua`, and `tools/*.lua` run on the
  host before any work starts, exactly like the Rust they extend. They are not model
  output and they are not sandboxed — they are configuration. What they must never do is
  execute a command on the host: `ctx.sh` goes to the microVM, and it is the only way out
  of a tool.
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
