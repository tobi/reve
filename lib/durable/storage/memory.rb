# frozen_string_literal: true

require_relative "base"

module Durable
  module Storage
    # The reference backend (§13). Nothing to do: Base already is it.
    class Memory < Base
      def self.open(_path = nil, metadata: {}) = new(metadata: metadata)

      def path = nil
      def close = nil
    end
  end
end
