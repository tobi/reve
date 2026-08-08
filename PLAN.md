# Leve coding agent in pure Ruby, on Ractors

Implementation plan. The durable-harness design it follows is documented by Pi at
[harness-v2.md](https://github.com/earendil-works/pi/blob/main/packages/agent/docs/harness-v2.md);
this document maps it onto Ruby 4 Ractors and records what was built and what was
deliberately left out.

Leve is a rewrite of the earlier reve project as a fresh 0.1.0.

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
| queues + writes | a `Queue` inside the lane Ractor, fed by its control thread, drained at checkpoints — durable first via `queue_enqueued` records |
| abort signal | `AbortFlag` (a mutex-free boolean + generation) inside the lane Ractor |
| hooks (awaited) | RPC from lane → host Port; host runs handlers in registration order, replies JSON |
| events (passive) | fire-and-forget JSON to the observer hub |
| `watch()` snapshot + gapless stream | the hub is single-threaded: it mirrors lane state from the event stream, so "capture snapshot + register port" is one atomic hub operation. The Port itself is the buffer; `start` is the consumer's first `receive` |
| tools | one Ractor per call: args JSON in, result JSON out, no shared state |
| telemetry | `leve.*`-shaped span events on a separate hub topic |

Things a Ractor forces us to do differently, all improvements:

* No `require` inside a Ractor: all code loads before any Ractor spawns. Configuration
  travels as JSON, never as live objects — which is what the document's "live objects are
  referenced by name, never embedded" rule asks for anyway.
* Tool implementations cannot be passed as closures into a lane. They are registered by
  name in a table that every Ractor loads at boot. This is exactly harness-v2 §8: "tool
  implementations are code and cannot persist; the active set (names) persists per lane."

## 2. Deliverables

What actually exists in `lib/leve/` today:

```
lib/leve/
  version.rb            Leve::VERSION (0.1.0)
  ipc.rb                Port helpers, JSON codec, request/reply, ractor-local reply ports
  ids.rb                entry/record/run id allocation
  records.rb            record + entry constructors and the record catalog
  storage/base.rb       in-memory core: entries, records, lanes, facts, one seq
  storage/memory.rb     reference backend
  storage/jsonl.rb      one file per session, one line per mutation, torn-tail truncation
  store.rb              the store Ractor + client proxy (SessionTree/Session API)
  observer.rb           event hub, lane mirrors, snapshots
  context.rb            workspace context assembly (AGENTS/SOUL/KNOWLEDGE)
  agents_md.rb          static AGENTS.md discovery from repo root down, nested on first touch
  frontmatter.rb        SKILL.md frontmatter parsing + validation
  skills.rb             skill discovery, catalog, reload, /skill
  prompt.rb             system prompt + skills XML section assembly
  compaction.rb         cut point, structured summary, previous-summary updates
  lane.rb               run, compaction, checkpoints, recovery, steering, follow-ups
  harness.rb            create/restore, lane management, global config
  agent_loop.rb         streamAssistant / prepare|execute|finalize tool call / batch
  tools.rb              tool registry + batch driver
  tool_dsl.rb           the `tool … do … end` DSL, JSON schema generation
  project.rb            agent-directory bootstrap, `leve init`, launcher guard
  heartbeat.rb          durable scheduled lanes, HEARTBEAT.yml reload
  provider.rb           provider dispatch + compat
  provider/http.rb      shared HTTP client
  provider/messages.rb  message-shape normalization
  provider/usage.rb     token usage / cache accounting
  provider/thinking.rb  reasoning-effort handling
  provider/anthropic.rb anthropic-messages provider
  provider/openai_responses.rb openai-responses provider
  provider/fake.rb      scripted fake provider for deterministic tests
  provider/models.rb    models.yml loading, /model, live discovery
  sandbox.rb            sandbox policy DSL, provisioning, the Client
  sandbox/native.rb     loads ext/leve_sandbox, fails closed with an instruction
  sandbox/host_auth.rb  explicit env-var credential reading, host-scoped secret entries
  channels.rb           channel loading + slash-command registration
  term.rb               cbreak mode, line editor, screen primitive, right-aligned outcomes
  tui.rb                streaming renderer + slash commands (Leve::InteractiveAgentTUI)
ext/leve_sandbox/       the native extension: magnus + rb-sys binding the microsandbox
                       Rust crate (pinned =0.6.8). Defines Leve::Sandbox::Native and Vm.
bin/leve               CLI entry (in the cutover tree)
test/                  parity + crash-site tests
```

## 3. Implementation sequence (what shipped)

1. **IPC + storage + store Ractor.** Entries, records, lanes, facts, one `seq`. JSONL
   round-trip, torn tail. Parity test: memory vs jsonl.
2. **Records and the durability rule.** Provisioned ids, `append_if_missing`.
3. **Agent loop blocks + providers.** `stream_assistant`, tool phases, anthropic SSE, the
   fake scripted provider, and the openai-responses provider with per-provider quirks read
   from the `compat` block of models.yml.
4. **Lane Ractor: the run procedure.** operation_started → task_attempt → assistant entry →
   tool_started → result entry → operation_finished. Checkpoints, steering, follow-ups,
   retry cap.
5. **Recovery.** The reduction from two bounded reads; `resume()` re-entering at the right
   point; crash-site tests driven by killing the process at each trace line.
6. **Abort + reconciliation.** Synthetic results, closing message, queue payload return.
7. **Observer + snapshots + events.** Then the TUI on top of `watch()`.
8. **Tools.** bash/read/write/edit/ls/grep/glob, replay safety declared per tool
   (`read`/`ls`/`grep` = safe, `bash`/`write`/`edit` = never).
9. **Compaction** (auto at checkpoint + manual operation) with branch summary.
10. **Project context.** AGENTS.md (static, from the repo root down; nested, on first
    touch, appended to the tool result that touched it).
11. **Skills.** SKILL.md discovery in `workspace/skills`; frontmatter validation with
    diagnostics (name shape, description length, collisions); the Agent Skills XML section
    in the system prompt; `/skill` to run one now.
12. **Real compaction.** Cut point over `keepRecentTokens`, kept suffix named by
    `firstKeptEntryId`, structured summary format, previous-summary updates, split turns,
    mechanically extracted file lists.
13. **Heartbeats.** Durable scheduled lanes with dynamic `workspace/HEARTBEAT.yml` reload,
    `vm-exec` prerequisites, and `SILENCE`/`Message`/`Steer` contracts.
14. **The agent directory.** `instructions.md`, `agent.rb`, `tools/*.rb`,
    `workspace/skills/`, `sandbox.rb`, `workspace/`, and `.leve/sessions/` for the durable
    logs. `leve init` scaffolds all of it, and leve refuses to launch outside such a
    directory (`--plain` overrides).
15. **Typed tools.** A tool's parameters are described by DSL helpers (`string`,
    `boolean`, …) that generate the JSON schema the model sees. `tools/*.rb` declares tools
    with the `tool … do … end` DSL; a block may declare `replay :safe`/`:never`.
