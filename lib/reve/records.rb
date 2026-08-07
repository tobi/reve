# frozen_string_literal: true

require_relative "ids"

module Reve
  # The record catalog of harness-v2 §5. The durability rule: before an effect,
  # write an intent record naming what will happen and the ids it will produce;
  # after the effect, append the result as an entry with exactly those ids.
  module Records
    OPERATION_STARTED = "operation_started"
    ABORT_REQUESTED   = "abort_requested"
    OPERATION_FINISHED = "operation_finished"
    TASK_ATTEMPT      = "task_attempt"
    TOOL_STARTED      = "tool_started"
    QUEUE_ENQUEUED    = "queue_enqueued"
    WRITE_DEFERRED    = "write_deferred"

    module_function

    def operation_started(lane:, source_leaf_id:, intent:, id: nil)
      { "type" => OPERATION_STARTED, "id" => id || Ids.record, "lane" => lane,
        "sourceLeafId" => source_leaf_id, "intent" => intent }
    end

    def abort_requested(lane:, run_id:, reason: "user")
      { "type" => ABORT_REQUESTED, "lane" => lane, "runId" => run_id, "reason" => reason }
    end

    def operation_finished(lane:, run_id:, outcome:, error: nil)
      r = { "type" => OPERATION_FINISHED, "lane" => lane, "runId" => run_id, "outcome" => outcome }
      r["error"] = error if error
      r
    end

    def task_attempt(lane:, run_id:, task:, attempt:)
      { "type" => TASK_ATTEMPT, "lane" => lane, "runId" => run_id, "task" => task, "attempt" => attempt }
    end

    def tool_started(lane:, run_id:, assistant_entry_id:, tool_index:, tool_call_id:, tool_name:,
                     effective_args:, result_entry_id:, replay:)
      { "type" => TOOL_STARTED, "lane" => lane, "runId" => run_id,
        "assistantEntryId" => assistant_entry_id, "toolIndex" => tool_index,
        "toolCallId" => tool_call_id, "toolName" => tool_name,
        "effectiveArgs" => effective_args, "resultEntryId" => result_entry_id, "replay" => replay }
    end

    def queue_enqueued(lane:, queue:, target:, run_id: nil)
      r = { "type" => QUEUE_ENQUEUED, "lane" => lane, "queue" => queue, "target" => target }
      r["runId"] = run_id if run_id
      r
    end

    def write_deferred(lane:, run_id:, target:)
      { "type" => WRITE_DEFERRED, "lane" => lane, "runId" => run_id, "target" => target }
    end

    # ── provisioned entries ────────────────────────────────────────────────
    # parentId, seq and timestamp are storage's business; the id is ours,
    # because an intent must be able to name its result.

    def message_entry(message, id: nil)
      { "type" => "message", "id" => id || Ids.entry, "message" => message }
    end

    def user_message(text_or_content, id: nil)
      content = text_or_content.is_a?(String) ? [{ "type" => "text", "text" => text_or_content }] : text_or_content
      message_entry({ "role" => "user", "content" => content }, id: id)
    end

    def assistant_entry(message, id: nil) = message_entry(message, id: id)

    def tool_result_message(tool_call_id:, tool_name:, content:, is_error: false, details: nil)
      msg = { "role" => "toolResult", "toolCallId" => tool_call_id, "toolName" => tool_name,
              "content" => content, "isError" => is_error }
      msg["details"] = details if details
      msg
    end

    def compaction_entry(id:, summary:, tokens_before:, first_kept_entry_id: nil, usage: nil)
      { "type" => "compaction", "id" => id, "summary" => summary, "tokensBefore" => tokens_before,
        "firstKeptEntryId" => first_kept_entry_id, "usage" => usage }
    end

    def branch_summary_entry(id:, from_id:, summary:, usage: nil)
      { "type" => "branch_summary", "id" => id, "fromId" => from_id, "summary" => summary, "usage" => usage }
    end

    def model_change_entry(provider:, model_id:, id: nil)
      { "type" => "model_change", "id" => id || Ids.entry, "provider" => provider, "modelId" => model_id }
    end

    def thinking_level_entry(level:, id: nil)
      { "type" => "thinking_level_change", "id" => id || Ids.entry, "thinkingLevel" => level }
    end

    def active_tools_entry(names:, id: nil)
      { "type" => "active_tools_change", "id" => id || Ids.entry, "activeToolNames" => names }
    end
  end
end
