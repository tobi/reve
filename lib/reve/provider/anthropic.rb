# frozen_string_literal: true

require_relative "http"
require_relative "usage"
require_relative "thinking"
require_relative "messages"

module Reve
  module Provider
    # anthropic-messages, streaming.
    #
    # Provider errors are in-band: the returned assistant message carries
    # stopReason "error" and an errorMessage, exactly like harness-v2 expects,
    # so the harness never sees an exception it has to translate into durable
    # state.
    #
    # Advanced features, all on by default when the model declares support:
    #
    #   prompt caching     breakpoints on the system prompt, the tool list and
    #                      the newest message — the three prefixes that are
    #                      stable between consecutive requests in a run
    #   extended thinking  budget from the lane's thinking level; signed
    #                      thinking blocks are replayed verbatim, which is what
    #                      lets the model resume its own reasoning across tool
    #                      calls instead of restarting it
    #   interleaved        thinking between tool calls within one turn
    #
    # Per-model quirks come from the `compat` block of models.yml:
    #
    #   cacheTtl     "5m" (default) or "1h"
    #   betas        extra anthropic-beta values, e.g. context-1m-2025-08-07
    #   interleaved  false to disable interleaved thinking
    module Anthropic
      VERSION = "2023-06-01"
      INTERLEAVED_BETA = "interleaved-thinking-2025-05-14"
      LONG_CACHE_BETA = "extended-cache-ttl-2025-04-11"

      # Anthropic's stop reasons → the harness's four.
      STOP = { "end_turn" => "stop", "stop_sequence" => "stop", "max_tokens" => "length",
               "tool_use" => "toolUse", "pause_turn" => "stop", "refusal" => "stop",
               "model_context_window_exceeded" => "length" }.freeze

      module_function

      def stream(model:, messages:, system: nil, tools: [], thinking: nil, max_tokens: nil,
                 abort_check: nil, timeout: 600, &on_event)
        HTTP.stream_json(url: HTTP.endpoint(model, "v1/messages"),
                         headers: headers(model, tools, thinking),
                         body: request_body(model, messages, system, tools, thinking, max_tokens),
                         acc: Accumulator.new(model), timeout: timeout, model: model,
                         abort_check: abort_check, &on_event)
      end

      def request_body(model, messages, system, tools, thinking, max_tokens)
        cap = max_tokens || model["maxTokens"] || 8192
        body = { "model" => model["modelId"], "max_tokens" => cap, "stream" => true,
                 "messages" => to_provider_messages(messages, model) }
        if system && !system.empty?
          body["system"] = [cached({ "type" => "text", "text" => system }, model)]
        end
        unless tools.empty?
          schemas = tools.map { tool_schema(_1) }
          # One breakpoint after the last tool: the whole declaration list is a
          # single stable prefix.
          schemas[-1] = cached(schemas[-1], model)
          body["tools"] = schemas
        end
        if (budget = Thinking.budget(model, thinking, cap))
          body["thinking"] = { "type" => "enabled", "budget_tokens" => budget }
          # Extended thinking rejects a sampling temperature.
          body.delete("temperature")
        end
        body
      end

      def headers(model, tools, thinking)
        h = { "anthropic-version" => VERSION, "x-api-key" => model["apiKey"].to_s,
              "anthropic-beta" => betas(model, tools, thinking).join(",") }
        # A user-set header from models.yml wins over the defaults above.
        h.merge(model["headers"] || {})
      end

      def betas(model, tools, thinking)
        list = Array(model.dig("compat", "betas")).map(&:to_s)
        list << LONG_CACHE_BETA if cache_ttl(model) != "5m"
        if !tools.empty? && !Thinking.off?(model, thinking) && model.dig("compat", "interleaved") != false
          list << INTERLEAVED_BETA
        end
        list.uniq
      end

      def cacheable?(model) = model.dig("compat", "caching") != false

      def cache_ttl(model) = model.dig("compat", "cacheTtl") || "5m"

      def cached(block, model)
        return block unless cacheable?(model)

        ttl = cache_ttl(model)
        control = { "type" => "ephemeral" }
        control["ttl"] = ttl unless ttl == "5m"
        block.merge("cache_control" => control)
      end

      def tool_schema(tool)
        { "name" => tool["name"], "description" => tool["description"].to_s,
          "input_schema" => tool["parameters"] || { "type" => "object", "properties" => {} } }
      end

      # AgentMessage[] → anthropic messages. Adjacent tool results merge into
      # one user message; deferred assistant messages project to nothing.
      def to_provider_messages(messages, model = nil)
        out = []
        messages.each do |m|
          case m["role"]
          when "user"
            out << { "role" => "user", "content" => content_blocks(m["content"]) }
          when "assistant"
            next unless Messages.projects?(m)

            blocks = assistant_blocks(m)
            out << { "role" => "assistant", "content" => blocks } unless blocks.empty?
          when "toolResult"
            append_tool_result(out, m)
          end
        end
        heal(out)
        mark_cache_breakpoint(out, model) if model && cacheable?(model)
        out
      end

      # Thinking first, always: anthropic requires the signed blocks of a turn
      # to precede its text and tool_use blocks, in their original order.
      def assistant_blocks(message)
        Messages.blocks(message).filter_map do |c|
          case c["type"]
          when "text"
            { "type" => "text", "text" => c["text"] } unless c["text"].to_s.empty?
          when "thinking"
            if c["redactedData"]
              { "type" => "redacted_thinking", "data" => c["redactedData"] }
            elsif !c["signature"].to_s.empty?
              { "type" => "thinking", "thinking" => c["thinking"].to_s, "signature" => c["signature"] }
            end
          when "toolCall"
            { "type" => "tool_use", "id" => c["id"], "name" => c["name"], "input" => c["arguments"] || {} }
          end
        end
      end

      def append_tool_result(out, message)
        block = { "type" => "tool_result", "tool_use_id" => message["toolCallId"],
                  "content" => content_blocks(message["content"]) }
        block["is_error"] = true if message["isError"]
        last = out.last
        if last && last["role"] == "user" && last["content"].all? { _1["type"] == "tool_result" }
          last["content"] << block
        else
          out << { "role" => "user", "content" => [block] }
        end
      end

      # Orphaned tool calls get synthetic results at request build time, so a
      # transcript whose tip sits mid-batch is still promptable (§17).
      def heal(msgs)
        msgs.each_with_index do |m, i|
          next unless m["role"] == "assistant"

          ids = m["content"].select { _1["type"] == "tool_use" }.map { _1["id"] }
          next if ids.empty?

          nxt = msgs[i + 1]
          answered = (nxt && nxt["role"] == "user" ? nxt["content"] : [])
                     .select { _1["type"] == "tool_result" }.map { _1["tool_use_id"] }
          missing = ids - answered
          next if missing.empty?

          synth = missing.map do |id|
            { "type" => "tool_result", "tool_use_id" => id, "is_error" => true,
              "content" => [{ "type" => "text", "text" => Messages::INTERRUPTED }] }
          end
          if nxt && nxt["role"] == "user"
            nxt["content"] = synth + nxt["content"]
          else
            msgs.insert(i + 1, { "role" => "user", "content" => synth })
          end
        end
        msgs
      end

      # One breakpoint on the newest message: everything before it is the
      # prefix the next request will reuse.
      def mark_cache_breakpoint(messages, model = {})
        last = messages.last or return messages

        blocks = last["content"]
        blocks[-1] = cached(blocks[-1], model) if blocks.is_a?(Array) && blocks.last.is_a?(Hash)
        messages
      end

      def content_blocks(content)
        return [{ "type" => "text", "text" => content.to_s }] if content.is_a?(String)

        blocks = (content || []).filter_map do |c|
          case c["type"]
          when "text" then { "type" => "text", "text" => c["text"].to_s }
          when "image"
            { "type" => "image",
              "source" => { "type" => "base64", "media_type" => c["mimeType"] || "image/png",
                            "data" => c["data"] } }
          end
        end
        blocks.empty? ? [{ "type" => "text", "text" => "" }] : blocks
      end

      # Accumulates SSE deltas into one AssistantMessage.
      class Accumulator
        def initialize(model)
          @model = model
          @content = []
          @partial = {}
          @stop_reason = "stop"
          @usage = Usage.new
        end

        def handle(event, &emit)
          case event["type"]
          when "message_start" then merge_usage(event.dig("message", "usage") || {})
          when "content_block_start" then open_block(event, &emit)
          when "content_block_delta" then delta(event, &emit)
          when "content_block_stop" then close_block(event)
          when "message_delta"
            @stop_reason = STOP[event.dig("delta", "stop_reason")] || @stop_reason
            merge_usage(event["usage"] || {})
          when "error"
            @error = event.dig("error", "message") || "provider error"
            @retryable = true
          end
        end

        def open_block(event)
          b = event["content_block"]
          case b["type"]
          when "text"
            @partial[event["index"]] = { "type" => "text", "text" => +"" }
          when "thinking"
            @partial[event["index"]] = { "type" => "thinking", "thinking" => +"", "signature" => nil }
          when "redacted_thinking"
            # Encrypted by the provider and opaque to us; it must still be
            # replayed or the turn it belongs to is incomplete.
            @content << { "type" => "thinking", "thinking" => "", "redactedData" => b["data"] }
          when "tool_use"
            @partial[event["index"]] = { "type" => "toolCall", "id" => b["id"], "name" => b["name"],
                                         "arguments" => {}, "_json" => +"" }
            yield({ "type" => "tool_call_start", "name" => b["name"], "id" => b["id"] }) if block_given?
          end
        end

        def delta(event)
          part = @partial[event["index"]] or return

          d = event["delta"]
          case d["type"]
          when "text_delta"
            part["text"] << d["text"]
            yield({ "type" => "text_delta", "text" => d["text"] }) if block_given?
          when "thinking_delta"
            part["thinking"] << d["thinking"]
            yield({ "type" => "thinking_delta", "text" => d["thinking"] }) if block_given?
          when "signature_delta"
            part["signature"] = "#{part["signature"]}#{d["signature"]}"
          when "input_json_delta"
            part["_json"] << d["partial_json"]
            yield({ "type" => "tool_args_delta", "id" => part["id"], "text" => d["partial_json"] }) if block_given?
          end
        end

        def close_block(event)
          part = @partial.delete(event["index"]) or return

          if part["type"] == "toolCall"
            json = part.delete("_json").to_s
            part["arguments"] = json.empty? ? {} : (JSON.parse(json) rescue {})
          end
          @content << part
        end

        # Anthropic reports *uncached* input with the cache counts beside it;
        # our shape is inclusive, so add them back. Every consumer can then
        # compute a hit rate the same way on every provider.
        def merge_usage(u)
          read = u["cache_read_input_tokens"].to_i
          write = u["cache_creation_input_tokens"].to_i
          @usage.add(input: u["input_tokens"].to_i + read + write, output: u["output_tokens"],
                     cache_read: read, cache_write: write)
        end

        def base
          { "role" => "assistant", "content" => @content, "usage" => @usage.to_h,
            "provider" => @model["provider"], "model" => @model["modelId"],
            "timestamp" => Reve::Ids.now_ms }
        end

        def finish
          return error(@error, retryable: @retryable) if @error

          @content.each { _1.delete("_json") }
          base.merge("stopReason" => @stop_reason)
        end

        def error(message, retryable:)
          base.merge("stopReason" => "error", "errorMessage" => message, "retryable" => retryable)
        end

        def aborted = base.merge("stopReason" => "aborted")
      end
    end
  end
end
