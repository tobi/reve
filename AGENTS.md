# reve

A durable coding agent in Ruby on Ractors. The design is
Pi's durable harness (see PLAN.md); PLAN.md maps it onto Ractors and records what is in and
out of scope.

## Rules

- **Sandbox or no Reve.** Microsandbox is provided exclusively by the mandatory
  `microsandbox-rb` gem. Reve must refuse to start if the VM cannot boot. Every shell
  command — model `bash`, project `ctx.sh`, and user `!command` — executes inside that VM.
  Never retain, add, or silently select a host/local shell fallback, even for tests,
  diagnostics, degraded operation, or convenience.
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
  because blocks and live handles cannot cross a Ractor boundary. “Host Ractor” describes
  orchestration only: it does not authorize host effects. Sandboxed built-ins dispatch
  through the VM handle; other built-ins may run in their own Ractor only when they do not
  execute processes.
- Do not maintain a second microsandbox transport. Use the public `microsandbox-rb` API and
  test the adapter against Ruby fakes; real-microVM tests are opt-in integration tests.

## Commands

    bin/test          run every suite, each in its own process
    bin/reve       the agent itself
