# leve

A durable coding agent in Ruby on Ractors. The design is
Pi's durable harness (see PLAN.md); PLAN.md maps it onto Ractors and records what is in and
out of scope.

## Rules

- **Sandbox or no Leve.** Microsandbox is provided exclusively by the in-repo
  `ext/leve_sandbox` native extension, which binds the official `microsandbox` Rust crate
  (pinned `=0.6.8`) directly. There is no Ruby gem dependency for the sandbox and exactly
  one transport. Leve must refuse to start if the extension or the microVM cannot boot.
  Every shell command — model `bash`, project `ctx.sh`, and user `!command` — executes
  inside that VM. Never retain, add, or silently select a host/local shell fallback, even
  for tests, diagnostics, degraded operation, or convenience.
- Everything loads before any Ractor spawns: a non-main Ractor cannot `require`.
- Constants reachable from a Ractor must be shareable (`Ractor.make_shareable`, or a
  frozen literal). `<<~TXT.strip` is *not* frozen — add `.freeze`.
- No `Dir.chdir` in tools: it is process-global and tool Ractors run in parallel.
- Between Ractors only JSON strings and `Ractor::Port`s travel.
- Durability rule: write the intent record before the effect, name the ids it will
  produce, then append the result with exactly those ids.
- Every new behaviour gets a test in `test/`, and recovery behaviour gets a crash-site
  test that kills a real child process.
- Project code (`tools/*.rb`, hooks, the sandbox connection) runs in the host Ractor,
  because blocks and live handles cannot cross a Ractor boundary. "Host Ractor" describes
  orchestration only: it does not authorize host effects. Sandboxed built-ins dispatch
  through the VM handle; other built-ins may run in their own Ractor only when they do not
  execute processes.
- There is exactly one sandbox transport, `ext/leve_sandbox`. Test the Ruby sandbox layer
  against a Ruby fake via the injectable `native:` seam; real-microVM tests are opt-in.

## Commands

    bin/test          run every suite, each in its own process
    rake compile      build the ext/leve_sandbox native extension
    bin/leve       the agent itself
