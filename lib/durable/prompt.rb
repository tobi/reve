# frozen_string_literal: true

require_relative "agents_md"
require_relative "skills"

module Durable
  # System prompt construction, modelled on pi's: a short role statement, the
  # available tools with one-line snippets, guidelines, then project context
  # (AGENTS.md), then skills, and the working directory last.
  module Prompt
    # One line per tool, in the order they should be considered.
    SNIPPETS = {
      "read" => "Read file contents (offset/limit in lines)",
      "write" => "Create or overwrite a file",
      "edit" => "Exact string replacement in a file",
      "bash" => "Run a shell command in the workspace",
      "ls" => "List a directory",
      "glob" => "Find files by glob pattern",
      "grep" => "Search file contents with a regular expression"
    }.freeze

    GUIDELINES = [
      "Investigate before acting: read the files you are about to change",
      "Use edit for targeted changes, write for new files, bash for everything else",
      "Batch independent tool calls in one message — they execute in parallel",
      "Verify APIs with grep/glob/read instead of guessing",
      "After changing code, run the relevant tests or a quick sanity command",
      "Be concise in your responses",
      "Show file paths clearly when working with files"
    ].freeze

    module_function

    def system_prompt(cwd: Dir.pwd, tools: nil, agents: nil, skills: nil, goal: nil, append: nil)
      tools ||= SNIPPETS.keys
      agents ||= AgentsMd.discover(cwd)
      skills ||= []
      visible = tools.select { SNIPPETS.key?(_1) }
      tool_list = visible.empty? ? "(none)" : visible.map { "- #{_1}: #{SNIPPETS[_1]}" }.join("\n")

      prompt = +<<~TXT.strip
        You are an expert coding assistant operating inside rbagent, a durable coding agent harness. You help users by reading files, executing commands, editing code, and writing new files.

        Available tools:
        #{tool_list}

        In addition to the tools above, you may have access to other tools depending on the project.

        Guidelines:
        #{GUIDELINES.map { "- #{_1}" }.join("\n")}

        About the harness you run in (mention it only when the user asks):
        - Every message, tool call and tool result is recorded before it happens, so an interrupted session resumes exactly where it stopped.
        - Work runs on a lane; a session can have several lanes running in parallel over shared history.
        - The user can steer you mid-run: a new user message may arrive between your steps. Take it into account immediately.
        - When context runs out it is compacted into a structured summary; write your messages so they still make sense after that.
      TXT

      prompt << "\n\n#{append.strip}" if append.to_s.strip != ""

      if goal.to_s.strip != ""
        prompt << "\n\n<session_goal>\n#{goal.strip}\n</session_goal>\n" \
                  "This goal was set by the user for the whole session. Keep it in view; " \
                  "if a request conflicts with it, say so."
      end

      unless agents.empty?
        prompt << "\n\n<project_context>\n\nProject-specific instructions and guidelines. " \
                  "They are the user's standing orders; prefer the closest (last) file on conflict.\n\n"
        agents.each do |f|
          prompt << "<project_instructions path=\"#{f["path"]}\">\n#{f["content"].strip}\n</project_instructions>\n\n"
        end
        prompt << "</project_context>\n"
      end

      if tools.include?("read")
        section = Skills.format_for_prompt(skills)
        prompt << "\n\n#{section}" unless section.empty?
      end

      prompt << "\n\nCurrent working directory: #{cwd}"
      prompt
    end
  end
end
