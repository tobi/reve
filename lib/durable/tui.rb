# frozen_string_literal: true

require_relative "harness"
require "reline"
require "io/console"

module Durable
  # Terminal UI. A client of the harness like any other: one atomic snapshot
  # from watch(), then a live event stream (§9). It never touches session state.
  #
  # Rendering rules:
  #  - streaming text is emitted line by line, so markdown can be formatted and
  #    wrapped without ever redrawing what is already on screen;
  #  - a single transient status line (spinner, elapsed, tokens, running tools)
  #    is erased before any real output and redrawn after;
  #  - tools render as one summary line plus a clipped preview of their result.
  class TUI
    RESET = "\e[0m"
    STYLE = {
      dim: "\e[2m", bold: "\e[1m", italic: "\e[3m",
      red: "\e[31m", green: "\e[32m", yellow: "\e[33m", blue: "\e[34m",
      magenta: "\e[35m", cyan: "\e[36m", gray: "\e[90m", white: "\e[97m"
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
        /model [spec]       show or set the model
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
      @status = nil
      @status_shown = false
      @line_buf = +""
      @in_code = false
      @tools = {}
      @usage = { "input" => 0, "output" => 0 }
      @started_at = nil
      @out = $stdout
      @mutex = Mutex.new
    end

    # ── styling ───────────────────────────────────────────────────────────

    def s(style, text) = "#{STYLE[style]}#{text}#{RESET}"
    def width = (IO.console&.winsize&.last || 100).clamp(40, 120)

    def wrap(text, indent = "")
      limit = width - indent.length
      out = []
      text.split(/\s+/).each do |word|
        if out.empty? || (visible(out.last).length + visible(word).length + 1) > limit
          out << +"#{word}"
        else
          out.last << " " << word
        end
      end
      out.map { "#{indent}#{_1}" }
    end

    def visible(str) = str.gsub(/\e\[[0-9;]*m/, "")

    def clip(str, n) = visible(str).length > n ? "#{visible(str)[0, n - 1]}…" : str

    # ── status line ───────────────────────────────────────────────────────

    def status_text
      return nil unless @started_at

      frame = SPINNER[(Time.now.to_f * 10).to_i % SPINNER.size]
      elapsed = (Time.now - @started_at).to_i
      bits = ["#{elapsed}s"]
      bits << "#{@tools.size} tool#{@tools.size == 1 ? "" : "s"}" unless @tools.empty?
      tok = @usage["input"].to_i + @usage["output"].to_i
      bits << "#{(tok / 1000.0).round(1)}k tok" if tok.positive?
      bits << "esc/^C aborts"
      "#{s(:cyan, frame)} #{s(:dim, bits.join(" · "))}"
    end

    def clear_status
      return unless @status_shown

      @out.print("\e[2K\r")
      @status_shown = false
    end

    def draw_status
      t = status_text or return
      @out.print("#{t}\e[0K\r")
      @status_shown = true
      @out.flush
    end

    def start_spinner
      @started_at = Time.now
      @spinner ||= Thread.new do
        loop do
          sleep 0.1
          @mutex.synchronize { draw_status if @started_at && !@writing }
        end
      end
    end

    def stop_spinner
      @started_at = nil
      @mutex.synchronize { clear_status }
    end

    # Everything that prints goes through here, so the status line is never
    # interleaved with real output.
    def emit(&blk)
      @mutex.synchronize do
        @writing = true
        clear_status
        blk.call
        @out.flush
        @writing = false
      end
    end

    def say(line = "")
      emit { @out.puts(line) }
    end

    # ── markdown-ish line formatting ──────────────────────────────────────

    def format_line(line)
      if line.strip.start_with?("```")
        lang = line.strip.delete_prefix("```")
        @in_code = !@in_code
        return @in_code ? [s(:gray, "  ┌ #{lang.empty? ? "code" : lang}")] : [s(:gray, "  └")]
      end
      return [s(:gray, "  │ ") + s(:white, line)] if @in_code

      case line
      when /\A\#{1,6}\s+(.*)\z/ then [s(:bold, ::Regexp.last_match(1))]
      when /\A\s*([-*])\s+(.*)\z/ then wrap("#{s(:cyan, "•")} #{inline(::Regexp.last_match(2))}", "  ")
      when /\A\s*(\d+)\.\s+(.*)\z/
        wrap("#{s(:cyan, "#{::Regexp.last_match(1)}.")} #{inline(::Regexp.last_match(2))}", "  ")
      when /\A\s*\z/ then [""]
      else wrap(inline(line), "")
      end
    end

    def inline(text)
      text.gsub(/`([^`]+)`/) { s(:cyan, ::Regexp.last_match(1)) }
          .gsub(/\*\*([^*]+)\*\*/) { s(:bold, ::Regexp.last_match(1)) }
    end

    # Streamed text: print whole lines, keep the partial one buffered.
    def stream_text(chunk)
      @line_buf << chunk
      return unless @line_buf.include?("\n")

      *lines, rest = @line_buf.split("\n", -1)
      @line_buf = rest.to_s
      emit { lines.each { |l| format_line(l).each { @out.puts(_1) } } }
    end

    def flush_text
      return if @line_buf.empty?

      line = @line_buf
      @line_buf = +""
      emit { format_line(line).each { @out.puts(_1) } }
    end

    # ── event rendering ───────────────────────────────────────────────────

    def start_renderer
      @renderer = Thread.new do
        watch = @h.watch(nil)
        watch.each_event { |ev| render(ev) }
      rescue Ractor::ClosedError
        nil
      end
      @renderer.abort_on_exception = false
    end

    def render(ev)
      lane_tag = ev["lane"] == @lane ? "" : s(:magenta, "[#{ev["lane"]}] ")
      case ev["type"]
      when "run_start", "run_resume", "compaction_start", "navigation_start"
        @run_started = Time.now
        @usage = { "input" => 0, "output" => 0 } unless ev["type"] == "compaction_start"
        @tools.clear
        start_spinner
        say(s(:dim, "· resuming")) if ev["type"] == "run_resume"
        say(s(:magenta, "  ⟲ compacting context (#{ev["reason"]})…")) if ev["type"] == "compaction_start"
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
        when "user" then say(lane_tag + s(:cyan, "› ") + text_of(msg).lines.first.to_s.strip)
        when "toolResult" then render_tool_result(msg)
        when "assistant" then @usage = msg["usage"] || @usage
        end
      when "tool_start"
        flush_text
        @tools[ev["toolCallId"]] = ev["toolName"]
        say(lane_tag + tool_header(ev["toolName"], ev["args"]))
      when "tool_end" then @tools.delete(ev["toolCallId"])
      when "retry_scheduled"
        say(s(:yellow, "  ↺ retry #{ev["attempt"]}/#{ev["maxAttempts"]} in #{ev["delayMs"]}ms — " \
                       "#{clip(ev["errorMessage"].to_s, width - 30)}"))
      when "compaction_start" then nil # announced below, after the spinner starts
      when "compaction_end"
        say(s(:magenta, "  ⟲ compaction #{ev["outcome"]}"))
      when "navigation_end"
        say(s(:magenta, "  ⤺ moved to #{ev["newLeafId"].to_s[0, 10]} (#{ev["outcome"]})"))
      when "run_suspend"
        stop_spinner
        say(s(:yellow, "⏸ parked on a deferred request — /resume later"))
      when "run_abort" then say(s(:yellow, "  ✋ aborting…"))
      when "run_end"
        flush_text
        stop_spinner
        say(footer(ev))
        say
      when "fault" then say(s(:red, "harness faulted: #{ev["message"]}"))
      when "handler_error" then say(s(:red, "hook error (#{ev["hook"]}): #{ev["error"]}"))
      when "lane_created" then say(s(:dim, "  + lane #{ev["lane"]}"))
      end
    end

    def footer(ev)
      u = ev.dig("finalMessage", "usage") || @usage
      dur = @run_started ? " · #{(Time.now - @run_started).round(1)}s" : ""
      bits = []
      bits << "#{u["input"]}in/#{u["output"]}out" if u && u["input"]
      mark = ev["outcome"] == "completed" ? s(:dim, "·") : s(:yellow, "·")
      "#{mark} #{s(ev["outcome"] == "completed" ? :dim : :yellow, ev["outcome"])}" \
        "#{s(:dim, dur)}#{s(:dim, bits.empty? ? "" : " · #{bits.join(" ")}")}"
    end

    TOOL_ICON = { "bash" => "$", "read" => "◂", "write" => "✎", "edit" => "✎",
                  "ls" => "▸", "glob" => "*", "grep" => "⌕" }.freeze

    def tool_header(name, args)
      icon = TOOL_ICON[name] || "→"
      detail =
        case name
        when "bash" then args["command"].to_s.gsub("\n", " ⏎ ")
        when "read", "write", "ls" then rel(args["path"])
        when "edit" then "#{rel(args["path"])}  #{s(:red, clip(args["oldText"].to_s.gsub("\n", "⏎"), 28))}" \
                          " → #{s(:green, clip(args["newText"].to_s.gsub("\n", "⏎"), 28))}"
        when "glob" then args["pattern"].to_s
        when "grep" then "#{args["pattern"]} #{s(:dim, args["glob"] || "")}"
        else args.is_a?(Hash) ? args.map { |k, v| "#{k}=#{clip(v.to_s, 30)}" }.join(" ") : ""
        end
      "  #{s(:blue, icon)} #{s(:bold, name)} #{clip(detail, width - 12)}"
    end

    def render_tool_result(msg)
      body = text_of(msg).to_s
      icon = msg["isError"] ? s(:red, "✗") : s(:green, "✓")
      lines = body.lines.map(&:rstrip).reject(&:empty?)
      limit = @verbose ? 40 : 4
      shown = lines.first(limit)
      say("    #{icon} #{s(:gray, clip(shown.first.to_s, width - 8))}") unless shown.empty?
      shown[1..]&.each { |l| say(s(:gray, "      #{clip(l, width - 8)}")) }
      say(s(:dim, "      … #{lines.size - limit} more lines (/verbose)")) if lines.size > limit
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
      model = "#{st.dig("model", "provider")}/#{st.dig("model", "modelId")}"
      say(s(:bold, "rbagent") + s(:dim, "  durable harness on ractors · ruby #{RUBY_VERSION}"))
      say(s(:dim, "  #{model} · #{st["activeTools"].size} tools · lane #{@lane} · #{rel(Dir.pwd)}"))
      unless @h.agents_md.empty?
        say(s(:dim, "  AGENTS.md: #{@h.agents_md.map { rel(_1["path"]) }.join(", ")}"))
      end
      unless @h.skills.empty?
        say(s(:dim, "  skills: #{@h.skills.map { _1["name"] }.sort.join(", ")}"))
      end
      # Skill authors want to hear about this immediately, not in a log file.
      @h.skill_diagnostics.each do |d|
        say(s(:yellow, "  ⚠ skill #{rel(d["path"])}: #{d["message"]}"))
      end
      if (g = lane_handle.state["goal"])
        say(s(:magenta, "  goal: #{clip(g.gsub(/\s+/, " "), width - 10)}"))
      end
      @suspended.each do |sp|
        say(s(:yellow, "  ⏸ suspended #{sp["kind"]} on lane #{sp["lane"]} (#{sp["reason"]}) — /resume"))
      end
      say(s(:dim, "  /help for commands"))
      say
    end

    # ── main loop ─────────────────────────────────────────────────────────

    def run
      banner
      start_renderer
      Signal.trap("INT") do
        if busy?
          Thread.new { lane_handle.abort! }
        else
          puts "\nbye"
          exit 0
        end
      end
      loop do
        line = read_line
        break if line.nil?

        line = line.strip
        next if line.empty?

        if line.start_with?("/")
          break if command(line) == :exit
        elsif busy?
          r = lane_handle.steer(line)
          say(r["ok"] ? s(:dim, "  ↳ steered") : s(:yellow, "  #{r.dig("error", "message")}"))
        else
          @run_started = Time.now
          @run_thread = Thread.new do
            lane_handle.prompt(line)
          rescue Durable::RemoteError, Ractor::ClosedError => e
            say(s(:red, "  #{e.message}"))
          end
        end
      end
      say("bye")
    ensure
      if @run_thread&.alive?
        say(s(:dim, "waiting for the current run to finish (Ctrl-C aborts)…"))
        @run_thread.join
      end
      @h.close
    end

    def read_line
      prompt = busy? ? s(:yellow, "steer › ") : s(:cyan, "› ")
      @mutex.synchronize { clear_status }
      Reline.readline(prompt, true)
    rescue Interrupt
      ""
    end

    def lane_handle = @h.lane(@lane) || @h.main
    def busy? = !!lane_handle.state["operation"]

    # ── commands ──────────────────────────────────────────────────────────

    def command(line)
      cmd, rest = line[1..].split(" ", 2)
      rest = rest&.strip
      case cmd
      when "help", "?" then say(HELP)
      when "exit", "quit", "q" then return :exit
      when "abort" then show(lane_handle.abort!)
      when "resume" then Thread.new { lane_handle.resume }
      when "compact" then Thread.new { show(lane_handle.compact(custom_instructions: rest)) }
      when "verbose"
        @verbose = !@verbose
        say(s(:dim, "  verbose #{@verbose ? "on" : "off"}"))
      when "model" then cmd_model(rest)
      when "models"
        @h.available_models.each do |m|
          cur = m["modelId"] == @h.model["modelId"] ? s(:green, " ●") : ""
          say("  #{m["provider"]}/#{m["modelId"]}#{s(:dim, m["reasoning"] ? " reasoning" : "")}#{cur}")
        end
      when "think"
        if %w[off low medium high].include?(rest)
          show(lane_handle.set_persisted("thinkingLevel", rest))
        else
          say("  thinking = #{lane_handle.state["thinkingLevel"]} (off|low|medium|high)")
        end
      when "tools" then cmd_tools(rest)
      when "goal" then cmd_goal(rest)
      when "skill" then cmd_skill(rest)
      when "state" then say(JSON.pretty_generate(lane_handle.state))
      when "agents"
        if @h.agents_md.empty?
          say(s(:dim, "  no AGENTS.md in scope"))
        else
          @h.agents_md.each { |f| say("  #{rel(f["path"])} #{s(:dim, "#{f["content"].lines.size} lines")}") }
        end
      when "lanes" then cmd_lanes
      when "lane" then cmd_lane(rest)
      when "tree" then cmd_tree
      when "back" then cmd_back(rest)
      when "log" then cmd_log(rest)
      when "steer" then show(lane_handle.steer(rest.to_s))
      when "next" then show(lane_handle.next_run(rest.to_s))
      else say(s(:yellow, "  unknown command /#{cmd} — /help"))
      end
      nil
    end

    def cmd_model(rest)
      if rest && !rest.empty?
        show(@h.set_model(rest))
      else
        st = lane_handle.state
        say("  #{st.dig("model", "provider")}/#{st.dig("model", "modelId")} " \
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
          say("  #{mark} #{d["name"].ljust(6)} #{s(:dim, "replay=#{d["replay"]}")}  #{clip(d["description"], width - 30)}")
        end
      end
    end

    def cmd_goal(rest)
      if rest.nil? || rest.empty?
        g = lane_handle.goal
        return say(s(:dim, "  no goal set — /goal <text>")) unless g

        say(s(:magenta, "  goal: ") + g)
      elsif %w[clear none off].include?(rest)
        lane_handle.set_goal("")
        say(s(:dim, "  goal cleared"))
      else
        lane_handle.set_goal(rest)
        say(s(:magenta, "  goal: ") + rest + s(:dim, busy? ? "  (applies at the next checkpoint)" : ""))
      end
    end

    def cmd_skill(rest)
      if rest.nil? || rest.empty?
        return say(s(:dim, "  no skills found")) if @h.skills.empty?

        @h.skills.sort_by { _1["name"] }.each do |sk|
          say("  #{s(:bold, sk["name"].ljust(18))} #{s(:dim, clip(sk["description"], width - 24))}")
          say("  #{" " * 18} #{s(:gray, rel(sk["path"]))}")
        end
        return
      end
      name, extra = rest.split(" ", 2)
      return say(s(:yellow, "  busy — steer instead")) if busy?

      @run_started = Time.now
      @run_thread = Thread.new { lane_handle.skill(name, extra) }
    end

    def cmd_lanes
      @h.lanes.each do |l|
        mark = l["name"] == @lane ? s(:green, "▸") : " "
        op = l["operation"] ? s(:yellow, " [#{l.dig("operation", "status")}]") : ""
        say("  #{mark} #{l["name"].ljust(16)} #{s(:dim, l["leafId"].to_s[0, 10])}#{op}")
      end
    end

    def cmd_lane(name)
      return say("  usage: /lane <name>") if name.nil? || name.empty?

      unless @h.lane(name)
        r = @h.create_lane(name, @h.main.state["leafId"])
        return show(r) unless r["ok"]
      end
      @lane = name
      say(s(:dim, "  now prompting lane #{name}"))
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
            e["summary"] || e.to_s
          end
        say("  #{s(:dim, e["id"][0, 8])} #{s(color, kind.to_s.ljust(10))} " \
            "#{clip(preview.to_s.gsub(/\s+/, " "), width - 24)}")
      end
    end

    # Navigate n user turns back: the design's tree navigation, from the UI.
    def cmd_back(rest)
      n = (rest.to_s.empty? ? 1 : rest.to_i)
      users = lane_handle.session.context_entries.select { _1.dig("message", "role") == "user" }
      target = users[-(n + 1)]
      return say(s(:yellow, "  not that far back (#{users.size} turns)")) unless target

      parent = lane_handle.session.entry(target["id"])["parentId"]
      Thread.new { show(lane_handle.navigate(parent, summarize: false)) }
    end

    def cmd_log(rest)
      n = (rest.to_s.empty? ? 20 : rest.to_i)
      @h.session.log.last(n).each do |l|
        tag = l["kind"] == "record" ? s(:yellow, "R") : (l["kind"] == "entry" ? s(:green, "E") : s(:blue, "·"))
        label = l["type"] || l["fact"] || l["kind"]
        extra = l["toolName"] || l["outcome"] || l.dig("intent", "kind") ||
                l.dig("message", "role") || l["lane"]
        say("  #{tag} #{label.to_s.ljust(20)} #{s(:dim, extra.to_s)}")
      end
    end

    def show(result)
      return unless result.is_a?(Hash)

      if result["ok"]
        say(s(:dim, "  ok"))
      else
        say(s(:yellow, "  #{result["outcome"]}: #{result.dig("error", "message")}"))
      end
    end
  end
end
