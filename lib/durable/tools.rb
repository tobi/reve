# frozen_string_literal: true

require "json"
require "fileutils"
require "tmpdir"
require "securerandom"
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
    MAX_OUTPUT = 50_000            # bytes kept in the tool result
    MAX_OUTPUT_LINES = 2_000       # lines kept in the tool result
    # Frozen on purpose: an unfrozen String constant is unreachable from a
    # non-main Ractor, and every tool runs in one.
    LOG_DIR = File.join(Dir.tmpdir, "rbagent").freeze

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
    #
    # Abort "signals running effects" (§4), and a Ractor cannot be reached
    # into — so cancellation is a message on the tool Ractor's own incoming
    # port, which a watcher thread inside it turns into a flag the tool polls.
    def cancel(ractor)
      ractor.send("cancel")
    rescue Ractor::ClosedError, Ractor::Error
      nil
    end

    def spawn(name, args, cwd)
      Ractor.new(name, IPC.encode(args), cwd) do |n, args_json, dir|
        cancelled = [false]
        watcher = Thread.new do
          Ractor.receive
          cancelled[0] = true
        rescue StandardError
          nil
        end
        begin
          result = Durable::Tools.invoke(n, JSON.parse(args_json), dir, -> { cancelled[0] })
        ensure
          watcher.kill
        end
        Durable::IPC.encode(result)
      end
    end

    # No Dir.chdir: it is process-global, and tool Ractors run in parallel
    # inside one process. Every path is resolved against the workspace instead.
    def invoke(name, args, cwd, cancel = nil)
      s = SPECS[name] or return error("unknown tool: #{name}")
      public_send(s["handler"], args, cwd || Dir.pwd, cancel || -> { false })
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

    def error(text, details: nil)
      r = { "content" => [{ "type" => "text", "text" => text.to_s }], "isError" => true }
      r["details"] = details if details
      r
    end

    # Big output does not belong in the context window, and it does not belong
    # in /dev/null either: the whole thing goes to a log file and the result
    # says where. The model can then read the parts it needs with `read`, and
    # the UI can expand it without another tool call.
    #
    # => [text_for_the_model, details_hash_or_nil]
    def overspill(text, kind)
      text = text.to_s
      lines = text.lines
      return [text, nil] if text.bytesize <= MAX_OUTPUT && lines.size <= MAX_OUTPUT_LINES

      FileUtils.mkdir_p(LOG_DIR)
      path = File.join(LOG_DIR, "#{kind}-#{SecureRandom.hex(6)}.log")
      File.write(path, text)

      # Keep the tail: for builds, tests and long listings the end is the part
      # that matters.
      kept = lines.last(MAX_OUTPUT_LINES)
      kept = kept.last(kept.size / 2) while kept.join.bytesize > MAX_OUTPUT && kept.size > 1
      omitted = lines.size - kept.size
      shown = kept.join
      footer = "[Full output: #{path}. Truncated: #{kept.size} lines shown, " \
               "#{omitted} earlier lines omitted (#{(MAX_OUTPUT / 1000.0).round(1)}KB limit)]"
      [(shown.end_with?("\n") ? shown : "#{shown}\n") + footer,
       { "logPath" => path, "totalLines" => lines.size, "shownLines" => kept.size,
         "totalBytes" => text.bytesize }]
    end

    # Kept for callers that only need a hard cap (no file, no details).
    def clip(text)
      overspill(text, "clip").first
    end

    # ── handlers ────────────────────────────────────────────────────────────

    # Deliberately not Open3: it spawns a waiter thread, and a Ractor whose
    # only other thread is a waiter can trip Ruby's deadlock detector
    # ("No live threads left") while the child is still running. One thread,
    # one pipe, IO.select, waitpid.
    # One shell runner, shared by the bash tool and by the TUI's `!` command.
    # Streams as it goes (the TUI wants live output), honours cancellation, and
    # kills the child's process group on timeout or abort.
    #
    # => { "output" =>, "exitCode" =>, "cancelled" =>, "timedOut" => }
    def exec_stream(command, cwd, timeout: 120.0, cancel: nil, &on_chunk)
      reader, writer = IO.pipe
      pid = Process.spawn({ "TERM" => "dumb" }, "bash", "-lc", command.to_s,
                          chdir: cwd, out: writer, err: writer, in: File::NULL, pgroup: true)
      writer.close
      out = +""
      deadline = Time.now + timeout
      timed_out = false
      cancelled = false
      loop do
        if cancel&.call
          cancelled = true
          break
        end
        remaining = deadline - Time.now
        if remaining <= 0
          timed_out = true
          break
        end
        next unless IO.select([reader], nil, nil, [remaining, 0.2].min)

        begin
          chunk = reader.readpartial(65_536)
        rescue EOFError
          break
        end
        out << chunk
        on_chunk&.call(chunk)
      end
      if timed_out || cancelled
        begin
          Process.kill("-TERM", pid)
          sleep 0.05
          Process.kill("-KILL", pid)
        rescue StandardError
          nil
        end
        tail = cancelled ? "\n[aborted]" : "\n[timed out after #{timeout}s]"
        out << tail
        on_chunk&.call(tail)
      end
      status = begin
        Process.waitpid2(pid)[1]
      rescue Errno::ECHILD
        nil
      end
      begin
        rest = reader.read.to_s
        unless rest.empty?
          out << rest
          on_chunk&.call(rest)
        end
      rescue StandardError
        nil
      ensure
        reader.close
      end
      { "output" => out, "exitCode" => status&.exitstatus || (timed_out ? 124 : -1),
        "cancelled" => cancelled, "timedOut" => timed_out }
    end

    def tool_bash(args, cwd, cancel = nil)
      started = Time.now
      r = exec_stream(args["command"], cwd, timeout: (args["timeout"] || 120).to_f, cancel: cancel)
      text, spill = overspill(r["output"], "bash")
      took = Time.now - started
      details = (spill || {}).merge("exitCode" => r["exitCode"], "durationMs" => (took * 1000).round)
      return error("Interrupted after #{took.round(1)}s.\n#{text}") if r["cancelled"]

      slow = took > 1 ? "\n[Took #{took.round(1)}s]" : ""
      if r["exitCode"].zero?
        ok(text.strip.empty? ? "(no output)#{slow}" : "#{text}#{slow}", details: details)
      else
        error("exit #{r["exitCode"]}#{slow}\n#{text}", details: details)
      end
    end

    def tool_read(args, cwd, cancel = nil)
      path = File.expand_path(args["path"].to_s, cwd)
      return error("no such file: #{path}") unless File.file?(path)

      lines = File.readlines(path)
      offset = (args["offset"] || 1).to_i
      limit = (args["limit"] || 2000).to_i
      slice = lines[(offset - 1)..]&.first(limit) || []
      numbered = slice.each_with_index.map { |l, i| format("%6d\t%s", offset + i, l) }.join
      text, spill = overspill(numbered.empty? ? "(empty)" : numbered, "read")
      remaining = lines.size - (offset - 1 + slice.size)
      text += "\n[#{remaining} more lines; call read again with offset=#{offset + slice.size}]" if remaining.positive?
      ok(text, details: { "path" => path, "lines" => lines.size }.merge(spill || {}))
    end

    def tool_write(args, cwd, cancel = nil)
      path = File.expand_path(args["path"].to_s, cwd)
      FileUtils.mkdir_p(File.dirname(path))
      File.write(path, args["content"].to_s)
      ok("wrote #{args["content"].to_s.bytesize} bytes to #{path}")
    end

    def tool_edit(args, cwd, cancel = nil)
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

    def tool_ls(args, cwd, cancel = nil)
      dir = File.expand_path(args["path"] || ".", cwd)
      return error("no such directory: #{dir}") unless File.directory?(dir)

      rows = Dir.children(dir).sort.map do |c|
        full = File.join(dir, c)
        File.directory?(full) ? "#{c}/" : "#{c}\t#{File.size(full)}"
      end
      text, spill = overspill(rows.join("\n"), "ls")
      ok(text, details: spill)
    end

    def tool_glob(args, cwd, cancel = nil)
      root = File.expand_path(args["path"] || ".", cwd)
      hits = Dir.glob(args["pattern"].to_s, base: root).map { File.join(root, _1) }
      hits = hits.sort_by { |f| -(begin
        File.mtime(f).to_f
      rescue StandardError
        0
      end) }.first(500)
      text, spill = overspill(hits.join("\n").then { _1.empty? ? "(no matches)" : _1 }, "glob")
      ok(text, details: spill)
    end

    def tool_grep(args, cwd, cancel = nil)
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
        break if out.size > 400 || cancel&.call
      end
      return error("Interrupted.") if cancel&.call

      text, spill = overspill(out.join("\n").then { _1.empty? ? "(no matches)" : _1 }, "grep")
      ok(text, details: spill)
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
