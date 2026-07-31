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
require_relative "durable/records"
require_relative "durable/context"
require_relative "durable/storage/base"
require_relative "durable/storage/memory"
require_relative "durable/storage/jsonl"
require_relative "durable/store"
require_relative "durable/provider"
require_relative "durable/tools"
require_relative "durable/agent_loop"
require_relative "durable/observer"
require_relative "durable/frontmatter"
require_relative "durable/agents_md"
require_relative "durable/skills"
require_relative "durable/prompt"

module Durable
  VERSION = "0.1.0"
end
