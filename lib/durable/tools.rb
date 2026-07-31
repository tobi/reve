# frozen_string_literal: true

require "json"
require "open3"
require "fileutils"
require_relative "ipc"

module Durable
  # Tools are code, so they cannot persist and cannot travel as closures (§8).
  # They are registered by *name* in a deep-frozen table that every Ractor loads
  # at boot, with the implementation named by a method symbol — a Proc in a
  # constant would be unreachable from a non-main Ractor, and that restriction
  # happens to enforce exactly the discipline the design asks for: a lane
  # persists only the active names.
  #
  # `replay` is the declared replay safety of §5: recovery re-executes an
  # unfinished call only when the tool_started record AND the current
  # declaration both say "safe".
  module Tools
    MAX_OUTPUT = 40_000

    module_function

    def registry = SPECS
    def spec(name) = SPECS[name]
    def names = SPECS.keys
    def replay_of(name) = SPECS.dig(name, "replay") || "never"

    def declarations(active = nil)
      (active || names).filter_map do |n|
        s = SPECS[n] or next
        { "name" => s["name"], "description" => s["description"],
          "parameters" => s["parameters"], "replay" => s["replay"] }
      end
    end

    # Run a tool in its own Ractor: args JSON in, result JSON out, no shared
    # state. Parallel batches are therefore parallel for real.
    def spawn(name, args, cwd)
      Ractor.new(name, IPC.encode(args), cwd) do |n, args_json, dir|
        Durable::IPC.encode(Durable::Tools.invoke(n, JSON.parse(args_json), dir))
      end
    end

    # No Dir.chdir: it is process-global, and tool Ractors run in parallel
    # inside one process. Every path is resolved against the workspace instead.
    def invoke(name, args, cwd)
      s = SPECS[name] or return error("unknown tool: #{name}")
      public_send(s["handler"], args, cwd || Dir.pwd)
    rescue StandardError => e
      error("#{e.class}: #{e.message}")
    end

    def validate(name, args)
      s = SPECS[name] or return "unknown tool: #{name}"
      missing = (s.dig("parameters", "required") || []) - args.keys
      return "missing required argument(s): #{missing.join(", ")}" unless missing.empty?

      nil
    end

    def ok(text, details: nil)
      r = { "content" => [{ "type" => "text", "text" => text.to_s }], "isError" => false }
      r["details"] = details if details
      r
    end

    def error(text) = { "content" => [{ "type" => "text", "text" => text.to_s }], "isError" => true }

    def clip(text)
      return text if text.bytesize <= MAX_OUTPUT

      "#{text.byteslice(0, MAX_OUTPUT)}\n… [truncated #{text.bytesize - MAX_OUTPUT} bytes]"
    end

    # ── handlers ────────────────────────────────────────────────────────────

    def tool_bash(args, cwd)
      timeout = (args["timeout"] || 120).to_f
      out = +""
      status = nil
      Open3.popen2e({ "TERM" => "dumb" }, "bash", "-lc", args["command"].to_s, chdir: cwd) do |stdin, oe, wait|
        stdin.close
        deadline = Time.now + timeout
        loop do
          break unless wait.alive? || oe.wait_readable(0)

          if oe.wait_readable(0.1)
            begin
              out << oe.read_nonblock(65_536)
            rescue EOFError
              break
            rescue IO::WaitReadable
              nil
            end
          end
          if Time.now >= deadline && wait.alive?
            Process.kill("TERM", wait.pid)
            out << "\n[timed out after #{timeout}s]"
            break
          end
        end
        begin
          out << oe.read
        rescue StandardError
          nil
        end
        status = wait.value
      end
      text = clip(out)
      code = status&.exitstatus || -1
      code.zero? ? ok(text.strip.empty? ? "(no output)" : text) : error("exit #{code}\n#{text}")
    end

    def tool_read(args, cwd)
      path = File.expand_path(args["path"].to_s, cwd)
      return error("no such file: #{path}") unless File.file?(path)

      lines = File.readlines(path)
      offset = (args["offset"] || 1).to_i
      limit = (args["limit"] || 2000).to_i
      slice = lines[(offset - 1)..]&.first(limit) || []
      numbered = slice.each_with_index.map { |l, i| format("%6d\t%s", offset + i, l) }.join
      ok(clip(numbered.empty? ? "(empty)" : numbered), details: { "path" => path, "lines" => lines.size })
    end

    def tool_write(args, cwd)
      path = File.expand_path(args["path"].to_s, cwd)
      FileUtils.mkdir_p(File.dirname(path))
      File.write(path, args["content"].to_s)
      ok("wrote #{args["content"].to_s.bytesize} bytes to #{path}")
    end

    def tool_edit(args, cwd)
      path = File.expand_path(args["path"].to_s, cwd)
      return error("no such file: #{path}") unless File.file?(path)

      body = File.read(path)
      old = args["oldText"].to_s
      count = body.scan(Regexp.new(Regexp.escape(old))).size
      return error("oldText not found in #{path}") if count.zero?
      return error("oldText matches #{count} times in #{path}; make it unique") if count > 1

      File.write(path, body.sub(old, args["newText"].to_s))
      ok("edited #{path}")
    end

    def tool_ls(args, cwd)
      dir = File.expand_path(args["path"] || ".", cwd)
      return error("no such directory: #{dir}") unless File.directory?(dir)

      rows = Dir.children(dir).sort.map do |c|
        full = File.join(dir, c)
        File.directory?(full) ? "#{c}/" : "#{c}\t#{File.size(full)}"
      end
      ok(clip(rows.join("\n")))
    end

    def tool_glob(args, cwd)
      root = File.expand_path(args["path"] || ".", cwd)
      hits = Dir.glob(args["pattern"].to_s, base: root).map { File.join(root, _1) }
      hits = hits.sort_by { |f| -(begin
        File.mtime(f).to_f
      rescue StandardError
        0
      end) }.first(500)
      ok(clip(hits.join("\n").then { _1.empty? ? "(no matches)" : _1 }))
    end

    def tool_grep(args, cwd)
      root = File.expand_path(args["path"] || ".", cwd)
      re = Regexp.new(args["pattern"].to_s)
      pattern = args["glob"] || "**/*"
      out = []
      Dir.glob(pattern, base: root).each do |rel|
        full = File.join(root, rel)
        next unless File.file?(full)
        next if File.size(full) > 2_000_000

        begin
          File.foreach(full).with_index(1) do |line, no|
            out << "#{rel}:#{no}: #{line.strip}" if re.match?(line)
            break if out.size > 400
          end
        rescue ArgumentError, Errno::EACCES
          next
        end
        break if out.size > 400
      end
      ok(clip(out.join("\n").then { _1.empty? ? "(no matches)" : _1 }))
    end

    STR = { "type" => "string" }.freeze
    NUM = { "type" => "number" }.freeze

    SPECS = Ractor.make_shareable({
      "bash" => {
        "name" => "bash", "handler" => :tool_bash, "replay" => "never",
        "description" => "Run a shell command in the workspace. Returns combined output and exit code.",
        "parameters" => { "type" => "object",
                          "properties" => { "command" => STR, "timeout" => NUM },
                          "required" => ["command"] }
      },
      "read" => {
        "name" => "read", "handler" => :tool_read, "replay" => "safe",
        "description" => "Read a text file. Optional offset/limit in lines (1-indexed).",
        "parameters" => { "type" => "object",
                          "properties" => { "path" => STR, "offset" => NUM, "limit" => NUM },
                          "required" => ["path"] }
      },
      "write" => {
        "name" => "write", "handler" => :tool_write, "replay" => "never",
        "description" => "Write a file, creating parent directories. Overwrites.",
        "parameters" => { "type" => "object",
                          "properties" => { "path" => STR, "content" => STR },
                          "required" => %w[path content] }
      },
      "edit" => {
        "name" => "edit", "handler" => :tool_edit, "replay" => "never",
        "description" => "Exact string replacement in a file. oldText must appear exactly once.",
        "parameters" => { "type" => "object",
                          "properties" => { "path" => STR, "oldText" => STR, "newText" => STR },
                          "required" => %w[path oldText newText] }
      },
      "ls" => {
        "name" => "ls", "handler" => :tool_ls, "replay" => "safe",
        "description" => "List a directory.",
        "parameters" => { "type" => "object", "properties" => { "path" => STR } }
      },
      "glob" => {
        "name" => "glob", "handler" => :tool_glob, "replay" => "safe",
        "description" => "Find files by glob pattern, newest first.",
        "parameters" => { "type" => "object", "properties" => { "pattern" => STR, "path" => STR },
                          "required" => ["pattern"] }
      },
      "grep" => {
        "name" => "grep", "handler" => :tool_grep, "replay" => "safe",
        "description" => "Search file contents with a regular expression.",
        "parameters" => { "type" => "object",
                          "properties" => { "pattern" => STR, "path" => STR, "glob" => STR },
                          "required" => ["pattern"] }
      }
    })
  end
end
