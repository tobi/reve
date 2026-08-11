# Contributing to Reve

Thanks for helping improve Reve.

## Development setup

Reve requires Rust 1.91 or newer, on Linux with KVM or macOS on Apple Silicon (the
microsandbox runtime needs one or the other).

```bash
git clone https://github.com/tobi/reve.git
cd reve
cargo build
cargo test
```

The unit test suite (46 tests) must not make model requests, provision a VM, or depend on a
developer's global configuration. The real-microVM tests are opt-in and `#[ignore]`d by
default:

```bash
cargo test --test microvm -- --ignored
```

Before opening a pull request, run:

```bash
cargo build
cargo test
cargo test --test microvm -- --ignored   # if your change touches the sandbox
cargo clippy
cargo fmt
git diff --check
```

## Design constraints

Please read `AGENTS.md` and `PLAN.md` before changing architecture. In particular:

- Reve has no host-shell, local-sandbox, CLI, or FFI fallback. If the microVM cannot boot,
  startup fails closed.
- There is exactly one sandbox transport, the `microsandbox` Rust crate (pinned `=0.6.8` in
  `Cargo.toml`). Do not add a second transport or a host-shell path — not even for tests,
  diagnostics, or convenience.
- No host command path is exposed to Lua. A tool's body runs on the host, but `ctx.sh` is
  its only command path and it goes to the microVM. Do not add a `ctx.host_exec` or
  equivalent.
- `Storage` is single-owner by construction: it is not thread-safe and must not be shared
  behind a mutex. Serialize access through the owning task.
- Record an effect's intent and result identifiers before performing the effect; ids are
  provisioned before the effect they name.
- Never silently overwrite files a user has edited in an agent directory. `reve init` is
  idempotent and keeps edited files.
- Add a focused test for every behavior change. Keep `cargo test` green.

## Pull requests

Keep changes focused and explain their durability and sandbox implications. Include the
commands used to verify the change. Do not include API keys, durable session files, VM
images, or user workspace contents.

By participating, you agree to follow the project's `CODE_OF_CONDUCT.md`.
