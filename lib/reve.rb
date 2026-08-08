# frozen_string_literal: true

# A durable coding agent in pure Ruby on Ractors.
# Design: Pi's durable harness (see PLAN.md).
#
# Everything must be required *before* any Ractor is spawned: a non-main Ractor
# cannot `require`.
Warning[:experimental] = false if Warning.respond_to?(:[]=)

require "set"
require_relative "reve/version"
require_relative "reve/ipc"
require_relative "reve/ids"
require_relative "reve/records"
require_relative "reve/context"
require_relative "reve/storage/base"
require_relative "reve/storage/memory"
require_relative "reve/storage/jsonl"
require_relative "reve/store"
require_relative "reve/provider"
require_relative "reve/tools"
require_relative "reve/agent_loop"
require_relative "reve/observer"
require_relative "reve/frontmatter"
require_relative "reve/agents_md"
require_relative "reve/skills"
require_relative "reve/compaction"
require_relative "reve/prompt"
require_relative "reve/tool_dsl"
require_relative "reve/channels"
require_relative "reve/sandbox"
require_relative "reve/project"
require_relative "reve/heartbeat"
require_relative "reve/lane"
require_relative "reve/harness"
