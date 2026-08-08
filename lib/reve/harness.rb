# frozen_string_literal: true

require_relative "ipc"
require_relative "store"
require_relative "observer"
require_relative "lane"
require_relative "tools"
require_relative "provider"
require_relative "prompt"
require_relative "agents_md"
require_relative "skills"
require_relative "compaction"
require "fileutils"
require_relative "project"
require_relative "sandbox"
require_relative "tool_dsl"

module Reve
  # The harness (§8). Lives in the main Ractor: it owns the store Ractor, the
  # observer Ractor, one Ractor per lane, and the hook registry. Hooks are
  # closures, so they can only live here; lanes reach them by RPC.
  class Harness
    HOOKS = %w[before_run before_resume before_run_end transform_context before_request
               after_response before_tool after_tool before_compaction before_navigation].freeze

    attr_reader :store, :hub, :session, :session_path, :conversation_name, :config, :suspended
    attr_accessor :new_session_factory, :channel_runtime

    # Returns [harness, suspended_operations]. Opens the session, restores every
    # lane, starts no effects.
    def self.create(storage: "memory", path: nil, model: nil, system_prompt: nil, **opts)
      new(storage: storage, path: path, model: model, system_prompt: system_prompt, **opts).then do |h|
        [h, h.suspended]
      end
    end

    def initialize(storage: "memory", path: nil, model: nil, system_prompt: nil,
                   active_tools: nil, thinking_level: "off", retry_policy: nil, compaction: nil,
                   cwd: Dir.pwd, tool_execution: "parallel", models_config: nil, agents_md: true,
                   skills: true, skill_dirs: [], user_skills: true, project: nil, sandbox: nil,
                   conversation: "main", channel_instructions: [])
      # An agent is a directory: instructions.md, agent.rb, tools/, sandbox.rb, workspace/.
      @project = project.is_a?(Project) ? project : (project == false ? nil : Project.load(cwd, user_skills: user_skills))
      @sandbox = sandbox || Sandbox.resolve(@project ? @project.sandbox_config : { "hostWorkspace" => cwd })
      # The bind-mount source and every tool's cwd; one mkdir at boot beats a
      # spawn failure on the first command.
      FileUtils.mkdir_p(@project.workspace_dir) if @project&.agent?
      @session_path = path
      @conversation_name = conversation
      @store = Store.spawn(kind: storage, path: path, metadata: { "cwd" => cwd })
      @hub = Observer.spawn(store: @store)
      @session = Session.new(@store)
      @models_config = models_config || Provider::Models.load(root: cwd)
      spec = model || @project&.config&.dig("model")
      @model = spec.is_a?(String) ? Provider::Models.resolve(@models_config, spec) : spec
      raise ArgumentError, "unknown model #{spec.inspect}" if @model.nil?

      # Discovery starts where the work is: workspace/AGENTS.md is the closest
      # file and the agent directory's is the outer one, which is the order the
      # prompt wants them in.
      @agents = agents_md ? AgentsMd.discover(@project&.workspace_dir || cwd, root: @project&.root || cwd) : []
      @agents_loaded = @agents.map { _1["path"] }
      @skills_enabled = skills
      @skill_dirs = skill_dirs
      @user_skills = user_skills
      loaded = skills ? Skills.load(cwd: cwd, extra_dirs: skill_dirs, user: user_skills)
                      : { "skills" => [], "diagnostics" => [] }
      @skills = loaded["skills"]
      @static_skills = @skills.reject { Skills.workspace_skill?(_1, cwd) }
      @skill_diagnostics = loaded["diagnostics"] + (@project&.diagnostics || [])
      @workspace_skill_fingerprint = Skills.workspace_fingerprint(cwd)
      @workspace_skills_announced = @skills.none? { Skills.workspace_skill?(_1, cwd) }
      @channel_instructions = Array(channel_instructions).map(&:to_s).reject(&:empty?)
      @project_tools = @project ? @project.tools : []
      project_declarations = @project_tools.map { _1.declaration }
      active_names = active_tools || @project&.config&.dig("activeTools") ||
                     (Tools.names + project_declarations.map { _1["name"] })
      @config = {
        "model" => @model,
        # Startup must not probe every configured HTTP endpoint. Explicit model
        # selection resolves on demand; `/models` may probe when the user asks.
        "models" => Provider::Models.list(@models_config, probe: false),
        "systemPrompt" => system_prompt || build_system_prompt(cwd, active_names),
        "activeToolNames" => active_names,
        "projectTools" => project_declarations,
        "thinkingLevel" => thinking_level || @project&.config&.dig("thinkingLevel") || "off",
        "retry" => retry_policy || @project&.config&.dig("retry") || { "maxAttempts" => 5, "baseMs" => 500 },
        "compaction" => compaction || @project&.config&.dig("compaction") || { "threshold" => 0.8 },
        # Tools run where the work is: workspace/ when the agent has one, so the
        # host and the sandbox agree about what "." means.
        "cwd" => @project&.workspace_dir || cwd,
        "agentRoot" => cwd,
        "toolExecution" => tool_execution
      }
      @hooks = {}
      @cancelled_tools = {}
      @event_listeners = []
      @lanes = {}
      @mutex = Mutex.new
      start_host
      install_agents_md_hook if agents_md
      install_workspace_skills_hook if skills
      install_workspace_context_hook if @project&.agent?
      restore_lanes
    end

    # The AGENTS.md files that are part of the system prompt.
    def agents_md = @agents
    def project = @project
    def sandbox = @sandbox
    def project_tools = @project_tools

    def build_system_prompt(cwd, active_names)
      base = if @project&.agent?
               @project.system_prompt(tools: active_names, sandbox: @sandbox, skills: @static_skills)
             else
               prompt = Prompt.system_prompt(cwd: cwd, agents: @agents, skills: @static_skills,
                                              tools: active_names)
               @sandbox&.isolated? ? "#{prompt}\n\nYour sandbox: #{@sandbox.describe}." : prompt
             end
      return base if @channel_instructions.empty?

      "#{base}\n\n<channel_instructions>\n#{@channel_instructions.join("\n\n")}\n</channel_instructions>"
    end

    # Skills and the diagnostics collected while loading them (over-long
    # descriptions, invalid names, name collisions). The caller decides how
    # loudly to complain.
    def skills = @skills
    def skill_diagnostics = @skill_diagnostics
    def skill(name) = Skills.find(@skills, name)

    def system_prompt = @config["systemPrompt"]

    # ── lanes ─────────────────────────────────────────────────────────────

    def lane(name) = @lanes[name]
    def main = @lanes["main"]

    def lanes
      @session.lanes.map do |l|
        st = @lanes[l["lane"]] ? @lanes[l["lane"]].state : nil
        { "name" => l["lane"], "leafId" => l["leafId"], "operation" => st && st["operation"] }
      end
    end

    def create_lane(name, at)
      return { "ok" => false, "error" => { "code" => "lane_exists" } } if @lanes.key?(name)

      @session.create_lane(name, at)
      handle = spawn_lane(name)
      emit_local("lane_created", { "lane" => name, "at" => at })
      { "ok" => true, "lane" => handle }
    end

    def delete_lane(name)
      return { "ok" => false, "error" => { "code" => "invalid_lane" } } if name == "main"

      handle = @lanes[name] or return { "ok" => false, "error" => { "code" => "unknown_lane" } }
      st = handle.state
      return { "ok" => false, "error" => { "code" => "busy" } } if st["operation"]

      handle.close
      @lanes.delete(name)
      @session.delete_lane(name)
      emit_local("lane_deleted", { "lane" => name })
      { "ok" => true }
    end

    # ── main-lane conveniences: the harness *is* main (§8) ─────────────────

    def prompt(text = nil, message: nil, content: nil) = main.prompt(text, message: message, content: content)
    def steer(text) = main.steer(text)
    def follow_up(text) = main.follow_up(text)
    def next_run(text) = main.next_run(text)
    def abort!(reason = "user") = main.abort!(reason)
    def resume = main.resume
    def compact(custom_instructions: nil) = main.compact(custom_instructions: custom_instructions)

    def new_session
      raise "new sessions are unavailable in this embedding" unless @new_session_factory

      @new_session_factory.call(self)
    end

    def navigate(target_id, summarize: false, label: nil, custom_instructions: nil)
      main.navigate(target_id, summarize: summarize, label: label, custom_instructions: custom_instructions)
    end

    def state = main.state
    def goal = main.goal
    def set_goal(text) = main.set_goal(text)
    def run_skill(name, additional_instructions = nil) = main.skill(name, additional_instructions)

    # ── hooks and events ──────────────────────────────────────────────────

    def on_hook(name, &blk)
      raise ArgumentError, "unknown hook #{name}" unless HOOKS.include?(name.to_s)

      @mutex.synchronize { (@hooks[name.to_s] ||= []) << blk }
      -> { @mutex.synchronize { @hooks[name.to_s].delete(blk) } }
    end

    # Live-only event listener (no snapshot, no buffer): a firehose watcher.
    def on_event(&blk)
      @event_listeners << blk
      ensure_firehose
      -> { @event_listeners.delete(blk) }
    end

    def watch(lane_name = nil) = Watch.new(@hub, lane: lane_name)
    def watch_session = Watch.new(@hub)

    # ── configuration ─────────────────────────────────────────────────────

    def model = @config["model"]

    def set_model(spec)
      m = spec.is_a?(String) ? Provider::Models.resolve(@models_config, spec) : spec
      if !m && spec.is_a?(String)
        matches = Array(@discovered_models).select { _1["modelId"] == spec }
        m = matches.first if matches.size == 1
      end
      return { "ok" => false, "error" => { "code" => "unknown_model" } } unless m

      @config["model"] = m
      @lanes.each_value do |l|
        l.update_runtime("model" => m)
        l.set_persisted("model", { "provider" => m["provider"], "modelId" => m["modelId"] })
      end
      { "ok" => true, "model" => m }
    end

    def available_models(probe: true) = Provider::Models.list(@models_config, probe: probe)

    def model_completions(probe: false)
      providers = (@models_config["providers"] || {})
      catalog = if probe
                  now = Process.clock_gettime(Process::CLOCK_MONOTONIC)
                  if !@model_catalog_at || now - @model_catalog_at > 15
                    result = Provider::Models.catalog(@models_config, probe: true)
                    @discovered_models = result["models"]
                    @model_catalog_diagnostics = result["diagnostics"]
                    @model_catalog_at = now
                  end
                  @discovered_models
                else
                  available_models(probe: false)
                end
      ids = catalog.map { _1["modelId"] }
      unique_ids = ids.tally.select { |_id, count| count == 1 }.keys
      qualified = catalog.map { "#{_1["provider"]}/#{_1["modelId"]}" }
      current = [@model && "#{@model["provider"]}/#{@model["modelId"]}", @model && @model["modelId"]]
      (providers.keys + qualified + unique_ids + current.compact).uniq.sort
    end

    def model_catalog_diagnostics = @model_catalog_diagnostics || []

    def resolve_model(spec) = Provider::Models.resolve(@models_config, spec)

    def emit_event(type, payload = {}) = emit_local(type, payload)
    def background_lane?(name) = !!@heartbeat&.background_lane?(name)

    def start_heartbeat
      return @heartbeat if @heartbeat || !@project&.agent?

      path = File.join(@project.workspace_dir, "HEARTBEAT.yml")
      tasks = begin
        Heartbeat.load(path)
      rescue ArgumentError => e
        emit_local("heartbeat_error", { "task" => "configuration", "message" => e.message })
        []
      end
      @heartbeat = Heartbeat::Runner.new(
        self, workspace: @project.workspace_dir, config_path: path, tasks: tasks,
        state_path: File.join(@project.root, ".reve", "heartbeat.json")
      ).start
    end

    # Tolerant of a second call and of Ractors that already went away: shutdown
    # paths race by nature, and a failure here would be the last thing a user
    # sees.
    def close(close_sandbox: true)
      return if @closed

      @closed = true
      @channel_runtime&.close
      @heartbeat&.stop
      @lanes.each_value(&:close)
      quietly { @sandbox&.stop if close_sandbox && @sandbox&.isolated? }
      quietly { IPC.cast(@hub, "close") }
      quietly { @session.close }
      @host_thread&.kill
      nil
    end

    def quietly
      yield
    rescue Ractor::ClosedError, Ractor::Error, Reve::RemoteError
      nil
    end

    private

    # Mutable skills live under workspace/ so the model can create and improve
    # them. Reload at the durable turn boundary and prepend a catalog update to
    # this turn's user content. The system prompt remains byte-for-byte stable,
    # preserving the provider cache.
    def install_workspace_skills_hook
      # External edits are picked up before a new user turn.
      on_hook("before_run") do |ev|
        update = refresh_workspace_skills
        update ? { "prompt" => [{ "type" => "text", "text" => update }] + Array(ev["prompt"]) } : nil
      end

      # A model may create or improve a skill with any tool during its own turn.
      # Check after every tool and append the update to that result, so the very
      # next model request sees it without changing an earlier cached prefix.
      on_hook("after_tool") do |ev|
        update = refresh_workspace_skills
        update ? { "content" => Array(ev["content"]) + [{ "type" => "text", "text" => update }] } : nil
      end
    end

    def refresh_workspace_skills
      @mutex.synchronize do
        fingerprint = Skills.workspace_fingerprint(@config["agentRoot"])
        changed = fingerprint != @workspace_skill_fingerprint || !@workspace_skills_announced
        return nil unless changed

        loaded = Skills.load(cwd: @config["agentRoot"], extra_dirs: @skill_dirs, user: @user_skills)
        dynamic = loaded["skills"].select { Skills.workspace_skill?(_1, @config["agentRoot"]) }
        @skills = loaded["skills"]
        @static_skills = @skills - dynamic
        @skill_diagnostics = loaded["diagnostics"] + (@project&.diagnostics || [])
        @workspace_skill_fingerprint = fingerprint
        @workspace_skills_announced = true
        Skills.update_message(dynamic)
      end
    end

    def install_workspace_context_hook
      on_hook("before_run") do |ev|
        context = workspace_context
        next nil if context.empty?

        { "prompt" => [{ "type" => "text", "text" => context }] + Array(ev["prompt"]) }
      end
    end

    def workspace_context
      root = @project.workspace_dir
      specs = [["AGENTS.md", nil], ["SOUL.md", nil], ["KNOWLEDGE.md", 100]]
      blocks = specs.filter_map do |name, limit|
        path = File.join(root, name)
        next unless File.file?(path)

        lines = File.readlines(path)
        selected = limit ? lines.first(limit) : lines
        content = selected.join.strip
        next if content.empty?

        if name == "AGENTS.md"
          @mutex.synchronize do
            found = @agents.find { _1["path"] == path }
            found["content"] = content if found
          end
        end
        truncated = limit && lines.size > limit ? " lines=\"1-#{limit}\" truncated=\"true\"" : ""
        "<workspace_file source=\"#{name}\"#{truncated}>\n#{content}\n</workspace_file>"
      rescue EncodingError, SystemCallError => e
        emit_local("workspace_context_error", { "path" => path, "message" => e.message })
        nil
      end
      return "" if blocks.empty?

      "<workspace_context>\n#{blocks.join("\n\n")}\n</workspace_context>\n" \
        "This workspace-maintained context applies to this run; root instructions remain authoritative."
    end

    # Nested AGENTS.md: the first time a tool touches a path under a directory
    # that has its own file, that file rides along on the tool result. Late
    # context arrives at the tail, never before the assistant message that did
    # not see it.
    def install_agents_md_hook
      on_hook("after_tool") do |ev|
        path = ev.dig("args", "path") || ev.dig("args", "cwd")
        next nil unless path

        found = @mutex.synchronize do
          f = AgentsMd.nested_for(path, @config["cwd"], @agents_loaded)
          f&.each { @agents_loaded << _1["path"] }
          f
        end
        next nil unless found

        note = found.map { "[AGENTS.md for this directory: #{_1["path"]}]\n#{_1["content"].strip}" }.join("\n\n")
        { "content" => (ev["content"] || []) + [{ "type" => "text", "text" => note }] }
      end
    end

    def spawn_lane(name)
      ractor = Lane.spawn(store: @store, hub: @hub, host: @host_port, lane: name, config: @config)
      handle = LaneHandle.new(ractor, name, self)
      @lanes[name] = handle
      handle
    end

    def restore_lanes
      @suspended = []
      @session.lanes.each do |l|
        handle = spawn_lane(l["lane"])
        st = handle.state
        next unless st["operation"]

        op = st["operation"]
        @suspended << { "lane" => l["lane"], "kind" => op["kind"], "id" => op["id"],
                        "startedAt" => op["startedAt"],
                        "reason" => op["deferred"] ? "deferred" : "crash",
                        "deferred" => op["deferred"], "missing" => op["missing"] }
      end
      @suspended
    end

    # The host serves hooks to lanes. Handlers run sequentially in registration
    # order; each transformation sees the previous one's output. A throwing
    # handler is skipped and reported — except before_tool, which fails closed.
    def start_host
      @host_port = Ractor::Port.new
      @host_thread = Thread.new do
        loop do
          msg = @host_port.receive
          # A VM exec blocks this request, so serve independently; otherwise a
          # cancel message would queue behind the command it needs to cancel.
          Thread.new(msg) do |request|
            IPC.serve(request) do |op, arg, _port|
              case op
              when "hook" then run_hook(arg["hook"], arg["lane"], arg["payload"])
              when "run_tool" then run_project_tool(arg["tool"], arg["args"], arg["lane"], arg["callId"])
              when "cancel_tool"
                @mutex.synchronize { @cancelled_tools[arg["callId"]] = true }
                true
              else raise ArgumentError, "unknown host op #{op}"
              end
            end
          end
        end
      rescue Ractor::ClosedError
        nil
      end
    end

    # Project tools run here: their bodies are Ruby blocks and the sandbox
    # connection lives in this Ractor. Each call gets its own thread, so a slow
    # tool does not block the host's hook traffic.
    def run_project_tool(name, args, lane_name, call_id = nil)
      if Tools.sandboxed?(name)
        cancelled = -> { @mutex.synchronize { @cancelled_tools.key?(call_id) } }
        return run_sandboxed_builtin(name, args || {}, cancelled)
      end

      definition = @project_tools.find { _1.name == name }
      return { "content" => [{ "type" => "text", "text" => "unknown tool: #{name}" }], "isError" => true } unless definition

      context = ToolDSL::Context.new(sandbox: @sandbox, cwd: @config["cwd"], lane: lane_name, harness: self)
      ToolDSL.invoke(definition, args || {}, context)
    ensure
      @mutex.synchronize { @cancelled_tools.delete(call_id) } if call_id
    end

    def run_sandboxed_builtin(name, args, cancelled)
      return Tools.error("unknown sandboxed tool: #{name}") unless name == "bash"

      started = Time.now
      result = @sandbox.exec(args["command"].to_s, timeout: (args["timeout"] || 120).to_i,
                                                   cancel: cancelled)
      output = "#{result["stdout"]}#{result["stderr"]}"
      text, spill = Tools.overspill(output, "bash", root: @config["cwd"])
      took = Time.now - started
      details = (spill || {}).merge("exitCode" => result["exitCode"],
                                    "durationMs" => (took * 1000).round,
                                    "sandbox" => @sandbox.backend_name)
      return Tools.error("Interrupted after #{took.round(1)}s.\n#{text}", details: details) if result["cancelled"]

      slow = took > 1 ? "\n[Took #{took.round(1)}s]" : ""
      if result["exitCode"].to_i.zero?
        Tools.ok(text.strip.empty? ? "(no output)#{slow}" : "#{text}#{slow}", details: details)
      else
        Tools.error("exit #{result["exitCode"]}#{slow}\n#{text}", details: details)
      end
    end

    def run_hook(name, lane_name, payload)
      handlers = @mutex.synchronize { (@hooks[name] || []).dup }
      return nil if handlers.empty?

      event = (payload || {}).merge("lane" => lane_name, "hook" => name)
      result = nil
      handlers.each do |h|
        out = begin
          h.call(event)
        rescue StandardError => e
          emit_local("handler_error", { "kind" => "hook", "hook" => name, "lane" => lane_name,
                                       "error" => "#{e.class}: #{e.message}" })
          return { "block" => { "reason" => "policy hook failed: #{e.message}" } } if name == "before_tool"

          nil
        end
        next unless out.is_a?(Hash)

        result = (result || {}).merge(out)
        # Transformations chain: the next handler sees the current values.
        event = event.merge(out)
      end
      result
    end

    def emit_local(type, payload)
      IPC.cast(@hub, "emit", payload.merge("type" => type))
    end
    public :emit_local

    def ensure_firehose
      return if @firehose

      @firehose = Thread.new do
        w = Watch.new(@hub)
        w.each_event do |ev|
          @event_listeners.dup.each do |l|
            l.call(ev)
          rescue StandardError => e
            warn "[durable] event listener error: #{e.class}: #{e.message}"
          end
        end
      rescue Ractor::ClosedError
        nil
      end
    end

    # ── lane handle: the AgentLane surface ────────────────────────────────

    class LaneHandle
      attr_reader :name

      def initialize(ractor, name, harness)
        @ractor = ractor
        @name = name
        @harness = harness
      end

      def state = call("state")
      def leaf_id = state["leafId"]

      # Blocks until the run ends — the operation's result comes back on the
      # caller's port, while the lane's control loop stays responsive.
      def prompt(text = nil, message: nil, content: nil)
        payload = {}
        payload["text"] = text if text
        payload["content"] = content if content
        payload["content"] = message["content"] if message
        call("prompt", payload)
      end

      # Run a skill: its instructions enter the conversation as a user message,
      # so the transcript shows exactly what the model was told.
      def skill(name, additional_instructions = nil)
        sk = @harness.skill(name)
        return { "ok" => false, "outcome" => "rejected",
                 "error" => { "code" => "unknown_skill", "message" => "no skill #{name.inspect}" } } unless sk

        prompt(Reve::Skills.invocation_message(sk, additional_instructions))
      end

      def goal = call("get_goal")["goal"]

      def append_bash(command, output, exit_code)
        call("append_bash", { "command" => command, "output" => output, "exitCode" => exit_code })
      end
      def set_goal(text) = call("set_goal", { "text" => text })
      def steer(text) = call("steer", { "text" => text })
      def follow_up(text) = call("follow_up", { "text" => text })
      def next_run(text) = call("next_run", { "text" => text })
      def abort!(reason = "user") = call("abort", { "reason" => reason })
      def resume = call("resume")
      def compact(custom_instructions: nil) = call("compact", { "customInstructions" => custom_instructions })

      def navigate(target_id, summarize: false, label: nil, custom_instructions: nil)
        call("navigate", { "targetId" => target_id, "summarize" => summarize, "label" => label,
                           "customInstructions" => custom_instructions })
      end

      def set_persisted(property, value) = call("set_config", { "property" => property, "value" => value })
      def update_runtime(patch) = call("set_runtime", patch)
      def wait_idle = call("wait_idle")
      def session = Session.new(@harness.store, lane: @name)

      def close
        call("close")
      rescue Reve::RemoteError, Ractor::ClosedError
        nil
      end

      # Each caller thread gets its own port, so concurrent prompt + steer from
      # different threads never cross answers.
      def call(op, payload = nil) = IPC.call(@ractor, op, payload, port: Ractor::Port.new)
    end
  end
end
