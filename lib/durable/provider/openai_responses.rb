# frozen_string_literal: true

require "json"
require "net/http"
require "uri"

module Durable
  module Provider
    # openai-responses, streaming. Written against the shape vLLM serves at
    # /v1/responses, which is also what OpenAI serves — the differences live in
    # the model's `compat` block (from models.yml), not in the code:
    #
    #   supportsStore            send "store": false explicitly
    #   supportsDeveloperRole    system prompt as a developer message vs "instructions"
    #   supportsReasoningEffort  send "reasoning": { effort }
    #   supportsUsageInStreaming (informational: we take usage where we find it)
    #   maxTokensField           "max_output_tokens" or "max_tokens"
    module OpenAIResponses
      RETRYABLE_STATUS = [408, 409, 425, 429, 500, 502, 503, 504, 529].freeze

      module_function

      def stream(model:, messages:, system: nil, tools: [], thinking: nil, max_tokens: nil,
                 abort_check: nil, timeout: 900, &on_event)
        compat = model["compat"] || {}
        body = {
          "model" => model["modelId"],
          "input" => to_input(messages),
          "stream" => true
        }
        body[compat["maxTokensField"] || "max_output_tokens"] = max_tokens || model["maxTokens"] || 8192
        body["store"] = false if compat["supportsStore"]
        if system && !system.empty?
          if compat["supportsDeveloperRole"]
            body["input"].unshift({ "role" => "developer",
                                    "content" => [{ "type" => "input_text", "text" => system }] })
          else
            body["instructions"] = system
          end
        end
        unless tools.empty?
          body["tools"] = tools.map do |t|
            { "type" => "function", "name" => t["name"], "description" => t["description"].to_s,
              "parameters" => t["parameters"] || { "type" => "object", "properties" => {} } }
          end
        end
        if compat["supportsReasoningEffort"] && model["reasoning"] && thinking && thinking != "off"
          body["reasoning"] = { "effort" => thinking }
        end

        uri = URI("#{model["baseUrl"].to_s.chomp("/")}/responses")
        http = Net::HTTP.new(uri.host, uri.port)
        http.use_ssl = uri.scheme == "https"
        http.read_timeout = timeout
        req = Net::HTTP::Post.new(uri)
        req["content-type"] = "application/json"
        req["accept"] = "text/event-stream"
        key = model["apiKey"].to_s
        req["authorization"] = "Bearer #{key}" unless key.empty?
        (model["headers"] || {}).each { |k, v| req[k] = v }
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
              return acc.aborted if abort_check&.call

              buffer << chunk
              while (idx = buffer.index("\n\n"))
                block = buffer.slice!(0, idx + 2)
                event = parse_sse(block) or next

                acc.handle(event, &on_event)
              end
            end
          end
        rescue Net::OpenTimeout, Net::ReadTimeout, Errno::ECONNRESET, Errno::ECONNREFUSED,
               Errno::EHOSTUNREACH, EOFError, SocketError, IOError => e
          return acc.error("#{e.class}: #{e.message}", retryable: true)
        rescue StandardError => e
          return acc.error("#{e.class}: #{e.message}", retryable: false)
        end
        acc.finish
      end

      def parse_sse(block)
        data = block.lines.filter_map { |l| l.start_with?("data:") ? l[5..].strip : nil }.join
        return nil if data.empty? || data == "[DONE]"

        JSON.parse(data)
      rescue JSON::ParserError
        nil
      end

      # AgentMessage[] → Responses input items.
      def to_input(messages)
        out = []
        messages.each do |m|
          case m["role"]
          when "user"
            out << { "role" => "user", "content" => input_content(m["content"]) }
          when "assistant"
            next if m["stopReason"] == "deferred"

            text = (m["content"] || []).select { _1["type"] == "text" }.map { _1["text"] }.join
            # Assistant history goes in as a plain string: an input message may
            # only carry input_* content parts, and output_text there is a
            # validation error on strict servers (vLLM is one).
            out << { "role" => "assistant", "content" => text } unless text.strip.empty?
            (m["content"] || []).each do |c|
              next unless c["type"] == "toolCall"

              out << { "type" => "function_call", "call_id" => c["id"], "name" => c["name"],
                       "arguments" => JSON.generate(c["arguments"] || {}) }
            end
          when "toolResult"
            text = (m["content"] || []).select { _1["type"] == "text" }.map { _1["text"] }.join
            out << { "type" => "function_call_output", "call_id" => m["toolCallId"],
                     "output" => text.empty? ? "(no output)" : text }
          end
        end
        heal(out)
      end

      # Orphaned tool calls get synthetic outputs, so a transcript whose tip
      # sits mid-batch is still promptable.
      def heal(items)
        answered = items.select { _1["type"] == "function_call_output" }.map { _1["call_id"] }
        out = []
        items.each do |item|
          out << item
          next unless item["type"] == "function_call" && !answered.include?(item["call_id"])

          out << { "type" => "function_call_output", "call_id" => item["call_id"], "output" => "Interrupted." }
        end
        out
      end

      def input_content(content)
        return [{ "type" => "input_text", "text" => content.to_s }] if content.is_a?(String)

        blocks = (content || []).filter_map do |c|
          case c["type"]
          when "text" then { "type" => "input_text", "text" => c["text"].to_s }
          when "image"
            { "type" => "input_image",
              "image_url" => "data:#{c["mimeType"] || "image/png"};base64,#{c["data"]}" }
          end
        end
        blocks.empty? ? [{ "type" => "input_text", "text" => "" }] : blocks
      end

      class Accumulator
        def initialize(model)
          @model = model
          @text = +""
          @thinking = +""
          @calls = {}      # item_id => {id, name, args}
          @order = []
          @usage = { "input" => 0, "output" => 0, "cacheRead" => 0, "cacheWrite" => 0 }
          @stop = nil
        end

        def handle(event)
          case event["type"]
          when "response.output_text.delta"
            @text << event["delta"].to_s
            yield({ "type" => "text_delta", "text" => event["delta"].to_s }) if block_given?
          when "response.reasoning_text.delta", "response.reasoning_summary_text.delta"
            @thinking << event["delta"].to_s
            yield({ "type" => "thinking_delta", "text" => event["delta"].to_s }) if block_given?
          when "response.output_item.added"
            item = event["item"] or return
            return unless item["type"] == "function_call"

            @order << item["id"]
            @calls[item["id"]] = { "id" => item["call_id"] || item["id"], "name" => item["name"], "args" => +"" }
            yield({ "type" => "tool_call_start", "id" => item["call_id"], "name" => item["name"] }) if block_given?
          when "response.function_call_arguments.delta"
            call = @calls[event["item_id"]] or return
            call["args"] << event["delta"].to_s
            yield({ "type" => "tool_args_delta", "id" => call["id"], "text" => event["delta"].to_s }) if block_given?
          when "response.function_call_arguments.done"
            call = @calls[event["item_id"]] or return
            call["args"] = event["arguments"].to_s unless event["arguments"].nil?
          when "response.output_item.done"
            item = event["item"] or return
            if item["type"] == "function_call"
              call = @calls[item["id"]] ||= { "id" => item["call_id"], "name" => item["name"], "args" => +"" }
              call["args"] = item["arguments"].to_s if item["arguments"]
              call["id"] = item["call_id"] if item["call_id"]
              @order << item["id"] unless @order.include?(item["id"])
            elsif item["type"] == "message" && @text.empty?
              (item["content"] || []).each { @text << _1["text"].to_s if _1["type"] == "output_text" }
            end
          when "response.completed", "response.incomplete", "response.failed"
            resp = event["response"] || {}
            merge_usage(resp["usage"] || {})
            case resp["status"]
            when "incomplete"
              @stop = resp.dig("incomplete_details", "reason") == "max_output_tokens" ? "length" : "stop"
            when "failed"
              @error = resp.dig("error", "message") || "response failed"
            end
          when "error"
            @error = event["message"] || event.dig("error", "message") || "provider error"
            @retryable = true
          end
        end

        def merge_usage(u)
          @usage["input"] += u["input_tokens"].to_i
          @usage["output"] += u["output_tokens"].to_i
          @usage["cacheRead"] += u.dig("input_tokens_details", "cached_tokens").to_i
        end

        def content
          blocks = []
          blocks << { "type" => "thinking", "thinking" => @thinking } unless @thinking.empty?
          blocks << { "type" => "text", "text" => @text } unless @text.empty?
          @order.uniq.each do |item_id|
            c = @calls[item_id] or next

            args = begin
              c["args"].to_s.empty? ? {} : JSON.parse(c["args"])
            rescue JSON::ParserError
              {}
            end
            blocks << { "type" => "toolCall", "id" => c["id"], "name" => c["name"], "arguments" => args }
          end
          blocks
        end

        def base
          { "role" => "assistant", "content" => content, "usage" => @usage,
            "provider" => @model["provider"], "model" => @model["modelId"], "timestamp" => Durable::Ids.now_ms }
        end

        def finish
          return error(@error, retryable: @retryable) if @error

          stop = @stop || (@calls.empty? ? "stop" : "toolUse")
          stop = "toolUse" if !@calls.empty? && stop == "stop"
          base.merge("stopReason" => stop)
        end

        def error(message, retryable:)
          base.merge("stopReason" => "error", "errorMessage" => message, "retryable" => retryable)
        end

        def aborted = base.merge("stopReason" => "aborted")
      end
    end
  end
end
