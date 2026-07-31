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
