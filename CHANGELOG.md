# Changelog

All notable changes to Leve are documented here. The project follows
[Semantic Versioning](https://semver.org/spec/v2.0.0.html).

Leve is a rewrite of the earlier reve project as a fresh 0.1.0.

## [0.1.0]

### Added

- Direct binding to the `microsandbox` Rust crate (pinned `=0.6.8`) through a new in-repo
  native extension, `ext/leve_sandbox` (magnus + rb-sys). The crate is compiled into the
  gem's extension, so there is no Ruby gem dependency for the sandbox. Mandatory microVM
  isolation with deny-by-default egress — the policy is built inside the extension from
  `NetworkPolicy::none()` plus one narrow gateway-DNS rule plus one allow rule per host
  named by `allow` — workspace-only bind mounts, host-scoped secret substitution, and
  visible startup progress. The microsandbox runtime and firmware are fetched once into
  `~/.microsandbox` on first use (`Leve::Sandbox::Native.install`).
- Durable named conversations, crash recovery, compaction, queueing, and concurrent lanes.
- Scheduled durable heartbeat lanes with dynamic `workspace/HEARTBEAT.yml` reload.
- Dynamically reloaded workspace context and skills without invalidating stable prompt caches.
- Agent-local provider configuration, live model discovery, `/model` switching, and detailed
  provider diagnostics. Three providers: `openai-responses`, `anthropic-messages`, and a
  scripted `fake` provider for deterministic tests.
- Template-aware initialization and upgrades, root `sandbox.rb`, and executable `agent.rb`.
- File-drop channel adapters with slash-command registration, namespaced host-side KV
  storage, stable system-message guidance, and ordered observer subscriptions.
- A stdlib-only Telegram rich-message channel example based on `tobi/pi-telegram`, with
  pairing, polling, durable connection state, and a monotonic streaming state machine.

### Security

- No local mode, no CLI transport, no Fiddle path, and no host-shell fallback. Leve fails
  closed if its extension or microVM cannot boot, and environment-backed credentials require
  explicit host-scoped configuration.

[0.1.0]: https://github.com/tobi/leve/releases/tag/v0.1.0
