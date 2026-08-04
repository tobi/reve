# rbagent

A durable coding agent in pure Ruby (stdlib only, no gems) on Ractors. The design is
omp's durable harness (see PLAN.md); PLAN.md maps it onto Ractors and records what is in and
out of scope.

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
- Project code (`tools/*.rb`, hooks, the sandbox connection) runs in the host Ractor,
  because blocks and live handles cannot cross a Ractor boundary. Built-in tools run in
  their own Ractor.
- FFI means `fiddle`, not the ffi gem. Bind C ABIs through one call helper and test them
  against a stub shared library built at test time.

## Commands

    bin/test          run every suite, each in its own process
    bin/rbagent       the agent itself
