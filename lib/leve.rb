# frozen_string_literal: true

# A durable coding agent in pure Ruby on Ractors.
#
# Everything must be required *before* any Ractor is spawned: a non-main Ractor
# cannot `require`.
Warning[:experimental] = false if Warning.respond_to?(:[]=)

require "set"
require_relative "leve/version"
require_relative "leve/ipc"
require_relative "leve/ids"
require_relative "leve/records"
require_relative "leve/context"
require_relative "leve/storage/base"
require_relative "leve/storage/memory"
require_relative "leve/storage/jsonl"
require_relative "leve/store"
require_relative "leve/provider"
require_relative "leve/tools"
require_relative "leve/agent_loop"
require_relative "leve/observer"
require_relative "leve/frontmatter"
require_relative "leve/agents_md"
require_relative "leve/skills"
require_relative "leve/compaction"
require_relative "leve/prompt"
require_relative "leve/tool_dsl"
require_relative "leve/channels"
require_relative "leve/sandbox"
require_relative "leve/project"
require_relative "leve/heartbeat"
require_relative "leve/lane"
require_relative "leve/harness"
