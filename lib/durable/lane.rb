# frozen_string_literal: true

require_relative "ipc"
require_relative "store"
require_relative "records"
require_relative "agent_loop"
require_relative "context"

module Durable
  # A lane: a named position in the tree plus the work serialized on it.
  # One Ractor per lane. Inside it, a control thread accepts commands (steer,
  # abort, config) while a worker thread executes the open operation — the two
  # meet only through the queues, exactly like the design's checkpoint model.
  module Lane
    # Internal control-flow signals (§15).
    class RunFailed < StandardError; end
    class AppendFailed < StandardError; end

    class Park < StandardError
      attr_reader :handle

      def initialize(handle)
        @handle = handle
        super("parked on deferred handle")
      end
    end

    def self.spawn(store:, hub:, host:, lane:, config:)
      Ractor.new(store, hub, host, lane, IPC.encode(config), name: "lane:#{lane}") do |st, hb, ho, ln, cfg_json|
        runner = Durable::Lane::Runner.new(store: st, hub: hb, host: ho, lane: ln,
                                           config: JSON.parse(cfg_json))
        runner.control_loop
      end
    end

    # ── the runner ─────────────────────────────────────────────────────────

    class Runner
      attr_reader :lane, :config

      def initialize(store:, hub:, host:, lane:, config:)
        @store_ractor = store
        @hub = hub
        @host = host
        @lane = lane
        @config = config
        @session = Durable::Session.new(store, lane: lane)
        @mutex = Mutex.new
        @inbox = []             # accepted-but-unapplied queue items / writes
        @abort = false
        @worker = nil
        @op = nil               # in-memory operation state == reduction of the records
        @stream_message = nil
        @running_tools = {}
        @closed = false
        restore
      end

      # ── control loop: one command at a time, never blocked by execution ──

      def control_loop
        until @closed
          msg = Ractor.receive
          Durable::IPC.serve(msg) { |op, arg, port| handle(op, arg, port) }
        end
      end

      def handle(op, arg, port = nil)
        case op
        when "state" then public_state
        when "prompt" then start_operation(:run, arg, port)
        when "compact" then start_operation(:compaction, arg, port)
        when "navigate" then start_operation(:navigation, arg, port)
        when "resume" then do_resume(port)
        when "abort" then do_abort(arg && arg["reason"] || "user")
        when "steer" then enqueue("steer", arg)
        when "follow_up" then enqueue("followUp", arg)
        when "next_run" then enqueue("nextRun", arg)
        when "set_config" then set_persisted_config(arg)
        when "set_goal" then set_goal(arg)
        when "get_goal" then { "goal" => current_goal }
        when "set_runtime" then update_runtime(arg)
        when "wait_idle" then wait_idle
        when "close"
          @closed = true
          @abort = true
          @worker&.join(2)
          true
        else raise ArgumentError, "unknown lane op #{op}"
        end
      end

      def busy? = @worker&.alive?

      def public_state
        {
          "lane" => @lane,
          "leafId" => @session.leaf_id,
          "operation" => @op && {
            "id" => @op["id"], "kind" => @op["kind"],
            "status" => busy? ? (@op["aborting"] ? "aborting" : "running") : "suspended",
            "startedAt" => @op["startedAt"],
            "attempts" => @op["attempts"],
            "deferred" => @op["deferred"],
            "missing" => missing_identities
          },
          "queues" => queues_snapshot,
          "pendingWrites" => @inbox.select { _1["kind"] == "write" }.map { _1["target"] },
          "streamingMessage" => @stream_message,
          "runningTools" => @running_tools.values,
          "model" => effective_model_spec,
          "thinkingLevel" => effective_thinking,
          "activeTools" => active_tool_names,
          "goal" => current_goal
        }
      end

      # ── acceptance ───────────────────────────────────────────────────────

      def start_operation(kind, arg, port)
        return rejected("busy", "lane #{@lane} is busy") if busy? || @op

        case kind
        when :run then accept_run(arg, port)
        when :compaction then accept_compaction(arg, port)
        when :navigation then accept_navigation(arg, port)
        end
      end

      def accept_run(arg, port)
        prompt_content = arg["content"] || [{ "type" => "text", "text" => arg["text"].to_s }]
        hook = hook_call("before_run", { "prompt" => prompt_content, "systemPrompt" => system_prompt })
        return declined_now("run") if hook && hook["decline"]

        initial = []
        initial << Records.user_message(prompt_content) unless arg["skipPrompt"]
        (hook && hook["messages"] || []).each { |m| initial << Records.message_entry(m) }
        # Next-run queue items seed this run and are consumed by its acceptance.
        take_inbox("nextRun").each { |item| initial << item["target"] }

        intent = { "kind" => "run", "initialMessages" => initial }
        intent["systemPromptOverride"] = hook["systemPrompt"] if hook && hook["systemPrompt"]
        intent["resumeData"] = hook["resumeData"] if hook && hook["resumeData"]
        record = @session.append_record(Records.operation_started(
                                          lane: @lane, source_leaf_id: @session.leaf_id, intent: intent
                                        ))
        open_operation(record)
        emit("run_start", {})
        crash_check("after_accept")
        run_in_worker(port) { run_procedure }
      end

      def accept_compaction(arg, port)
        result_id = @session.create_entry_id
        intent = { "kind" => "compaction", "customInstructions" => arg && arg["customInstructions"],
                   "resultEntryId" => result_id }
        record = @session.append_record(Records.operation_started(
                                          lane: @lane, source_leaf_id: @session.leaf_id, intent: intent
                                        ))
        open_operation(record)
        run_in_worker(port) { compaction_procedure(reason: "manual") }
      end

      def accept_navigation(arg, port)
        target = arg["targetId"]
        return rejected("unknown_target", "no entry #{target}") if target && !@session.entry(target)

        intent = { "kind" => "navigation", "targetId" => target, "summarize" => !!arg["summarize"],
                   "customInstructions" => arg["customInstructions"], "label" => arg["label"] }
        intent["summaryEntryId"] = @session.create_entry_id if arg["summarize"]
        record = @session.append_record(Records.operation_started(
                                          lane: @lane, source_leaf_id: @session.leaf_id, intent: intent
                                        ))
        open_operation(record)
        run_in_worker(port) { navigation_procedure }
      end

      def do_resume(port)
        return rejected("busy", "lane #{@lane} is busy") if busy?
        return rejected("nothing_to_resume", "no open operation") unless @op

        miss = missing_identities
        unless miss["tools"].empty? && miss["models"].empty?
          return rejected("missing_identities", "missing #{miss.inspect}")
        end

        hook_call("before_resume", { "runId" => @op["id"], "kind" => @op["kind"],
                                    "resumeData" => @op.dig("intent", "resumeData") })
        emit("run_resume", { "recovery" => true })
        case @op["kind"]
        when "run" then run_in_worker(port) { run_procedure }
        when "compaction" then run_in_worker(port) { compaction_procedure(reason: "manual", resumed: true) }
        when "navigation" then run_in_worker(port) { navigation_procedure(resumed: true) }
        end
      end

      # abort() is durable when it resolves; reconciliation runs in background.
      def do_abort(reason)
        return rejected("no_active_run", "nothing to abort") unless @op

        unless @op["aborting"]
          @session.append_record(Records.abort_requested(lane: @lane, run_id: @op["id"], reason: reason))
          @op["aborting"] = true
        end
        @abort = true
        crash_check("after_abort_requested")
        cleared = { "steer" => take_inbox("steer").map { _1["target"]["message"] },
                    "followUp" => take_inbox("followUp").map { _1["target"]["message"] } }
        emit("run_abort", cleared)
        # A suspended lane has no worker to notice: reconcile right away.
        run_in_worker(nil) { abort_path } unless busy?
        { "ok" => true, "cleared" => cleared }
      end

      def enqueue(queue, arg)
        return rejected("no_active_run", "#{queue} needs an active run") if queue != "nextRun" && !@op

        message = arg["message"] || { "role" => "user",
                                      "content" => arg["content"] ||
                                        [{ "type" => "text", "text" => arg["text"].to_s }] }
        target = Records.message_entry(message)
        @session.append_record(Records.queue_enqueued(lane: @lane, queue: queue, target: target,
                                                      run_id: queue == "nextRun" ? nil : @op["id"]))
        @mutex.synchronize { @inbox << { "kind" => queue, "target" => target } }
        emit("queue_update", queues_snapshot)
        { "ok" => true }
      end

      # Config setters: immediate when idle, deferred writes while a step is in
      # flight (append-only context, §4).
      def set_persisted_config(arg)
        entry =
          case arg["property"]
          when "model"
            Records.model_change_entry(provider: arg["value"]["provider"], model_id: arg["value"]["modelId"])
          when "thinkingLevel" then Records.thinking_level_entry(level: arg["value"])
          when "activeTools" then Records.active_tools_entry(names: arg["value"])
          else return rejected("rejected", "unknown property #{arg["property"]}")
          end
        if busy?
          @session.append_record(Records.write_deferred(lane: @lane, run_id: @op["id"], target: entry))
          @mutex.synchronize { @inbox << { "kind" => "write", "target" => entry } }
          emit("write_pending", { "entryId" => entry["id"], "entry" => entry })
        else
          @session.append_entry(entry)
          emit("config_update", { "property" => arg["property"], "value" => arg["value"] })
        end
        { "ok" => true }
      end

      # The goal is branch state: a custom entry, resolved by a point query and
      # injected into the system prompt of every request on this lane. It
      # survives compaction because it never was a message.
      def set_goal(arg)
        entry = { "type" => "custom", "id" => Ids.entry, "customType" => "goal",
                  "data" => { "text" => arg["text"].to_s } }
        if busy?
          @session.append_record(Records.write_deferred(lane: @lane, run_id: @op["id"], target: entry))
          @mutex.synchronize { @inbox << { "kind" => "write", "target" => entry } }
          emit("write_pending", { "entryId" => entry["id"], "entry" => entry })
        else
          @session.append_entry(entry)
          emit("entry_added", { "entry" => entry })
        end
        { "ok" => true, "goal" => arg["text"] }
      end

      def update_runtime(arg)
        @config.merge!(arg)
        emit("config_update", { "property" => "runtime" })
        { "ok" => true }
      end

      def wait_idle
        @worker&.join
        { "ok" => true }
      end

      # ── worker ───────────────────────────────────────────────────────────

      # The worker owns the caller's reply port: the answer arrives when the
      # operation ends, and the control loop stays free for steer and abort.
      def run_in_worker(port, &blk)
        @abort = false if @op && !@op["aborting"]
        @worker = Thread.new do
          Thread.current.report_on_exception = false
          result =
            begin
              blk.call
            rescue StandardError => e
              faulted(e)
            end
          Durable::IPC.reply(port, result) if port
        end
        Durable::IPC::DEFER
      end

      # ── procedures (§15) ─────────────────────────────────────────────────

      def run_procedure
        @op["missingInitialMessages"].each { |m| append_if_missing(m) }
        @op["missingInitialMessages"] = []
        return abort_path if @op["aborting"]

        redeem_deferred if @op["deferred"]
        reconcile_tool_batch if unresolved_batch?
        driver_loop
      rescue Park => e
        emit("run_suspend", { "deferred" => e.handle })
        { "ok" => false, "outcome" => "suspended", "runId" => @op["id"], "deferred" => e.handle }
      rescue RunFailed => e
        finish("failed", error: { "code" => "run_failed", "message" => e.message })
      rescue AppendFailed => e
        faulted(e)
      end

      def driver_loop
        loop do
          # checkpoint: pending writes, steering, compaction
          take_inbox("write").each { |item| append_if_missing(item["target"]) }
          take_inbox("steer").each { |item| append_if_missing(item["target"]) }
          return abort_path if aborting?

          auto_compact if @op["compactionSkippedAt"] != @session.leaf_id && context_over_limit?

          if needs_assistant?
            assistant = step_task
            return abort_path if aborting? && assistant["stopReason"] != "aborted"

            if AgentLoop.tool_calls(assistant).any? && assistant["stopReason"] != "aborted"
              batch = run_tool_batch(assistant)
              return finish("completed") if batch[:terminate]

              next
            end
            return abort_path if assistant["stopReason"] == "aborted"
            next if assistant["stopReason"] == "toolUse" # tool calls got lost; ask again
          end

          followups = take_inbox("followUp")
          if followups.any?
            followups.each { |item| append_if_missing(item["target"]) }
            next
          end

          hook = hook_call("before_run_end", { "runId" => @op["id"] })
          if hook && hook["followUp"]
            enqueue("followUp", { "text" => hook["followUp"] })
            next
          end
          next if pending_work?

          return finish("completed")
        end
      end

      # A step: one task producing an assistant message. task_attempt is written
      # before every attempt, so the retry cap survives restarts.
      def step_task
        loop do
          attempt = @op["attempts"] + 1
          max = (@config.dig("retry", "maxAttempts") || 5).to_i
          if attempt > max
            @session.append_entry(Records.assistant_entry(
                                    { "role" => "assistant",
                                      "content" => [{ "type" => "text",
                                                      "text" => "Retries exhausted: #{@op["lastError"]}" }],
                                      "stopReason" => "error" }
                                  ))
            raise RunFailed, "retries_exhausted: #{@op["lastError"]}"
          end

          @session.append_record(Records.task_attempt(lane: @lane, run_id: @op["id"], task: "step",
                                                      attempt: attempt))
          @op["attempts"] = attempt
          stepid = Ids.step
          emit("step_start", { "stepId" => stepid })
          model = effective_model
          @stream_message = { "role" => "assistant", "content" => [] }
          final = AgentLoop.stream_assistant(
            context_messages,
            { model: model, system_prompt: @op.dig("intent", "systemPromptOverride") || system_prompt,
              tools: tool_declarations, thinking_level: effective_thinking,
              transform_context: method(:transform_context).to_proc,
              abort_check: -> { @abort } },
            method(:on_stream_event).to_proc
          )
          patched = hook_call("after_response", { "message" => final })
          final = patched["message"] if patched && patched["message"]
          @stream_message = nil

          entry = @session.append_entry(Records.assistant_entry(final))
          emit("message_end", { "message" => final, "entryId" => entry["id"] })
          @op["attempts"] = 0 unless final["stopReason"] == "error"

          if final["stopReason"] == "deferred"
            @op["deferred"] = final["deferred"]
            raise Park, final["deferred"]
          end
          if final["stopReason"] == "error"
            @op["lastError"] = final["errorMessage"]
            if final["retryable"] && !aborting?
              delay = backoff_delay(attempt)
              emit("retry_scheduled", { "task" => "step", "attempt" => attempt, "maxAttempts" => max,
                                        "delayMs" => (delay * 1000).round, "errorMessage" => final["errorMessage"] })
              sleep_interruptible(delay)
              emit("retry_start", { "task" => "step", "attempt" => attempt + 1 })
              next
            end
            raise RunFailed, final["errorMessage"].to_s
          end
          emit("step_end", { "stepId" => stepid, "message" => final })
          return final
        end
      end

      def run_tool_batch(assistant)
        crash_check("before_tool")
        assistant_entry_id = newest_own_assistant_id
        result_ids = {}
        callbacks = {
          before_tool: lambda do |call, args|
            hook_call("before_tool", { "toolCallId" => call["id"], "toolName" => call["name"], "args" => args })
          end,
          on_tool_start: lambda do |prepared|
            rid = @session.create_entry_id
            result_ids[prepared[:call]["id"]] = rid
            idx = AgentLoop.tool_calls(assistant).index { _1["id"] == prepared[:call]["id"] }
            @session.append_record(Records.tool_started(
                                     lane: @lane, run_id: @op["id"], assistant_entry_id: assistant_entry_id,
                                     tool_index: idx, tool_call_id: prepared[:call]["id"],
                                     tool_name: prepared[:name], effective_args: prepared[:args],
                                     result_entry_id: rid, replay: prepared[:replay]
                                   ))
            @running_tools[prepared[:call]["id"]] = { "toolCallId" => prepared[:call]["id"],
                                                     "toolName" => prepared[:name], "args" => prepared[:args] }
            crash_check("after_tool_started")
          end,
          after_tool: lambda do |prepared, executed|
            hook_call("after_tool", { "toolCallId" => prepared[:call]["id"], "toolName" => prepared[:name],
                                      "args" => prepared[:args], "content" => executed["content"],
                                      "isError" => executed["isError"] })
          end,
          on_tool_result: lambda do |message, prepared|
            @running_tools.delete(message["toolCallId"])
            id = result_ids[message["toolCallId"]] || @session.create_entry_id
            # append_if_missing emits message_end; emitting again here would
            # render every tool result twice.
            append_if_missing(Records.message_entry(message, id: id))
          end
        }
        AgentLoop.execute_tool_batch(assistant, active_tool_names, callbacks,
                                     { cwd: @config["cwd"] || Dir.pwd,
                                       tool_execution: @config["toolExecution"] },
                                     method(:emit_raw).to_proc, -> { @abort })
      end

      # Recovery path: each call of the batch at its own crash site (§6).
      def reconcile_tool_batch
        batch = @op["toolBatch"]
        batch["calls"].each do |call|
          next if call["resultExists"]

          started = call["started"]
          if started
            current = Tools.replay_of(started["toolName"])
            if started["replay"] == "safe" && current == "safe"
              prepared = { kind: "prepared", call: call["toolCall"], name: started["toolName"],
                           args: started["effectiveArgs"], replay: "safe" }
              executed = AgentLoop.execute_tool_call(prepared, @config["cwd"] || Dir.pwd,
                                                     method(:emit_raw).to_proc, -> { @abort })
              result = AgentLoop.finalize_tool_call(prepared, executed, {})
              msg = AgentLoop.tool_result_message(prepared, result)
              append_if_missing(Records.message_entry(msg, id: started["resultEntryId"]))
            else
              msg = Records.tool_result_message(tool_call_id: call["toolCall"]["id"],
                                                tool_name: started["toolName"],
                                                content: [{ "type" => "text", "text" => "Interrupted." }],
                                                is_error: true)
              append_if_missing(Records.message_entry(msg, id: started["resultEntryId"]))
            end
          else
            # No record: the full normal path, before_tool included.
            single = { "role" => "assistant", "content" => [call["toolCall"]],
                       "stopReason" => "toolUse" }
            run_tool_batch(single)
          end
        end
        @op["toolBatch"] = nil
      end

      def redeem_deferred
        handle = @op["deferred"]
        final = Provider.fetch_deferred(model: effective_model, handle: handle,
                                        wait: (@config["deferredWaitMs"] || 0) / 1000.0)
        raise Park, handle if final["stopReason"] == "deferred"

        if final["stopReason"] == "error"
          @op["lastError"] = final["errorMessage"]
          @op["deferred"] = nil
          return # the attempt failed; the driver loop starts a fresh one
        end
        @op["deferred"] = nil
        entry = @session.append_entry(Records.assistant_entry(final))
        emit("message_end", { "message" => final, "entryId" => entry["id"] })
      end

      # ── abort reconciliation ─────────────────────────────────────────────

      def abort_path
        Provider.cancel_deferred(model: effective_model, handle: @op["deferred"]) if @op["deferred"]
        (@op.dig("toolBatch", "calls") || []).each do |call|
          next if call["resultExists"]

          id = call.dig("started", "resultEntryId") || @session.create_entry_id
          text = call["started"] ? "Interrupted." : "Aborted before execution."
          msg = Records.tool_result_message(tool_call_id: call["toolCall"]["id"],
                                            tool_name: call["toolCall"]["name"],
                                            content: [{ "type" => "text", "text" => text }], is_error: true)
          append_if_missing(Records.message_entry(msg, id: id))
        end
        # Facts survive abort; conversational intent does not.
        take_inbox("write").each { |item| append_if_missing(item["target"]) }
        take_inbox("steer")
        take_inbox("followUp")
        unless newest_own_assistant_aborted?
          @session.append_entry(Records.assistant_entry({ "role" => "assistant",
                                                          "content" => [{ "type" => "text", "text" => "Aborted." }],
                                                          "stopReason" => "aborted" }))
        end
        finish("aborted")
      end

      # ── structural operations ────────────────────────────────────────────

      def compaction_procedure(reason:, resumed: false)
        emit("compaction_start", { "reason" => reason, "recovery" => resumed })
        result_id = @op.dig("intent", "resultEntryId")
        unless @session.entry(result_id)
          outcome = perform_compaction(reason: reason, result_id: result_id,
                                       custom_instructions: @op.dig("intent", "customInstructions"))
          if outcome == :declined || outcome == :nothing
            emit("compaction_end", { "reason" => reason, "outcome" => "declined" })
            code = outcome == :nothing ? "nothing_to_compact" : "declined_by_hook"
            return finish("declined", error: { "code" => code, "message" => code.tr("_", " ") })
          end
        end
        emit("compaction_end", { "reason" => reason, "outcome" => "completed" })
        finish("completed")
      rescue RunFailed => e
        emit("compaction_end", { "reason" => reason, "outcome" => "failed", "error" => e.message })
        finish("failed", error: { "code" => "compaction_failed", "message" => e.message })
      rescue AppendFailed => e
        faulted(e)
      end

      def navigation_procedure(resumed: false)
        target = @op.dig("intent", "targetId")
        old_leaf = @session.leaf_id
        emit("navigation_start", { "targetId" => target, "recovery" => resumed })
        summary_entry = nil
        if @op.dig("intent", "summarize") && !@session.entry(@op.dig("intent", "summaryEntryId"))
          hook = hook_call("before_navigation", { "targetId" => target })
          if hook && hook["decline"]
            emit("navigation_end", { "outcome" => "declined", "oldLeafId" => old_leaf, "newLeafId" => old_leaf })
            return finish("declined")
          end
          summary =
            if hook && hook["summary"]
              hook["summary"]
            else
              req = Compaction.request_message(context_messages, kind: :turn_prefix,
                                               custom_instructions: @op.dig("intent", "customInstructions"))
              r = summary_task("branch_summary", [req])
              { "summary" => r["texts"].join("\n"), "usage" => r["usage"] }
            end
          summary_entry = append_if_missing(Records.branch_summary_entry(
                                              id: @op.dig("intent", "summaryEntryId"),
                                              from_id: old_leaf, summary: summary["summary"],
                                              usage: summary["usage"]
                                            ))
        end
        @session.set_label(target, @op["intent"]["label"]) unless @op.dig("intent", "label").nil?
        # The leaf move and operation_finished are one atomic write.
        rec = Records.operation_finished(lane: @lane, run_id: @op["id"], outcome: "completed")
        @session.append_record(rec, move_lane: { "lane" => @lane, "to" => target })
        emit("navigation_end", { "outcome" => "completed", "oldLeafId" => old_leaf, "newLeafId" => target,
                                 "summaryEntry" => summary_entry })
        run_id = @op["id"]
        @op = nil
        { "ok" => true, "runId" => run_id, "newLeafId" => target, "summaryEntry" => summary_entry }
      rescue RunFailed => e
        emit("navigation_end", { "outcome" => "failed", "oldLeafId" => old_leaf, "newLeafId" => old_leaf })
        finish("failed", error: { "code" => "navigation_failed", "message" => e.message })
      rescue AppendFailed => e
        faulted(e)
      end

      # A retryable summarization task. One attempt may make several provider
      # requests (a split turn makes two); the durable count bounds attempts,
      # not requests.
      def summary_task(task, requests)
        max = (@config.dig("retry", "maxAttempts") || 5).to_i
        attempt = 0
        loop do
          attempt += 1
          raise RunFailed, "retries_exhausted (#{task})" if attempt > max

          @session.append_record(Records.task_attempt(lane: @lane, run_id: @op["id"], task: task,
                                                      attempt: attempt))
          texts = []
          usage = { "input" => 0, "output" => 0 }
          failed = nil
          requests.each do |message|
            final = AgentLoop.stream_assistant([message],
                                               { model: effective_model, system_prompt: Compaction::SYSTEM_PROMPT,
                                                 tools: [], thinking_level: "off",
                                                 max_tokens: summary_max_tokens,
                                                 abort_check: -> { @abort } })
            if final["stopReason"] == "error"
              failed = final
              break
            end
            texts << (final["content"] || []).select { _1["type"] == "text" }.map { _1["text"] }.join("\n")
            (final["usage"] || {}).each { |k, v| usage[k] = usage[k].to_i + v.to_i if v.is_a?(Numeric) }
          end
          if failed
            next if failed["retryable"] && !aborting?

            raise RunFailed, failed["errorMessage"].to_s
          end
          return { "texts" => texts, "usage" => usage }
        end
      end

      def summary_max_tokens
        reserve = (@config.dig("compaction", "reserveTokens") || Compaction::DEFAULTS["reserveTokens"]).to_i
        [(reserve * 0.8).floor, effective_model["maxTokens"] || 8192].min
      end

      # Shared by manual and automatic compaction. Returns :completed,
      # :declined or :nothing.
      def perform_compaction(reason:, result_id:, custom_instructions: nil)
        prep = Compaction.prepare(@session.path_entries, @config["compaction"])
        return :nothing unless prep

        hook = hook_call("before_compaction",
                         { "reason" => reason, "customInstructions" => custom_instructions,
                           "preparation" => { "firstKeptEntryId" => prep["firstKeptEntryId"],
                                              "tokensBefore" => prep["tokensBefore"],
                                              "splitTurn" => prep["splitTurn"],
                                              "fileOps" => prep["fileOps"] } })
        return :declined if hook && hook["decline"]

        if hook && hook["compaction"]
          summary_text = hook["compaction"]["summary"]
          usage = hook["compaction"]["usage"]
        else
          requests = []
          unless prep["messagesToSummarize"].empty?
            requests << Compaction.request_message(prep["messagesToSummarize"],
                                                   previous_summary: prep["previousSummary"],
                                                   custom_instructions: custom_instructions)
          end
          if prep["splitTurn"] && !prep["turnPrefixMessages"].empty?
            requests << Compaction.request_message(prep["turnPrefixMessages"], kind: :turn_prefix)
          end
          return :nothing if requests.empty?

          result = summary_task("compaction", requests)
          history, prefix = prep["messagesToSummarize"].empty? ? [nil, result["texts"][0]] : result["texts"]
          summary_text = Compaction.assemble(history, prep["splitTurn"] ? prefix : nil, prep["fileOps"])
          usage = result["usage"]
        end

        entry = append_if_missing(Records.compaction_entry(
                                    id: result_id, summary: summary_text,
                                    tokens_before: prep["tokensBefore"],
                                    first_kept_entry_id: prep["firstKeptEntryId"],
                                    usage: usage
                                  ).merge("details" => prep["fileOps"]))
        emit("entry_added", { "entry" => entry })
        :completed
      end

      def auto_compact
        emit("compaction_start", { "reason" => "threshold" })
        outcome = perform_compaction(reason: "threshold", result_id: @session.create_entry_id)
        # Over the threshold with nothing summarizable: do not ask again until
        # the lane has moved on (a new entry can change the answer).
        @op["compactionSkippedAt"] = outcome == :completed ? nil : @session.leaf_id
        emit("compaction_end", { "reason" => "threshold",
                                 "outcome" => outcome == :completed ? "completed" : "declined" })
      end

      # ── finishing ────────────────────────────────────────────────────────

      def finish(outcome, error: nil)
        run_id = @op["id"]
        kind = @op["kind"]
        @session.append_record(Records.operation_finished(lane: @lane, run_id: run_id, outcome: outcome,
                                                          error: error))
        leaf = @session.leaf_id
        final_entry = own_entries.reverse.find { _1["type"] == "message" && _1.dig("message", "role") == "assistant" }
        @op = nil
        @abort = false
        @running_tools = {}
        payload = { "runId" => run_id, "kind" => kind, "leafId" => leaf,
                    "finalEntryId" => final_entry && final_entry["id"],
                    "finalMessage" => final_entry && final_entry["message"] }
        emit("run_end", payload.merge("outcome" => outcome, "error" => error))
        outcome == "completed" ? payload.merge("ok" => true) : payload.merge("ok" => false, "outcome" => outcome,
                                                                            "error" => error)
      end

      def rejected(code, message)
        { "ok" => false, "outcome" => "rejected", "error" => { "code" => code, "message" => message } }
      end

      def declined_now(_kind)
        { "ok" => false, "outcome" => "declined" }
      end

      def faulted(e)
        emit("fault", { "code" => e.class.name, "message" => e.message })
        warn "[durable] lane #{@lane} faulted: #{e.class}: #{e.message}\n#{(e.backtrace || []).first(10).join("\n")}"
        { "ok" => false, "outcome" => "faulted",
          "error" => { "code" => "faulted", "message" => "#{e.class}: #{e.message}" } }
      end

      # ── restore: the reduction of §7 ──────────────────────────────────────

      def restore
        records = @session.find_records("lane" => @lane)
        open = nil
        last_run_start = nil
        records.each do |r|
          case r["type"]
          when Records::OPERATION_STARTED
            open = r
            last_run_start = r if r.dig("intent", "kind") == "run"
          when Records::OPERATION_FINISHED
            open = nil if open && r["runId"] == open["id"]
          end
        end

        if open.nil?
          # Idle. The only remaining state is pending next-run queue items.
          after = last_run_start ? records.select { _1["seq"] > last_run_start["seq"] } : records
          after.select { _1["type"] == Records::QUEUE_ENQUEUED && _1["queue"] == "nextRun" }.each do |r|
            next if @session.entry(r["target"]["id"])

            @inbox << { "kind" => "nextRun", "target" => r["target"] }
          end
          @op = nil
          return
        end

        after = records.select { _1["seq"] > open["seq"] }
        entries = own_entries(source_leaf: open["sourceLeafId"])
        newest_entry_seq = entries.last ? entries.last["seq"] : open["seq"]

        op = {
          "id" => open["id"], "kind" => open.dig("intent", "kind"), "intent" => open["intent"],
          "startedAt" => open["timestamp"], "sourceLeafId" => open["sourceLeafId"],
          "aborting" => after.any? { _1["type"] == Records::ABORT_REQUESTED },
          "attempts" => after.count { _1["type"] == Records::TASK_ATTEMPT && _1["seq"] > newest_entry_seq },
          "missingInitialMessages" => (open.dig("intent", "initialMessages") || [])
                                        .reject { @session.entry(_1["id"]) },
          "toolBatch" => nil, "deferred" => nil, "lastError" => nil
        }

        # Deferred handle: the newest own entry is a deferred assistant message.
        newest = entries.last
        if newest && newest["type"] == "message" && newest.dig("message", "stopReason") == "deferred"
          op["deferred"] = newest.dig("message", "deferred")
        end

        # Tool batch: the newest assistant entry with tool calls.
        assistant = entries.reverse.find do |e|
          e["type"] == "message" && e.dig("message", "role") == "assistant" &&
            (e.dig("message", "content") || []).any? { _1["type"] == "toolCall" }
        end
        if assistant
          calls = (assistant.dig("message", "content") || []).select { _1["type"] == "toolCall" }
          answered = entries.select { _1.dig("message", "role") == "toolResult" }
                            .map { _1.dig("message", "toolCallId") }
          started = after.select { _1["type"] == Records::TOOL_STARTED && _1["assistantEntryId"] == assistant["id"] }
          state = calls.map do |c|
            { "toolCall" => c, "started" => started.find { _1["toolCallId"] == c["id"] },
              "resultExists" => answered.include?(c["id"]) }
          end
          op["toolBatch"] = { "assistantEntryId" => assistant["id"], "calls" => state } if state.any? { !_1["resultExists"] }
        end

        # Queue items and deferred writes accepted before the crash.
        after.each do |r|
          case r["type"]
          when Records::QUEUE_ENQUEUED
            next if @session.entry(r["target"]["id"])
            next if r["queue"] != "nextRun" && r["runId"] != op["id"]

            @inbox << { "kind" => r["queue"], "target" => r["target"] }
          when Records::WRITE_DEFERRED
            next if @session.entry(r["target"]["id"])

            @inbox << { "kind" => "write", "target" => r["target"] }
          end
        end
        # Aborting kills conversational intent, keeps facts.
        if op["aborting"]
          @inbox.reject! { %w[steer followUp].include?(_1["kind"]) }
          @abort = true
        end
        @op = op
      end

      def open_operation(record)
        @op = { "id" => record["id"], "kind" => record.dig("intent", "kind"), "intent" => record["intent"],
                "startedAt" => record["timestamp"], "sourceLeafId" => record["sourceLeafId"],
                "aborting" => false, "attempts" => 0,
                "missingInitialMessages" => (record.dig("intent", "initialMessages") || []).dup,
                "toolBatch" => nil, "deferred" => nil, "lastError" => nil }
      end

      # ── helpers ──────────────────────────────────────────────────────────

      def append_if_missing(target)
        existing = target["id"] && @session.entry(target["id"])
        return existing if existing

        entry = @session.append_entry(target)
        if entry["type"] == "message"
          emit("message_end", { "message" => entry["message"], "entryId" => entry["id"] })
        else
          emit("entry_added", { "entry" => entry })
        end
        entry
      rescue Durable::RemoteError => e
        raise AppendFailed, e.message
      end

      def own_entries(source_leaf: nil)
        anchor = source_leaf || (@op && @op["sourceLeafId"])
        leaf = @session.leaf_id
        return [] unless leaf

        path = @session.find_entries_on_branch("start" => leaf, "stopAtId" => anchor, "order" => "newestFirst")
        path = path.reject { _1["id"] == anchor }
        path.reverse
      end

      def newest_own_assistant_id
        own_entries.reverse.find { _1.dig("message", "role") == "assistant" }&.dig("id")
      end

      def newest_own_assistant_aborted?
        e = own_entries.reverse.find { _1.dig("message", "role") == "assistant" }
        e && e.dig("message", "stopReason") == "aborted"
      end

      def unresolved_batch? = !!@op && !!@op["toolBatch"]

      def needs_assistant?
        entries = @session.context_entries
        last = entries.reverse.find { _1["type"] == "message" }
        return true if last.nil?

        %w[user toolResult].include?(last.dig("message", "role"))
      end

      def pending_work?
        @mutex.synchronize { @inbox.any? { %w[steer followUp write].include?(_1["kind"]) } }
      end

      def aborting? = @abort || (@op && @op["aborting"])

      def queues_snapshot
        @mutex.synchronize do
          { "steer" => @inbox.select { _1["kind"] == "steer" }.map { _1.dig("target", "message") },
            "followUp" => @inbox.select { _1["kind"] == "followUp" }.map { _1.dig("target", "message") },
            "nextRun" => @inbox.select { _1["kind"] == "nextRun" }.map { _1.dig("target", "message") } }
        end
      end

      def take_inbox(kind)
        @mutex.synchronize do
          taken = @inbox.select { _1["kind"] == kind }
          @inbox -= taken
          taken
        end
      end

      def context_messages = Context.messages(@session.context_entries)

      def transform_context(messages)
        hook = hook_call("transform_context", { "messages" => messages })
        (hook && hook["messages"]) || messages
      end

      def tool_declarations = Tools.declarations(active_tool_names)

      def active_tool_names
        entry = @session.find_entry_on_branch("type" => "active_tools_change")
        entry ? entry["activeToolNames"] : (@config["activeToolNames"] || Tools.names)
      end

      def effective_thinking
        entry = @session.find_entry_on_branch("type" => "thinking_level_change")
        entry ? entry["thinkingLevel"] : (@config["thinkingLevel"] || "off")
      end

      def effective_model_spec
        entry = @session.find_entry_on_branch("type" => "model_change")
        return { "provider" => entry["provider"], "modelId" => entry["modelId"] } if entry

        { "provider" => @config.dig("model", "provider"), "modelId" => @config.dig("model", "modelId") }
      end

      def effective_model
        spec = effective_model_spec
        base = @config["model"] || {}
        return base if base["provider"] == spec["provider"] && base["modelId"] == spec["modelId"]

        (@config["models"] || []).find { _1["provider"] == spec["provider"] && _1["modelId"] == spec["modelId"] } || base
      end

      def missing_identities
        tools = (@op&.dig("toolBatch", "calls") || []).filter_map do |c|
          name = c.dig("started", "toolName")
          name if name && !Tools.spec(name)
        end
        model = effective_model
        { "tools" => tools.uniq, "models" => model && model["modelId"] ? [] : [effective_model_spec.to_s] }
      end

      # The base prompt is configuration; the goal is branch state, so it is
      # resolved per request and survives compaction with the branch.
      def system_prompt
        base = @config["systemPrompt"].to_s
        goal = current_goal
        return base if goal.nil? || goal.strip.empty?

        "#{base}\n\n<session_goal>\n#{goal.strip}\n</session_goal>\n" \
          "This goal was set by the user for the whole session. Keep it in view; " \
          "if a request conflicts with it, say so."
      end

      def current_goal
        entry = @session.find_entry_on_branch("type" => "custom", "customType" => "goal")
        entry && entry.dig("data", "text")
      end

      def estimated_tokens
        Context.estimate_tokens(context_messages)
      end

      # Prefer what the provider actually charged for: the newest assistant
      # usage on this branch. Fall back to a character estimate.
      def context_tokens
        entry = @session.context_entries.reverse.find do |e|
          e.dig("message", "role") == "assistant" && e.dig("message", "usage") &&
            !%w[error aborted].include?(e.dig("message", "stopReason"))
        end
        usage = entry && entry.dig("message", "usage")
        return estimated_tokens unless usage

        total = usage["input"].to_i + usage["output"].to_i + usage["cacheRead"].to_i + usage["cacheWrite"].to_i
        total.positive? ? total : estimated_tokens
      end

      def context_over_limit?
        cfg = Compaction.settings(@config["compaction"])
        window = effective_model["contextWindow"] || 200_000
        headroom = window - cfg["reserveTokens"].to_i
        context_tokens > [window * cfg["threshold"], headroom].min
      end

      def backoff_delay(attempt)
        base = (@config.dig("retry", "baseMs") || 500) / 1000.0
        [base * (2**(attempt - 1)), 30.0].min
      end

      # Crash injection: the only way to prove the recovery paths is real process
      # death at an exact durable state (§20).
      def crash_check(site)
        c = @config["crashAt"]
        return unless c && c["site"] == site

        sleep((c["delayMs"] || 0) / 1000.0)
        warn "[durable] crash injected at #{site}"
        exit!(9)
      end

      def sleep_interruptible(seconds)
        slept = 0.0
        while slept < seconds
          return if @abort

          sleep 0.1
          slept += 0.1
        end
      end

      # ── hooks and events ─────────────────────────────────────────────────

      def hook_call(name, payload)
        Durable::IPC.call(@host, "hook", { "hook" => name, "lane" => @lane, "payload" => payload })
      rescue Durable::RemoteError => e
        emit("handler_error", { "kind" => "hook", "hook" => name, "error" => e.message })
        name == "before_tool" ? { "block" => { "reason" => "hook failed: #{e.message}" } } : nil
      end

      def emit(type, payload)
        emit_raw(payload.merge("type" => type))
      end

      def emit_raw(event)
        e = event.merge("lane" => @lane)
        e["runId"] ||= @op["id"] if @op
        Durable::IPC.cast(@hub, "emit", e)
        nil
      end

      def on_stream_event(event)
        if event["type"] == "message_update" && (ev = event["event"])
          case ev["type"]
          when "text_delta"
            block = (@stream_message["content"].last if @stream_message["content"].last&.dig("type") == "text")
            if block
              block["text"] += ev["text"]
            else
              @stream_message["content"] << { "type" => "text", "text" => ev["text"].dup }
            end
          end
        end
        emit_raw(event)
      end
    end
  end
end
