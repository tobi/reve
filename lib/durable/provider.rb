# frozen_string_literal: true

require_relative "provider/models"
require_relative "provider/anthropic"
require_relative "provider/openai_responses"
require_relative "provider/fake"

module Durable
  # Dispatch by api name. Providers are selected from the model hash, which is
  # plain JSON — the only thing a lane Ractor ever holds.
  module Provider
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

    def for_model(model)
      case model["api"]
      when "fake" then Fake
      when "openai-responses" then OpenAIResponses
      when "anthropic-messages" then Anthropic
      else Anthropic
      end
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
