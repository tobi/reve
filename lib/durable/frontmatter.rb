# frozen_string_literal: true

module Durable
  # Minimal YAML-frontmatter reader — enough for SKILL.md: scalars, quoted
  # strings, block scalars (| and >), and flat lists. No gems, no YAML engine.
  module Frontmatter
    module_function

    # Returns [frontmatter_hash, body_string].
    def parse(text)
      return [{}, text] unless text.start_with?("---")

      lines = text.lines
      close = lines[1..]&.index { |l| l.rstrip == "---" || l.rstrip == "..." }
      return [{}, text] unless close

      head = lines[1, close]
      body = lines[(close + 2)..]&.join.to_s
      [parse_block(head), body]
    end

    def parse_block(lines)
      out = {}
      key = nil
      mode = nil       # :block | :list
      buffer = []
      indent = nil

      flush = lambda do
        next unless key

        case mode
        when :block then out[key] = buffer.join("\n").strip
        when :list then out[key] = buffer.empty? ? "" : buffer.dup
        end
        buffer = []
        mode = nil
      end

      lines.each do |raw|
        line = raw.chomp
        if mode == :block
          if line.strip.empty?
            buffer << ""
            next
          end
          cur = line[/\A */].size
          indent ||= cur
          if cur >= indent
            buffer << line[indent..].to_s
            next
          end
          flush.call
        elsif mode == :list && line =~ /\A\s*-\s+(.*)\z/
          buffer << unquote(::Regexp.last_match(1))
          next
        elsif mode == :list
          flush.call
        end

        next if line.strip.empty? || line.strip.start_with?("#")

        m = line.match(/\A([A-Za-z0-9_.-]+):\s*(.*)\z/) or next
        key = m[1]
        value = m[2].strip
        case value
        when "", "|", "|-", ">", ">-"
          mode = value.empty? ? :list : :block
          indent = nil
          buffer = []
          out[key] = "" if mode == :block
        else
          out[key] = unquote(value)
          key = nil
        end
      end
      flush.call
      out
    end

    def unquote(value)
      v = value.strip
      return v[1..-2].to_s.gsub('\\"', '"') if v.start_with?('"') && v.end_with?('"') && v.length > 1
      return v[1..-2].to_s if v.start_with?("'") && v.end_with?("'") && v.length > 1
      return true if v == "true"
      return false if v == "false"

      v
    end
  end
end
