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

module Durable
  # The harness (§8). Lives in the main Ractor: it owns the store Ractor, the
  # observer Ractor, one Ractor per lane, and the hook registry. Hooks are
  # closures, so they can only live here; lanes reach them by RPC.
  class Harness
    HOOKS = %w[before_run before_resume before_run_end transform_context before_request
               after_response before_tool after_tool before_compaction before_navigation].freeze

    attr_reader :store, :hub, :session, :config, :suspended

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
                   skills: true, skill_dirs: [], user_skills: true)
      @store = Store.spawn(kind: storage, path: path, metadata: { "cwd" => cwd })
      @hub = Observer.spawn(store: @store)
      @session = Session.new(@store)
      @models_config = models_config || Provider::Models.load
      @model = model.is_a?(String) ? Provider::Models.resolve(@models_config, model) : model
      raise ArgumentError, "unknown model #{model.inspect}" if @model.nil?

      @agents = agents_md ? AgentsMd.discover(cwd) : []
      @agents_loaded = @agents.map { _1["path"] }
      loaded = skills ? Skills.load(cwd: cwd, extra_dirs: skill_dirs, user: user_skills)
                      : { "skills" => [], "diagnostics" => [] }
      @skills = loaded["skills"]
      @skill_diagnostics = loaded["diagnostics"]
      @config = {
        "model" => @model,
        "models" => Provider::Models.list(@models_config),
        "systemPrompt" => system_prompt || Prompt.system_prompt(cwd: cwd, agents: @agents, skills: @skills,
                                                                tools: active_tools || Tools.names),
        "activeToolNames" => active_tools || Tools.names,
        "thinkingLevel" => thinking_level,
        "retry" => retry_policy || { "maxAttempts" => 5, "baseMs" => 500 },
        "compaction" => compaction || { "threshold" => 0.8 },
        "cwd" => cwd,
        "toolExecution" => tool_execution
      }
      @hooks = {}
      @event_listeners = []
      @lanes = {}
      @mutex = Mutex.new
      start_host
      install_agents_md_hook if agents_md
      restore_lanes
    end

    # The AGENTS.md files that are part of the system prompt.
    def agents_md = @agents

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
      return { "ok" => false, "error" => { "code" => "unknown_model" } } unless m

      @config["model"] = m
      @lanes.each_value do |l|
        l.update_runtime("model" => m)
        l.set_persisted("model", { "provider" => m["provider"], "modelId" => m["modelId"] })
      end
      { "ok" => true, "model" => m }
    end

    def available_models = Provider::Models.list(@models_config)

    def close
      @lanes.each_value(&:close)
      IPC.cast(@hub, "close")
      @session.close
      @host_thread&.kill
      nil
    end

    private

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
          IPC.serve(msg) do |op, arg, _port|
            case op
            when "hook" then run_hook(arg["hook"], arg["lane"], arg["payload"])
            else raise ArgumentError, "unknown host op #{op}"
            end
          end
        end
      rescue Ractor::ClosedError
        nil
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

        prompt(Durable::Skills.invocation_message(sk, additional_instructions))
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
      rescue Durable::RemoteError, Ractor::ClosedError
        nil
      end

      # Each caller thread gets its own port, so concurrent prompt + steer from
      # different threads never cross answers.
      def call(op, payload = nil) = IPC.call(@ractor, op, payload, port: Ractor::Port.new)
    end
  end
end
