# Changelog

All notable changes to Reve are documented here. The project follows
[Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [0.1.0]

Reve is now a Rust crate with Lua for scripting, superseding an earlier Ruby prototype as a
fresh 0.1.0. The core is Rust (edition 2024); everything an agent author writes —
configuration, project tools, sandbox policy — is Lua that vendors into the binary and
starts in microseconds. Concurrency is tokio tasks over single-owner session state.

### Added

- Direct dependency on the [`microsandbox`](https://github.com/superradcompany/microsandbox)
  Rust crate (pinned `=0.6.8` in `Cargo.toml`) and `microsandbox-network`. No FFI shim, no
  CLI, no daemon, no host shell: the crate is linked and called directly. Mandatory microVM
  isolation with deny-by-default egress — the policy is built in Rust from
  `NetworkPolicy::none()` plus one narrow gateway-DNS rule plus one allow rule per host
  named by `sandbox.lua` — workspace-only bind mounts, source-backed host-scoped secret
  substitution with placeholders, fingerprint-based VM reuse, runtime env/secret refresh
  without disk rebuild, fail-closed boot verification, effect-driven restart, 30-second
  idle shutdown, and cancellation that kills the guest command through the exec control
  channel. Verified live against a real microVM by the opt-in
  `cargo test --test microvm -- --ignored` tests.
- The agent directory: `reve init` scaffolds `agent.lua`, `sandbox.lua`,
  `tools/example.lua`, `instructions.md`, `models.yml`, `workspace/{AGENTS.md,SOUL.md,
  KNOWLEDGE.md,HEARTBEAT.yml,knowledge/,notes/,skills/}`, and `.gitignore`. Idempotent; an
  agent-dir guard refuses to run outside one.
- The Lua scripting surface (`src/lua.rs`): `agent { … }`, `sandbox { … }`, and
  `tool("name", { … })`. Tool `params` become the JSON schema the model sees; `ctx.sh`
  runs in the microVM and is a tool's only command path; `ctx.workdir`, `ctx.shellescape`.
- The CLI (`src/main.rs`): `reve init [dir]`, `reve info`, `reve exec <cmd...>`,
  `reve tool [name] [--args JSON]`, `--version`.
- Pi-compatible `read` offsets and limits, plus bounded model context for long tool output;
  complete results spill to a model-readable guest `/tmp` path.
- The durable wire format (`src/records.rs`): JSONL version 4, one line per mutation in
  three shapes — `header`, `record`, `entry`. Entries are the conversation tree; records
  are metadata. Intent-before-effect records with provisioned ids; `Replay::{Safe,Never}`.
- Single-owner session state (`src/storage/`): entries, records, lanes, facts, one
  monotonic `seq`. JSONL append with flush, torn-tail truncation on reopen, and a
  malformed line in the middle refused as corruption.
- The inline ratatui terminal, including durable turns, streaming Markdown, slash commands,
  and workspace-relative `@file` completion with live post-run refresh.
- OpenAI Chat Completions transport with streaming text and tool-call assembly, usage
  accounting, configurable developer/system roles and token-cap fields, and durable tool
  continuation repair.

### Fixed

- Serialized microVM stop and restart transitions so concurrent tools and the first effect
  after idle shutdown reuse one sandbox without racing its persisted runtime.

### Pending

The remaining engine-level limitation is provider tool continuation from the standalone
CLI tool command; normal TUI turns run the durable lane.

### Security

- No host-shell, local, CLI, or FFI fallback. Reve fails closed if the microVM cannot boot.
  Credentials require explicit host-scoped configuration; the guest sees only a placeholder
  and the real value is injected at the network boundary.

[0.1.0]: https://github.com/tobi/reve/releases/tag/v0.1.0
