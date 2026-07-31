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
      dim: "\e[2m", bold: "\e[1m", red: "\e[31m", green: "\e[32m", yellow: "\e[33m",
      blue: "\e[34m", magenta: "\e[35m", cyan: "\e[36m", gray: "\e[90m", white: "\e[97m"
    }.freeze
    SPINNER = %w[⠋ ⠙ ⠹ ⠸ ⠼ ⠴ ⠦ ⠧ ⠇ ⠏].freeze

    HELP = <<~TXT
      conversation
        <text>              prompt · typing while the agent works steers it
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
      when /\A\#{1,6}\s+(.*)\z/ then [s(:bold, ::Regexp.last_match(1))]
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
        emit(s(:magenta, "  ⟲ compacting context (#{ev["reason"]})…")) if ev["type"] == "compaction_start"
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
        emit(s(:yellow, "  ↺ retry #{ev["attempt"]}/#{ev["maxAttempts"]} in #{ev["delayMs"]}ms — " \
                        "#{clip(ev["errorMessage"].to_s, width - 30)}"))
      when "compaction_end" then emit(s(:magenta, "  ⟲ compaction #{ev["outcome"]}"))
      when "navigation_end"
        emit(s(:magenta, "  ⤺ moved to #{ev["newLeafId"].to_s[0, 10]} (#{ev["outcome"]})"))
      when "run_suspend"
        @busy = false if ev["lane"] == @lane
        stop_spinner
        emit(s(:yellow, "⏸ parked on a deferred request — /resume later"))
      when "run_abort" then emit(s(:yellow, "  ✋ aborting…"))
      when "run_end"
        flush_text
        @busy = false if ev["lane"] == @lane
        stop_spinner
        emit(footer(ev), "")
        refresh_prompt if @input_active
      when "fault" then emit(s(:red, "harness faulted: #{ev["message"]}"))
      when "handler_error" then emit(s(:red, "hook error (#{ev["hook"]}): #{ev["error"]}"))
      when "lane_created" then emit(s(:dim, "  + lane #{ev["lane"]}"))
      end
    end

    def footer(ev)
      u = ev.dig("finalMessage", "usage") || @usage
      dur = @run_started ? "#{(Time.now - @run_started).round(1)}s" : nil
      right = [dur, (u && u["input"] ? "#{u["input"]}in/#{u["output"]}out" : nil)].compact.join(" · ")
      ok = ev["outcome"] == "completed"
      Term.two_column("#{s(ok ? :dim : :yellow, "·")} #{s(ok ? :dim : :yellow, ev["outcome"])}",
                      s(:dim, right), width)
    end

    TOOL_ICON = { "bash" => "$", "read" => "◂", "write" => "✎", "edit" => "✎",
                  "ls" => "▸", "glob" => "*", "grep" => "⌕" }.freeze

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

    # The RPROMPT idea: the call on the left, its outcome right-aligned. Full
    # output only for errors, or with /verbose.
    def render_tool_result(msg)
      id = msg["toolCallId"]
      args = (@tool_args || {}).delete(id)
      started = (@tool_started_at || {}).delete(id)
      body = text_of(msg).to_s
      lines = body.lines.map(&:rstrip).reject(&:empty?)
      error = msg["isError"]

      summary = result_summary(msg["toolName"], lines, error)
      extra = []
      extra << "#{(Time.now - started).round(1)}s" if started && (Time.now - started) > 0.4
      mark = error ? s(:red, "✗") : s(:green, "✓")
      right = "#{mark} #{s(error ? :red : :gray, clip(summary, [width / 3, 24].max))}"
      right += s(:dim, " #{extra.join(" · ")}") unless extra.empty?

      left = tool_label(msg["toolName"], args)
      emit(Term.two_column(clip(left, width - Term.display_width(right) - 2), right, width))

      shown = error ? lines.first(12) : (@verbose ? lines.first(60) : [])
      shown = shown.drop(1) if shown.first == lines.first
      emit(shown.map { s(:gray, "      #{clip(_1, width - 8)}") }) unless shown.empty?
      if !@verbose && !error && lines.size > 1
        nil # the count on the right already says how much there was
      end
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
      when "bash" then first == "(no output)" ? "ok" : "#{first}#{lines.size > 1 ? " +#{lines.size - 1}" : ""}"
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
      @h.skill_diagnostics.each { emit(s(:yellow, "  ⚠ skill #{rel(_1["path"])}: #{_1["message"]}")) }
      emit(s(:magenta, "  goal: #{clip(st["goal"].to_s.gsub(/\s+/, " "), width - 10)}")) if st["goal"]
      @suspended.each do |sp|
        emit(s(:yellow, "  ⏸ suspended #{sp["kind"]} on lane #{sp["lane"]} (#{sp["reason"]}) — /resume"))
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
          @mutex.synchronize do
            @line.hide
            @out.flush
          end
          break if submit(text) == :exit
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

    def refresh_prompt
      @mutex.synchronize do
        @line.prompt = busy? ? s(:yellow, "steer › ") : s(:cyan, "› ")
        @line.rprompt = status_rprompt
        @line.redraw
      end
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

      if busy?
        echo(text)
        emit(s(:yellow, "↳ ") + text.lines.first.to_s.strip)
        r = lane_handle.steer(text)
        emit(s(:yellow, "  #{r.dig("error", "message")}")) unless r["ok"]
      else
        echo(text)
        emit(s(:cyan, "› ") + text.lines.first.to_s.strip)
        start_run { lane_handle.prompt(text) }
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
          mark = active.include?(d["name"]) ? s(:green, "●") : s(:dim, "○")
          emit(Term.two_column("  #{mark} #{s(:bold, d["name"])} #{s(:dim, clip(d["description"], width / 2))}",
                               s(:dim, "replay=#{d["replay"]}"), width))
        end
      end
    end

    def cmd_lanes
      @h.lanes.each do |l|
        mark = l["name"] == @lane ? s(:green, "▸") : " "
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
