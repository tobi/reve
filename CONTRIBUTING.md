# Contributing to Reve

Thanks for helping improve Reve.

## Development setup

Reve requires Ruby 4.0 or newer.

```bash
git clone https://github.com/tobi/reve.git
cd reve
bundle install
bin/test
```

The normal test suite uses fake providers and fake sandbox adapters. It must not make model
requests, provision a VM, or depend on a developer's global configuration.

Before opening a pull request, run:

```bash
bin/test
rake lint
rake rbs
git diff --check
```

## Design constraints

Please read `AGENTS.md` and `PLAN.md` before changing architecture. In particular:

- Reve has no host-shell or local-sandbox fallback. If microsandbox cannot boot, startup
  fails closed.
- Runtime code uses Ruby's standard library except for the mandatory `microsandbox-rb`
  transport.
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
