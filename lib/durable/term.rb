# frozen_string_literal: true

require "io/console"

module Durable
  # Terminal plumbing: cbreak mode and a small line editor.
  #
  # Not Reline: a readline library owns the bottom line, and this UI has a
  # renderer thread that must print above it while the user is typing. Owning
  # the input line ourselves is the only way to redraw without leaving stale
  # prompts behind — the duplicated "› ›" that any print-behind-readline
  # design produces.
  module Term
    module_function

    def tty? = $stdin.tty? && $stdout.tty?

    def size
      h, w = ($stdout.winsize rescue nil) || [24, 100]
      [h, w.clamp(40, 200)]
    end

    def width = size.last

    # cbreak, not raw: output post-processing stays on (so "\n" still works
    # from the renderer thread) and Ctrl-C still raises SIGINT.
    def cbreak!
      return false unless tty?

      @saved = `stty -g 2>/dev/null`.strip
      system("stty", "-icanon", "-echo", "min", "1", "time", "0", err: File::NULL)
      true
    end

    def restore!
      return unless @saved && !@saved.empty?

      system("stty", @saved, err: File::NULL)
      @saved = nil
    end

    def visible(str) = str.to_s.gsub(/\e\[[0-9;?]*[a-zA-Z]/, "")
    def display_width(str) = visible(str).length

    # left … right, right-aligned like a zsh RPROMPT. Falls back to two lines
    # when they do not fit.
    def two_column(left, right, cols = width, min_gap: 2)
      lw = display_width(left)
      rw = display_width(right)
      gap = cols - lw - rw
      return "#{left}#{" " * gap}#{right}" if gap >= min_gap
      return left if rw.zero?

      pad = [cols - rw, 0].max
      "#{left}\n#{" " * pad}#{right}"
    end

    def clip(str, max)
      v = visible(str)
      return str if v.length <= max || max <= 1

      "#{v[0, max - 1]}…"
    end

    # A line editor over one screen line, redrawable at any time.
    class Line
      attr_accessor :prompt, :rprompt
      attr_reader :buffer

      def initialize(out: $stdout)
        @out = out
        @buffer = +""
        @cursor = 0
        @prompt = "› "
        @rprompt = nil
        @history = []
        @hindex = nil
        @visible = false
      end

      def history = @history

      def push_history(line)
        return if line.strip.empty? || @history.last == line

        @history << line
        @history.shift while @history.size > 500
      end

      def reset(keep: false)
        @buffer = +"" unless keep
        @cursor = @buffer.length
        @hindex = nil
      end

      def hide
        return unless @visible

        @out.print("\r\e[2K")
        @visible = false
      end

      def redraw
        # One column short of the terminal: a line that exactly fills the width
        # wraps on some terminals, and a wrapped input line cannot be cleared
        # by \r\e[2K — that is how a redrawn prompt starts stacking copies.
        cols = Term.width - 1
        left = "#{@prompt}#{@buffer}"
        line =
          if @rprompt && cols > Term.display_width(@rprompt) + 8
            Term.two_column(Term.clip(left, cols - Term.display_width(@rprompt) - 2), @rprompt, cols)
          else
            Term.clip(left, cols)
          end
        @out.print("\r\e[2K#{line}")
        # Put the cursor back where the user is typing.
        back = Term.display_width(line) - (Term.display_width(@prompt) + @cursor)
        @out.print("\e[#{back}D") if back.positive?
        @out.flush
        @visible = true
      end

      # Feed one character. Returns :submit, :interrupt, :eof or nil.
      def feed(char)
        case char
        when "\r", "\n" then :submit
        when "\u0003" then :interrupt
        when "\u0004" then @buffer.empty? ? :eof : nil
        when "\u007F", "\b"
          if @cursor.positive?
            @buffer.slice!(@cursor - 1)
            @cursor -= 1
          end
          nil
        when "\u0001" then (@cursor = 0) && nil
        when "\u0005" then (@cursor = @buffer.length) && nil
        when "\u0015"
          @buffer.slice!(0, @cursor)
          @cursor = 0
          nil
        when "\u000B"
          @buffer.slice!(@cursor..)
          nil
        when "\u0017"
          left = @buffer[0, @cursor].sub(/\S*\s*\z/, "")
          @buffer = left + @buffer[@cursor..].to_s
          @cursor = left.length
          nil
        when "\u000C" then :clear
        when "\e" then :escape
        else
          return nil if char.ord < 32

          @buffer.insert(@cursor, char)
          @cursor += char.length
          nil
        end
      end

      # After "\e" the caller feeds the rest of the sequence.
      def feed_escape(seq)
        case seq
        when "[A" then history_move(-1)
        when "[B" then history_move(1)
        when "[C" then @cursor += 1 if @cursor < @buffer.length
        when "[D" then @cursor -= 1 if @cursor.positive?
        when "[H", "OH" then @cursor = 0
        when "[F", "OF" then @cursor = @buffer.length
        when "[3~"
          @buffer.slice!(@cursor) if @cursor < @buffer.length
        end
        nil
      end

      def history_move(delta)
        return if @history.empty?

        @hindex = @hindex.nil? ? @history.size : @hindex
        @hindex = (@hindex + delta).clamp(0, @history.size)
        @buffer = (@hindex == @history.size ? +"" : @history[@hindex].dup)
        @cursor = @buffer.length
      end

      def take
        line = @buffer
        push_history(line)
        @buffer = +""
        @cursor = 0
        @hindex = nil
        line
      end
    end
  end
end
