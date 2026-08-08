# frozen_string_literal: true

module Leve
  module Provider
    # Readers for the harness's own message shape (harness-v2 AgentMessage).
    # Writing it out is protocol-specific and lives in each provider; reading
    # it is not, and triplicating these predicates is how the three providers
    # would drift apart.
    #
    # An AgentMessage is one of:
    #   { role: "user",       content: [ {type:"text"|"image", ...} ] }
    #   { role: "assistant",  content: [ text | thinking | toolCall ], stopReason:, usage: }
    #   { role: "toolResult", toolCallId:, toolName:, content: [...], isError: }
    module Messages
      module_function

      def blocks(message) = message["content"].is_a?(Array) ? message["content"] : []

      def text(message)
        c = message["content"]
        return c.to_s if c.is_a?(String)

        blocks(message).select { _1["type"] == "text" }.map { _1["text"] }.join
      end

      def tool_calls(message) = blocks(message).select { _1["type"] == "toolCall" }

      # Signed or encrypted thinking blocks are the only ones that may be
      # replayed: an unsigned one is a local rendering artefact and sending it
      # back is a validation error on both protocols.
      def replayable_thinking(message)
        blocks(message).select { _1["type"] == "thinking" && !_1["signature"].to_s.empty? }
      end

      # A parked (deferred) assistant message has no content yet; it projects
      # to nothing in a request.
      def projects?(message) = message["stopReason"] != "deferred"

      def image_data_url(block) = "data:#{block["mimeType"] || "image/png"};base64,#{block["data"]}"

      # Tool call ids that no tool result answers, in order. Both protocols
      # need synthetic results for these or the request is rejected: a
      # transcript whose tip sits mid-batch (a crash, an abort) must stay
      # promptable.
      def unanswered(messages)
        answered = messages.select { _1["role"] == "toolResult" }.map { _1["toolCallId"] }
        messages.select { _1["role"] == "assistant" && projects?(_1) }
                .flat_map { tool_calls(_1) }.map { _1["id"] } - answered
      end

      INTERRUPTED = "Interrupted."
    end
  end
end
