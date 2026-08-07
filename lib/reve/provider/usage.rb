# frozen_string_literal: true

module Reve
  module Provider
    # Token statistics, one shape for every protocol.
    #
    # Every assistant message carries one of these, always, even when the
    # provider reported nothing: an unknown count is 0, never nil, so consumers
    # add and divide without guards.
    #
    #   input      total prompt tokens — cached ones included
    #   cacheRead  the part of input that was served from the prompt cache
    #   cacheWrite the part of input that was written into the prompt cache
    #   output     completion tokens — reasoning included
    #   reasoning  the part of output spent on thinking
    #   total      input + output, the number to compare against contextWindow
    #
    # The inclusive convention is the one the anthropic API does *not* use (it
    # reports uncached input), so its accumulator adds the cache counts back.
    # Normalising here rather than at each reader is what makes a cache hit
    # rate mean the same thing on every provider.
    class Usage
      FIELDS = %w[input output cacheRead cacheWrite reasoning].freeze
      ZERO = FIELDS.to_h { [_1, 0] }.merge("total" => 0).freeze

      def initialize = @counts = FIELDS.to_h { [_1, 0] }

      # Streaming reports usage in pieces (anthropic splits it across
      # message_start and message_delta), so every field accumulates.
      def add(input: 0, output: 0, cache_read: 0, cache_write: 0, reasoning: 0)
        @counts["input"] += input.to_i
        @counts["output"] += output.to_i
        @counts["cacheRead"] += cache_read.to_i
        @counts["cacheWrite"] += cache_write.to_i
        @counts["reasoning"] += reasoning.to_i
        self
      end

      def to_h = @counts.merge("total" => @counts["input"] + @counts["output"])

      # Sum of any number of persisted usage hashes, in the same shape.
      def self.sum(hashes)
        hashes.compact.each_with_object(new) do |u, acc|
          acc.add(input: u["input"], output: u["output"], cache_read: u["cacheRead"],
                  cache_write: u["cacheWrite"], reasoning: u["reasoning"])
        end.to_h
      end

      # What a reader should charge against the context window. Tolerates the
      # shape being absent entirely.
      def self.total(usage)
        return 0 unless usage

        t = usage["total"].to_i
        t.positive? ? t : usage["input"].to_i + usage["output"].to_i
      end
    end
  end
end