16. **The native sandbox extension.** `ext/leve_sandbox` binds the `microsandbox` Rust
    crate directly (magnus + rb-sys, pinned `=0.6.8`). The Ruby layer is tested against a
    fake through the injectable `native:` seam; real-microVM tests are opt-in.
17. **A terminal the renderer can print into.** Own the input line instead of handing it to
    a readline library: cbreak mode, a small line editor, one screen primitive that hides
    the input line, prints, and redraws it. Tool outcomes render right-aligned.

## 3a. The agent directory

An agent is a directory, and the files in it are its definition: `instructions.md` (the
authority in the system prompt), `agent.rb` (config), `tools/*.rb` (Ruby DSL),
`workspace/skills/`, `sandbox.rb`, `workspace/` (the work), and `.leve/sessions/` for the
durable logs. `leve init` scaffolds all of it, and leve refuses to launch outside such a
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

## 3b. Sandbox policy

The mandatory sandbox is a provisioned debian microVM, reached through the in-repo
`ext/leve_sandbox` native extension that binds the `microsandbox` Rust crate (pinned
`=0.6.8`) directly (git, ripgrep, fd, jq, build-essential, mise with node). There is no
local, CLI, Fiddle, or host-shell fallback. Egress is **deny-by-default**: the policy is
built inside the extension from `NetworkPolicy::none()` plus one narrow gateway-DNS rule
plus one allow rule per host named by `allow`. Package mirrors are allowed only while
provisioning is enabled, so an agent that bakes its own image gets the github-only policy
and nothing more. Verified live: `github.com` reachable, an unlisted host blocked.

The `sandbox.rb` DSL is unchanged from its predecessor except that `allow_all` and
`backend` are gone — a sandbox that can reach everything is not a sandbox, and there is
exactly one backend. Secrets are scoped with `allow HOSTS do secret "VAR", value: ...,
placeholder: ... end`; the guest sees only the placeholder, and the real value is injected
into requests to those hosts at the network boundary.

GitHub access may use an explicitly exported host credential without copying it into the
VM: microsandbox's secret proxy substitutes the value into requests to allowed hosts, and
the guest only ever holds a placeholder. Leve reads `$GITHUB_TOKEN` or `$GH_TOKEN`; it does
not execute `gh auth token` or consult host credential helpers.

## 4. Scope cuts (explicit)

* No v3 JSONL compatibility: this is a new agent, there is nothing to be compatible with.
  Our own format is the v4 shape.
* No SQLite backend. Memory + JSONL only; the branch cache design is not needed until there
  is a database.
* Forks/subagents: the storage-level copy primitive is in scope, a subagent tool is not.
* **DROPPED — RBS-typed tool signatures and `rbs_schema.rb`.** Tools declare parameters
  with DSL helpers that generate the JSON schema directly; there is no RBS signature file.
* **DROPPED — conversation navigation** (`navigate`, `/tree`, `/back`). Compaction and
  `/new` remain; branch browsing does not.
* **DROPPED — session goal** (`/goal`, `set_goal`/`get_goal`). There is no goal custom entry
  injected into the system prompt.
* **DROPPED — deferred/parked provider requests.** There is no park/redeem path and no
  batch-API provider; the queue is a normal in-lane `Queue`.
* **DROPPED — the `openai-chat` provider.** Only three providers exist: `openai-responses`,
  `anthropic-messages`, and the scripted `fake`.
* Telemetry: span events on the hub, no exporters.
* Subagents remain out of scope. Channels are trusted file-drop adapters with commands,
  namespaced KV state, prompt guidance, and observer subscriptions; schedules are durable
  heartbeat lanes.
* The normal suite tests the Ruby sandbox layer against a Ruby fake via the injectable
  `native:` seam; real microVM coverage is an opt-in integration concern. There is only one
  transport, `ext/leve_sandbox`.

## 5. Invariants we test

* One writer: any append from outside the store Ractor is impossible by construction.
* Intent before effect: for every `tool_started` there is either a result entry with the
  provisioned id, or recovery produces one.
* Append-only context: mid-step writes never land before the in-flight assistant entry.
* At most one open operation per lane; a second `prompt` is rejected with `busy`.
* Deleting every record leaves a valid conversation tree.
* Re-running recovery is idempotent.
