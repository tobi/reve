# rbagent

A durable coding agent in pure Ruby (stdlib only, no gems) on Ractors. The design is
pi's `harness-v2`; PLAN.md maps it onto Ractors and records what is in and out of scope.

## Rules

- Stdlib only. No gems, ever — that constraint is the point of the project.
- Everything loads before any Ractor spawns: a non-main Ractor cannot `require`.
- Constants reachable from a Ractor must be shareable (`Ractor.make_shareable`, or a
  frozen literal). `<<~TXT.strip` is *not* frozen — add `.freeze`.
- No `Dir.chdir` in tools: it is process-global and tool Ractors run in parallel.
- Between Ractors only JSON strings and `Ractor::Port`s travel.
- Durability rule: write the intent record before the effect, name the ids it will
  produce, then append the result with exactly those ids.
- Every new behaviour gets a test in `test/`, and recovery behaviour gets a crash-site
  test that kills a real child process.

## Commands

    bin/test          run every suite, each in its own process
    bin/rbagent       the agent itself
