# frozen_string_literal: true

require_relative "provider/usage"
require_relative "provider/messages"
require_relative "provider/thinking"
require_relative "provider/http"
require_relative "provider/models"
require_relative "provider/anthropic"
require_relative "provider/openai_responses"
require_relative "provider/fake"

module Leve
  # Dispatch by api name. Providers are selected from the model hash, which is
  # plain JSON — the only thing a lane Ractor ever holds.
  #
  # Every provider is a module with the same four-method surface, and nothing
  # else. There is no base class and no instance state: a provider is a pure
  # function from (model, messages) to one assistant message.
  #
  #   stream(model:, messages:, system:, tools:, thinking:, max_tokens:,
  #          abort_check:, timeout:) { |event| } -> AssistantMessage
  #   fetch_deferred(model:, handle:, wait:)     -> AssistantMessage   (optional)
  #   cancel_deferred(model:, handle:)           -> nil                (optional)
  #
  # `stream` never raises: every failure — HTTP status, socket error, provider
  # error event, abort — comes back as an assistant message whose stopReason is
  # "error" | "aborted", carrying whatever usage was reported before it failed.
  # The harness therefore never has to translate an exception into durable
  # state.
  #
  # Streaming events passed to the block are one of:
  #   { type: "text_delta",      text: }
  #   { type: "thinking_delta",  text: }
  #   { type: "tool_call_start", id:, name: }
  #   { type: "tool_args_delta", id:, text: }
  module Provider
    APIS = { "anthropic-messages" => Anthropic,
             "openai-responses" => OpenAIResponses,
             "fake" => Fake }.freeze

    module_function

    # Run a blocking HTTP stream so that abort takes effect immediately.
    #
    # Checking a flag between chunks is not enough: a model that thinks for
    # thirty seconds sends nothing, and the user pressing Ctrl-C would wait for
    # it. The request runs in its own thread and the flag is polled; on abort
    # the thread is killed and whatever was accumulated so far is returned as
    # an aborted message.
    def run_abortable(abort_check, accumulator)
      return yield unless abort_check

      result = nil
      worker = Thread.new do
        Thread.current.report_on_exception = false
        result = yield
      end
      until worker.join(0.05)
        next unless abort_check.call

        worker.kill
        worker.join(0.5)
        return accumulator.aborted
      end
      result
    end

    # An unknown api is a typo in models.yml, and guessing a protocol produces
    # a confusing 400 from the endpoint instead of a clear failure here.
    def for_model(model)
      api = model["api"] || "anthropic-messages"
      APIS[api] or raise ArgumentError, "unknown api #{api.inspect}; known: #{APIS.keys.join(", ")}"
    end

    def stream(model:, **kwargs, &blk) = for_model(model).stream(model: model, **kwargs, &blk)

    def supports_deferred?(model) = for_model(model).respond_to?(:fetch_deferred)

    def fetch_deferred(model:, handle:, wait: 0)
      for_model(model).fetch_deferred(model: model, handle: handle, wait: wait)
    end

    def cancel_deferred(model:, handle:)
      p = for_model(model)
      p.cancel_deferred(model: model, handle: handle) if p.respond_to?(:cancel_deferred)
    end
  end
end
