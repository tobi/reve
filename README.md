# Reve

[![CI](https://github.com/tobi/reve/actions/workflows/ci.yml/badge.svg)](https://github.com/tobi/reve/actions/workflows/ci.yml)
[![MIT License](https://img.shields.io/badge/license-MIT-blue.svg)](LICENSE)

Reve is a Ruby environment for building durable coding agents. Its central idea is:

> **The directory is the agent.**

An agent is not a profile hidden in a home directory or state scattered across services.
It is one portable directory containing identity, model configuration, tools, mutable
memory, skills, sandbox policy, and durable history. Copy the directory and you copy the
agent.

## Philosophy

Reve combines three ideas:

1. **Ruby is the agent language.** An agent's configuration and project tools are ordinary,
   readable Ruby. Ractors isolate concurrent lanes, while a small channel boundary keeps
   the durable core independent from the terminal UI.
2. **The environment is a real sandbox.** Every model-authored command, context command,
   and interactive `!command` runs in a full microVM—never in a host-shell fallback. Reve
   uses the community Ruby port [`microsandbox-rb`](https://github.com/ya-luotao/microsandbox-rb),
   built on [microsandbox](https://github.com/superradcompany/microsandbox). The host only
   orchestrates; the agent works inside its mounted `workspace/` with deny-by-default
   networking and explicitly scoped secrets.
3. **State is durable data, not process memory.** Reve's append-only conversation tree and
   intent-before-effect records are based on the durable harness work in
   [Pi](https://github.com/badlogic/pi-mono). A crash can leave an incomplete operation,
   but not an ambiguous one: recovery has the identifiers and intent needed to reconcile
   it safely.

The result is an agent you can inspect with normal filesystem and Ruby tools, constrain as
an operating environment, stop at any moment, and resume without pretending the
interruption never happened.

There is no machine-wide Reve profile, home-directory prompt, global model file, or session
store outside the agent directory.

## Ractors are the runtime architecture

Ractors are not a decorative implementation detail. The main Ractor owns trusted Ruby
configuration, channel adapters, hooks, project-tool blocks, and the live microVM handle.
Around it Reve creates:

- **One store Ractor**, the only object allowed to mutate a session.
- **One observer Ractor**, which atomically snapshots and subscribes channels to ordered
  events.
- **One Ractor per lane**, so main, heartbeat, and maintenance work can progress
  independently while each lane serializes its own durable operation.
- **Temporary tool Ractors** for shareable built-ins, providing real parallel batches and
  message-based cancellation.

Application payloads cross those boundaries as JSON through `Ractor::Port` RPC. The split
is deliberate: microVMs isolate effects, append-only records isolate crashes, and Ractors
isolate ownership and concurrent work.

## Install and create an agent

Requirements:

- Ruby 4.0 or newer.
- Linux with KVM, or macOS on Apple Silicon, as required by `microsandbox-rb`.
- Network access on first use to install the embedded microsandbox runtime and pull the VM
  image. A source-gem install may additionally require Rust 1.91 or newer when no
  precompiled native gem exists for the platform.

```bash
gem install reve-agent  # installs the `reve` executable
mkdir my-agent && cd my-agent
reve init
export OPENAI_API_KEY=...
./agent.rb
```

The RubyGems package is named `reve-agent` because the `reve` package name belongs to an
unrelated project. It installs the `reve` executable and `Reve` Ruby namespace.

The first launch builds and provisions the microVM and shows live startup progress. Later
launches restart its persisted root disk.

## Agent directory

```text
reve/                         the agent root
├── instructions.md            identity, purpose, and standing instructions
├── models.yml                 provider and model configuration owned by this agent
├── agent.rb                   executable configuration DSL (`./agent.rb` launches Reve)
├── channels/
│   └── tui.rb                 default inline terminal adapter; add more files here
├── tools/
│   └── example.rb             optional project tools written in Ruby
├── sandbox.rb                 optional sandbox policy
├── workspace/                 the VM-visible, agent-editable mind and worktree
│   ├── AGENTS.md              abbreviated stateful-agent kernel
│   ├── SOUL.md                identity, voice, boundaries, and timezone
│   ├── KNOWLEDGE.md           index into knowledge/
│   ├── DREAM.md               memory-consolidation protocol
│   ├── HEARTBEAT.yml          dynamically reloaded background task schedule
│   ├── knowledge/             mutable durable facts
│   ├── notes/                 append-only daily narrative
│   └── skills/                all skills, including heartbeat authoring guidance
└── .reve/
    ├── sessions/              JSONL durable session logs
    └── logs/                  oversized tool output
```

Create the complete structure in the current directory and launch it:

```bash
reve init .
./agent.rb
```

When working from a source checkout instead, use `bundle install` and
`bundle exec bin/reve`.

`reve init` is idempotent. It never writes to `$HOME`, a global cache, or another
project. `models.yml` is copied into the new root and becomes the only model configuration
that this agent reads. The generated `channels/tui.rb` is intentionally small enough to
serve as a channel implementation example.

The launcher refuses to run in a directory that is not an agent. This prevents an agent
from silently attaching itself to an arbitrary checkout. The only durable paths are under
the agent root, and `--session` is rejected when it points outside `.reve/sessions`.
Launching `reve` reopens the named `main` conversation by default (adopting the newest
legacy session on first use). `reve -c research` opens another persistent named
conversation. Use `/new` to rotate the selected conversation to a fresh durable session
without rebooting the microVM.

## Examples

### Define an agent in Ruby

`agent.rb` selects the model and thinking level; `instructions.md` holds the prose identity:

```ruby
#!/usr/bin/env reve

agent do
  model "openai/gpt-5.6-luna"
  thinking :low
end
```

The launcher is executable, so the directory itself feels like an application:

```bash
./agent.rb -c refactor
```

### Add a complex tool by dropping in one Ruby file

Every `tools/*.rb` file is trusted launch code and is loaded before Ractors spawn. There is
no plugin manifest, package step, or central registry to edit. For example,
`tools/release_report.rb` can combine validation, sandbox commands, and structured input:

```ruby
require "shellwords"

tool "release_report" do
  description "Run release checks and summarize commits since a Git reference"
  string :since, "Starting Git reference", required: true
  boolean :include_tests, "Run the test suite", default: true
  replay :safe

  run do |args, ctx|
    log = ctx.sh("git log --format='%h %s' #{Shellwords.escape(args["since"])}..HEAD")
    checks = args.fetch("include_tests", true) ? ctx.sh("bin/test") : "tests skipped"
    <<~REPORT
      Commits:
      #{log}

      Verification:
      #{checks}
    REPORT
  end
end
```

Restart Reve and the model immediately sees the generated JSON schema for
`release_report`. The Ruby block remains in the trusted host Ractor, while every `ctx.sh`
command still runs in the mandatory microVM. A file can define multiple tools and use any
Ruby standard-library logic needed to implement a complex integration.

### Give the VM narrowly scoped GitHub access

`sandbox.rb` is ordinary Ruby. This policy allows GitHub egress and lends a token only to
those hosts. The VM sees `reve-github-token`; microsandbox substitutes the real value at
the network boundary:

```ruby
sandbox do
  image "debian:trixie-slim"
  cpus 2
  memory 2048

  allow "github.com", "api.github.com" do
    secret "GITHUB_TOKEN",
           value: ENV.fetch("GITHUB_TOKEN"),
           placeholder: "reve-github-token"
  end
end
```

There is no `host-exec`, and omitting the token does not create an invisible host fallback.
`gh auth login` may keep its token only in the operating-system keyring; export it before
launching Reve when needed:

```bash
export GITHUB_TOKEN="$(gh auth token --hostname github.com)"
./agent.rb
```

Reve itself never executes that host command.

### Stop and resume durable work

```text
$ ./agent.rb -c migration
› update the storage format and run the recovery suite
^C
  aborting — ctrl-c again to quit

$ ./agent.rb -c migration
  conversation migration · recovered interrupted operation
› /resume
```

Tool intent, result IDs, queue state, and the conversation branch are persisted under
`.reve/sessions/`; recovery does not depend on the original Ruby process surviving.

### Schedule background maintenance

`workspace/HEARTBEAT.yml` creates durable background lanes while the main conversation is
open:

```yaml
tasks:
  - name: maintain
    every: 30m
    lane: maintenance
    continue: true
    model: openai/gpt-5.6-luna
    vm-exec: git status --short
    prompt: Review the workspace and perform one safe maintenance improvement.
    delivery: main
```

A heartbeat returns `SILENCE`, `Message: ...`, or `Steer: ...`; its intent, completion,
delivery, skips, and errors are recorded like foreground work.

### Add a reloadable skill

Create `workspace/skills/review/SKILL.md`:

```markdown
---
name: review
description: Review a change for correctness, durability, and sandbox escapes.
---

Read the diff, run focused tests, and report findings before proposing edits.
```

Reve fingerprints the complete skill directory and exposes changes at the next turn
boundary without rewriting the stable system prompt.

## Channels are file-drop adapters

Reve ships an inline terminal channel, but the observer boundary makes new channels
trivial to add. Every `channels/*.rb` file loads before Ractors spawn. A channel may:

- Subscribe to atomic snapshots plus ordered live events.
- Submit or steer durable lane work.
- Register new `/commands` with JSON-object arguments.
- Persist host-side credentials and cursors in a namespaced `.reve/channels.json` KV store.
- Append stable channel-style guidance to the system message.

The default TUI does not use an alternate screen buffer. Output stays in normal terminal
scrollback, while one owned input line is hidden, printed above, and redrawn after every
event. This keeps command history, copy/paste, and terminal scrollback useful.

The library renderer is `Reve::InteractiveAgentTUI`. The generated `channels/tui.rb` is a
visitor adapter, not a second renderer:

```ruby
module Reve
  module Channels
    class TUI
      def initialize(harness, suspended, lane: "main")
        @renderer = Reve::InteractiveAgentTUI.new(harness, suspended, lane: lane)
      end

      def visit(event) = @renderer.render(event)
      def run = @renderer.run
      def submit(text) = @renderer.submit(text)
    end
  end
end
```

That is the default channel boundary. It delegates to high-level harness operations and
visits observer events. Other adapters compose with it without changing storage, lanes,
providers, or tools.

### Telegram channel example

`examples/telegram.rb` is a complete stdlib-only adapter based on
[`tobi/pi-telegram`](https://github.com/tobi/pi-telegram). Install it with one file copy:

From a source checkout:

```bash
cp examples/telegram.rb /path/to/my-agent/channels/telegram.rb
```

From the installed gem:

```bash
GEM_DIR="$(ruby -e 'print Gem::Specification.find_by_name("reve-agent").gem_dir')"
cp "$GEM_DIR/examples/telegram.rb" /path/to/my-agent/channels/telegram.rb
cd /path/to/my-agent
./agent.rb
```

Then connect using a BotFather token:

```text
/telegram-connect {"botToken":"123456:token"}
```

The command validates the token and stores it in the channel KV file with mode `0600`.
Later sessions reconnect without resending it:

```text
/telegram-connect {}
/telegram-status
/telegram-disconnect
```

The sender of the first private Telegram message becomes the permanently paired user and
chat. Every later inbound message must match both identities, and every outbound API call
independently refuses any other chat. A first `/start` pairs without creating a model turn.
Every inbound prompt is durably submitted as `[channel=telegram] …`. The channel's system-message
injection tells the agent to treat that prefix as transport metadata and to write concise
Telegram Rich Markdown.

Streaming output uses an explicit monotonic state machine:

```text
thinking  →  tools  →  answering  →  done
```

It opens a private `Working…` rich draft, adds live tool summaries, streams answer text,
and persists the final rich message. Late events cannot move the renderer backward. The
bot token, pairing ID, and update cursor remain host-side in `.reve/channels.json`; they
never enter `workspace/` or the microVM.

The host Ractor owns the terminal entry box and renderer. Lane Ractors own durable work.
Input is translated into lane messages; rendering consumes the observer stream:

```mermaid
flowchart LR
  U[stdin / inline entry box] --> H[host Ractor]
  H --> C[channels/tui.rb visitor]
  C --> R[InteractiveAgentTUI renderer]
  H -->|prompt| L[main lane Ractor]
  H -->|/steer / /followup / /abort / /resume| L
  L -->|JSON events| O[observer hub Ractor]
  O --> C
  L --> S[store Ractor]
  S --> J[(agent/.reve/sessions/*.jsonl)]
```

Useful commands include:

```text
/help                 command reference
/steer <text>         queue guidance at the next checkpoint
/next <text>          queue text for the next run
/followup <text>      add a follow-up while work is active
/abort                abort and durably reconcile the current operation
/resume               resume a suspended operation
/compact [instr]      compact the current branch, optionally with summary instructions
/new                  create and switch to a fresh durable session
/model [spec]         inspect or select the local models.yml model
/lanes                inspect lane state
```

## Background heartbeats

`workspace/HEARTBEAT.yml` declares periodic tasks that run in unattached durable lanes
while the `main` conversation is open. Reve fingerprints and reloads the file every
scheduler scan. Each task selects a model and lane, chooses whether to continue that
lane, and may run a `vm-exec` prerequisite. A nonzero prerequisite skips the model turn
and is logged. Host execution is deliberately unsupported.

The model must return exactly `SILENCE`, `Message: one paragraph`, or `Steer: command`.
Messages and steering are durably queued into main; malformed output is reported as a
heartbeat error. Before each run, Reve refreshes
`workspace/RECENT_CONVERSATIONS.md` from a bounded tail of main's durable context, so
`DREAM.md` can consolidate recent work without mounting `.reve/` in the VM. The generated
`heartbeat` skill documents every option.

## Durable architecture

Every mutation follows the same sequence: record intent, perform the effect, then append
the result with the identifiers named by the intent. A crash leaves either a completed
operation or enough information for recovery to finish it. Records are metadata; entries
are the conversation tree.

```mermaid
flowchart TB
  subgraph Host[host Ractor]
    Channel[channel visitor]
    Hooks[hooks and project tools]
  end
  subgraph Lanes[lane Ractors]
    Main[main lane]
    Other[other lanes]
  end
  Store[one store Ractor]
  Hub[observer hub Ractor]
  Files[(agent/.reve/sessions)]
  Tools[tool Ractors]
  Provider[provider stream]

  Channel --> Main
  Channel --> Other
  Main --> Hooks
  Main --> Provider
  Main --> Tools
  Main --> Store
  Other --> Store
  Store --> Files
  Main --> Hub
  Other --> Hub
  Hub --> Channel
```

The store is the single writer for one session. JSON strings and `Ractor::Port`s are the
only values crossing Ractor boundaries. A tool call is isolated in its own Ractor unless a
project tool or sandbox connection must remain in the host Ractor. Lanes serialize their
own operation, queue, abort, retry, compaction, and recovery state.

## Mandatory sandbox and dynamic skills

Reve depends on `microsandbox-rb`. There is no local mode, CLI transport, Fiddle fallback,
or host shell: if the gem or embedded runtime cannot boot the configured VM, Reve refuses
to start. Model `bash`, project `ctx.sh`, and user `!command` all execute through the same
live VM handle. `workspace/` is the only writable bind mount; host-side file helpers are
strictly confined to that bind source, including symlink resolution. GitHub hosts are
allowed by default, but credentials are never borrowed implicitly. `allow ... do;
secret ...; end` explicitly scopes placeholder substitution to named hosts.

The first launch creates and provisions a VM. Clean shutdown stops it but preserves its
root disk and definition; later launches restart that named VM instead of reinstalling
APT and language tools. Node is installed through mise; ast-grep uses npm because mise's
aqua backend still queries GitHub's unauthenticated, rate-limited releases API. A sandbox policy or toolchain change
intentionally replaces and reprovisions it. Before the TUI appears, a live startup spinner
names image/VM creation, APT/mise provisioning, and each bootstrap stage, then reports
elapsed time. Reve also avoids model-endpoint discovery during startup.

At every run boundary Reve rereads full `workspace/AGENTS.md`, full
`workspace/SOUL.md`, and the first 100 lines of `workspace/KNOWLEDGE.md`. They enter the
durable turn context rather than the stable system prefix, so edits apply immediately
without destroying prompt-cache continuity across tool steps.

All skills live in VM-editable `workspace/skills/` and are fingerprinted at each turn
boundary. When any file there changes,
Reve reloads the catalog and prepends an `<available_skills_update>` to the new user turn.
This exposes newly created skills to modern models without rewriting the system prompt and
invalidating its cached prefix.

For the same reason, Reve watches provider cache usage. A normal request with more than
30% uncached input emits a visible cache-miss warning. The first request in a session and
compaction requests are exempt because their cold prefixes are expected.

## Local configuration

`models.yml` is YAML and belongs to the agent root. Environment references require an
explicit `$`: for example, `baseUrl: $LLAMA_CPP_BASE` and `apiKey: $LLAMA_API_KEY`.
Every `apiKey` in YAML must be a `$ENV_VAR` reference; literal and bare-name API keys are
rejected. Generated agents default to `openai/gpt-5.6-luna`, and OpenAI is active in the
template. `/model` and its autocomplete refresh each configured endpoint through
`<baseUrl>/models`, parsing OpenAI `data` arrays and common `models` arrays without
hardcoded model ids. Discovery failures are printed with provider, URL, HTTP status, and
the complete response body; static declarations remain available. Provider request
configuration errors are returned in-band with provider/model and resolved environment
context rather than faulting a lane. No model file is read from `$HOME` or from a global
Reve directory.

The project uses `openai-responses`, `anthropic-messages`, and a scripted `fake` provider
for deterministic tests. Provider-specific differences live in each provider's `compat`
block rather than in scattered conditionals.

## Durable records

Sessions are append-only JSONL under `.reve/sessions/`:

```jsonl
{"kind":"header","version":4,"id":"...","cwd":"workspace"}
{"kind":"record","type":"operation_started","lane":"main","intent":{"kind":"run"}}
{"kind":"entry","lane":"main","type":"message","message":{"role":"user"}}
{"kind":"record","type":"tool_started","resultEntryId":"e_...","replay":"never"}
{"kind":"entry","lane":"main","type":"message","message":{"role":"toolResult"}}
{"kind":"record","type":"operation_finished","outcome":"completed"}
```

Recovery is tested against real child-process termination. Tool intent records provision
result IDs before effects. Safe tools may be replayed only when both the recorded and
current declarations say `safe`; effectful tools receive a synthetic interrupted result.

## Development

```bash
bin/test                 # every test file in its own process
rake lint                # syntax-check the project
rake test                # run the complete suite
rake rbs                 # validate signatures when RBS is available
bin/reve --version
```

The repository itself is also an ordinary Reve agent folder for development purposes.
Tests create isolated temporary agent folders and fake providers; they do not consult a
user profile or write persistent state outside their fixture folder.
