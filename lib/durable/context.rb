# frozen_string_literal: true

module Durable
  # Entry → provider-context projection. Entries without a projector never enter
  # provider context (§12).
  module Context
    module_function

    def messages(entries)
      entries.filter_map { |e| project(e) }.flatten
    end

    def project(entry)
      case entry["type"]
      when "message" then entry["message"]
      when "compaction"
        { "role" => "user",
          "content" => [{ "type" => "text",
                          "text" => "[Summary of the earlier conversation]\n#{entry["summary"]}" }] }
      when "branch_summary"
        { "role" => "user",
          "content" => [{ "type" => "text",
                          "text" => "[Summary of an abandoned branch]\n#{entry["summary"]}" }] }
      end
    end

    def estimate_tokens(messages)
      chars = messages.sum do |m|
        (m["content"].is_a?(Array) ? m["content"] : []).sum do |c|
          case c["type"]
          when "text" then c["text"].to_s.length
          when "thinking" then c["thinking"].to_s.length
          when "toolCall" then JSON.generate(c["arguments"] || {}).length + 40
          else 200
          end
        end + 20
      end
      chars / 4
    end

    def summary_instructions(task, custom)
      base =
        if task == "compaction"
          <<~TXT
            Summarize the conversation so far so that work can continue without the full history.
            Cover: the user's goals and constraints, decisions made and why, files and symbols touched,
            commands run and their outcomes, current state, and the immediate next steps.
            Be specific — file paths, function names, error messages. No pleasantries, no meta commentary.
          TXT
        else
          <<~TXT
            Summarize this branch of the conversation before we move elsewhere: what was attempted,
            what was learned, what was changed on disk, and what remains open. Be specific and brief.
          TXT
        end
      custom.to_s.empty? ? base : "#{base}\nAdditional instructions: #{custom}"
    end
  end
end
