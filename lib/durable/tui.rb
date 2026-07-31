# frozen_string_literal: true

require_relative "harness"
require_relative "term"

module Durable
  # Terminal UI. A client of the harness like any other: one atomic snapshot
  # from watch(), then a live event stream (§9). It never touches session state.
  #
  # Screen model: output scrolls above one input line that the UI owns. Every
  # print hides the input line, writes, and redraws it — so the prompt is never
  # duplicated and typing survives a burst of streaming output. The input line
  # carries a right-aligned status (spinner, elapsed, tools, tokens) like a zsh
  # RPROMPT, and tool results are rendered the same way: the call on the left,
  # its outcome right-aligned on the same line.
  class TUI
    RESET = "\e[0m"
    STYLE = {
      dim: "\e[2m", bold: "\e[1m", bright: "\e[1;97m", red: "\e[31m", green: "\e[32m", yellow: "\e[33m",
      blue: "\e[34m", magenta: "\e[35m", cyan: "\e[36m", gray: "\e[90m", white: "\e[97m"
    }.freeze
    SPINNER = %w[⠋ ⠙ ⠹ ⠸ ⠼ ⠴ ⠦ ⠧ ⠇ ⠏].freeze

    HELP = <<~TXT
      conversation
        <text>              prompt · typing while the agent works steers it
        !<command>          run a shell command; it and its output enter the conversation
        <tab>               complete commands, skills, models, lanes, tools, paths
        ctrl-o              expand the last tool output
        /goal [text]        show or set the session goal (kept in every prompt)
        /skill [name]       list skills, or run one now
        /steer <text>       queue a steering message explicitly
        /next <text>        queue a message for the next run
        /abort              abort the running operation      (or Ctrl-C)
        /resume             resume a suspended operation
        /compact [instr]    compact the context now
      session
        /tree               the current branch
        /log [n]            the tail of the durable log (entries + records)
        /state              lane state as JSON
        /cache              prompt-cache hit rate for this lane
        /output [n]         print the last (or n-th last) tool output in full
        /back [n]           navigate n user turns back (branches the tree)
        /agents             AGENTS.md files in play
      lanes
        /lanes              lane inventory
        /lane <name>        prompt a lane (created at the current leaf if new)
      config
        /model [spec]       show or set the model (provider, provider/id, or id)
        /models             list available models
        /think <level>      off | low | medium | high
        /tools [names]      show or set the active tools
        /verbose            toggle thinking + full tool output
      /help  /exit
    TXT

    COMMANDS = %w[help exit quit abort resume compact verbose goal skill model models think
                  tools state cache output agents lanes lane tree back log steer next].freeze
    THINK_LEVELS = %w[off low medium high].freeze

    def initialize(harness, suspended, lane: "main")
      @h = harness
      @suspended = suspended
      @lane = lane
      @verbose = false
      @line = Term::Line.new
      @mutex = Mutex.new
      @tools = {}
      @usage = { "input" => 0, "output" => 0 }
      @started_at = nil
      @stream_open = false
      @line_buf = +""
      @in_code = false
      @out = $stdout
    end

    # ── styling ───────────────────────────────────────────────────────────

    def s(style, text) = "#{STYLE[style]}#{text}#{RESET}"
    # One short of the terminal: see Term::Line#redraw.
    def width = Term.width - 1
    def visible(str) = Term.visible(str)
    def clip(str, n) = Term.clip(str, n)

    def wrap(text, indent = "")
      limit = width - indent.length
      out = []
      text.to_s.split(/\s+/).each do |word|
        if out.empty? || (visible(out.last).length + visible(word).length + 1) > limit
          out << +word.dup
        else
          out.last << " " << word
        end
      end
      out.map { "#{indent}#{_1}" }
    end

    # ── the one screen primitive ──────────────────────────────────────────

    # Print above the input line. Everything that reaches the screen goes here.
    def emit(*lines)
      @mutex.synchronize do
        @line.hide
        lines.flatten.each { @out.puts(_1) }
        @line.rprompt = status_rprompt
        @line.redraw if @input_active
        @out.flush
      end
    end

    def refresh_status
      @mutex.synchronize do
        @line.rprompt = status_rprompt
        @line.redraw if @input_active
      end
    end

    def status_rprompt
      return nil unless @started_at

      frame = SPINNER[(Time.now.to_f * 10).to_i % SPINNER.size]
      bits = ["#{(Time.now - @started_at).to_i}s"]
      bits << @tools.values.uniq.join(",") unless @tools.empty?
      tok = @usage["input"].to_i + @usage["output"].to_i
      bits << "#{(tok / 1000.0).round(1)}k" if tok.positive?
      s(:cyan, frame) + s(:dim, " #{bits.join(" · ")}")
    end

    def start_spinner
      @started_at = Time.now
      @spinner ||= Thread.new do
        loop do
          sleep 0.1
          refresh_status if @started_at
        end
      end
    end

    def stop_spinner
      @started_at = nil
      @tools.clear
      refresh_status
    end

    # ── markdown-ish streaming ────────────────────────────────────────────

    def format_line(line)
      if line.strip.start_with?("```")
        lang = line.strip.delete_prefix("```")
        @in_code = !@in_code
        return [@in_code ? s(:gray, "  ┌ #{lang.empty? ? "code" : lang}") : s(:gray, "  └")]
      end
      return [s(:gray, "  │ ") + s(:white, line)] if @in_code

      case line
      when /\A(\#{1,6})\s+(.*)\z/
        # Headlines are the one thing worth making brighter than body text.
        [s(:bright, inline(::Regexp.last_match(2)))]
      when /\A\s*([-*])\s+(.*)\z/ then wrap("#{s(:cyan, "•")} #{inline(::Regexp.last_match(2))}", "  ")
      when /\A\s*(\d+)\.\s+(.*)\z/
        wrap("#{s(:cyan, "#{::Regexp.last_match(1)}.")} #{inline(::Regexp.last_match(2))}", "  ")
      when /\A\s*\z/ then [""]
      else wrap(inline(line))
      end
    end

    def inline(text)
      text.gsub(/`([^`]+)`/) { s(:cyan, ::Regexp.last_match(1)) }
          .gsub(/\*\*([^*]+)\*\*/) { s(:bold, ::Regexp.last_match(1)) }
    end

    def stream_text(chunk)
      @line_buf << chunk
      return unless @line_buf.include?("\n")

      *lines, rest = @line_buf.split("\n", -1)
      @line_buf = rest.to_s
      emit(lines.flat_map { format_line(_1) })
    end

    def flush_text
      return if @line_buf.empty?

      line = @line_buf
      @line_buf = +""
      emit(format_line(line))
    end

    # ── event rendering ───────────────────────────────────────────────────

    def start_renderer
      @renderer = Thread.new do
        watch = @h.watch(nil)
        watch.each_event { |ev| render(ev) }
      rescue Ractor::ClosedError
        nil
      end
    end

    def render(ev)
      tag = ev["lane"] == @lane ? "" : s(:magenta, "[#{ev["lane"]}] ")
      case ev["type"]
      when "run_start", "run_resume", "compaction_start", "navigation_start"
        @busy = true if ev["lane"] == @lane
        @run_started = Time.now
        @usage = { "input" => 0, "output" => 0 } if ev["type"].start_with?("run")
        start_spinner
        emit(s(:dim, "· resuming")) if ev["type"] == "run_resume"
        emit(s(:magenta, "  ~ compacting context (#{ev["reason"]})…")) if ev["type"] == "compaction_start"
      when "message_update"
        d = ev["event"]
        case d && d["type"]
        when "text_delta" then stream_text(d["text"])
        when "thinking_delta" then stream_text(d["text"]) if @verbose
        end
      when "message_end"
        flush_text
        msg = ev["message"]
        case msg["role"]
        when "user"
          text = text_of(msg)
          # We echo what the user typed immediately; the committed entry then
          # arrives as an event. Show it only if it is not that same line.
          emit(tag + s(:cyan, "› ") + text.lines.first.to_s.strip) unless claim_echo(text)
        when "toolResult" then render_tool_result(msg)
        when "assistant" then @usage = msg["usage"] || @usage
        end
      when "tool_start"
        flush_text
        @tools[ev["toolCallId"]] = ev["toolName"]
        @tool_started_at ||= {}
        @tool_started_at[ev["toolCallId"]] = Time.now
        @tool_args ||= {}
        @tool_args[ev["toolCallId"]] = ev["args"]
        refresh_status
      when "tool_end" then @tools.delete(ev["toolCallId"])
      when "retry_scheduled"
        emit(s(:yellow, "  ^ retry #{ev["attempt"]}/#{ev["maxAttempts"]} in #{ev["delayMs"]}ms — " \
                        "#{clip(ev["errorMessage"].to_s, width - 30)}"))
      when "compaction_end" then emit(s(:magenta, "  ~ compaction #{ev["outcome"]}"))
      when "navigation_end"
        emit(s(:magenta, "  <- moved to #{ev["newLeafId"].to_s[0, 10]} (#{ev["outcome"]})"))
      when "run_suspend"
        @busy = false if ev["lane"] == @lane
        stop_spinner
        emit(s(:yellow, "|| parked on a deferred request — /resume later"))
      when "run_abort" then emit(s(:yellow, "  ! aborting…"))
      when "run_end"
        flush_text
        @busy = false if ev["lane"] == @lane
        stop_spinner
        emit(footer(ev), "")
        refresh_prompt if @input_active
      when "cache_invalidated"
        if ev["expected"]
          emit(s(:dim, "  prompt cache reset (#{ev["cause"]})"))
        else
          emit("\e[41;97;1m PROMPT CACHE \e[0m " + s(:red, (ev["reasons"] || []).join("; ")))
        end
      when "fault" then emit(s(:red, "harness faulted: #{ev["message"]}"))
      when "handler_error" then emit(s(:red, "hook error (#{ev["hook"]}): #{ev["error"]}"))
      when "lane_created" then emit(s(:dim, "  + lane #{ev["lane"]}"))
      end
    end

    # A finished turn should read like a receipt, not an announcement: the
    # common case (it worked) says nothing on the left and puts the numbers
    # that matter — time, output size, how full the context now is — quietly on
    # the right. Only an unhappy outcome gets a word.
    def footer(ev)
      u = ev.dig("finalMessage", "usage") || @usage || {}
      bits = []
      bits << "#{(Time.now - @run_started).round(1)}s" if @run_started
      bits << "#{tok(u["output"])} out" if u["output"].to_i.positive?
      bits << "ctx #{tok(context_used(u))}/#{tok(context_window)}" if context_used(u).positive?
      hit = cache_rate(u)
      bits << "cache #{hit}%" if hit
      right = s(:dim, bits.join(" · "))
      left =
        case ev["outcome"]
        when "completed" then ""
        when "aborted" then s(:yellow, "  aborted")
        else s(:red, "  #{ev["outcome"]}#{ev.dig("error", "message") ? ": #{clip(ev.dig("error", "message"), width / 2)}" : ""}")
        end
      Term.two_column(left, right, width)
    end

    def tok(n)
      n = n.to_i
      return n.to_s if n < 1000
      return "#{(n / 1000.0).round(1)}k" if n < 10_000

      "#{(n / 1000.0).round}k"
    end

    # "input" already includes cached tokens (providers normalise this), so the
    # context in play is simply input + output.
    def context_used(usage)
      usage["input"].to_i + usage["output"].to_i
    end

    def cache_rate(usage)
      input = usage["input"].to_i
      return nil unless input.positive? && usage["cacheRead"]

      (usage["cacheRead"].to_i * 100.0 / input).round
    end

    def context_window
      @context_window ||= (@h.model["contextWindow"] || 200_000)
    end

    # Single-width glyphs only: an ambiguous-width icon costs one cell of
    # budget and wraps the line on half the terminals out there.
    TOOL_ICON = { "bash" => "$", "read" => "<", "write" => "+", "edit" => "~",
                  "ls" => "/", "glob" => "*", "grep" => "?" }.freeze

    def tool_label(name, args)
      icon = TOOL_ICON[name] || "→"
      args ||= {}
      return "  #{s(:blue, icon)} #{args["command"].to_s.gsub("\n", " ⏎ ")}" if name == "bash"

      detail =
        case name
        when "read", "write", "ls" then rel(args["path"])
        when "edit" then "#{rel(args["path"])} #{s(:dim, clip(args["oldText"].to_s.gsub("\n", "⏎"), 24))}"
        when "glob" then args["pattern"].to_s
        when "grep" then "#{args["pattern"]} #{s(:dim, args["glob"] || "")}"
        else args.is_a?(Hash) ? args.map { |k, v| "#{k}=#{clip(v.to_s, 24)}" }.join(" ") : ""
        end
      "  #{s(:blue, icon)} #{s(:bold, name)} #{detail}"
    end

    # The RPROMPT idea: the call on the left, its outcome right-aligned. Long
    # output is collapsed to a hint; ctrl-o (or /output) prints it, and the
    # tool has already spilled anything huge to a log file the model can read.
    def remember_output(msg, lines)
      @outputs ||= []
      @outputs << { "tool" => msg["toolName"], "lines" => lines,
                    "logPath" => msg.dig("details", "logPath"),
                    "total" => msg.dig("details", "totalLines") || lines.size }
      @outputs.shift while @outputs.size > 20
    end

    def expand_last_output(index = -1)
      out = (@outputs || [])[index]
      return emit(s(:dim, "  no tool output to expand")) unless out

      lines = out["lines"]
      if out["logPath"] && File.exist?(out["logPath"])
        lines = File.readlines(out["logPath"]).map(&:rstrip)
      end
      emit(s(:dim, "  ── #{out["tool"]} · #{lines.size} lines#{out["logPath"] ? " · #{out["logPath"]}" : ""}"))
      emit(lines.last(400).map { s(:gray, "  #{clip(_1, width - 4)}") })
      emit(s(:dim, "  ── end")) if lines.size > 400
    end

    def render_tool_result(msg)
      id = msg["toolCallId"]
      args = (@tool_args || {}).delete(id)
      started = (@tool_started_at || {}).delete(id)
      body = text_of(msg).to_s
      lines = body.lines.map(&:rstrip).reject(&:empty?)
      # The spill footer is for the model; the UI shows the path in the hint.
      lines.pop if lines.last.to_s.start_with?("[Full output:")
      error = msg["isError"]

      summary = result_summary(msg["toolName"], lines, error)
      extra = []
      extra << "#{(Time.now - started).round(1)}s" if started && (Time.now - started) > 0.4
      mark = error ? s(:red, "✗") : s(:green, "✓")
      right = "#{mark} #{s(error ? :red : :gray, clip(summary, [width / 3, 24].max))}"
      right += s(:dim, " #{extra.join(" · ")}") unless extra.empty?

      left = tool_label(msg["toolName"], args)
      emit(Term.two_column(clip(left, width - Term.display_width(right) - 2), right, width))

      remember_output(msg, lines)
      shown = error ? lines.first(12) : (@verbose ? lines.first(60) : [])
      shown = shown.drop(1) if shown.first == lines.first
      emit(shown.map { s(:gray, "      #{clip(_1, width - 8)}") }) unless shown.empty?

      hidden = lines.size - shown.size - 1
      total = msg.dig("details", "totalLines") || lines.size
      hidden = total - shown.size - 1 if total > lines.size
      return unless hidden.positive?

      spill = msg.dig("details", "logPath")
      emit(s(:dim, "      … #{hidden} more line#{hidden == 1 ? "" : "s"} · ctrl-o to expand" \
                   "#{spill ? " · #{spill}" : ""}"))
    end

    # What belongs on the right: the outcome, not the output.
    def result_summary(tool, lines, error)
      first = lines.first.to_s.gsub(/\s+/, " ")
      return first if error

      case tool
      when "read" then "#{lines.size} lines"
      when "glob", "grep"
        first == "(no matches)" ? "no matches" : "#{lines.size} #{tool == "grep" ? "hits" : "files"}"
      when "ls" then "#{lines.size} entries"
      when "write", "edit" then first
      when "bash"
        # For a command, the last line is the answer; the first is scrollback.
        return "ok" if first == "(no output)" || lines.empty?

        lines.size > 1 ? "#{lines.last.to_s.gsub(/\s+/, " ")} · #{lines.size} lines" : first
      else first
      end
    end

    def rel(path)
      p = path.to_s
      cwd = Dir.pwd
      p.start_with?("#{cwd}/") ? p.delete_prefix("#{cwd}/") : p
    end

    def text_of(msg)
      (msg["content"] || []).select { _1["type"] == "text" }.map { _1["text"] }.join
    end

    # ── banner ────────────────────────────────────────────────────────────

    def banner
      st = @h.state
      emit(s(:bold, "rbagent") + s(:dim, "  durable harness on ractors · ruby #{RUBY_VERSION}"),
           s(:dim, "  #{st.dig("model", "provider")}/#{st.dig("model", "modelId")} · " \
                   "#{st["activeTools"].size} tools · lane #{@lane} · #{Dir.pwd}"))
      emit(s(:dim, "  AGENTS.md: #{@h.agents_md.map { rel(_1["path"]) }.join(", ")}")) unless @h.agents_md.empty?
      emit(s(:dim, "  skills: #{@h.skills.map { _1["name"] }.sort.join(", ")}")) unless @h.skills.empty?
      @h.skill_diagnostics.each { emit(s(:yellow, "  ! skill #{rel(_1["path"])}: #{_1["message"]}")) }
      emit(s(:magenta, "  goal: #{clip(st["goal"].to_s.gsub(/\s+/, " "), width - 10)}")) if st["goal"]
      @suspended.each do |sp|
        emit(s(:yellow, "  || suspended #{sp["kind"]} on lane #{sp["lane"]} (#{sp["reason"]}) — /resume"))
      end
      emit(s(:dim, "  /help for commands"), "")
    end

    # ── main loop ─────────────────────────────────────────────────────────

    def run
      banner
      start_renderer
      return run_piped unless Term.tty?

      Term.cbreak!
      @input_active = true
      trap("INT") { handle_interrupt }
      refresh_prompt
      loop do
        char = $stdin.getc
        break if char.nil?

        # A leading ! is a mode, not a character: it becomes the prompt.
        if char == "!" && @line.buffer.empty? && !@shell_mode
          @shell_mode = true
          refresh_prompt
          next
        end
        if @shell_mode && @line.buffer.empty? && ["\u007F", "\b"].include?(char)
          @shell_mode = false
          refresh_prompt
          next
        end

        action =
          if char == "\e"
            seq = read_escape
            @line.feed_escape(seq)
          else
            @line.feed(char)
          end
        case action
        when :submit
          text = @line.take
          shell_line = @shell_mode
          @shell_mode = false
          @mutex.synchronize do
            @line.hide
            @out.flush
          end
          break if submit(shell_line ? "!#{text}" : text) == :exit
        when :complete then complete!
        when :expand then expand_last_output
        when :interrupt then handle_interrupt
        when :eof then break
        when :clear
          @mutex.synchronize { @out.print("\e[2J\e[H") }
        end
        refresh_prompt
      end
      emit("bye")
    ensure
      shutdown
    end

    # Escape sequences arrive as separate reads; grab the short tail.
    def read_escape
      seq = +""
      2.times do
        c = begin
          $stdin.read_nonblock(1)
        rescue IO::WaitReadable, EOFError
          IO.select([$stdin], nil, nil, 0.02) ? retry : nil
        end
        break if c.nil?

        seq << c
        break if c =~ /[A-Za-z~]/
      end
      seq
    end

    # Tab completion. What can be completed depends on where the cursor is:
    # the command itself, that command's argument, or a path.
    def complete!
      buffer = @shell_mode ? "!#{@line.buffer}" : @line.buffer
      candidates, token, start = completion_for(buffer, @line.token.first, @line.token.last)
      return if candidates.nil? || candidates.empty?

      if candidates.size == 1
        @line.replace_token(candidates.first + (candidates.first.end_with?("/") ? "" : " "), start)
        return
      end
      prefix = common_prefix(candidates)
      @line.replace_token(prefix, start) if prefix.length > token.length
      emit(columns(candidates))
    end

    # => [candidates, token, replace_start]
    def completion_for(buffer, token, start)
      if buffer.start_with?("/") && !buffer[0...start].include?(" ")
        cmds = COMMANDS.select { _1.start_with?(token.delete_prefix("/")) }.map { "/#{_1}" }
        return [cmds, token, 0]
      end
      if buffer.start_with?("/")
        cmd = buffer[1..].split(" ", 2).first.to_s
        list = argument_candidates(cmd)
        return [list.select { _1.start_with?(token) }, token, start] if list
      end
      [path_candidates(token), token, start]
    end

    def argument_candidates(cmd)
      case cmd
      when "skill" then @h.skills.map { _1["name"] }.sort
      when "lane" then @h.lanes.map { _1["name"] }
      when "model" then @h.available_models.flat_map { ["#{_1["provider"]}/#{_1["modelId"]}", _1["modelId"]] }.uniq
      when "think" then THINK_LEVELS
      when "tools" then Durable::Tools.names
      when "help" then COMMANDS
      end
    end

    # Paths, for `!command <tab>` and for naming files in a prompt.
    def path_candidates(token)
      return [] if token.empty? && !@shell_mode

      expanded = token.start_with?("~") ? File.expand_path(token) : token
      dir = expanded.end_with?("/") ? expanded : File.dirname(expanded)
      dir = "." if dir == "" || (!expanded.include?("/") && dir == ".")
      base = expanded.end_with?("/") ? "" : File.basename(expanded)
      prefix = expanded.include?("/") ? "#{dir.chomp("/")}/" : ""
      Dir.children(dir).sort.filter_map do |name|
        next unless name.start_with?(base)
        next if name.start_with?(".") && !base.start_with?(".")

        File.directory?(File.join(dir, name)) ? "#{prefix}#{name}/" : "#{prefix}#{name}"
      end
    rescue SystemCallError
      []
    end

    def common_prefix(list)
      first = list.first
      first.each_char.with_index do |c, i|
        return first[0, i] unless list.all? { _1[i] == c }
      end
      first
    end

    def columns(items)
      w = items.map { _1.length }.max + 2
      per_row = [(width / w), 1].max
      items.each_slice(per_row).map { |row| "  " + row.map { _1.ljust(w) }.join.rstrip }
    end

    def refresh_prompt
      @mutex.synchronize do
        @line.prompt = prompt_for(@line.buffer)
        @line.rprompt = status_rprompt
        @line.redraw
      end
    end

    # The prompt says what the line will do, and it says it the moment you
    # type: a leading ! switches the line to a shell, and the marker moves into
    # the prompt instead of sitting in the text you are editing.
    def prompt_for(_buffer = nil)
      return s(:red, "! ") if @shell_mode

      busy? ? s(:yellow, "steer › ") : s(:cyan, "› ")
    end

    # Non-tty (pipes, CI): plain line reading, same command handling.
    def run_piped
      @input_active = false
      while (text = $stdin.gets)
        break if submit(text.strip) == :exit
      end
      @run_thread&.join
      emit("bye")
    end

    def submit(text)
      text = text.to_s.strip
      return nil if text.empty?

      return command(text) if text.start_with?("/")
      return shell(text[1..].to_s.strip) if text.start_with?("!")

      if busy?
        echo(text)
        emit(s(:yellow, "-> ") + text.lines.first.to_s.strip)
        r = lane_handle.steer(text)
        emit(s(:yellow, "  #{r.dig("error", "message")}")) unless r["ok"]
      else
        echo(text)
        emit(s(:cyan, "› ") + text.lines.first.to_s.strip)
        start_run { lane_handle.prompt(text) }
      end
      nil
    end

    # `!command`: the user's own shell command. It runs here, not through the
    # model, and lands in the conversation as a bash_execution entry so the
    # model sees what happened — durable like any other write, deferred when a
    # step is in flight.
    def shell(command)
      return emit(s(:dim, "  usage: !<command>")) if command.empty?

      emit(s(:blue, "$ ") + command)
      Thread.new do
        started = Time.now
        printed = 0
        limit = @verbose ? 2000 : 40
        r = Durable::Tools.exec_stream(command, Dir.pwd, timeout: 600) do |chunk|
          chunk.each_line do |l|
            printed += 1
            emit(s(:gray, "  #{clip(l.rstrip, width - 4)}")) if printed <= limit
          end
        end
        code = r["exitCode"]
        all = r["output"].lines.map(&:rstrip)
        remember_output({ "toolName" => "!#{command.split.first}" }, all)
        if all.size > printed || printed > limit
          emit(s(:dim, "  … #{all.size - [printed, limit].min} more lines · ctrl-o to expand"))
        end
        emit(Term.two_column("  #{code.zero? ? s(:green, "ok") : s(:red, "exit #{code}")}",
                             s(:dim, "#{(Time.now - started).round(1)}s"), width))
        res = lane_handle.append_bash(command, Durable::Tools.clip(r["output"]), code)
        emit(s(:dim, "  (queued for the next checkpoint)")) if busy? && res["ok"]
      rescue StandardError => e
        emit(s(:red, "  #{e.class}: #{e.message}"))
      end
      nil
    end

    # Local echo bookkeeping, so a line never appears twice.
    def echo(text)
      @echoed ||= []
      @echoed << text.to_s.strip
      @echoed.shift while @echoed.size > 8
    end

    def claim_echo(text)
      @echoed ||= []
      idx = @echoed.index(text.to_s.strip) or return false

      @echoed.delete_at(idx)
      true
    end

    def start_run(&blk)
      @run_started = Time.now
      @run_thread = Thread.new do
        blk.call
      rescue Durable::RemoteError, Ractor::ClosedError => e
        emit(s(:red, "  #{e.message}"))
      end
    end

    def handle_interrupt
      if busy?
        Thread.new { lane_handle.abort! }
      else
        emit(s(:dim, "bye"))
        shutdown
        exit 0
      end
    end

    def shutdown
      @input_active = false
      Term.restore!
      if @run_thread&.alive?
        emit(s(:dim, "waiting for the current run to finish (Ctrl-C aborts)…"))
        @run_thread.join
      end
      @h.close
    end

    def lane_handle = @h.lane(@lane) || @h.main

    # The event stream already says whether this lane is working; asking the
    # lane on every keystroke would be a round trip per character.
    def busy?
      return @busy unless @busy.nil?

      @busy = !!lane_handle.state["operation"]
    end

    # ── commands ──────────────────────────────────────────────────────────

    def command(line)
      cmd, rest = line[1..].split(" ", 2)
      rest = rest&.strip
      case cmd
      when "help", "?" then emit(HELP)
      when "exit", "quit", "q" then return :exit
      when "abort" then show(lane_handle.abort!)
      when "resume" then start_run { lane_handle.resume }
      when "compact" then start_run { show(lane_handle.compact(custom_instructions: rest)) }
      when "verbose"
        @verbose = !@verbose
        emit(s(:dim, "  verbose #{@verbose ? "on" : "off"}"))
      when "goal" then cmd_goal(rest)
      when "skill" then cmd_skill(rest)
      when "model" then cmd_model(rest)
      when "models"
        @h.available_models.each do |m|
          cur = m["modelId"] == @h.model["modelId"] ? s(:green, " ●") : ""
          emit("  #{m["provider"]}/#{m["modelId"]}#{s(:dim, m["reasoning"] ? " reasoning" : "")}#{cur}")
        end
      when "think"
        if %w[off low medium high].include?(rest)
          show(lane_handle.set_persisted("thinkingLevel", rest))
        else
          emit("  thinking = #{lane_handle.state["thinkingLevel"]} (off|low|medium|high)")
        end
      when "tools" then cmd_tools(rest)
      when "cache" then cmd_cache
      when "output" then expand_last_output(rest.to_s.empty? ? -1 : -rest.to_i)
      when "state" then emit(JSON.pretty_generate(lane_handle.state))
      when "agents"
        if @h.agents_md.empty?
          emit(s(:dim, "  no AGENTS.md in scope"))
        else
          @h.agents_md.each { emit("  #{rel(_1["path"])} #{s(:dim, "#{_1["content"].lines.size} lines")}") }
        end
      when "lanes" then cmd_lanes
      when "lane" then cmd_lane(rest)
      when "tree" then cmd_tree
      when "back" then cmd_back(rest)
      when "log" then cmd_log(rest)
      when "steer" then show(lane_handle.steer(rest.to_s))
      when "next" then show(lane_handle.next_run(rest.to_s))
      else emit(s(:yellow, "  unknown command /#{cmd} — /help"))
      end
      nil
    end

    def cmd_goal(rest)
      if rest.nil? || rest.empty?
        g = lane_handle.goal
        return emit(s(:dim, "  no goal set — /goal <text>")) unless g

        emit(s(:magenta, "  goal: ") + g)
      elsif %w[clear none off].include?(rest)
        lane_handle.set_goal("")
        emit(s(:dim, "  goal cleared"))
      else
        lane_handle.set_goal(rest)
        emit(s(:magenta, "  goal: ") + rest + s(:dim, busy? ? "  (applies at the next checkpoint)" : ""))
      end
    end

    def cmd_skill(rest)
      if rest.nil? || rest.empty?
        return emit(s(:dim, "  no skills found")) if @h.skills.empty?

        @h.skills.sort_by { _1["name"] }.each do |sk|
          emit(Term.two_column("  #{s(:bold, sk["name"])} #{s(:dim, clip(sk["description"], width / 2))}",
                               s(:gray, rel(sk["path"])), width))
        end
        return
      end
      name, extra = rest.split(" ", 2)
      return emit(s(:yellow, "  busy — steer instead")) if busy?

      start_run { lane_handle.skill(name, extra) }
    end

    def cmd_model(rest)
      if rest && !rest.empty?
        r = @h.set_model(rest)
        emit(r["ok"] ? s(:dim, "  #{r["model"]["provider"]}/#{r["model"]["modelId"]}") : s(:yellow, "  unknown model"))
      else
        st = lane_handle.state
        emit("  #{st.dig("model", "provider")}/#{st.dig("model", "modelId")} " \
             "#{s(:dim, "thinking=#{st["thinkingLevel"]}")}")
      end
    end

    def cmd_tools(rest)
      if rest && !rest.empty?
        show(lane_handle.set_persisted("activeTools", rest.split(/[\s,]+/)))
      else
        active = lane_handle.state["activeTools"]
        Durable::Tools.declarations.each do |d|
          mark = active.include?(d["name"]) ? s(:green, "*") : s(:dim, "-")
          emit(Term.two_column("  #{mark} #{s(:bold, d["name"])} #{s(:dim, clip(d["description"], width / 2))}",
                               s(:dim, "replay=#{d["replay"]}"), width))
        end
      end
    end

    def cmd_cache
      c = lane_handle.state["cache"] || {}
      rate = c["hitRate"] ? (c["hitRate"] * 100).round : nil
      emit("  requests #{c["requests"]}  input #{tok(c["input"])}  cached #{tok(c["cacheRead"])}")
      emit("  hit rate #{rate ? "#{rate}%" : "—"}#{c["misses"].to_i.positive? ? s(:red, "  misses #{c["misses"]}") : ""}")
      emit(s(:dim, "  a cold start and each compaction cost one full prefix; steady state should be >80%"))
    end

    def cmd_lanes
      @h.lanes.each do |l|
        mark = l["name"] == @lane ? s(:green, ">") : " "
        op = l["operation"] ? s(:yellow, " [#{l.dig("operation", "status")}]") : ""
        emit("  #{mark} #{l["name"].ljust(16)} #{s(:dim, l["leafId"].to_s[0, 10])}#{op}")
      end
    end

    def cmd_lane(name)
      return emit("  usage: /lane <name>") if name.nil? || name.empty?

      unless @h.lane(name)
        r = @h.create_lane(name, @h.main.state["leafId"])
        return show(r) unless r["ok"]
      end
      @lane = name
      emit(s(:dim, "  now prompting lane #{name}"))
    end

    def cmd_tree
      lane_handle.session.context_entries.each do |e|
        kind = e["type"] == "message" ? e.dig("message", "role") : e["type"]
        color = { "user" => :cyan, "assistant" => :white, "toolResult" => :gray }[kind] || :magenta
        preview =
          if e["type"] == "message"
            m = e["message"]
            if m["role"] == "toolResult"
              "#{m["toolName"]}: #{text_of(m)}"
            else
              calls = (m["content"] || []).select { _1["type"] == "toolCall" }.map { _1["name"] }
              [text_of(m), calls.empty? ? nil : "(#{calls.join(", ")})"].compact.join(" ")
            end
          else
            e["summary"] || e["customType"] || e["type"]
          end
        emit("  #{s(:dim, e["id"][0, 8])} #{s(color, kind.to_s.ljust(10))} " \
             "#{clip(preview.to_s.gsub(/\s+/, " "), width - 24)}")
      end
    end

    def cmd_back(rest)
      n = (rest.to_s.empty? ? 1 : rest.to_i)
      users = lane_handle.session.context_entries.select { _1.dig("message", "role") == "user" }
      target = users[-(n + 1)]
      return emit(s(:yellow, "  not that far back (#{users.size} turns)")) unless target

      parent = lane_handle.session.entry(target["id"])["parentId"]
      start_run { show(lane_handle.navigate(parent, summarize: false)) }
    end

    def cmd_log(rest)
      n = (rest.to_s.empty? ? 20 : rest.to_i)
      @h.session.log.last(n).each do |l|
        tag = case l["kind"]
              when "record" then s(:yellow, "R")
              when "entry" then s(:green, "E")
              else s(:blue, "·")
              end
        label = l["type"] || l["fact"] || l["kind"]
        extra = l["toolName"] || l["outcome"] || l.dig("intent", "kind") ||
                l.dig("message", "role") || l["lane"]
        emit("  #{tag} #{label.to_s.ljust(20)} #{s(:dim, extra.to_s)}")
      end
    end

    def show(result)
      return unless result.is_a?(Hash)

      emit(result["ok"] ? s(:dim, "  ok") : s(:yellow, "  #{result["outcome"]}: #{result.dig("error", "message")}"))
    end
  end
end
