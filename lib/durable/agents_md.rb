# frozen_string_literal: true

module Durable
  # AGENTS.md discovery.
  #
  # Static: every AGENTS.md from the repository root down to the working
  # directory, outermost first, plus a global one. They become part of the
  # system prompt, so they are visible to every request of every lane.
  #
  # Dynamic: a nested AGENTS.md deeper in the tree is loaded the first time a
  # tool touches a path under it, and appended to that tool's result — the
  # append-only-context rule of the design means late context must arrive at the
  # tail, and a tool result is exactly that.
  module AgentsMd
    NAMES = %w[AGENTS.md CLAUDE.md .agents.md].freeze
    GLOBAL = [File.expand_path("~/.config/rbagent/AGENTS.md"),
              File.expand_path("~/.rbagent/AGENTS.md")].freeze
    MAX_BYTES = 32_000

    module_function

    def find_in(dir)
      NAMES.each do |n|
        p = File.join(dir, n)
        return p if File.file?(p)
      end
      nil
    end

    # Outermost first: the closest file wins by being last in the prompt.
    def discover(cwd)
      cwd = File.expand_path(cwd)
      dirs = []
      cur = cwd
      loop do
        dirs << cur
        break if cur == File.dirname(cur) || cur == Dir.home

        parent = File.dirname(cur)
        # Stop at the repository root, inclusive.
        break if File.directory?(File.join(cur, ".git")) && cur != cwd

        cur = parent
      end
      paths = GLOBAL.select { File.file?(_1) } + dirs.reverse.filter_map { find_in(_1) }
      paths.uniq.map { |p| { "path" => p, "content" => read(p) } }
    end

    def read(path)
      body = File.read(path)
      body.bytesize > MAX_BYTES ? "#{body.byteslice(0, MAX_BYTES)}\n… [truncated]" : body
    end

    def render(files)
      return "" if files.empty?

      files.map do |f|
        "<agents_md path=\"#{f["path"]}\">\n#{f["content"].strip}\n</agents_md>"
      end.join("\n\n")
    end

    # The nested file governing `path`, if it is below cwd and not already
    # loaded. Returns nil when there is nothing new to say.
    def nested_for(path, cwd, loaded)
      full = File.expand_path(path.to_s)
      cwd = File.expand_path(cwd)
      return nil unless full.start_with?("#{cwd}/")

      dir = File.directory?(full) ? full : File.dirname(full)
      found = []
      while dir.start_with?(cwd) && dir != cwd
        f = find_in(dir)
        found << f if f && !loaded.include?(f)
        dir = File.dirname(dir)
      end
      return nil if found.empty?

      found.reverse.map { |f| { "path" => f, "content" => read(f) } }
    end
  end
end
