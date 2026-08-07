# Reve coding agent in pure Ruby, on Ractors

Implementation plan. The durable-harness design it follows is documented by Pi at
[harness-v2.md](https://github.com/earendil-works/pi/blob/main/packages/agent/docs/harness-v2.md);
this document maps it onto Ruby 4 Ractors and records what we build, in which order, and
what we deliberately leave out.

## 0. Why Ractors

harness-v2's central structural claim is **single writer per session**. In TypeScript that is
an assertion the serving layer must uphold. In Ruby with Ractors it is enforced by the
runtime: the session's mutable state lives inside one Ractor and no other Ractor can reach
it. Every other invariant of the document — lanes owning their own queues, records never
shared across lanes, hooks awaited at interception points, tools as isolated effects —
maps onto "one Ractor, one owner, messages in between".

Ractor topology:

```
                    ┌──────────────┐
   stdin/TUI ─────► │ host (main)  │ ──► hooks, results, lane inventory
                    └──┬────┬──────┘
          commands     │    │  watch()/snapshot
                 ┌─────▼─┐  │   ┌──────────────┐
                 │ lane  │──┼──►│ observer hub │──► watchers (TUI, logs)
                 │ main  │  │   └──────┬───────┘
                 └───┬───┘  │          │ transcript reads
                 ┌───▼───┐  │          │
                 │ lane  │  │          │
                 │ slack:│  │          │
                 └───┬───┘  ▼          ▼
                    ┌──────────────────────┐
                    │  store  (single writer)
                    │  JSONL / memory       │
                    └──────────────────────┘
                 ┌────────┐ ┌────────┐
   tool batch ──►│ tool r │ │ tool r │   one Ractor per tool call
                 └────────┘ └────────┘
```

Wire format between Ractors: **JSON strings** plus `Ractor::Port` objects. Both are
shareable, so nothing is deep-copied by accident and no `IsolationError` can appear at
runtime. Records and entries are JSON on the wire and JSON on disk — one representation.

## 1. Mapping harness-v2 concepts to Ractors

| harness-v2 | Ruby |
|---|---|
| Session (tree, lanes, logs, facts) | `store` Ractor owning `Storage::Jsonl` or `Storage::Memory` |
| single writer | structural: only the store Ractor holds the state |
| shared monotonic `seq` | store-local counter; every write assigns it |
| lane (leaf + op log + queues) | one `lane` Ractor per lane name; leaf persisted in store |
| lanes run in parallel | real parallelism; they meet only on the store's command port |
| `prompt/steer/abort/resume` | commands sent to the lane Ractor; results returned on a reply Port |
| queues + deferred writes | a `Queue` inside the lane Ractor, fed by its control thread, drained at checkpoints — durable first via `queue_enqueued` / `write_deferred` records |
| abort signal | `AbortFlag` (a mutex-free boolean + generation) inside the lane Ractor |
| hooks (awaited) | RPC from lane → host Port; host runs handlers in registration order, replies JSON |
| events (passive) | fire-and-forget JSON to the observer hub |
| `watch()` snapshot + gapless stream | the hub is single-threaded: it mirrors lane state from the event stream, so "capture snapshot + register port" is one atomic hub operation. The Port itself is the buffer; `start` is the consumer's first `receive` |
| tools | one Ractor per call: args JSON in, result JSON out, no shared state |
| telemetry | `reve.*`-shaped span events on a separate hub topic |

Things a Ractor forces us to do differently, all improvements:

* No `require` inside a Ractor: all code loads before any Ractor spawns. Configuration
  travels as JSON, never as live objects — which is what the document's "live objects are
  referenced by name, never embedded" rule asks for anyway.
* Tool implementations cannot be passed as closures into a lane. They are registered by
  name in a table that every Ractor loads at boot. This is exactly harness-v2 §8: "tool
  implementations are code and cannot persist; the active set (names) persists per lane."

## 2. Deliverables

```
lib/reve/
  ipc.rb            Port helpers, JSON codec, request/reply, ractor-local reply ports
  ids.rb            entry/record/run id allocation
  records.rb        record + entry constructors and the record catalog (§5)
  storage/base.rb   in-memory core: entries, records, lanes, facts, one seq
  storage/memory.rb reference backend
  storage/jsonl.rb  one file per session, one line per mutation, torn-tail truncation
  store.rb          the store Ractor + client proxy (SessionTree/Session API, §12)
  observer.rb       event hub, lane mirrors, snapshots (§9, §10)
  hooks.rb          host-side hook registry + lane-side RPC caller (§11)
  agent_loop.rb     streamAssistant / prepare|execute|finalize tool call / batch (§14)
  lane.rb           run, compaction, navigation procedures; checkpoints; recovery (§15, §7)
  harness.rb        create/restore, lane management, global config (§8)
  provider/         models.yml loading, anthropic-messages SSE, fake provider (§16)
  tools/            bash, read, write, edit, ls, grep, glob
  tui.rb            streaming renderer + slash commands
bin/reve         CLI entry
test/               parity + crash-site tests (§20)
```

## 3. Implementation sequence

1. **IPC + storage + store Ractor.** Entries, records, lanes, facts, one `seq`. JSONL
   round-trip, torn tail. Parity test: memory vs jsonl.
2. **Records and the durability rule.** Provisioned ids, `append_if_missing`.
3. **Agent loop blocks + providers.** `stream_assistant`, tool phases, anthropic SSE, fake
   scripted provider for tests.
4. **Lane Ractor: the run procedure.** operation_started → task_attempt → assistant entry →
   tool_started → result entry → operation_finished. Checkpoints, steering, follow-ups,
   deferred writes, retry cap.
5. **Recovery.** The reduction (§7) from two bounded reads; `resume()` re-entering at the
   right point; crash-site tests driven by killing the process at each trace line.
6. **Abort + reconciliation.** Synthetic results, closing message, queue payload return.
7. **Observer + snapshots + events.** Then the TUI on top of `watch()`.
8. **Tools.** bash/read/write/edit/ls/grep/glob, replay safety declared per tool
   (`read`/`ls`/`grep` = safe, `bash`/`write`/`edit` = never).
9. **Compaction** (auto at checkpoint + manual operation) and **navigation** with branch
   summary and atomic leaf move.
10. **Deferred requests.** Park/redeem path, exercised by the fake provider.
11. **Project context.** AGENTS.md (static, from the repo root down; nested, on first
    touch, appended to the tool result that touched it).
12. **Skills.** SKILL.md discovery in `.agents/skills`, `.agent/skills`, `.reve/skills` and
    the `~/` equivalents; frontmatter validation with diagnostics (name shape, description
    length, collisions); the Agent Skills XML section in the system prompt; `/skill` to run
    one now.
13. **Real compaction.** Cut point over `keepRecentTokens`, kept suffix named by
    `firstKeptEntryId`, structured summary format, previous-summary updates, split turns,
    mechanically extracted file lists.
14. **Session goal.** A `goal` custom entry on the branch, injected into the system prompt
    of every request on that lane.
15. **openai-responses.** A second provider (the local vLLM endpoint is the default), with
    per-provider quirks read from the `compat` block of models.yml.
16. **Shell passthrough and completion.** `!command` as a first-class durable fact, and
    context-aware tab completion driven by the same command table the dispatcher uses.
17. **A terminal the renderer can print into.** Own the input line instead of handing it to
    a readline library: cbreak mode, a small line editor, one screen primitive that hides
    the input line, prints, and redraws it. Tool outcomes render right-aligned.

## 3a. The agent directory (eve's model)

An agent is a directory, and the files in it are its definition: `instructions.md` (the
authority in the system prompt), `agent.rb` (config), `tools/*.rb` (Ruby DSL), `skills/`,
`sandbox/sandbox.rb`, `workspace/` (the work), and `.reve/sessions/` for the durable
logs. `reve init` scaffolds all of it, and reve refuses to launch outside such a
directory (`--plain` overrides).

`workspace/` is the working directory for every tool and is mounted at `/workspace` in the
sandbox, so relative paths mean the same thing on both sides and the agent's own files are
not in the material it edits.

Two Ractor consequences shape the implementation:

* A project tool's body is a Ruby block, so it cannot travel into a tool Ractor. Project
  tools run in the host Ractor and lanes call them over the same RPC channel as hooks. The
  declaration carries `runner: "host"`, and the batch driver dispatches accordingly. Records,
  replay safety and recovery are unchanged.
* The sandbox holds a live connection (a microVM handle), so it lives in the host Ractor too,
  and sandboxed tools are host-run by construction.

## 3a2. Typed tools

A tool's parameters are a type signature. RBS comments above the `run` block
(`#: (city: String, ?units: ("metric" | "imperial")) -> String`) are read from the source
via `Proc#source_location`, parsed by RBS when it is available and by a small fallback
parser when it is not, and turned into the JSON schema the model sees — literal unions
become enums, `@param` lines become descriptions, `Proc#parameters` decides requiredness.
Typed blocks are invoked with keywords; the older `|args, ctx|` form still works.

`sig/reve.rbs` covers the library's public surface and `rake rbs` resolves it.

## 3b. Sandbox policy

The mandatory sandbox is a provisioned debian microVM, embedded through the
`microsandbox-rb` Rust extension (git, ripgrep, fd, jq, build-essential, mise with node).
There is no local, CLI, or Fiddle fallback. Egress is **deny-by-default with github.com the
only allowed destination**. Package mirrors are allowed only while provisioning is enabled,
so an agent that bakes its own image gets the github-only policy and nothing more.

GitHub access uses the host's own credential without copying it into the VM:
microsandbox's secret proxy substitutes the value into requests to the allowed hosts, and
the guest only ever holds a placeholder. Discovery order is `$GITHUB_TOKEN`/`$GH_TOKEN`,
`gh auth token`, then the git credential helper.

## 4. Scope cuts (explicit)

* No v3 JSONL compatibility: this is a new agent, there is nothing to be compatible with.
  Our own format is the v4 shape from §13.
* No SQLite backend. Memory + JSONL only; the branch cache design of §13 is not needed
  until there is a database.
* Forks/subagents (§17): the storage-level copy primitive is in scope, a subagent tool is not.
* Deferred requests exist as a code path and are tested against the fake provider; no real
  batch-API provider.
* Telemetry: span events on the hub, no exporters.
* Channels, connections, subagents and schedules from eve's model are out of scope for now;
  the directory layout leaves room for them.
* The normal suite mocks the `microsandbox-rb` public API; real microVM coverage is an
  opt-in integration concern. There is only one production adapter.

## 5. Invariants we test

* One writer: any append from outside the store Ractor is impossible by construction.
* Intent before effect: for every `tool_started` there is either a result entry with the
  provisioned id, or recovery produces one.
* Append-only context: mid-step writes never land before the in-flight assistant entry.
* At most one open operation per lane; a second `prompt` is rejected with `busy`.
* Deleting every record leaves a valid conversation tree.
* Re-running recovery is idempotent.
