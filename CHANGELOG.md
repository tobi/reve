# Changelog

All notable changes to Reve are documented here. The project follows
[Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

## [0.8.0] - 2026-08-08

### Added

- Mandatory microVM isolation through `microsandbox-rb`, with deny-by-default egress,
  workspace-only bind mounts, host-scoped secret substitution, and visible startup progress.
- Durable named conversations, crash recovery, compaction, queueing, and concurrent lanes.
- Scheduled durable heartbeat lanes with dynamic `workspace/HEARTBEAT.yml` reload.
- Dynamically reloaded workspace context and skills without invalidating stable prompt caches.
- Agent-local provider configuration, live model discovery, `/model` switching, and detailed
  provider diagnostics.
- Template-aware initialization and upgrades, root `sandbox.rb`, and executable `agent.rb`.

### Security

- Removed every host-shell and local-sandbox fallback. Reve now fails closed if its microVM
  cannot boot, and environment-backed credentials require explicit host-scoped configuration.

[Unreleased]: https://github.com/tobi/reve/compare/v0.8.0...HEAD
[0.8.0]: https://github.com/tobi/reve/releases/tag/v0.8.0
