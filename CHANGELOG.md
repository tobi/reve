# Changelog

All notable changes to Leve are documented here. The project follows
[Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [0.1.0]

Leve is now a Rust crate with Lua for scripting, superseding an earlier Ruby prototype as a
fresh 0.1.0. The core is Rust (edition 2024); everything an agent author writes —
configuration, project tools, sandbox policy — is Lua that vendors into the binary and
starts in microseconds. Concurrency is tokio tasks over single-owner session state.

### Added

- Direct dependency on the [`microsandbox`](https://github.com/superradcompany/microsandbox)
  Rust crate (pinned `=0.6.8` in `Cargo.toml`) and `microsandbox-network`. No FFI shim, no
  CLI, no daemon, no host shell: the crate is linked and called directly. Mandatory microVM
  isolation with deny-by-default egress — the policy is built in Rust from
  `NetworkPolicy::none()` plus one narrow gateway-DNS rule plus one allow rule per host
  named by `sandbox.lua` — workspace-only bind mounts, host-scoped secret substitution with
  placeholders, fingerprint-based VM reuse, and cancellation that kills the guest command
  through the exec control channel. Verified live against a real microVM by the opt-in
  `cargo test --test microvm -- --ignored` tests.
- The agent directory: `leve init` scaffolds `agent.lua`, `sandbox.lua`,
  `tools/example.lua`, `instructions.md`, `models.yml`, `workspace/{AGENTS.md,SOUL.md,
  KNOWLEDGE.md,HEARTBEAT.yml,knowledge/,notes/,skills/}`, and `.gitignore`. Idempotent; an
  agent-dir guard refuses to run outside one.
- The Lua scripting surface (`src/lua.rs`): `agent { … }`, `sandbox { … }`, and
  `tool("name", { … })`. Tool `params` become the JSON schema the model sees; `ctx.sh`
  runs in the microVM and is a tool's only command path; `ctx.workdir`, `ctx.shellescape`.
- The CLI (`src/main.rs`): `leve init [dir]`, `leve info`, `leve exec <cmd...>`,
  `leve tool [name] [--args JSON]`, `--version`.
- The durable wire format (`src/records.rs`): JSONL version 4, one line per mutation in
  three shapes — `header`, `record`, `entry`. Entries are the conversation tree; records
  are metadata. Intent-before-effect records with provisioned ids; `Replay::{Safe,Never}`.
- Single-owner session state (`src/storage/`): entries, records, lanes, facts, one
  monotonic `seq`. JSONL append with flush, torn-tail truncation on reopen, and a
  malformed line in the middle refused as corruption.

### Pending

The durable format and sandbox are in place; the engine is not. The agent loop, providers
(openai-responses / anthropic-messages / fake), lanes, the observer hub, hooks, compaction,
recovery/resume, heartbeats, skills, channels, and the TUI are planned but not yet built.

### Security

- No host-shell, local, CLI, or FFI fallback. Leve fails closed if the microVM cannot boot.
  Credentials require explicit host-scoped configuration; the guest sees only a placeholder
  and the real value is injected at the network boundary.

[0.1.0]: https://github.com/tobi/leve/releases/tag/v0.1.0
