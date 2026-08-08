# frozen_string_literal: true

module Leve
  module Provider
    # The lane speaks in levels — off | low | medium | high — because that is
    # what a user sets and what persists in a `thinking_level_change` entry.
    # Each protocol wants something else: anthropic wants a token budget,
    # openai wants an effort word, and a given endpoint may serve only a subset
    # of the effort words. This is the one place that translation lives.
    #
    # A model declares its capability in models.yml:
    #
    #   reasoning: true
    #   thinking:
    #     mode: effort          # effort | budget (default: protocol's native)
    #     efforts: [low, high]  # what this endpoint actually accepts
    #     budgets: { low: 4000, medium: 10000, high: 24000 }
    module Thinking
      LEVELS = %w[off minimal low medium high max].freeze
      BUDGETS = { "minimal" => 1024, "low" => 4000, "medium" => 10_000,
                  "high" => 24_000, "max" => 48_000 }.freeze
      MIN_BUDGET = 1024

      module_function

      def off?(model, level)
        level.nil? || level == "off" || !model["reasoning"]
      end

      # The effort word this endpoint accepts that is closest to `level`,
      # never stepping below it unless nothing higher exists.
      def effort(model, level)
        return nil if off?(model, level)

        allowed = Array(model.dig("thinking", "efforts")).map(&:to_s)
        return level if allowed.empty? || allowed.include?(level)

        want = LEVELS.index(level) || LEVELS.index("medium")
        allowed.min_by { |e| [((LEVELS.index(e) || 0) - want).abs, -(LEVELS.index(e) || 0)] }
      end

      # A token budget bounded by the response cap: anthropic requires
      # budget_tokens < max_tokens and at least 1024, so a small cap means no
      # thinking rather than a rejected request.
      def budget(model, level, max_tokens)
        return nil if off?(model, level)

        configured = model.dig("thinking", "budgets")
        want = (configured && configured[level]) || BUDGETS[level] || BUDGETS["medium"]
        budget = [want.to_i, max_tokens.to_i - MIN_BUDGET].min
        budget >= MIN_BUDGET ? budget : nil
      end
    end
  end
end
