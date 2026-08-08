# Contributing to Leve

Thanks for helping improve Leve.

## Development setup

Leve requires Ruby 4.0 or newer. Building the sandbox native extension from source also
requires a Rust toolchain (>= 1.91).

```bash
git clone https://github.com/tobi/leve.git
cd leve
bundle install
rake compile          # builds ext/leve_sandbox against the pinned microsandbox crate
bin/test
```

`rake compile` must succeed before `bin/test`, because the suite loads the
`leve_sandbox` extension. The normal test suite uses fake providers and a Ruby fake for the
sandbox `native:` seam. It must not make model requests, provision a VM, or depend on a
developer's global configuration. Real-microVM tests are opt-in.

Before opening a pull request, run:

```bash
rake compile
bin/test
rake lint
git diff --check
```

## Design constraints

Please read `AGENTS.md` and `PLAN.md` before changing architecture. In particular:

- Leve has no host-shell, local-sandbox, CLI, or Fiddle fallback. If the extension or
  microsandbox cannot boot, startup fails closed.
- There is exactly one sandbox transport, the in-repo `ext/leve_sandbox` native extension
  binding the `microsandbox` Rust crate (pinned `=0.6.8`). Do not add a second transport.
  Test the Ruby sandbox layer against a Ruby fake via the injectable `native:` seam.
- Runtime code uses Ruby's standard library; the only native dependency is
  `ext/leve_sandbox`.
- Load dependencies before spawning Ractors; only JSON strings and `Ractor::Port` objects
  cross Ractor boundaries.
- Record an effect's intent and result identifiers before performing the effect.
- Add a focused test for every behavior change. Recovery changes require a crash-site test
  that terminates a real child process.
- Never silently overwrite files a user has edited in an agent directory.

## Pull requests

Keep changes focused and explain their durability and sandbox implications. Include the
commands used to verify the change. Do not include API keys, durable session files, VM
images, generated gems, or user workspace contents.

By participating, you agree to follow the project's `CODE_OF_CONDUCT.md`.
