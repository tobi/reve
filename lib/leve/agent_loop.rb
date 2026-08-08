# frozen_string_literal: true

require_relative "provider"
require_relative "tools"
require_relative "records"

module Leve
  # The building blocks of harness-v2 §14. They own no durable state and know
  # nothing about sessions, records or lanes. The harness composes them and
  # inserts its durability writes between their phases.
  module AgentLoop
    module_function

    # One provider request. Emits streaming events through `emit`; returns the
    # final assistant message. Provider errors are in-band (stopReason
    # "error" | "aborted"). Does not persist anything.
    def stream_assistant(messages, config, emit = nil)
      ctx = config[:transform_context] ? config[:transform_context].call(messages) : messages
      emit&.call({ "type" => "message_start", "message" => { "role" => "assistant", "content" => [] } })
      final = Provider.stream(
        model: config[:model],
        messages: ctx,
        system: config[:system_prompt],
        tools: config[:tools] || [],
        thinking: config[:thinking_level],
        max_tokens: config[:max_tokens],
        abort_check: config[:abort_check]
      ) do |ev|
        emit&.call({ "type" => "message_update", "event" => ev })
      end
      final
    end

    def tool_calls(assistant)
      (assistant["content"] || []).select { _1["type"] == "toolCall" }
    end

    # Phase 1 — clearance. Tool lookup, validation, before_tool (may block),
    # abort checks. No effect starts here.
    #
    # `active` maps tool name => declaration. A declaration whose "runner" is
    # "host" is a project tool: its body is a Ruby block, so it cannot run in a
    # tool Ractor and is dispatched back to the host instead.
    def prepare_tool_call(call, active, callbacks, abort_check = nil)
      name = call["name"]
      declaration = active[name]
      return immediate(call, "Aborted before execution.") if abort_check&.call
      return immediate(call, "unknown tool: #{name}") unless declaration

      args = call["arguments"] || {}
      if (err = validate(declaration, args))
        return immediate(call, err)
      end

      hook = callbacks[:before_tool]&.call(call, args)
      if hook && hook["block"]
        return immediate(call, "blocked: #{hook.dig("block", "reason")}")
      end

      args = hook["args"] if hook && hook["args"]
      { kind: "prepared", call: call, name: name, args: args,
        replay: declaration["replay"] || "never", runner: declaration["runner"] || "ractor" }
    end

    def validate(declaration, args)
      missing = (declaration.dig("parameters", "required") || []) - args.keys
      return nil if missing.empty?

      "missing required argument(s): #{missing.join(", ")}"
    end

    def immediate(call, text)
      { kind: "immediate", call: call,
        result: { "content" => [{ "type" => "text", "text" => text }], "isError" => true } }
    end

    # Phase 2 — the effect, in its own Ractor. Abort signals the tool rather
    # than waiting it out: a `sleep 60` must not hold a run open for a minute.
    def execute_tool_call(prepared, cwd, emit = nil, abort_check = nil, remote: nil, cancel_remote: nil)
      emit&.call({ "type" => "tool_start", "toolCallId" => prepared[:call]["id"],
                   "toolName" => prepared[:name], "args" => prepared[:args] })
      id = prepared[:call]["id"]
      if prepared[:runner] == "host"
        thread = Thread.new { remote.call(prepared[:name], prepared[:args], id) }
        raw = await_host_tools({ id => thread }, abort_check, cancel_remote).values.first
        return { "content" => raw["content"], "isError" => !!raw["isError"], "details" => raw["details"] }
      end

      ractor = Tools.spawn(prepared[:name], prepared[:args], cwd)
      result = await_tools({ id => ractor }, abort_check).values.first
      { "content" => result["content"], "isError" => !!result["isError"], "details" => result["details"] }
    end

    # Wait for tool Ractors, cancelling them once if the run is aborting.
    def await_tools(ractors, abort_check)
      threads = ractors.transform_values { |r| Thread.new { IPC.decode(r.value) } }
      cancelled = false
      until threads.each_value.none?(&:alive?)
        if !cancelled && abort_check&.call
          ractors.each_value { Tools.cancel(_1) }
          cancelled = true
        end
        sleep 0.05
      end
      threads.transform_values do |t|
        t.value
      rescue Ractor::RemoteError => e
        { "content" => [{ "type" => "text", "text" => "tool ractor failed: #{e.cause&.message || e.message}" }],
          "isError" => true }
      end
    end

    def await_host_tools(threads, abort_check, cancel_remote)
      cancelled = false
      until threads.each_value.none?(&:alive?)
        if !cancelled && abort_check&.call
          threads.each_key { cancel_remote&.call(_1) }
          cancelled = true
        end
        sleep 0.05
      end
      threads.transform_values(&:value)
    end

    # Phase 3 — after_tool patch, field by field.
    def finalize_tool_call(prepared, executed, callbacks)
      patch = begin
        callbacks[:after_tool]&.call(prepared, executed)
      rescue StandardError => e
        { "content" => [{ "type" => "text", "text" => "after_tool failed: #{e.message}" }], "isError" => true }
      end
      result = executed.dup
      if patch
        result["content"] = patch["content"] if patch["content"]
        result["details"] = patch["details"] if patch["details"]
        result["isError"] = patch["isError"] unless patch["isError"].nil?
        result["terminate"] = true if patch["terminate"]
      end
      result
    end

    def tool_result_message(prepared_or_immediate, result)
      call = prepared_or_immediate[:call]
      Records.tool_result_message(tool_call_id: call["id"], tool_name: call["name"],
                                  content: result["content"] || [], is_error: !!result["isError"],
                                  details: result["details"])
    end

    # The batch driver. Rules preserved from the reference loop:
    #  - stopReason "length" fails every call without executing (streamed
    #    arguments may validate while silently truncated);
    #  - sequential when requested, else parallel;
    #  - phase 1 and on_tool_start run sequentially in source order, so a crash
    #    mid-batch leaves a source-order prefix of records;
    #  - phase 3, on_tool_result and message emission happen in source order;
    #  - abort: no further calls are prepared, running ones settle.
    def execute_tool_batch(assistant, active, callbacks, options, emit = nil, abort_check = nil)
      calls = tool_calls(assistant)
      return { messages: [], terminate: false } if calls.empty?

      cwd = options[:cwd] || Dir.pwd

      if assistant["stopReason"] == "length"
        messages = calls.map do |c|
          imm = immediate(c, "Tool call arguments were truncated by the context limit; not executed.")
          msg = tool_result_message(imm, imm[:result])
          callbacks[:on_tool_result]&.call(msg, nil)
          msg
        end
        return { messages: messages, terminate: false }
      end

      prepared = calls.map do |c|
        p = prepare_tool_call(c, active, callbacks, abort_check)
        if p[:kind] == "prepared"
          # The durability point: the harness writes tool_started here.
          callbacks[:on_tool_start]&.call(p)
        end
        p
      end

      sequential = options[:tool_execution] == "sequential"
      executed = {}
      if sequential
        prepared.each do |p|
          executed[p[:call]["id"]] =
            if p[:kind] == "prepared"
              execute_tool_call(p, cwd, emit, abort_check, remote: options[:remote],
                                                         cancel_remote: options[:cancel_remote])
            else
              p[:result]
            end
        end
      else
        ractors = {}
        host_threads = {}
        prepared.each do |p|
          next unless p[:kind] == "prepared"

          if p[:runner] == "host"
            emit&.call({ "type" => "tool_start", "toolCallId" => p[:call]["id"],
                         "toolName" => p[:name], "args" => p[:args] })
            id = p[:call]["id"]
            host_threads[id] = Thread.new { options[:remote].call(p[:name], p[:args], id) }
            next
          end

          emit&.call({ "type" => "tool_start", "toolCallId" => p[:call]["id"],
                       "toolName" => p[:name], "args" => p[:args] })
          ractors[p[:call]["id"]] = Tools.spawn(p[:name], p[:args], cwd)
        end
        raw_results = await_tools(ractors, abort_check)
        raw_results.merge!(await_host_tools(host_threads, abort_check, options[:cancel_remote]))
        prepared.each do |p|
          executed[p[:call]["id"]] =
            if p[:kind] == "prepared"
              raw = raw_results[p[:call]["id"]]
              { "content" => raw["content"], "isError" => !!raw["isError"], "details" => raw["details"] }
            else
              p[:result]
            end
        end
      end

      terminate = !prepared.empty?
      messages = prepared.map do |p|
        result = p[:kind] == "prepared" ? finalize_tool_call(p, executed[p[:call]["id"]], callbacks) : p[:result]
        terminate = false unless result["terminate"]
        msg = tool_result_message(p, result)
        emit&.call({ "type" => "tool_end", "toolCallId" => p[:call]["id"], "toolName" => p[:call]["name"],
                     "result" => result, "isError" => !!result["isError"] })
        callbacks[:on_tool_result]&.call(msg, p)
        msg
      end
      { messages: messages, terminate: terminate }
    end
  end
end
