# frozen_string_literal: true

require_relative "context"

module Reve
  # Context compaction: pure preparation plus the prompts. The lane owns the
  # durability (operation_started / task_attempt / the compaction entry); this
  # module only decides *what* to summarize and *what to keep*.
  #
  # The kept suffix is the point: a compaction entry names `firstKeptEntryId`,
  # and the context build is [summary] + [kept entries] + [everything after the
  # compaction entry]. Recent turns survive verbatim; only the old head is
  # replaced by prose.
  module Compaction
    DEFAULTS = Ractor.make_shareable({ "threshold" => 0.8, "reserveTokens" => 16_384,
                                       "keepRecentTokens" => 20_000 })
    TOOL_RESULT_MAX_CHARS = 2000

    SYSTEM_PROMPT = <<~TXT.strip.freeze
      You are a context summarization assistant. Your task is to read a conversation between a user
      and an AI assistant, then produce a structured summary following the exact format specified.

      Do NOT continue the conversation. Do NOT respond to any questions in the conversation.
      ONLY output the structured summary.
    TXT

    FORMAT = <<~TXT.strip.freeze
      ## Goal
      [What is the user trying to accomplish? Can be multiple items if the session covers different tasks.]

      ## Constraints & Preferences
      - [Any constraints, preferences, or requirements mentioned by the user]
      - [Or "(none)" if none were mentioned]

      ## Progress
      ### Done
      - [x] [Completed tasks/changes]

      ### In Progress
      - [ ] [Current work]

      ### Blocked
      - [Issues preventing progress, if any]

      ## Key Decisions
      - **[Decision]**: [Brief rationale]

      ## Next Steps
      1. [Ordered list of what should happen next]

      ## Critical Context
      - [Any data, examples, or references needed to continue]
      - [Or "(none)" if not applicable]

      Keep each section concise. Preserve exact file paths, function names, and error messages.
    TXT

    INITIAL_PROMPT = <<~TXT.strip.freeze
      The messages above are a conversation to summarize. Create a structured context checkpoint
      summary that another LLM will use to continue the work.

      Use this EXACT format:

      #{FORMAT}
    TXT

    UPDATE_PROMPT = <<~TXT.strip.freeze
      The messages above are NEW conversation messages to incorporate into the existing summary
      provided in <previous-summary> tags.

      Update the existing structured summary with new information. RULES:
      - PRESERVE all existing information from the previous summary
      - ADD new progress, decisions, and context from the new messages
      - UPDATE the Progress section: move items from "In Progress" to "Done" when completed
      - UPDATE "Next Steps" based on what was accomplished
      - PRESERVE exact file paths, function names, and error messages
      - If something is no longer relevant, you may remove it

      Use this EXACT format:

      #{FORMAT}
    TXT

    TURN_PREFIX_PROMPT = <<~TXT.strip.freeze
      This is the PREFIX of a turn that was too large to keep. The SUFFIX (recent work) is retained.

      Summarize the prefix to provide context for the retained suffix:

      ## Original Request
      [What did the user ask for in this turn?]

      ## Early Progress
      - [Key decisions and work done in the prefix]

      ## Context for Suffix
      - [Information needed to understand the retained recent work]

      Be concise. Focus on what's needed to understand the kept suffix.
    TXT

    module_function

    def settings(overrides = nil) = DEFAULTS.merge(overrides || {})

    # An entry may start a turn: user messages and everything that is not a
    # tool result. Cutting there keeps tool calls and their results together.
    def turn_start?(entry)
      return false unless entry["type"] == "message"

      entry.dig("message", "role") == "user"
    end

    def valid_cut?(entry)
      return false unless entry["type"] == "message"

      %w[user assistant].include?(entry.dig("message", "role"))
    end

    def entry_tokens(entry)
      msg = Context.project(entry)
      msg ? Context.estimate_tokens([msg]) : 0
    end

    # Walk backwards from the newest entry, accumulating tokens; cut at the
    # first valid cut point at or after the entry that blew the budget.
    def find_cut_point(entries, start_index, keep_recent_tokens)
      cut_points = (start_index...entries.size).select { valid_cut?(entries[_1]) }
      return { "index" => start_index, "turnStart" => -1, "splitTurn" => false } if cut_points.empty?

      accumulated = 0
      cut = cut_points.first
      (entries.size - 1).downto(start_index) do |i|
        t = entry_tokens(entries[i])
        next if t.zero?

        accumulated += t
        next if accumulated < keep_recent_tokens

        cut = cut_points.find { _1 >= i } || cut_points.last
        break
      end

      # Pull in adjacent entries that contribute nothing to context.
      while cut > start_index
        prev = entries[cut - 1]
        break if prev["type"] == "compaction" || Context.project(prev)

        cut -= 1
      end

      starts = turn_start?(entries[cut])
      turn_start = starts ? -1 : (cut.downto(start_index).find { turn_start?(entries[_1]) } || -1)
      { "index" => cut, "turnStart" => turn_start, "splitTurn" => !starts && turn_start >= 0 }
    end

    # `entries` is the lane's path, oldest first (the full path, not the
    # context window). Returns nil when there is nothing worth compacting.
    def prepare(entries, opts = nil)
      cfg = settings(opts)
      return nil if entries.empty? || entries.last["type"] == "compaction"

      prev_index = entries.rindex { _1["type"] == "compaction" }
      previous_summary = nil
      boundary_start = 0
      if prev_index
        prev = entries[prev_index]
        previous_summary = prev["summary"]
        kept = entries.index { _1["id"] == prev["firstKeptEntryId"] }
        boundary_start = kept || (prev_index + 1)
      end

      tokens_before = Context.estimate_tokens(Context.messages(entries))
      cut = find_cut_point(entries, boundary_start, cfg["keepRecentTokens"])
      first_kept = entries[cut["index"]] or return nil

      history_end = cut["splitTurn"] ? cut["turnStart"] : cut["index"]
      to_summarize = entries[boundary_start...history_end].to_a.reject { _1["type"] == "compaction" }
      turn_prefix = cut["splitTurn"] ? entries[cut["turnStart"]...cut["index"]].to_a : []
      return nil if to_summarize.empty? && turn_prefix.empty?

      {
        "firstKeptEntryId" => first_kept["id"],
        "messagesToSummarize" => Context.messages(to_summarize),
        "turnPrefixMessages" => Context.messages(turn_prefix),
        "splitTurn" => cut["splitTurn"],
        "tokensBefore" => tokens_before,
        "previousSummary" => previous_summary,
        "fileOps" => file_lists(to_summarize + turn_prefix, prev_index ? entries[prev_index] : nil),
        "settings" => cfg
      }
    end

    # Which files were read and which were changed — cheap, exact, and the part
    # of a summary a model is most likely to garble.
    def file_lists(entries, previous_compaction)
      read = []
      modified = []
      if previous_compaction && previous_compaction["details"]
        read.concat(previous_compaction.dig("details", "readFiles") || [])
        modified.concat(previous_compaction.dig("details", "modifiedFiles") || [])
      end
      entries.each do |e|
        next unless e.dig("message", "role") == "assistant"

        (e.dig("message", "content") || []).each do |c|
          next unless c["type"] == "toolCall"

          path = c.dig("arguments", "path")
          next unless path.is_a?(String)

          case c["name"]
          when "read" then read << path
          when "write", "edit" then modified << path
          end
        end
      end
      modified.uniq!
      { "readFiles" => (read.uniq - modified).sort, "modifiedFiles" => modified.sort }
    end

    def format_file_operations(file_ops)
      sections = []
      unless (file_ops["readFiles"] || []).empty?
        sections << "<read-files>\n#{file_ops["readFiles"].join("\n")}\n</read-files>"
      end
      unless (file_ops["modifiedFiles"] || []).empty?
        sections << "<modified-files>\n#{file_ops["modifiedFiles"].join("\n")}\n</modified-files>"
      end
      sections.empty? ? "" : "\n\n#{sections.join("\n\n")}"
    end

    # Serialize to text so the model summarizes instead of continuing the chat.
    def serialize(messages)
      parts = []
      messages.each do |m|
        case m["role"]
        when "user"
          text = text_of(m)
          parts << "[User]: #{text}" unless text.empty?
        when "assistant"
          thinking = (m["content"] || []).select { _1["type"] == "thinking" }.map { _1["thinking"] }
          calls = (m["content"] || []).select { _1["type"] == "toolCall" }.map do |c|
            args = (c["arguments"] || {}).map { |k, v| "#{k}=#{JSON.generate(v)}" }.join(", ")
            "#{c["name"]}(#{args})"
          end
          parts << "[Assistant thinking]: #{thinking.join("\n")}" unless thinking.empty?
          text = text_of(m)
          parts << "[Assistant]: #{text}" unless text.empty?
          parts << "[Assistant tool calls]: #{calls.join("; ")}" unless calls.empty?
        when "toolResult"
          text = text_of(m)
          parts << "[Tool result]: #{truncate(text, TOOL_RESULT_MAX_CHARS)}" unless text.empty?
        end
      end
      parts.join("\n\n")
    end

    def text_of(message)
      (message["content"] || []).select { _1["type"] == "text" }.map { _1["text"] }.join("\n")
    end

    def truncate(text, max)
      return text if text.length <= max

      "#{text[0, max]}\n\n[... #{text.length - max} more characters truncated]"
    end

    # The single user message that carries a summarization request.
    def request_message(messages, previous_summary: nil, custom_instructions: nil, kind: :history)
      base =
        case kind
        when :turn_prefix then TURN_PREFIX_PROMPT
        else previous_summary ? UPDATE_PROMPT : INITIAL_PROMPT
        end
      base = "#{base}\n\nAdditional focus: #{custom_instructions}" if custom_instructions.to_s != ""
      text = +"<conversation>\n#{serialize(messages)}\n</conversation>\n\n"
      text << "<previous-summary>\n#{previous_summary}\n</previous-summary>\n\n" if previous_summary
      text << base
      { "role" => "user", "content" => [{ "type" => "text", "text" => text }] }
    end

    # Merge the pieces into the text that goes into the compaction entry.
    def assemble(history_text, turn_prefix_text, file_ops)
      body = history_text.to_s.strip
      body = "No prior history." if body.empty?
      body = "#{body}\n\n---\n\n**Turn context (split turn):**\n\n#{turn_prefix_text.strip}" if turn_prefix_text
      "#{body}#{format_file_operations(file_ops)}"
    end
  end
end
