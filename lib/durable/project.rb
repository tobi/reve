# frozen_string_literal: true

require "fileutils"
require_relative "frontmatter"
require_relative "skills"
require_relative "agents_md"
require_relative "tool_dsl"
require_relative "sandbox"

module Durable
  # An agent is a directory (eve's model). Launch rbagent in it and it picks up
  # its setup from the files:
  #
  #   instructions.md      what the agent is and how it should work — all you need
  #   agent.rb             optional: model, thinking level, active tools, sandbox
  #   tools/*.rb           optional: tools written in the Ruby DSL
  #   skills/*/SKILL.md    optional: skills (also .agents/skills, .pi/skills)
  #   sandbox/sandbox.rb   optional: swap the sandbox backend or bootstrap it
  #   .rbagent/sessions/   where the durable session logs live
  #
  # Nothing here is required: with no files at all rbagent is a plain coding
  # agent in the current directory, which is why `rbagent` in a random checkout
  # still works.
  class Project
    INSTRUCTIONS = %w[instructions.md INSTRUCTIONS.md].freeze
    # Files that join the prompt without being asked for, when they exist. A
    # SOUL.md is a common second file: instructions.md is the job, SOUL.md is
    # the character.
    EXTRA_PROMPT_FILES = %w[SOUL.md agent/SOUL.md .rbagent/SOUL.md].freeze
    AGENT_FILES = %w[agent.rb .rbagent/agent.rb].freeze

    attr_reader :root, :instructions, :config, :tools, :sandbox_config, :diagnostics, :skills,
                :prompt_sources

    def self.load(root = Dir.pwd, user_skills: true) = new(root, user_skills: user_skills)

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
    def name = @config["name"] || File.basename(@root)
    def sessions_dir = File.join(@root, ".rbagent", "sessions")

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
      listed = @config["promptFiles"]
      paths =
        if listed && !listed.empty?
          listed
        else
          EXTRA_PROMPT_FILES.select { File.file?(File.join(@root, _1)) }
        end
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

    # ── sandbox/ ──────────────────────────────────────────────────────────

    def load_sandbox
      path = %w[sandbox/sandbox.rb sandbox.rb].map { File.join(@root, _1) }.find { File.file?(_1) }
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
                               .merge("hostWorkspace" => @root)
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
    def system_prompt(tools: nil, sandbox: nil)
      base = Prompt.system_prompt(cwd: @root, tools: tools, agents: AgentsMd.discover(@root),
                                 skills: @skills)
      parts = [base]
      sources = @prompt_sources.reject { _1["content"].to_s.empty? }
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
      "instructions.md" => <<~'MD',
        ---
        name: %<name>s
        model: vllm
        ---

        You are %<name>s, an agent that works in this directory.

        Describe here what you are for: the work you do, the conventions you follow, and
        anything a new colleague would need to be told. Everything in this file goes into
        every request, so keep it short and concrete.

        - Read before you change. Verify after you change.
        - Prefer small, reviewable steps.
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
      "skills/release-notes/SKILL.md" => <<~'MD',
        ---
        name: release-notes
        description: Write release notes from a git log range. Use when asked for a changelog or release notes.
        ---

        1. Run `git log --oneline` for the range in question.
        2. Group the commits into Added / Changed / Fixed.
        3. Write them to CHANGELOG.md under a new version heading.
      MD
      "sandbox/sandbox.rb" => <<~'RUBY',
        # The sandbox every command runs in.
        #
        # The default is `:auto`: a microVM when microsandbox is installed, this
        # machine otherwise. The VM is debian with the tools an agent reaches for
        # (git, ripgrep, fd, jq, build-essential) and mise for language runtimes,
        # activated for every shell.
        #
        # Egress is deny-by-default: github.com only, using your own GitHub
        # credential — lent to the sandbox through microsandbox's secret proxy, so
        # the token never enters the VM. Add hosts explicitly with `allow`.

        sandbox do
          backend :auto           # :microsandbox to insist, :local to opt out

          # image "debian:trixie-slim"
          # cpus 2
          # memory 2048
          # mise "node@lts", "python@3.12"
          # packages "ripgrep", "fd-find", "postgresql-client"

          # allow "rubygems.org", "registry.npmjs.org"
          # allow_all                     # opt out of the egress policy
          # github_auth false             # do not lend the host's github token
          # secret "OPENAI_API_KEY", hosts: ["api.openai.com"]

          # bootstrap "bundle install"
        end
      RUBY
      "SOUL.md" => <<~'MD',
        You are %<name>s.

        instructions.md is the job; this file is the character. Voice, taste, what you
        refuse to do, how you talk to the user. Both files go into every request, in
        order, and `agent.rb` can name more of them.
      MD
      "AGENTS.md" => <<~'MD'
        # %<name>s

        Conventions for anyone — human or agent — working in this directory.

        - (add yours here)
      MD
    }.freeze

    def self.init(root = Dir.pwd, name: nil, force: false)
      root = File.expand_path(root)
      name ||= File.basename(root)
      created = []
      skipped = []
      SCAFFOLD.each do |rel, template|
        path = File.join(root, rel)
        if File.exist?(path) && !force
          skipped << rel
          next
        end
        FileUtils.mkdir_p(File.dirname(path))
        File.write(path, format(template, name: name))
        created << rel
      end
      FileUtils.mkdir_p(File.join(root, ".rbagent", "sessions"))
      gitignore = File.join(root, ".gitignore")
      unless File.exist?(gitignore) && File.read(gitignore).include?(".rbagent")
        File.open(gitignore, "a") { _1.puts(".rbagent/") }
        created << ".gitignore"
      end
      { "root" => root, "created" => created, "skipped" => skipped }
    end
  end
end
