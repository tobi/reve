# frozen_string_literal: true

require "securerandom"

module Durable
  module Ids
    module_function

    def entry = "e_#{SecureRandom.alphanumeric(16).downcase}"
    def record = "r_#{SecureRandom.alphanumeric(16).downcase}"
    def session = SecureRandom.uuid
    def step = "s_#{SecureRandom.alphanumeric(10).downcase}"
    def now_ms = (Time.now.to_f * 1000).round
  end
end
