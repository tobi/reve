# frozen_string_literal: true

require "fileutils"
require "json"
require_relative "frontmatter"
require_relative "skills"
require_relative "agents_md"
require_relative "tool_dsl"
require_relative "sandbox"

module Reve
  # An agent is a directory (eve's model). Launch reve in it and it picks up
  # its setup from the files:
  #
  #   instructions.md      what the agent is and how it should work — all you need
  #   agent.rb             optional: model, thinking level, active tools, sandbox
  #   tools/*.rb           optional: tools written in the Ruby DSL
  #   workspace/skills/*/SKILL.md optional: mutable skills visible inside the VM
  #   sandbox.rb           optional: configure the mandatory microVM
  #   .reve/sessions/   where the durable session logs live
  #
  # Nothing here is required: with no files at all reve is a plain coding
  # agent in the current directory, which is why `reve` in a random checkout
  # still works.
  class Project
    INSTRUCTIONS = %w[instructions.md INSTRUCTIONS.md].freeze
    # Files that join the prompt without being asked for, when they exist. A
    # SOUL.md is a common second file: instructions.md is the job, SOUL.md is
    # the character.
    EXTRA_PROMPT_FILES = %w[SOUL.md agent/SOUL.md .reve/SOUL.md].freeze
    AGENT_FILES = %w[agent.rb .reve/agent.rb].freeze

    attr_reader :root, :instructions, :config, :tools, :sandbox_config, :diagnostics, :skills,
                :prompt_sources

    def self.load(root = Dir.pwd, user_skills: true) = new(root, user_skills: user_skills)

    # What makes a directory an agent directory. reve refuses to launch
    # without one, because an agent with no instructions is just a chat window
    # with your filesystem attached.
    def self.agent_dir?(root = Dir.pwd)
      (INSTRUCTIONS + AGENT_FILES + EXTRA_PROMPT_FILES).any? { File.file?(File.join(root, _1)) }
    end

    def initialize(root = Dir.pwd, user_skills: true)
      @root = File.expand_path(root)
      @user_skills = user_skills
      @diagnostics = []
      @instructions_path = INSTRUCTIONS.map { File.join(@root, _1) }.find { File.file?(_1) }
      @instructions = nil
      @prompt_sources = []
      @config = {}
      load_instructions
      load_agent_file
      load_prompt_files
      load_tools
      load_sandbox
      load_skills
    end

    def agent? = !@instructions_path.nil? || !@prompt_sources.empty?

    # The root holds immutable launch authority (instructions, Ruby config and
    # trusted tool definitions). workspace/ holds the agent-editable mind,
    # skills, memory and work. It is /workspace inside the VM.
    WORKSPACE = "workspace"

    # For an agent, always <root>/workspace — never a fallback to the agent
    # directory, because that would bind-mount trusted launch configuration and
    # Ruby definitions into the sandbox. Loading a
    # project creates nothing: the directory appears at init, or the first time
    # the sandbox needs it.
    #
    # A plain checkout (reve --plain) has no workspace; the checkout is the
    # work.
    def workspace_dir = agent? ? File.join(@root, WORKSPACE) : @root

    def workspace? = File.directory?(File.join(@root, WORKSPACE))
    def name = @config["name"] || File.basename(@root)
    def sessions_dir = File.join(@root, ".reve", "sessions")

    CONVERSATION_NAME = /\A[A-Za-z0-9][A-Za-z0-9_.-]*\z/

    def latest_session_path
      Dir.glob(File.join(sessions_dir, "*.jsonl")).max_by { File.mtime(_1) }
    end

    def conversation_path(name = "main", fresh: false)
      name = name.to_s
      raise ArgumentError, "invalid conversation name #{name.inspect}" unless name.match?(CONVERSATION_NAME)

      FileUtils.mkdir_p(sessions_dir)
      index_path = File.join(@root, ".reve", "conversations.json")
      index = File.file?(index_path) ? JSON.parse(File.read(index_path)) : {}
      current = index[name]
      path = current && File.join(sessions_dir, current)
      return path if !fresh && path

      # Adopt pre-named-session history as main, preserving existing agents.
      candidate = !fresh && name == "main" ? latest_session_path : nil
      path = candidate || File.join(sessions_dir,
                                    "#{name}-#{Time.now.strftime("%Y%m%dT%H%M%S.%6N")}.jsonl")
      index[name] = File.basename(path)
      tmp = "#{index_path}.tmp-#{Process.pid}-#{Thread.current.object_id}"
      File.write(tmp, JSON.pretty_generate(index))
      File.rename(tmp, index_path)
      path
    rescue JSON::ParserError => e
      raise ArgumentError, "invalid .reve/conversations.json: #{e.message}"
    end

    # ── instructions.md ───────────────────────────────────────────────────

    # Frontmatter is the config an agent can carry without a second file:
    #
    #   ---
    #   name: release-bot
    #   model: vllm/glm52
    #   thinking: medium
    #   tools: read, write, edit, bash
    #   sandbox: microsandbox
    #   ---
    def load_instructions
      return unless @instructions_path

      fm, body = Frontmatter.parse(File.read(@instructions_path))
      @instructions = body.strip
      @prompt_sources << { "path" => @instructions_path, "content" => @instructions }
      @config["name"] = fm["name"] if fm["name"]
      @config["model"] = fm["model"] if fm["model"]
      @config["thinkingLevel"] = fm["thinking"] if fm["thinking"]
      @config["activeTools"] = split_list(fm["tools"]) if fm["tools"]
      @config["sandbox"] = { "backend" => fm["sandbox"].to_s } if fm["sandbox"]
      @diagnostics << { "type" => "warning", "path" => @instructions_path,
                        "message" => "instructions.md is empty" } if @instructions.empty?
    end

    def split_list(value)
      return value if value.is_a?(Array)

      value.to_s.split(/[\s,]+/).reject(&:empty?)
    end

    # The prompt is a list of files, not one file. instructions.md is the
    # default; agent.rb may name more (or different ones), and a SOUL.md next to
    # it is picked up on its own.
    def load_prompt_files
      # A listed file is deliberate and keeps its position; a SOUL.md that
      # simply exists is appended. Dropping one next to a scaffolded agent
      # should work without editing agent.rb.
      listed = @config["promptFiles"] || []
      extras = EXTRA_PROMPT_FILES.select { File.file?(File.join(@root, _1)) }
                                .reject { |rel| listed.any? { File.basename(_1) == File.basename(rel) } }
      paths = (listed + extras).uniq
      paths.each do |rel|
        path = File.expand_path(rel, @root)
        next if @prompt_sources.any? { _1["path"] == path }

        unless File.file?(path)
          @diagnostics << { "type" => "warning", "path" => path, "message" => "prompt file not found" }
          next
        end
        fm, body = Frontmatter.parse(File.read(path))
        # Later files may carry config too; the closest write wins.
        @config["name"] = fm["name"] if fm["name"]
        @config["model"] = fm["model"] if fm["model"]
        @config["thinkingLevel"] = fm["thinking"] if fm["thinking"]
        @prompt_sources << { "path" => path, "content" => body.strip }
      end
      # Inline prose from agent.rb counts as a source, after the files.
      if (inline = @config["inlineInstructions"])
        @prompt_sources << { "path" => "agent.rb", "content" => inline.strip }
      end
      @instructions ||= @prompt_sources.first&.dig("content")
    end

    # ── agent.rb ──────────────────────────────────────────────────────────

    # A tiny DSL, the same shape as eve's defineAgent:
    #
    #   agent do
    #     model "vllm/glm52"
    #     thinking :medium
    #     tools :read, :write, :edit, :bash
    #     sandbox :microsandbox
    #   end
    class AgentFile
      attr_reader :config

      def initialize
        @config = {}
      end

      def agent(&blk) = instance_eval(&blk)
      def name(value) = @config["name"] = value.to_s
      def model(value) = @config["model"] = value.to_s
      def thinking(value) = @config["thinkingLevel"] = value.to_s
      def tools(*names) = @config["activeTools"] = names.flatten.map(&:to_s)
      # instructions "instructions.md", "SOUL.md"   → prompt files, in order
      # instructions <<~TXT ... TXT                  → inline prose
      def instructions(*sources)
        files, inline = sources.flatten.map(&:to_s).partition { _1.length < 200 && _1.end_with?(".md") }
        @config["promptFiles"] = files unless files.empty?
        @config["inlineInstructions"] = inline.join("\n\n") unless inline.empty?
        @config["promptFiles"] || @config["inlineInstructions"]
      end

      # An explicit alias for the file list, when that reads better.
      def prompt_files(*paths) = @config["promptFiles"] = paths.flatten.map(&:to_s)

      def sandbox(backend = nil, **opts)
        cfg = @config["sandbox"] ||= {}
        cfg["backend"] = backend.to_s if backend
        opts.each { |k, v| cfg[k.to_s] = v }
        cfg
      end

      def retry_policy(**opts) = @config["retry"] = opts.transform_keys(&:to_s)
      def compaction(**opts) = @config["compaction"] = opts.transform_keys(&:to_s)
    end

    def load_agent_file
      path = AGENT_FILES.map { File.join(@root, _1) }.find { File.file?(_1) }
      return unless path

      file = AgentFile.new
      begin
        file.instance_eval(File.read(path), path)
      rescue SyntaxError, StandardError => e
        @diagnostics << { "type" => "error", "path" => path, "message" => "#{e.class}: #{e.message}" }
        return
      end
      @agent_path = path
      @config = @config.merge(file.config)
    end

    # ── tools/ ────────────────────────────────────────────────────────────

    def load_tools
      dir = File.join(@root, "tools")
      loaded = ToolDSL.load_dir(dir)
      @tools = loaded["tools"]
      @diagnostics.concat(loaded["diagnostics"])
    end

    def tool(name) = @tools.find { _1.name == name }
    def tool_declarations = @tools.map(&:declaration)

    # ── sandbox.rb ────────────────────────────────────────────────────────

    def load_sandbox
      # Root sandbox.rb is canonical; the nested path remains a read-only
      # compatibility fallback for agents generated before Reve 0.8.
      path = %w[sandbox.rb sandbox/sandbox.rb].map { File.join(@root, _1) }.find { File.file?(_1) }
      from_file =
        if path
          begin
            Sandbox.load_definition(path)
          rescue SyntaxError, StandardError => e
            @diagnostics << { "type" => "error", "path" => path, "message" => "#{e.class}: #{e.message}" }
            {}
          end
        else
          {}
        end
      @sandbox_config = Sandbox.config(from_file.merge(@config["sandbox"] || {}))
                               .merge("hostWorkspace" => workspace_dir)
    end

    def load_skills
      loaded = Skills.load(cwd: @root, user: @user_skills)
      @skills = loaded["skills"]
      @diagnostics.concat(loaded["diagnostics"])
    end

    # ── the system prompt ─────────────────────────────────────────────────

    # instructions.md is the agent's own definition, so it goes in as the
    # authority; the harness preamble stays because a model still needs to know
    # which tools exist and how this loop behaves.
    def system_prompt(tools: nil, sandbox: nil, skills: @skills)
      # VM-editable AGENTS/SOUL/KNOWLEDGE are injected at each run boundary by
      # Harness. Keeping them out of the stable prefix lets edits take effect
      # without invalidating the whole prompt cache.
      base = Prompt.system_prompt(cwd: workspace_dir, tools: tools, agents: [], skills: skills)
      parts = [base]
      sources = @prompt_sources.reject do |source|
        source["content"].to_s.empty? || source["path"].to_s.start_with?("#{workspace_dir}/")
      end
      unless sources.empty?
        blocks = sources.map do |src|
          rel = src["path"].to_s.start_with?(@root) ? src["path"].delete_prefix("#{@root}/") : src["path"]
          "<agent_instructions source=\"#{rel}\">\n#{src["content"]}\n</agent_instructions>"
        end
        parts << "#{blocks.join("\n\n")}\n" \
                 "These instructions define this agent. They outrank the general guidance above."
      end
      parts << "Your sandbox: #{sandbox.describe}." if sandbox
      parts.join("\n\n")
    end

    # ── scaffolding ───────────────────────────────────────────────────────

    SCAFFOLD = {
      "agent.rb" => <<~'RUBY',
        #!/usr/bin/env reve
        # What this agent is, in code. instructions.md is its prose; this file is
        # its configuration.

        agent do
          model "openai/gpt-5.6-luna"  # configured in this agent's models.yml
          thinking :low                # off | low | medium | high

          # instructions.md stays outside the VM; mutable identity and memory live
          # in workspace/ so the agent can maintain them itself.
          instructions "instructions.md", "workspace/SOUL.md"

          # tools :read, :write, :edit, :bash   # restrict the active set
          # Microsandbox is mandatory; ./sandbox.rb configures its policy.
        end
      RUBY
      "instructions.md" => <<~'MD',
        ---
        name: %<name>s
        ---

        You are %<name>s, an agent that works in this directory.

        Describe here what you are for: the work you do, the conventions you follow, and
        anything a new colleague would need to be told. Everything in this file goes into
        every request, so keep it short and concrete.

        - Read before you change. Verify after you change.
        - Prefer small, reviewable steps.
        - Work in workspace/ — it is /workspace in the sandbox and your working
          directory. rg, fd, ast-grep, jq, gh and mise are all available there.
      MD
      "tools/example.rb" => <<~'RUBY',
        # Tools are Ruby. One file may define several.
        #
        # Arguments are declared with typed helpers, which become the JSON schema the
        # model sees. `replay :safe` tells recovery it may re-run this call after a
        # crash; leave it out for anything with an effect.

        tool "word_count" do
          description "Count words in a file in the workspace"
          string :path, "Path relative to the workspace", required: true
          replay :safe

          run do |args, ctx|
            text = ctx.read(args["path"])
            "#{text.split.size} words, #{text.lines.size} lines"
          end
        end

        tool "sandboxed_uname" do
          description "Show what the sandbox is running"
          sandbox true
          replay :safe

          run { |_args, ctx| ctx.sh("uname -a") }
        end
      RUBY
      "channels/tui.rb" => <<~'RUBY',
        # Reve's default channel: a small visitor that delegates to the library's
        # InteractiveAgentTUI renderer. Drop more adapters into channels/*.rb; they
        # load before Ractors spawn and may add slash commands and prompt guidance.
        #
        # The host Ractor owns the entry box and rendering. The renderer sends
        # prompt, steer, follow-up, abort, and resume messages to lane Ractors;
        # it consumes the observer's event stream for output.
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
      RUBY
      "workspace/skills/heartbeat/SKILL.md" => <<~'MD',
        ---
        name: heartbeat
        description: Design, review, or edit HEARTBEAT.yml background tasks. Use when scheduling dreams, maintenance, monitoring, or delivery into the main conversation.
        ---

        # Heartbeat tasks

        Edit `/workspace/HEARTBEAT.yml`. Reve watches the complete file and applies each
        valid saved revision without a restart. A transient invalid revision is reported
        while the last valid task set keeps running.

        Each item under `tasks:` has:

        - `name`: unique durable scheduler identity.
        - `model`: `default`, a provider, `provider/model-id`, or configured model id.
        - `channel-name`: background lane name; use a stable descriptive name.
        - `continue`: when true, reuse that lane's context; when false, branch a fresh
          lane for every run.
        - `every`: positive interval such as `30m`, `4h`, or `1d`.
        - `prompt`: the task instruction. `@FILE.md` references are ordinary instructions
          to read files from this workspace.
        - `vm-exec` (optional): command run in the mandatory VM before the model turn.
          Exit 0 adds combined stdout/stderr to the prompt. Any other exit skips the turn
          and writes a durable heartbeat log entry.
        - `delivery`: currently only `main`.

        There is no `host-exec`; host process execution is forbidden. Heartbeat lanes are
        unattached and do not stream their working output into the foreground UI.

        Reve appends the strict response contract to every task. Return exactly one of:

        - `SILENCE`
        - `Message: one paragraph for the user`
        - `Steer: instruction for the main conversation`

        Anything else is a durable heartbeat error. Before each task Reve refreshes
        `/workspace/RECENT_CONVERSATIONS.md` with a bounded snapshot of recent main-lane
        context. Use it for consolidation, but never treat remembered claims as live truth.
      MD
      "workspace/skills/release-notes/SKILL.md" => <<~'MD',
        ---
        name: release-notes
        description: Write release notes from a git log range. Use when asked for a changelog or release notes.
        ---

        1. Run `git log --oneline` for the range in question.
        2. Group the commits into Added / Changed / Fixed.
        3. Write them to CHANGELOG.md under a new version heading.
      MD
      "sandbox.rb" => <<~'RUBY',
        # The sandbox every command runs in.
        #
        # workspace/ is mounted at /workspace and is the working directory, so a
        # relative path means the same thing on the host and in the VM. The agent's
        # immutable definition files stay outside it; memory and skills live inside.
        #
        # Microsandbox is mandatory. Reve uses the microsandbox-rb gem's embedded
        # runtime and refuses to run without it; there is no host/local mode.
        #
        # Egress is deny-by-default. GitHub hosts are reachable, but no host
        # credential is lent implicitly. The scoped secret example below shows
        # explicit placeholder substitution without putting the token in the VM.

        sandbox do
          image "debian:trixie-slim"
          cpus 2
          memory 2048
          security :restricted
          mount_workspace true

          provision true
          packages "ca-certificates", "curl", "git", "gh", "build-essential", "jq",
                   "unzip", "ripgrep", "fd-find", "file", "less"
          mise "node@lts"
          npm "@ast-grep/cli" # avoids mise's unauthenticated GitHub API lookup

          # Host-scoped substitution: the VM sees only this fake placeholder;
          # microsandbox substitutes the real value on requests to these hosts.
          # `gh` keyring login is not an environment variable; export it first:
          #   export GITHUB_TOKEN="$(gh auth token --hostname github.com)"
          github_token = ENV["GITHUB_TOKEN"] || ENV["GH_TOKEN"]
          allow "github.com", "api.github.com", "raw.githubusercontent.com",
                "objects.githubusercontent.com", "codeload.github.com" do
            if github_token && !github_token.empty?
              secret "GITHUB_TOKEN", value: github_token,
                     placeholder: "reve-github-token"
            end
          end
          allow_all false

          # allow "api.openai.com" do
          #   secret "OPENAI_API_KEY", value: ENV.fetch("OPENAI_API_KEY")
          # end
          # bootstrap "bundle install"
        end
      RUBY
      "workspace/AGENTS.md" => <<~'MD',
        <!-- reve-kernel: v1 -->
        # Agent workspace

        You are stateful. `SOUL.md` says who you are; `KNOWLEDGE.md`, `knowledge/`, and
        append-only `notes/` preserve what you learn. Read them at the start of relevant
        work. Reality wins over memory: verify live state and correct stale knowledge.

        ## Session protocol
        - Read `SOUL.md`, the knowledge index, and the newest relevant notes.
        - Keep durable facts in `knowledge/`; keep a short dated narrative in `notes/`.
        - Never rewrite a previous day's note. Use absolute dates, not “recently”.
        - Keep memory concise and factual. Update `Updated: YYYY-MM-DD` when state changes.
        - Reusable procedures belong in `skills/<name>/SKILL.md`; Reve reloads them live.

        ## Dreaming
        `DREAM.md` consolidates conversation and note noise into current knowledge. Reve
        writes a bounded snapshot of the main conversation to `RECENT_CONVERSATIONS.md`
        before each heartbeat. Dreaming may update memory files but never session logs.

        ## Workspace
        This directory is `/workspace` in the mandatory VM and every command starts here.
        Prefer `rg` over recursive grep, `fd` over find, and `ast-grep` for structural code
        queries. `jq`, `gh`, `mise`, and `git` are available. Do not expect host access.
      MD
      "workspace/SOUL.md" => <<~'MD',
        # Soul

        You are a new agent. Ask the user to define your name, role, voice, priorities,
        boundaries, and timezone, then maintain those facts here concisely.
      MD
      "workspace/KNOWLEDGE.md" => <<~'MD',
        # Knowledge Index

        No knowledge files yet. Create focused files under `knowledge/` as durable facts
        emerge. List each file here with one sentence saying what it contains.
      MD
      "workspace/DREAM.md" => <<~'MD',
        # Dream protocol

        When this protocol is invoked by the scheduled `dream` heartbeat, assume there
        were recent conversations and inspect `RECENT_CONVERSATIONS.md` before orienting.

        1. **Orient:** Read `SOUL.md`, `KNOWLEDGE.md`, `knowledge/`, recent `notes/`, and
           `RECENT_CONVERSATIONS.md`. Notice likely drift before searching.
        2. **Signal:** Gather only narrow evidence needed to confirm suspected drift.
        3. **Consolidate:** Correct contradictions, promote durable insights, normalize
           dates, and update each touched file's `Updated:` line.
        4. **Prune:** Remove stale or cheaply derivable knowledge and repair the index.

        Preserve information that would change a future decision. Never modify old notes,
        project code, tests, configuration, or Reve's durable session files. Record a short
        `## Dream` account in today's note.
      MD
      "workspace/HEARTBEAT.yml" => <<~'YAML',
        tasks:
          - name: dream
            model: default
            channel-name: dream
            continue: true
            every: 4h
            prompt: Run @DREAM.md
            delivery: main

          # - name: repository-check
          #   model: default
          #   channel-name: repository-check
          #   continue: false
          #   every: 30m
          #   vm-exec: git status --short
          #   prompt: Review the VM command output and report only actionable problems.
          #   delivery: main
      YAML
      "workspace/knowledge/.gitkeep" => "",
      "workspace/notes/.gitkeep" => "",
      "workspace/skills/.gitkeep" => ""
    }.freeze

    # Entries written verbatim, without format() — no %<name>s in them.
    VERBATIM = ["workspace/knowledge/.gitkeep", "workspace/notes/.gitkeep",
                "workspace/skills/.gitkeep"].freeze

    # `update` is true or a list of scaffold-relative paths approved by the
    # caller. Existing byte-identical files are never rewritten; differing ones
    # are candidates, not assumptions that Reve owns the user's edits.
    def self.init(root = Dir.pwd, name: nil, force: false, update: false)
      root = File.expand_path(root)
      name ||= begin
        instructions = INSTRUCTIONS.map { File.join(root, _1) }.find { File.file?(_1) }
        instructions && Frontmatter.parse(File.read(instructions)).first["name"]
      rescue StandardError
        nil
      end
      name ||= File.basename(root)
      created = []
      updated = []
      skipped = []
      unchanged = []
      candidates = []
      approved = update == true ? nil : Array(update).map(&:to_s)
      # Preserve old agents while flattening the scaffold. Moving an edited
      # policy is safe; replacing it with the new template is still opt-in.
      legacy_sandbox = File.join(root, "sandbox", "sandbox.rb")
      canonical_sandbox = File.join(root, "sandbox.rb")
      if File.file?(legacy_sandbox) && !File.exist?(canonical_sandbox)
        FileUtils.mv(legacy_sandbox, canonical_sandbox)
        Dir.rmdir(File.dirname(legacy_sandbox)) rescue nil
      end
      scaffold = SCAFFOLD.merge(Provider::Models::FILENAME => Provider::Models.template)
      scaffold.each do |rel, template|
        path = File.join(root, rel)
        content = VERBATIM.include?(rel) || rel == Provider::Models::FILENAME ? template : format(template, name: name)
        if File.exist?(path)
          if File.binread(path) == content.b
            unchanged << rel
            skipped << rel
            next
          end

          candidates << rel
          unless force || update == true || approved.include?(rel)
            skipped << rel
            next
          end
          FileUtils.mkdir_p(File.dirname(path))
          File.binwrite(path, content)
          updated << rel
          next
        end
        FileUtils.mkdir_p(File.dirname(path))
        File.binwrite(path, content)
        created << rel
      end
      agent_file = File.join(root, "agent.rb")
      File.chmod(File.stat(agent_file).mode | 0o111, agent_file) if File.file?(agent_file)
      FileUtils.mkdir_p(File.join(root, ".reve", "sessions"))
      gitignore = File.join(root, ".gitignore")
      existing = File.file?(gitignore) ? File.read(gitignore) : ""
      missing_ignores = [".reve/", "workspace/RECENT_CONVERSATIONS.md"].reject do |line|
        existing.lines.map(&:strip).include?(line)
      end
      unless missing_ignores.empty?
        File.open(gitignore, "a") { |file| missing_ignores.each { file.puts(_1) } }
        created << ".gitignore"
      end
      { "root" => root, "created" => created, "updated" => updated,
        "skipped" => skipped, "unchanged" => unchanged, "updateCandidates" => candidates }
    end
  end
end
