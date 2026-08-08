# frozen_string_literal: true

module Leve
  # AGENTS.md discovery is bounded by the agent root. The agent's own files
  # and workspace files travel with it; no home or enclosing repository is
  # consulted.
  module AgentsMd
    NAMES = %w[AGENTS.md CLAUDE.md .agents.md].freeze
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
    def discover(cwd, root: nil)
      cwd = File.expand_path(cwd)
      root = File.expand_path(root || cwd)
      return [] unless cwd == root || cwd.start_with?("#{root}/")

      dirs = []
      cur = cwd
      loop do
        dirs << cur
        break if cur == root

        cur = File.dirname(cur)
      end
      dirs.reverse.filter_map { find_in(_1) }.uniq.map { |p| { "path" => p, "content" => read(p) } }
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
