# frozen_string_literal: true

require "json"
require "net/http"
require "uri"

module Durable
  module Provider
    # anthropic-messages, streaming. Provider errors are in-band: the returned
    # assistant message carries stopReason "error" and an errorMessage, exactly
    # like harness-v2 expects, so the harness never sees an exception it has to
    # translate into durable state.
    module Anthropic
      RETRYABLE_STATUS = [408, 409, 425, 429, 500, 502, 503, 504, 529].freeze

      module_function

      def stream(model:, messages:, system: nil, tools: [], thinking: nil, max_tokens: nil,
                 abort_check: nil, timeout: 600, &on_event)
        body = {
          "model" => model["modelId"],
          "max_tokens" => max_tokens || model["maxTokens"] || 8192,
          "messages" => to_provider_messages(messages),
          "stream" => true
        }
        if system && !system.empty?
          # Cache breakpoints: the system prompt never changes within a run, and
          # the message tail is the longest stable prefix of the next request.
          body["system"] = [{ "type" => "text", "text" => system,
                              "cache_control" => { "type" => "ephemeral" } }]
        end
        unless tools.empty?
          schemas = tools.map { tool_schema(_1) }
          schemas.last["cache_control"] = { "type" => "ephemeral" }
          body["tools"] = schemas
        end
        mark_cache_breakpoint(body["messages"])
        if thinking && thinking != "off" && model["reasoning"]
          budget = { "low" => 4000, "medium" => 10_000, "high" => 24_000 }[thinking] || 10_000
          budget = [budget, body["max_tokens"] - 1024].min
          body["thinking"] = { "type" => "enabled", "budget_tokens" => budget } if budget >= 1024
        end

        uri = URI.join("#{model["baseUrl"].chomp("/")}/", "v1/messages")
        http = Net::HTTP.new(uri.host, uri.port)
        http.use_ssl = uri.scheme == "https"
        http.read_timeout = timeout
        req = Net::HTTP::Post.new(uri)
        req["content-type"] = "application/json"
        req["accept"] = "text/event-stream"
        req["anthropic-version"] = "2023-06-01"
        req["x-api-key"] = model["apiKey"].to_s
        req.body = JSON.generate(body)

        acc = Accumulator.new(model)
        Durable::Provider.run_abortable(abort_check, acc) do
          perform(http, req, acc, abort_check, &on_event)
        end
      end

      # The blocking part, so it can be run in a killable thread.
      def perform(http, req, acc, abort_check, &on_event)
        begin
          http.request(req) do |res|
            unless res.code.to_i == 200
              text = res.read_body.to_s[0, 2000]
              return acc.error("HTTP #{res.code}: #{text}", retryable: RETRYABLE_STATUS.include?(res.code.to_i))
            end
            buffer = +""
            res.read_body do |chunk|
              if abort_check&.call
                return acc.aborted
              end

              buffer << chunk
              while (idx = buffer.index("\n\n"))
                block = buffer.slice!(0, idx + 2)
                event = parse_sse(block) or next
                acc.handle(event, &on_event)
              end
            end
          end
        rescue Net::OpenTimeout, Net::ReadTimeout, Errno::ECONNRESET, Errno::ECONNREFUSED,
               EOFError, SocketError, IOError => e
          return acc.error("#{e.class}: #{e.message}", retryable: true)
        rescue StandardError => e
          return acc.error("#{e.class}: #{e.message}", retryable: false)
        end
        acc.finish
      end

      # One breakpoint on the newest message: everything before it is the
      # prefix the next request will reuse.
      def mark_cache_breakpoint(messages)
        last = messages.last or return

        block = last["content"].is_a?(Array) ? last["content"].last : nil
        block["cache_control"] = { "type" => "ephemeral" } if block.is_a?(Hash)
      end

      def parse_sse(block)
        data = block.lines.filter_map { |l| l.start_with?("data:") ? l[5..].strip : nil }.join
        return nil if data.empty? || data == "[DONE]"

        JSON.parse(data)
      rescue JSON::ParserError
        nil
      end

      def tool_schema(tool)
        { "name" => tool["name"], "description" => tool["description"].to_s,
          "input_schema" => tool["parameters"] || { "type" => "object", "properties" => {} } }
      end

      # AgentMessage[] → anthropic messages. Adjacent tool results merge into
      # one user message; deferred assistant messages project to nothing.
      def to_provider_messages(messages)
        out = []
        messages.each do |m|
          case m["role"]
          when "user"
            out << { "role" => "user", "content" => content_blocks(m["content"]) }
          when "assistant"
            next if m["stopReason"] == "deferred"

            blocks = []
            (m["content"] || []).each do |c|
              case c["type"]
              when "text"
                blocks << { "type" => "text", "text" => c["text"] } unless c["text"].to_s.empty?
              when "thinking"
                blocks << { "type" => "thinking", "thinking" => c["thinking"], "signature" => c["signature"] } if c["signature"]
              when "toolCall"
                blocks << { "type" => "tool_use", "id" => c["id"], "name" => c["name"],
                            "input" => c["arguments"] || {} }
              end
            end
            next if blocks.empty?

            out << { "role" => "assistant", "content" => blocks }
          when "toolResult"
            block = { "type" => "tool_result", "tool_use_id" => m["toolCallId"],
                      "content" => content_blocks(m["content"]) }
            block["is_error"] = true if m["isError"]
            if out.last && out.last["role"] == "user" && out.last["content"].all? { _1["type"] == "tool_result" }
              out.last["content"] << block
            else
              out << { "role" => "user", "content" => [block] }
            end
          end
        end
        heal(out)
      end

      # Orphaned tool calls get synthetic results at request build time, so a
      # transcript whose tip sits mid-batch is still promptable (§17).
      def heal(msgs)
        msgs.each_with_index do |m, i|
          next unless m["role"] == "assistant"

          ids = m["content"].select { _1["type"] == "tool_use" }.map { _1["id"] }
          next if ids.empty?

          answered = (msgs[i + 1] && msgs[i + 1]["role"] == "user" ? msgs[i + 1]["content"] : [])
                     .select { _1["type"] == "tool_result" }.map { _1["tool_use_id"] }
          missing = ids - answered
          next if missing.empty?

          synth = missing.map do |id|
            { "type" => "tool_result", "tool_use_id" => id,
              "content" => [{ "type" => "text", "text" => "Interrupted." }], "is_error" => true }
          end
          if msgs[i + 1] && msgs[i + 1]["role"] == "user"
            msgs[i + 1]["content"] = synth + msgs[i + 1]["content"]
          else
            msgs.insert(i + 1, { "role" => "user", "content" => synth })
          end
        end
        msgs
      end

      def content_blocks(content)
        return [{ "type" => "text", "text" => content.to_s }] if content.is_a?(String)

        (content || []).filter_map do |c|
          case c["type"]
          when "text" then { "type" => "text", "text" => c["text"].to_s }
          when "image"
            { "type" => "image",
              "source" => { "type" => "base64", "media_type" => c["mimeType"] || "image/png", "data" => c["data"] } }
          end
        end.then { _1.empty? ? [{ "type" => "text", "text" => "" }] : _1 }
      end

      # Accumulates SSE deltas into one AssistantMessage.
      class Accumulator
        STOP = { "end_turn" => "stop", "stop_sequence" => "stop", "max_tokens" => "length",
                 "tool_use" => "toolUse", "pause_turn" => "stop", "refusal" => "stop" }.freeze

        def initialize(model)
          @model = model
          @content = []
          @stop_reason = "stop"
          @usage = { "input" => 0, "output" => 0, "cacheRead" => 0, "cacheWrite" => 0 }
          @partial = {}
        end

        def handle(event)
          case event["type"]
          when "message_start"
            u = event.dig("message", "usage") || {}
            merge_usage(u)
          when "content_block_start"
            b = event["content_block"]
            idx = event["index"]
            case b["type"]
            when "text" then @partial[idx] = { "type" => "text", "text" => +"" }
            when "thinking" then @partial[idx] = { "type" => "thinking", "thinking" => +"", "signature" => nil }
            when "tool_use"
              @partial[idx] = { "type" => "toolCall", "id" => b["id"], "name" => b["name"],
                                "arguments" => {}, "_json" => +"" }
              yield({ "type" => "tool_call_start", "name" => b["name"], "id" => b["id"] }) if block_given?
            end
          when "content_block_delta"
            idx = event["index"]
            d = event["delta"]
            part = @partial[idx] or return
            case d["type"]
            when "text_delta"
              part["text"] << d["text"]
              yield({ "type" => "text_delta", "text" => d["text"] }) if block_given?
            when "thinking_delta"
              part["thinking"] << d["thinking"]
              yield({ "type" => "thinking_delta", "text" => d["thinking"] }) if block_given?
            when "signature_delta"
              part["signature"] = (part["signature"] || +"") + d["signature"]
            when "input_json_delta"
              part["_json"] << d["partial_json"]
              yield({ "type" => "tool_args_delta", "id" => part["id"], "text" => d["partial_json"] }) if block_given?
            end
          when "content_block_stop"
            part = @partial.delete(event["index"]) or return
            if part["type"] == "toolCall"
              json = part.delete("_json")
              part["arguments"] = (JSON.parse(json) rescue {}) unless json.to_s.empty?
            end
            @content << part
          when "message_delta"
            @stop_reason = STOP[event.dig("delta", "stop_reason")] || @stop_reason
            merge_usage(event["usage"] || {})
          when "error"
            @error = event.dig("error", "message") || "provider error"
            @retryable = true
          end
        end

        # "input" is the *total* prompt size, with cacheRead/cacheWrite as
        # subsets of it — anthropic reports uncached input, so add them back.
        # Every consumer can then compute a hit rate the same way.
        def merge_usage(u)
          read = u["cache_read_input_tokens"].to_i
          write = u["cache_creation_input_tokens"].to_i
          @usage["input"] += u["input_tokens"].to_i + read + write
          @usage["output"] += u["output_tokens"].to_i
          @usage["cacheRead"] += read
          @usage["cacheWrite"] += write
        end

        def base
          { "role" => "assistant", "content" => @content, "usage" => @usage,
            "provider" => @model["provider"], "model" => @model["modelId"], "timestamp" => Durable::Ids.now_ms }
        end

        def finish
          return error(@error, retryable: @retryable) if @error

          @content.each { |c| c.delete("_json") }
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
