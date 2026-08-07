# frozen_string_literal: true

require_relative "http"
require_relative "usage"
require_relative "thinking"
require_relative "messages"

module Reve
  module Provider
    # openai-chat-completions, streaming. The oldest of the three protocols and
    # the one every inference server implements, which is exactly why it is
    # here: it is the fallback that always works.
    #
    # It is also the poorest. Chat completions has no standard place to put a
    # model's reasoning on the way back in — reasoning arrives as
    # `reasoning_content` (vLLM, DeepSeek, most OSS servers) or `reasoning`
    # (some proxies), and no server accepts either one in a request. So
    # thinking is captured for display and for compaction, unsigned, and never
    # replayed. A protocol that can preserve reasoning across tool calls
    # (openai-responses with encrypted content, anthropic-messages with signed
    # blocks) is worth preferring for a reasoning model.
    #
    # `compat` keys:
    #
    #   supportsReasoningEffort  send "reasoning_effort"
    #   supportsDeveloperRole    system prompt as "developer" instead of "system"
    #   maxTokensField           "max_completion_tokens" (default) or "max_tokens"
    #   parallelToolCalls        false to send parallel_tool_calls: false
    #   promptCacheKey           true to send a stable cache key
    module OpenAIChat
      STOP = { "stop" => "stop", "length" => "length", "tool_calls" => "toolUse",
               "function_call" => "toolUse", "content_filter" => "stop" }.freeze

      module_function

      def stream(model:, messages:, system: nil, tools: [], thinking: nil, max_tokens: nil,
                 abort_check: nil, timeout: 900, &on_event)
        HTTP.stream_json(url: HTTP.endpoint(model, "chat/completions"),
                         headers: { "authorization" => HTTP.bearer(model) }.merge(model["headers"] || {}),
                         body: request_body(model, messages, system, tools, thinking, max_tokens),
                         acc: Accumulator.new(model), timeout: timeout,
                         abort_check: abort_check, &on_event)
      end

      def request_body(model, messages, system, tools, thinking, max_tokens)
        compat = model["compat"] || {}
        body = { "model" => model["modelId"], "messages" => to_messages(messages, system, compat),
                 "stream" => true, "stream_options" => { "include_usage" => true } }
        body[compat["maxTokensField"] || "max_completion_tokens"] = max_tokens || model["maxTokens"] || 8192
        body["prompt_cache_key"] = "reve:#{model["modelId"]}" if compat["promptCacheKey"]
        unless tools.empty?
          body["tools"] = tools.map { tool_schema(_1) }
          body["parallel_tool_calls"] = false if compat["parallelToolCalls"] == false
        end
        if compat["supportsReasoningEffort"] && (effort = Thinking.effort(model, thinking))
          body["reasoning_effort"] = effort
        end
        body
      end

      def tool_schema(tool)
        { "type" => "function",
          "function" => { "name" => tool["name"], "description" => tool["description"].to_s,
                          "parameters" => tool["parameters"] || { "type" => "object", "properties" => {} } } }
      end

      # AgentMessage[] → chat messages.
      def to_messages(messages, system = nil, compat = {})
        out = []
        if system && !system.empty?
          out << { "role" => compat["supportsDeveloperRole"] ? "developer" : "system", "content" => system }
        end
        messages.each do |m|
          case m["role"]
          when "user"
            out << { "role" => "user", "content" => user_content(m["content"]) }
          when "assistant"
            next unless Messages.projects?(m)

            item = assistant_message(m) or next
            out << item
          when "toolResult"
            out << { "role" => "tool", "tool_call_id" => m["toolCallId"],
                     "content" => Messages.text(m).then { _1.empty? ? "(no output)" : _1 } }
          end
        end
        heal(out)
      end

      # An assistant message needs content or tool_calls; one with neither (a
      # pure thinking turn, which this protocol cannot replay) is dropped.
      def assistant_message(message)
        text = Messages.text(message)
        calls = Messages.tool_calls(message).map do |c|
          { "id" => c["id"], "type" => "function",
            "function" => { "name" => c["name"], "arguments" => JSON.generate(c["arguments"] || {}) } }
        end
        return nil if text.strip.empty? && calls.empty?

        item = { "role" => "assistant", "content" => text.empty? ? nil : text }
        item["tool_calls"] = calls unless calls.empty?
        item
      end

      # Every tool_call must be answered by a tool message or the request is
      # rejected, so a transcript whose tip sits mid-batch is healed here.
      def heal(msgs)
        answered = msgs.select { _1["role"] == "tool" }.map { _1["tool_call_id"] }
        msgs.flat_map do |m|
          missing = (m["tool_calls"] || []).map { _1["id"] } - answered
          [m] + missing.map do |id|
            { "role" => "tool", "tool_call_id" => id, "content" => Messages::INTERRUPTED }
          end
        end
      end

      def user_content(content)
        return content.to_s if content.is_a?(String)

        parts = (content || []).filter_map do |c|
          case c["type"]
          when "text" then { "type" => "text", "text" => c["text"].to_s }
          when "image" then { "type" => "image_url", "image_url" => { "url" => Messages.image_data_url(c) } }
          end
        end
        # A text-only message goes in as a plain string: some servers reject
        # the parts form on anything but multimodal input.
        return parts.first["text"] if parts.size == 1 && parts.first["type"] == "text"

        parts.empty? ? "" : parts
      end

      # Accumulates chat completion chunks into one AssistantMessage.
      class Accumulator
        def initialize(model)
          @model = model
          @text = +""
          @thinking = +""
          @calls = []      # index-ordered, as the protocol numbers them
          @stop = nil
          @usage = Usage.new
        end

        def handle(event, &emit)
          if (err = event["error"])
            @error = err.is_a?(Hash) ? (err["message"] || "provider error") : err.to_s
            @retryable = true
            return
          end
          merge_usage(event["usage"]) if event["usage"]
          choice = (event["choices"] || []).first or return

          delta(choice["delta"] || {}, &emit)
          @stop = STOP[choice["finish_reason"]] || @stop if choice["finish_reason"]
        end

        def delta(d, &emit)
          if (text = d["content"]) && !text.to_s.empty?
            @text << text
            emit&.call({ "type" => "text_delta", "text" => text })
          end
          # Two spellings of the same field across servers; never both.
          if (r = d["reasoning_content"] || d["reasoning"]) && !r.to_s.empty?
            @thinking << r
            emit&.call({ "type" => "thinking_delta", "text" => r })
          end
          (d["tool_calls"] || []).each { tool_call_delta(_1, &emit) }
        end

        # Only the first chunk of a call carries its id and name; the rest are
        # argument fragments keyed by the same index.
        def tool_call_delta(td, &emit)
          idx = td["index"] || @calls.size
          call = (@calls[idx] ||= { "id" => nil, "name" => nil, "args" => +"" })
          call["id"] ||= td["id"]
          fn = td["function"] || {}
          if fn["name"] && !call["name"]
            call["name"] = fn["name"]
            emit&.call({ "type" => "tool_call_start", "id" => call["id"], "name" => call["name"] })
          end
          return if fn["arguments"].to_s.empty?

          call["args"] << fn["arguments"]
          emit&.call({ "type" => "tool_args_delta", "id" => call["id"], "text" => fn["arguments"] })
        end

        # Servers disagree on where cache hits are reported: OpenAI nests them
        # under prompt_tokens_details, DeepSeek puts them at the top level.
        # Neither reports cache writes, so cacheWrite stays 0 here.
        def merge_usage(u)
          cached = u.dig("prompt_tokens_details", "cached_tokens") || u["prompt_cache_hit_tokens"]
          @usage.add(input: u["prompt_tokens"], output: u["completion_tokens"], cache_read: cached,
                     reasoning: u.dig("completion_tokens_details", "reasoning_tokens"))
        end

        def content
          blocks = []
          blocks << { "type" => "thinking", "thinking" => @thinking } unless @thinking.empty?
          blocks << { "type" => "text", "text" => @text } unless @text.empty?
          @calls.compact.each_with_index do |c, i|
            next if c["name"].to_s.empty?

            blocks << { "type" => "toolCall", "id" => c["id"] || "call_#{i}", "name" => c["name"],
                        "arguments" => parse(c["args"]) }
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
            "timestamp" => Reve::Ids.now_ms }
        end

        def finish
          return error(@error, retryable: @retryable) if @error

          # A server that streams tool call deltas but forgets the
          # finish_reason still gets the right stop reason.
          base.merge("stopReason" => @calls.compact.empty? ? (@stop || "stop") : "toolUse")
        end

        def error(message, retryable:)
          base.merge("stopReason" => "error", "errorMessage" => message, "retryable" => retryable)
        end

        def aborted = base.merge("stopReason" => "aborted")
      end
    end
  end
end
