# frozen_string_literal: true

require "yaml"
require "json"
require "fileutils"
require "time"

module Leve
  # Periodic, unattached lane work declared by workspace/HEARTBEAT.yml.
  # Shell preparation is VM-only. The durable state file is written before an
  # attempt so a crash cannot duplicate an external/model effect immediately.
  module Heartbeat
    RESPONSE_RULE = <<~TEXT.strip.freeze
      If you need to send a message to the user respond with "Message: {one paragraph}" otherwise just output the token SILENCE. Anything else will be reported back to the main thread as an error. You can also send an instruction to the main thread inbox called Steer: command.
    TEXT
    NAME = /\A[A-Za-z0-9][A-Za-z0-9_.-]*\z/

    module_function

    def load(path)
      return [] unless File.file?(path)

      root = YAML.safe_load(File.read(path), permitted_classes: [], aliases: false) || {}
      tasks = root["tasks"] || []
      raise ArgumentError, "HEARTBEAT.yml tasks must be a list" unless tasks.is_a?(Array)

      tasks.map.with_index do |raw, index|
        raise ArgumentError, "HEARTBEAT.yml task #{index + 1} must be a mapping" unless raw.is_a?(Hash)

        task = raw.transform_keys(&:to_s)
        required = %w[name model channel-name continue prompt]
        missing = required.reject { task.key?(_1) }
        raise ArgumentError, "heartbeat task #{index + 1} missing #{missing.join(", ")}" unless missing.empty?
        raise ArgumentError, "heartbeat task #{task["name"].inspect} has invalid name" unless task["name"].to_s.match?(NAME)
        unless task["channel-name"].to_s.match?(NAME) && task["channel-name"] != "main"
          raise ArgumentError, "heartbeat task #{task["name"]} has invalid channel-name"
        end
        unless [true, false].include?(task["continue"])
          raise ArgumentError, "heartbeat task #{task["name"]}: continue must be true or false"
        end
        raise ArgumentError, "heartbeat task #{task["name"]}: prompt must not be empty" if task["prompt"].to_s.strip.empty?
        if task.key?("vm-exec") && task["vm-exec"].to_s.strip.empty?
          raise ArgumentError, "heartbeat task #{task["name"]}: vm-exec must not be empty"
        end
        raise ArgumentError, "heartbeat task #{task["name"]}: host-exec is forbidden" if task.key?("host-exec")
        raise ArgumentError, "heartbeat task #{task["name"]}: delivery must be main" unless
          !task.key?("delivery") || task["delivery"] == "main"

        task["everySeconds"] = parse_duration(task["every"] || "4h")
        task
      end
    rescue Psych::Exception => e
      raise ArgumentError, "invalid HEARTBEAT.yml: #{e.message}"
    end

    def parse_duration(value)
      match = value.to_s.match(/\A(\d+)([smhd])\z/) or
        raise ArgumentError, "invalid heartbeat interval #{value.inspect} (use 30m, 4h, or 1d)"
      amount = match[1].to_i
      raise ArgumentError, "heartbeat interval must be positive" unless amount.positive?

      amount * { "s" => 1, "m" => 60, "h" => 3600, "d" => 86_400 }.fetch(match[2])
    end

    class Runner
      def initialize(harness, workspace:, config_path:, tasks:, state_path:)
        @harness = harness
        @workspace = workspace
        @config_path = config_path
        @tasks = tasks
        @config_fingerprint = fingerprint
        @state_path = state_path
        @stop = false
        @mutex = Mutex.new
        @workers = []
        @lane_names = {}
      end

      def start
        @thread = Thread.new do
          until @stop
            reload_config
            run_due
            50.times do
              break if @stop
              sleep 0.1
            end
          end
        rescue StandardError => e
          @harness.emit_local("heartbeat_error", { "task" => "scheduler", "message" => e.message })
        end
        self
      end

      def background_lane?(name)
        @lane_names[name] || @tasks.any? do |task|
          channel = task["channel-name"]
          name == channel || (!task["continue"] && name.to_s.start_with?("#{channel}-"))
        end
      end

      def stop
        @stop = true
        @thread&.join(1)
        @workers.each { _1.join(1) }
      end

      def fingerprint
        return nil unless File.file?(@config_path)

        stat = File.stat(@config_path)
        [stat.mtime.to_f, stat.size, File.read(@config_path)]
      end

      def reload_config
        current = fingerprint
        return if current == @config_fingerprint

        tasks = Heartbeat.load(@config_path)
        @tasks = tasks
        @config_fingerprint = current
        @harness.emit_local("heartbeat_reloaded", { "tasks" => tasks.map { _1["name"] } })
      rescue StandardError => e
        # Keep the last valid set while an editor is between writes. Remember
        # this bad fingerprint so the same error is not emitted every scan.
        @config_fingerprint = current
        @harness.emit_local("heartbeat_error", { "task" => "configuration", "message" => e.message })
      end

      def run_due(now = Time.now)
        claimed = []
        with_state_lock do
          state = read_state
          @tasks.each do |task|
            last = state.dig(task["name"], "startedAt")
            next if last && now.to_f - last.to_f < task["everySeconds"]
            next if @workers.any? { _1.alive? && _1[:heartbeat_name] == task["name"] }

            # Intent before effect. A killed process waits one full interval rather
            # than accidentally repeating the task on restart or in another process.
            state[task["name"]] = { "startedAt" => now.to_f, "status" => "started" }
            claimed << task
          end
          write_state(state) unless claimed.empty?
        end
        claimed.each do |task|
          worker = Thread.new { run_task(task) }
          worker[:heartbeat_name] = task["name"]
          @workers << worker
        end
        @workers.reject! { !_1.alive? }
      end

      def run_task(task)
        lane = task_lane(task)
        @harness.emit_local("heartbeat_task_start", { "task" => task["name"], "laneName" => lane.name })
        log(lane, "heartbeat_started", "task" => task["name"])
        snapshot = write_recent_snapshot
        preface = +"Recent main-conversation context is available at @RECENT_CONVERSATIONS.md.\n"

        if (command = task["vm-exec"])
          result = @harness.sandbox.exec(command.to_s, timeout: 600, cancel: -> { @stop })
          output = "#{result["stdout"]}#{result["stderr"]}"
          if result["exitCode"].to_i != 0
            log(lane, "heartbeat_skipped", "task" => task["name"], "exitCode" => result["exitCode"],
                                               "output" => output)
            finish_state(task, "skipped", "exitCode" => result["exitCode"])
            return
          end
          preface << "\nVM preparation output (exit 0):\n```text\n#{output}\n```\n"
        end

        set_model(lane, task["model"])
        prompt = "#{preface}\n#{task["prompt"]}\n\n#{RESPONSE_RULE}"
        result = lane.prompt(prompt)
        text = result.dig("finalMessage", "content")&.filter_map { _1["text"] }&.join.to_s.strip
        handle_response(task, lane, text)
        finish_state(task, result["ok"] ? "completed" : result["outcome"].to_s,
                           "snapshotBytes" => snapshot.bytesize)
      rescue StandardError => e
        log(lane, "heartbeat_error", "task" => task["name"], "message" => "#{e.class}: #{e.message}") if lane
        @harness.emit_local("heartbeat_error", { "task" => task["name"], "message" => e.message })
        finish_state(task, "failed", "error" => e.message)
      end

      def task_lane(task)
        base = task["channel-name"]
        name = task["continue"] ? base : "#{base}-#{Time.now.strftime("%Y%m%d%H%M%S%L")}"
        @lane_names[name] = true
        lane = @harness.lane(name)
        unless lane
          result = @harness.create_lane(name, @harness.main.leaf_id)
          raise "could not create heartbeat lane #{name}" unless result["ok"]
          lane = result["lane"]
        end
        lane
      end

      def set_model(lane, spec)
        model = spec.to_s == "default" ? @harness.model : @harness.resolve_model(spec)
        raise "unknown heartbeat model #{spec.inspect}" unless model

        lane.update_runtime("model" => model)
        lane.set_persisted("model", { "provider" => model["provider"], "modelId" => model["modelId"] })
      end

      def handle_response(task, lane, text)
        case text
        when "SILENCE"
          log(lane, "heartbeat_silence", "task" => task["name"])
        when /\AMessage: ([^\r\n]+)\z/
          message = Regexp.last_match(1).strip
          @harness.main.next_run("Background task #{task["name"]}: #{message}")
          @harness.emit_local("heartbeat_message", { "task" => task["name"], "message" => message })
          log(lane, "heartbeat_delivery", "task" => task["name"], "kind" => "message", "message" => message)
        when /\ASteer: ([^\r\n]+)\z/
          command = Regexp.last_match(1).strip
          main_state = @harness.main.state
          delivered = main_state["operation"] ? @harness.main.steer(command) : @harness.main.next_run(command)
          @harness.emit_local("heartbeat_steer", { "task" => task["name"], "command" => command })
          log(lane, "heartbeat_delivery", "task" => task["name"], "kind" => "steer",
                                                 "command" => command, "accepted" => delivered["ok"])
        else
          message = "invalid response #{text.inspect}"
          log(lane, "heartbeat_error", "task" => task["name"],
                                         "message" => "invalid response", "response" => text)
          @harness.main.next_run("Heartbeat task #{task["name"]} ERROR: #{message}")
          @harness.emit_local("heartbeat_error", { "task" => task["name"], "message" => message })
        end
      end

      def write_recent_snapshot
        entries = @harness.main.session.context_entries.last(80)
        body = entries.filter_map do |entry|
          message = entry["message"]
          next unless message
          text = (message["content"] || []).filter_map { _1["text"] }.join
          next if text.empty?
          "## #{message["role"]}\n\n#{text}"
        end.join("\n\n")
        body = body[-60_000, 60_000] || body
        content = "# Recent Conversations\n\nGenerated by Leve at #{Time.now.utc.iso8601}.\n\n#{body}\n"
        File.write(File.join(@workspace, "RECENT_CONVERSATIONS.md"), content)
        content
      end

      def log(lane, type, data)
        lane.session.append_entry({ "type" => "custom", "id" => Ids.entry,
                                    "customType" => type, "data" => data })
      end

      def read_state
        @mutex.synchronize do
          File.file?(@state_path) ? JSON.parse(File.read(@state_path)) : {}
        end
      rescue JSON::ParserError
        {}
      end

      def write_state(state)
        @mutex.synchronize do
          FileUtils.mkdir_p(File.dirname(@state_path))
          tmp = "#{@state_path}.tmp-#{Process.pid}-#{Thread.current.object_id}"
          File.write(tmp, JSON.generate(state))
          File.rename(tmp, @state_path)
        end
      end

      def with_state_lock
        FileUtils.mkdir_p(File.dirname(@state_path))
        File.open("#{@state_path}.lock", File::RDWR | File::CREAT, 0o600) do |file|
          file.flock(File::LOCK_EX)
          yield
        ensure
          file.flock(File::LOCK_UN) rescue nil
        end
      end

      def finish_state(task, status, details = {})
        with_state_lock do
          state = read_state
          state[task["name"]] ||= {}
          state[task["name"]].merge!(details).merge!("status" => status, "finishedAt" => Time.now.to_f)
          write_state(state)
        end
      end
    end
  end
end
