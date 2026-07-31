# rbagent — a durable coding agent in pure Ruby, on Ractors

An implementation of [pi's harness-v2 design](https://github.com/earendil-works/pi/blob/main/packages/agent/docs/harness-v2.md)
in stdlib-only Ruby 4. No gems. The plan and the mapping from the design to Ractors is in
[PLAN.md](PLAN.md).

```
$ bin/rbagent
rbagent · durable harness on ractors · ruby 4.0.6
model anthropic-gw/claude-opus-5  tools 7  lane main  /help for commands

› math.rb has a bug in add. Fix it and verify.
  → read path=/tmp/rbdemo/math.rb
  ✓ read      1  def add(a,b)=a-b
  → edit path=/tmp/rbdemo/math.rb oldText=def add(a,b)=a-b newText=def add(a,b)=a+b
  ✓ edit edited /tmp/rbdemo/math.rb
  → bash command=ruby -r./math -e 'p add(2,3)==5'
  ✓ bash true
· `a-b` → `a+b`. Verified.
· completed 2494in/94out
```

## Why this is interesting

The design's central claim is **durability**: a prompt is an operation, every effect is
preceded by an intent record naming the ids it will produce, and a crash at *any* point
leaves a state that recovery can either complete or close. Nothing partial is ever
observable.

Its structural precondition is **one writer per session**. In Ruby that is not a
convention you hope holds — a Ractor owns the storage and no other Ractor can reach it.
`test/test_storage.rb` proves the point by writing from a second Ractor: the write still
goes through the one store.

The recovery claims are tested against *real process death*: `test/test_recovery.rb`
forks a child, kills it (scripted crash sites and `SIGKILL`), reopens the JSONL session in
the parent and resumes. Nine crash sites, including a real model-less variant of every
trace in §6 of the design.

## Run it

```bash
bin/rbagent                          # interactive
bin/rbagent -p "fix the failing test"   # one-shot, streams to stdout
bin/rbagent -c                       # continue the newest session for this directory
bin/rbagent -r                       # continue and resume whatever a crash left open
bin/rbagent --list                   # sessions for this directory
bin/test                             # the whole suite (~140 checks)
```

Models come from `~/.pi/agent/models.json` (pi's format) or `~/.config/rbagent/models.json`.
`-m` takes `provider/model-id`, a bare `model-id`, or just a `provider` — the last form asks
the endpoint what it is serving right now (`GET /v1/models`) and falls back to the configured
list when it cannot be reached. The default is `vllm`, i.e. whatever the local inference
server has loaded.

The provider layer speaks `openai-responses` and `anthropic-messages` streaming, plus a
scripted `fake` provider for the tests. Per-provider quirks live in the `compat` block of
models.json (`maxTokensField`, `supportsDeveloperRole`, `supportsReasoningEffort`, …), not
in the code.

Sessions are JSONL, one file per session, one line per mutation:

```jsonl
{"kind":"header","version":4,"id":"fddb…","cwd":"/tmp/rbdemo"}
{"kind":"record","type":"operation_started","lane":"main","intent":{"kind":"run",…}}
{"kind":"entry","lane":"main","type":"message","id":"e_…","message":{"role":"user",…}}
{"kind":"record","type":"task_attempt","task":"step","attempt":1,…}
{"kind":"entry","lane":"main","type":"message","message":{"role":"assistant",…}}
{"kind":"record","type":"tool_started","toolName":"edit","resultEntryId":"e_…","replay":"never"}
{"kind":"entry","lane":"main","type":"message","message":{"role":"toolResult",…}}
{"kind":"record","type":"operation_finished","outcome":"completed"}
```

Delete every `record` line and a complete, valid conversation remains. That is an
invariant, and a test.

## Architecture

```
                    ┌──────────────┐
   stdin/TUI ─────► │ host (main)  │ ──► hooks (closures live only here)
                    └──┬────┬──────┘
          commands     │    │  watch() → snapshot + live events
                 ┌─────▼─┐  │   ┌──────────────┐
                 │ lane  │──┼──►│ observer hub │──► watchers
                 │ main  │  │   └──────┬───────┘
                 └───┬───┘  │          │
                 ┌───▼───┐  │          │
                 │ lane  │  │          │
                 │slack:1│  │          │
                 └───┬───┘  ▼          ▼
                    ┌──────────────────────┐
                    │ store (single writer)│  JSONL / memory
                    └──────────────────────┘
                 ┌────────┐ ┌────────┐
   tool batch ──►│ tool R │ │ tool R │  one Ractor per call, args in / result out
                 └────────┘ └────────┘
```

Everything between Ractors is JSON strings and `Ractor::Port`s — both shareable, so no
deep copies and no isolation errors at runtime.

| file | what it is |
|---|---|
| `lib/durable/ipc.rb` | port-based request/reply, per-thread reply ports, `DEFER` |
| `lib/durable/storage/*` | the four parts of a session, one `seq`; memory + JSONL (torn-tail truncation) |
| `lib/durable/store.rb` | the single-writer Ractor and the `Session`/`SessionTree` client |
| `lib/durable/records.rb` | the §5 record catalog, provisioned entry ids |
| `lib/durable/agent_loop.rb` | `stream_assistant`, tool phases 1/2/3, the batch driver |
| `lib/durable/lane.rb` | lane Ractor: run/compaction/navigation procedures, checkpoints, **the recovery reduction** |
| `lib/durable/harness.rb` | lanes, hooks, config, `watch()` |
| `lib/durable/observer.rb` | event hub, lane mirrors, gapless snapshots |
| `lib/durable/provider/*` | models.json, anthropic SSE, scripted fake |
| `lib/durable/tools.rb` | bash/read/write/edit/ls/glob/grep, each with declared replay safety |
| `lib/durable/prompt.rb` | system prompt (pi-shaped: tools, guidelines, project context, skills, cwd) |
| `lib/durable/agents_md.rb` | AGENTS.md discovery, static and nested-on-demand |
| `lib/durable/skills.rb` | Agent Skills: SKILL.md discovery, validation, prompt section |
| `lib/durable/compaction.rb` | cut point, kept suffix, structured summary, file lists |
| `lib/durable/term.rb` | cbreak mode, a line editor, right-aligned columns |
| `lib/durable/tui.rb` | the terminal client — an ordinary consumer of `watch()` |

## What the harness gives you

* **Lanes.** One session, many parallel positions in the conversation tree. `main` always
  exists; `harness.create_lane("slack:1719…", entry_id)` makes another. Lanes run at the
  same time (real Ractor parallelism), share history, and own their own operation log,
  queues and model.
* **Steering / follow-ups / next-run.** Durable at acceptance (a `queue_enqueued` record),
  applied at the next checkpoint so provider context only ever grows at the tail. Steering
  dies on abort; next-run survives.
* **Deferred writes.** `set_model` and friends mid-step become `write_deferred` records
  and land after the in-flight assistant message — never before it.
* **Abort.** Signals the running tool (its Ractor gets a cancel message and kills its child
  process), durable on return; reconciliation (synthetic tool results, closing message,
  `operation_finished aborted`) finishes in the background, and completes on resume if the
  process dies first.
* **Retries.** The attempt count is a record, so a crash-restart loop cannot reset it.
* **Compaction** automatically at a checkpoint (inside the run's records) or as its own
  operation. It walks back from the newest entry until `keepRecentTokens` is spent, cuts at
  a turn boundary, and writes a compaction entry naming `firstKeptEntryId`: the context
  becomes `[structured summary] + [recent turns, verbatim] + [everything after]`. A turn
  too large to keep whole is split, with its prefix summarized separately. Read and
  modified file lists are extracted mechanically rather than left to the model, and a
  second compaction updates the previous summary instead of starting over.
  **Navigation** moves a lane's leaf atomically with `operation_finished`.
* **Deferred provider requests.** A handle persisted in an assistant message parks the
  lane; a later process redeems it without paying for a new request.
* **AGENTS.md, automatically.** Every AGENTS.md from the repo root down to the working
  directory joins the system prompt as `<project_instructions>`. A nested AGENTS.md deeper
  in the tree is loaded the first time a tool touches a path under it and rides along on
  that tool's result — late context arrives at the tail, never before the assistant message
  that did not see it.
* **Skills.** `SKILL.md` files under `.agents/skills/`, `.pi/skills/`, `.rbagent/skills/`
  and their `~/` counterparts. Names and descriptions go into the system prompt in the
  Agent Skills XML shape so the model can pick one and `read` it; `/skill <name>` loads the
  body into the conversation immediately. Over-long descriptions (>1024 chars), invalid
  names and name collisions are reported at startup, and the skill still loads.
* **A session goal.** `/goal <text>` writes a custom entry on the lane's branch and every
  request on that lane carries it in the system prompt. It is branch state, so it is
  per lane, survives compaction, and is a deferred write when set mid-run.
* **Hooks** (`before_run`, `before_tool`, `after_tool`, `transform_context`,
  `after_response`, `before_compaction`, `before_navigation`, `before_run_end`,
  `before_resume`) intercept; **events** only observe. `before_tool` fails closed.

```ruby
harness, suspended = Durable::Harness.create(storage: "jsonl", path: path, model: "claude-opus-5")
suspended.each { |s| harness.lane(s["lane"]).resume }

harness.on_hook("before_tool") do |ev|
  { "block" => { "reason" => "not in this workspace" } } if ev["toolName"] == "bash"
end

Thread.new { harness.prompt("fix the failing test") }
harness.steer("start with the parser")        # durable when it returns
harness.abort!                                # durable when it returns
```

## Scope

Implemented: memory + JSONL storage, lanes, runs, steps, retries, tools, abort,
compaction, navigation, deferred requests, forks, snapshots/events, hooks, recovery, TUI.
Not implemented (see PLAN.md §4): SQLite backend, v3 session compatibility, subagents,
telemetry exporters.
