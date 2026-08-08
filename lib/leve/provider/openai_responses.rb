# frozen_string_literal: true

require_relative "http"
require_relative "usage"
require_relative "thinking"
require_relative "messages"

module Leve
  module Provider
    # openai-responses, streaming. Written against the shape vLLM serves at
    # /v1/responses, which is also what OpenAI serves — the differences live in
    # the model's `compat` block (from models.yml), not in the code:
    #
    #   supportsStore              send "store": false explicitly
    #   supportsDeveloperRole      system prompt as a developer message vs "instructions"
    #   supportsReasoningEffort    send "reasoning": { effort }
    #   reasoningSummary           "auto" (default) | "detailed" | "none"
    #   encryptedReasoning         opt in/out of encrypted reasoning replay
    #   maxTokensField             "max_output_tokens" or "max_tokens"
    #   promptCacheKey             true to send a stable cache key
    #
    # Encrypted reasoning is the important one. This harness is stateless
    # against the provider — it owns the transcript, so it sends `store: false`
    # and never references a previous_response_id. Without help, the model's
    # reasoning for turn N is then gone by turn N+1 and it re-derives it after
    # every tool call. With `include: ["reasoning.encrypted_content"]` the
    # provider hands back an opaque blob per reasoning item; we persist it on
    # the thinking block as its signature and replay it verbatim. The reasoning
    # survives compaction of everything around it, is unreadable to us, and
    # costs cached input tokens rather than fresh thinking.
    module OpenAIResponses
      ENCRYPTED_CONTENT = "reasoning.encrypted_content"

      module_function

      def stream(model:, messages:, system: nil, tools: [], thinking: nil, max_tokens: nil,
                 abort_check: nil, timeout: 900, &on_event)
        HTTP.stream_json(url: HTTP.endpoint(model, "responses"),
                         headers: { "authorization" => HTTP.bearer(model) }.merge(model["headers"] || {}),
                         body: request_body(model, messages, system, tools, thinking, max_tokens),
                         acc: Accumulator.new(model), timeout: timeout, model: model,
                         abort_check: abort_check, &on_event)
      end

      def request_body(model, messages, system, tools, thinking, max_tokens)
        compat = model["compat"] || {}
        body = { "model" => model["modelId"], "input" => to_input(messages), "stream" => true }
        body[compat["maxTokensField"] || "max_output_tokens"] = max_tokens || model["maxTokens"] || 8192
        body["store"] = false if compat["supportsStore"]
        body["include"] = [ENCRYPTED_CONTENT] if encrypted_reasoning?(model)
        body["prompt_cache_key"] = "leve:#{model["modelId"]}" if compat["promptCacheKey"]
        apply_system(body, system, compat)
        body["tools"] = tools.map { tool_schema(_1) } unless tools.empty?
        if compat["supportsReasoningEffort"] && (effort = Thinking.effort(model, thinking))
          body["reasoning"] = { "effort" => effort }
          summary = compat["reasoningSummary"] || "auto"
          body["reasoning"]["summary"] = summary unless summary == "none"
        end
        body
      end

      def apply_system(body, system, compat)
        return if system.nil? || system.empty?

        if compat["supportsDeveloperRole"]
          body["input"].unshift({ "role" => "developer",
                                  "content" => [{ "type" => "input_text", "text" => system }] })
        else
          body["instructions"] = system
        end
      end

      def tool_schema(tool)
        { "type" => "function", "name" => tool["name"], "description" => tool["description"].to_s,
          "parameters" => tool["parameters"] || { "type" => "object", "properties" => {} } }
      end

      # Explicit opt-in wins; otherwise infer it from the endpoint being a real
      # Responses server (one that understands `store`) serving a reasoning
      # model. vLLM answers neither, and gets nothing it would reject.
      def encrypted_reasoning?(model)
        compat = model["compat"] || {}
        return compat["encryptedReasoning"] unless compat["encryptedReasoning"].nil?

        !!model["reasoning"] && !!compat["supportsStore"]
      end

      # AgentMessage[] → Responses input items.
      def to_input(messages)
        out = []
        messages.each do |m|
          case m["role"]
          when "user"
            out << { "role" => "user", "content" => input_content(m["content"]) }
          when "assistant"
            next unless Messages.projects?(m)

            assistant_items(m).each { out << _1 }
          when "toolResult"
            text = Messages.text(m)
            out << { "type" => "function_call_output", "call_id" => m["toolCallId"],
                     "output" => text.empty? ? "(no output)" : text }
          end
        end
        heal(out)
      end

      # Reasoning items first and in their original order: the provider pairs a
      # reasoning item with the function_call that follows it, and rejects one
      # whose encrypted content it cannot place.
      def assistant_items(message)
        items = Messages.replayable_thinking(message).map { reasoning_item(_1) }
        # Assistant history goes in as a plain string: an input message may only
        # carry input_* content parts, and output_text there is a validation
        # error on strict servers (vLLM is one).
        text = Messages.text(message)
        items << { "role" => "assistant", "content" => text } unless text.strip.empty?
        items + Messages.tool_calls(message).map do |c|
          { "type" => "function_call", "call_id" => c["id"], "name" => c["name"],
            "arguments" => JSON.generate(c["arguments"] || {}) }
        end
      end

      def reasoning_item(block)
        item = { "type" => "reasoning", "encrypted_content" => block["signature"], "summary" => [] }
        item["id"] = block["itemId"] if block["itemId"]
        unless block["thinking"].to_s.empty?
          item["summary"] = [{ "type" => "summary_text", "text" => block["thinking"] }]
        end
        item
      end

      # Orphaned tool calls get synthetic outputs, so a transcript whose tip
      # sits mid-batch is still promptable.
      def heal(items)
        answered = items.select { _1["type"] == "function_call_output" }.map { _1["call_id"] }
        items.flat_map do |item|
          next [item] unless item["type"] == "function_call" && !answered.include?(item["call_id"])

          [item, { "type" => "function_call_output", "call_id" => item["call_id"],
                   "output" => Messages::INTERRUPTED }]
        end
      end

      def input_content(content)
        return [{ "type" => "input_text", "text" => content.to_s }] if content.is_a?(String)

        blocks = (content || []).filter_map do |c|
          case c["type"]
          when "text" then { "type" => "input_text", "text" => c["text"].to_s }
          when "image" then { "type" => "input_image", "image_url" => Messages.image_data_url(c) }
          end
        end
        blocks.empty? ? [{ "type" => "input_text", "text" => "" }] : blocks
      end

      class Accumulator
        def initialize(model)
          @model = model
          @text = +""
          @thinking = +""
          @reasoning = {}  # item_id => reasoning block, in arrival order
          @calls = {}      # item_id => { id, name, args }
          @order = []
          @usage = Usage.new
        end

        def handle(event, &emit)
          case event["type"]
          when "response.output_text.delta"
            @text << event["delta"].to_s
            emit&.call({ "type" => "text_delta", "text" => event["delta"].to_s })
          when "response.reasoning_text.delta", "response.reasoning_summary_text.delta"
            @thinking << event["delta"].to_s
            emit&.call({ "type" => "thinking_delta", "text" => event["delta"].to_s })
          when "response.output_item.added" then item_added(event, &emit)
          when "response.function_call_arguments.delta"
            call = @calls[event["item_id"]] or return

            call["args"] << event["delta"].to_s
            emit&.call({ "type" => "tool_args_delta", "id" => call["id"], "text" => event["delta"].to_s })
          when "response.function_call_arguments.done"
            call = @calls[event["item_id"]] or return

            call["args"] = event["arguments"].to_s unless event["arguments"].nil?
          when "response.output_item.done" then item_done(event)
          when "response.completed", "response.incomplete", "response.failed" then response_done(event)
          when "error"
            @error = event["message"] || event.dig("error", "message") || "provider error"
            @retryable = true
          end
        end

        def item_added(event)
          item = event["item"] or return
          return unless item["type"] == "function_call"

          @order << item["id"]
          @calls[item["id"]] = { "id" => item["call_id"] || item["id"], "name" => item["name"], "args" => +"" }
          yield({ "type" => "tool_call_start", "id" => item["call_id"], "name" => item["name"] }) if block_given?
        end

        def item_done(event)
          item = event["item"] or return

          case item["type"]
          when "function_call"
            call = @calls[item["id"]] ||= { "id" => item["call_id"], "name" => item["name"], "args" => +"" }
            call["args"] = item["arguments"].to_s if item["arguments"]
            call["id"] = item["call_id"] if item["call_id"]
            @order << item["id"] unless @order.include?(item["id"])
          when "reasoning"
            capture_reasoning(item)
          when "message"
            (item["content"] || []).each { @text << _1["text"].to_s if _1["type"] == "output_text" } if @text.empty?
          end
        end

        # The encrypted blob is the whole point: without it the item is a
        # rendering artefact and must not be replayed.
        def capture_reasoning(item)
          blob = item["encrypted_content"].to_s
          return if blob.empty?

          summary = (item["summary"] || []).map { _1["text"].to_s }.join("\n")
          @reasoning[item["id"]] = { "type" => "thinking", "thinking" => summary,
                                     "signature" => blob, "itemId" => item["id"] }
        end

        def response_done(event)
          resp = event["response"] || {}
          merge_usage(resp["usage"] || {})
          case resp["status"]
          when "incomplete"
            @stop = resp.dig("incomplete_details", "reason") == "max_output_tokens" ? "length" : "stop"
          when "failed"
            @error = resp.dig("error", "message") || "response failed"
          end
        end

        def merge_usage(u)
          @usage.add(input: u["input_tokens"], output: u["output_tokens"],
                     cache_read: u.dig("input_tokens_details", "cached_tokens"),
                     reasoning: u.dig("output_tokens_details", "reasoning_tokens"))
        end

        def content
          blocks = @reasoning.values
          # A summary with no encrypted blob still renders, but only once: it is
          # not replayable, so it carries no signature.
          blocks << { "type" => "thinking", "thinking" => @thinking } if blocks.empty? && !@thinking.empty?
          blocks << { "type" => "text", "text" => @text } unless @text.empty?
          @order.uniq.each do |item_id|
            c = @calls[item_id] or next

            blocks << { "type" => "toolCall", "id" => c["id"], "name" => c["name"], "arguments" => parse(c["args"]) }
          end
          blocks
        end

        def parse(args)
          args.to_s.empty? ? {} : JSON.parse(args)
        rescue JSON::ParserError
          {}
        end

        def base
          { "role" => "assistant", "content" => content, "usage" => @usage.to_h,
            "provider" => @model["provider"], "model" => @model["modelId"],
            "timestamp" => Leve::Ids.now_ms }
        end

        def finish
          return error(@error, retryable: @retryable) if @error

          base.merge("stopReason" => @calls.empty? ? (@stop || "stop") : "toolUse")
        end

        def error(message, retryable:)
          base.merge("stopReason" => "error", "errorMessage" => message, "retryable" => retryable)
        end

        def aborted = base.merge("stopReason" => "aborted")
      end
    end
  end
end
