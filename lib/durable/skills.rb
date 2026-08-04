# frozen_string_literal: true

require_relative "frontmatter"

module Durable
  # Agent Skills (agentskills.io): a directory with a SKILL.md whose frontmatter
  # carries a name and a description. Descriptions go into the system prompt so
  # the model can decide when a skill applies; the body is read on demand with
  # the `read` tool, or loaded eagerly by `/skill <name>`.
  #
  # Discovery, project before user (project wins on a name collision):
  #   ./.agents/skills  ./.agent/skills  ./.rbagent/skills
  #   ~/.agents/skills  ~/.agent/skills  ~/.config/rbagent/skills
  #
  # Rules: a directory containing SKILL.md is a skill root and is not recursed
  # into; otherwise direct .md children of a skills root count, and
  # subdirectories are searched for SKILL.md.
  module Skills
    MAX_NAME = 64
    MAX_DESCRIPTION = 1024
    # "skills/" comes first: in an agent directory (instructions.md, tools/,
    # skills/) that is where they live.
    PROJECT_DIRS = ["skills", ".agents/skills", ".pi/skills", ".rbagent/skills"].freeze
    USER_DIRS = ["~/.agents/skills", "~/.pi/agent/skills", "~/.config/rbagent/skills"].freeze

    module_function

    def roots(cwd, user: true)
      PROJECT_DIRS.map { File.join(File.expand_path(cwd), _1) } +
        (user ? USER_DIRS.map { File.expand_path(_1) } : [])
    end

    # => { "skills" => [...], "diagnostics" => [...] }
    def load(cwd: Dir.pwd, extra_dirs: [], user: true)
      skills = {}
      diagnostics = []
      real_paths = {}
      (roots(cwd, user: user) + extra_dirs.map { File.expand_path(_1) }).each do |dir|
        scope = dir.start_with?(File.expand_path(cwd)) ? "project" : "user"
        found = scan(dir, dir, true)
        found[:diagnostics].each { diagnostics << _1 }
        found[:skills].each do |sk|
          real = begin
            File.realpath(sk["path"])
          rescue StandardError
            sk["path"]
          end
          next if real_paths[real]

          if (existing = skills[sk["name"]])
            diagnostics << { "type" => "collision", "path" => sk["path"],
                             "message" => "skill name #{sk["name"].inspect} already provided by #{existing["path"]}" }
            next
          end
          real_paths[real] = true
          skills[sk["name"]] = sk.merge("scope" => scope)
        end
      end
      { "skills" => skills.values, "diagnostics" => diagnostics }
    end

    def scan(dir, root, include_root_files)
      out = { skills: [], diagnostics: [] }
      return out unless File.directory?(dir)

      children = begin
        Dir.children(dir).sort
      rescue StandardError
        []
      end

      if children.include?("SKILL.md") && File.file?(File.join(dir, "SKILL.md"))
        one = read_skill(File.join(dir, "SKILL.md"))
        out[:skills] << one[:skill] if one[:skill]
        out[:diagnostics].concat(one[:diagnostics])
        return out # a skill root is never recursed into
      end

      children.each do |name|
        next if name.start_with?(".") || name == "node_modules"

        full = File.join(dir, name)
        if File.directory?(full)
          sub = scan(full, root, false)
          out[:skills].concat(sub[:skills])
          out[:diagnostics].concat(sub[:diagnostics])
        elsif include_root_files && name.end_with?(".md") && File.file?(full)
          one = read_skill(full)
          out[:skills] << one[:skill] if one[:skill]
          out[:diagnostics].concat(one[:diagnostics])
        end
      end
      out
    end

    def read_skill(path)
      diagnostics = []
      body = File.read(path)
      fm, content = Frontmatter.parse(body)
      name = (fm["name"] || File.basename(File.dirname(path))).to_s
      description = fm["description"].to_s

      diagnostics.concat(validate_name(name).map { { "type" => "warning", "path" => path, "message" => _1 } })
      diagnostics.concat(validate_description(description)
                           .map { { "type" => "warning", "path" => path, "message" => _1 } })

      if description.strip.empty?
        # Without a description the model cannot decide when to use it.
        return { skill: nil, diagnostics: diagnostics }
      end

      skill = { "name" => name, "description" => description.strip, "path" => path,
                "baseDir" => File.dirname(path), "body" => content,
                "disableModelInvocation" => fm["disable-model-invocation"] == true }
      { skill: skill, diagnostics: diagnostics }
    rescue StandardError => e
      { skill: nil, diagnostics: [{ "type" => "warning", "path" => path, "message" => e.message }] }
    end

    def validate_name(name)
      errors = []
      errors << "name exceeds #{MAX_NAME} characters (#{name.length})" if name.length > MAX_NAME
      errors << "name must be lowercase a-z, 0-9 and hyphens only" unless /\A[a-z0-9-]+\z/.match?(name)
      errors << "name must not start or end with a hyphen" if name.start_with?("-") || name.end_with?("-")
      errors << "name must not contain consecutive hyphens" if name.include?("--")
      errors
    end

    def validate_description(description)
      return ["description is required"] if description.strip.empty?
      return [] if description.length <= MAX_DESCRIPTION

      ["description exceeds #{MAX_DESCRIPTION} characters (#{description.length}) — " \
       "keep it to when-to-use guidance and move the detail into the skill body"]
    end

    def find(skills, name) = skills.find { _1["name"] == name }

    # The system-prompt section, in the Agent Skills XML shape.
    def format_for_prompt(skills)
      visible = skills.reject { _1["disableModelInvocation"] }
      return "" if visible.empty?

      lines = [
        "The following skills provide specialized instructions for specific tasks.",
        "Use the read tool to load a skill's file when the task matches its description.",
        "When a skill file references a relative path, resolve it against the skill directory " \
        "(the parent of SKILL.md) and use that absolute path in tool commands.",
        "",
        "<available_skills>"
      ]
      visible.each do |sk|
        lines << "  <skill>"
        lines << "    <name>#{escape(sk["name"])}</name>"
        lines << "    <description>#{escape(sk["description"])}</description>"
        lines << "    <location>#{escape(sk["path"])}</location>"
        lines << "  </skill>"
      end
      lines << "</available_skills>"
      lines.join("\n")
    end

    def escape(str)
      str.to_s.gsub("&", "&amp;").gsub("<", "&lt;").gsub(">", "&gt;")
         .gsub('"', "&quot;").gsub("'", "&apos;")
    end

    # The message that /skill <name> puts into the conversation.
    def invocation_message(skill, additional_instructions = nil)
      text = +"Use the skill **#{skill["name"]}** (#{skill["path"]}).\n\n"
      text << "Its instructions follow. Relative paths in them resolve against #{skill["baseDir"]}.\n\n"
      text << "<skill name=\"#{escape(skill["name"])}\" path=\"#{escape(skill["path"])}\">\n"
      text << skill["body"].to_s.strip
      text << "\n</skill>"
      text << "\n\nAdditional instructions: #{additional_instructions}" if additional_instructions.to_s != ""
      text
    end
  end
end
