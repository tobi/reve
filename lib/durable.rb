# frozen_string_literal: true

# A durable coding agent in pure Ruby on Ractors.
# Design: pi's harness-v2 (see PLAN.md).
#
# Everything must be required *before* any Ractor is spawned: a non-main Ractor
# cannot `require`.
Warning[:experimental] = false if Warning.respond_to?(:[]=)

require "set"
require_relative "durable/ipc"
require_relative "durable/ids"

module Durable
  VERSION = "0.1.0"
end
