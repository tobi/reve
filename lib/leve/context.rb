# frozen_string_literal: true

module Leve
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
      when "custom"
        project_custom(entry)
      end
    end

    # Custom entries only enter provider context when they have a projector.
    # A shell command the *user* ran is one: the model must see it, and it must
    # be unmistakably the user's action rather than a tool result of its own.
    def project_custom(entry)
      case entry["customType"]
      when "bash_execution"
        d = entry["data"] || {}
        { "role" => "user",
          "content" => [{ "type" => "text",
                          "text" => "The user ran a shell command.\n" \
                                    "<bash_execution command=#{d["command"].to_s.inspect} " \
                                    "exit=#{d["exitCode"]}>\n#{d["output"]}\n</bash_execution>" }] }
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
