# frozen_string_literal: true

module Reve
  # Tool schemas from RBS type comments.
  #
  # A tool's parameters are a type signature, and Ruby already has a notation
  # for that. So a tool may be written like this:
  #
  #   tool "weather" do
  #     description "Get the weather for a city"
  #     # @param city  City name, e.g. "Berlin"
  #     # @param units Unit system
  #     #: (city: String, ?units: ("metric" | "imperial"), ?days: Integer) -> String
  #     run do |city:, units: "metric", days: 3|
  #       ...
  #     end
  #   end
  #
  # and the JSON schema the model sees — types, enums, requiredness,
  # descriptions — is derived from the signature instead of being written twice.
  #
  # RBS ships with Ruby, so we use its parser when it is there (it handles the
  # whole grammar) and fall back to a small parser for the common forms, because
  # reve depends on nothing.
  module RbsSchema
    # Single-quoted on purpose: "#@rbs" in a double-quoted string interpolates
    # the instance variable @rbs, which is nil, which makes the marker "" —
    # and an empty marker matches every comment line.
    SIGNATURE_MARKERS = ["#:", "# @rbs", '#@rbs'].freeze
    PARAM_DOC = /\A#\s*@param\s+(\w+)\s+(.*)\z/
    RETURN_DOC = /\A#\s*@return\s+(.*)\z/

    module_function

    def rbs_available?
      return @rbs_available unless @rbs_available.nil?

      @rbs_available =
        begin
          require "rbs"
          true
        rescue LoadError
          false
        end
    end

    # ── reading the comment block above a proc ────────────────────────────

    SEARCH_LIMIT = 40

    # Returns { "signature" =>, "params" => { name => doc }, "doc" => } for the
    # comments above the given source location.
    #
    # The signature does not have to sit immediately above the block: a tool may
    # put `replay :safe` or a blank line in between, and the comment block above
    # `tool "name" do` counts too. So: walk upward, gather comment blocks, take
    # the nearest signature, and merge the @param docs.
    def comment_block(path, lineno)
      return empty_block unless path && lineno && File.file?(path)

      lines = File.readlines(path)
      result = empty_block
      i = lineno - 2 # zero-based, the line above the definition
      floor = [0, i - SEARCH_LIMIT].max
      while i >= floor
        line = lines[i].to_s.strip
        if line.start_with?("#")
          block = []
          while i >= 0 && lines[i].to_s.strip.start_with?("#")
            block.unshift(lines[i].to_s.strip)
            i -= 1
          end
          parsed = parse_comments(block)
          result["signature"] ||= parsed["signature"]
          result["doc"] ||= parsed["doc"]
          result["params"] = parsed["params"].merge(result["params"])
          next
        end
        break if /\btool\b.*\bdo\b/.match?(line) # the comments above it were the last chance

        i -= 1
      end
      result
    rescue SystemCallError
      empty_block
    end

    def empty_block = { "signature" => nil, "params" => {}, "doc" => nil }

    def parse_comments(lines)
      block = empty_block
      doc = []
      lines.each do |line|
        if (marker = SIGNATURE_MARKERS.find { line.start_with?(_1) })
          block["signature"] = line.delete_prefix(marker).strip
        elsif (m = PARAM_DOC.match(line))
          block["params"][m[1]] = m[2].strip
        elsif RETURN_DOC.match?(line)
          next
        else
          text = line.sub(/\A#+\s?/, "").strip
          doc << text unless text.empty?
        end
      end
      block["doc"] = doc.join(" ") unless doc.empty?
      block
    end

    # Everything a proc can tell us about its own arguments.
    def proc_signature(callable)
      path, lineno = callable.source_location
      block = comment_block(path, lineno)
      block["parameters"] = callable.parameters
      block
    end

    # ── signature → JSON schema ───────────────────────────────────────────

    # `parameters` is Proc#parameters; it supplies the names and which ones are
    # optional even when the signature omits a `?`.
    def to_schema(signature, params: {}, parameters: nil)
      types = signature ? parse(signature) : { "required" => {}, "optional" => {} }
      properties = {}
      required = []

      types["required"].each do |name, type|
        properties[name.to_s] = json_type(type).merge(description_for(name, params))
        required << name.to_s
      end
      types["optional"].each do |name, type|
        properties[name.to_s] = json_type(type).merge(description_for(name, params))
      end

      # Keyword arguments the signature did not mention still belong in the
      # schema — otherwise the model cannot pass them.
      (parameters || []).each do |kind, name|
        next unless %i[key keyreq].include?(kind)
        next if name.nil? || name.to_s == "ctx" || properties.key?(name.to_s)

        properties[name.to_s] = { "type" => "string" }.merge(description_for(name, params))
        required << name.to_s if kind == :keyreq
      end

      # A signature's `?` and a block's default value should agree; when they do
      # not, the block wins, because that is what actually runs.
      (parameters || []).each do |kind, name|
        required.delete(name.to_s) if kind == :key
      end

      { "type" => "object", "properties" => properties, "required" => required.uniq }
    end

    def description_for(name, params)
      doc = params[name.to_s]
      doc ? { "description" => doc } : {}
    end

    # => { "required" => { name => type }, "optional" => { name => type } }
    def parse(signature)
      rbs_available? ? parse_with_rbs(signature) : parse_simple(signature)
    rescue StandardError
      parse_simple(signature)
    end

    def parse_with_rbs(signature)
      method_type = RBS::Parser.parse_method_type(normalise(signature))
      fn = method_type.type
      out = { "required" => {}, "optional" => {} }
      fn.required_keywords.each { |name, param| out["required"][name] = param.type }
      fn.optional_keywords.each { |name, param| out["optional"][name] = param.type }
      # Positional parameters are named in RBS (`(String path)`), which is what
      # a tool's arguments are: named values.
      fn.required_positionals.each_with_index do |param, index|
        name = param.name || :"arg#{index}"
        out["required"][name] = param.type
      end
      fn.optional_positionals.each_with_index do |param, index|
        name = param.name || :"opt#{index}"
        out["optional"][name] = param.type
      end
      out
    end

    def normalise(signature)
      sig = signature.strip
      sig = sig.sub(/\A(def\s+\w+\s*)?/, "")
      sig = "(#{sig})" unless sig.start_with?("(")
      sig.include?("->") ? sig : "#{sig} -> untyped"
    end

    # The fallback: enough of the grammar for tool signatures, with no RBS.
    def parse_simple(signature)
      out = { "required" => {}, "optional" => {} }
      inner = signature.to_s[/\((.*)\)\s*(->.*)?\z/m, 1] || signature.to_s
      split_top_level(inner).each do |part|
        part = part.strip
        next if part.empty?

        optional = part.start_with?("?")
        part = part.delete_prefix("?")
        if (m = /\A(\w+)\s*:\s*(.+)\z/m.match(part))
          name = m[1].to_sym
          type = m[2].strip
        else
          words = part.split(/\s+/)
          type = words[0]
          name = (words[1] || "arg").to_sym
        end
        out[optional ? "optional" : "required"][name] = type
      end
      out
    end

    # Commas inside brackets or quotes do not separate parameters.
    def split_top_level(text)
      parts = []
      depth = 0
      quote = nil
      current = +""
      text.to_s.each_char do |char|
        case char
        when '"', "'"
          quote = quote == char ? nil : (quote || char)
          current << char
        when "[", "(", "{" then (depth += 1) && (current << char)
        when "]", ")", "}" then (depth -= 1) && (current << char)
        when ","
          if depth.zero? && quote.nil?
            parts << current
            current = +""
          else
            current << char
          end
        else current << char
        end
      end
      parts << current
      parts
    end

    # ── type mapping ──────────────────────────────────────────────────────

    SCALARS = {
      "String" => { "type" => "string" },
      "Symbol" => { "type" => "string" },
      "Integer" => { "type" => "integer" },
      "Float" => { "type" => "number" },
      "Numeric" => { "type" => "number" },
      "TrueClass" => { "type" => "boolean" },
      "FalseClass" => { "type" => "boolean" },
      "bool" => { "type" => "boolean" },
      "boolish" => { "type" => "boolean" },
      "untyped" => {},
      "top" => {},
      "void" => {}
    }.freeze

    def json_type(type)
      return json_type_from_string(type) if type.is_a?(String)
      return {} if type.nil?

      case type
      when defined?(RBS) && RBS::Types::ClassInstance then class_instance(type)
      when defined?(RBS) && RBS::Types::Optional then json_type(type.type)
      when defined?(RBS) && RBS::Types::Union then union(type)
      when defined?(RBS) && RBS::Types::Literal then literal(type)
      when defined?(RBS) && RBS::Types::Bases::Bool then { "type" => "boolean" }
      when defined?(RBS) && RBS::Types::Bases::Any then {}
      when defined?(RBS) && RBS::Types::Tuple then { "type" => "array" }
      when defined?(RBS) && RBS::Types::Record then { "type" => "object" }
      when defined?(RBS) && RBS::Types::Alias then json_type_from_string(type.name.to_s)
      else json_type_from_string(type.to_s)
      end
    end

    def class_instance(type)
      name = type.name.to_s.delete_prefix("::")
      case name
      when "Array"
        item = type.args.first
        item ? { "type" => "array", "items" => json_type(item) } : { "type" => "array" }
      when "Hash" then { "type" => "object" }
      else SCALARS[name] || { "type" => "string" }
      end
    end

    def literal(type)
      value = type.literal
      case value
      when String, Symbol then { "type" => "string", "enum" => [value.to_s] }
      when Integer then { "type" => "integer", "enum" => [value] }
      when true, false then { "type" => "boolean", "enum" => [value] }
      else { "enum" => [value] }
      end
    end

    # A union of literals is an enum; a union with nil is just the other type;
    # anything else degrades to the first member, which is still better than
    # nothing.
    def union(type)
      members = type.types.reject { |t| t.is_a?(RBS::Types::Bases::Nil) }
      return {} if members.empty?
      return json_type(members.first) if members.size == 1

      if members.all? { _1.is_a?(RBS::Types::Literal) }
        schemas = members.map { literal(_1) }
        return { "type" => schemas.first["type"], "enum" => schemas.flat_map { _1["enum"] } }.compact
      end

      mapped = members.map { json_type(_1) }.uniq
      return mapped.first if mapped.size == 1

      types = mapped.filter_map { _1["type"] }.uniq
      types.size == 1 ? { "type" => types.first } : { "anyOf" => mapped }
    end

    def json_type_from_string(text)
      text = text.to_s.strip
      return {} if text.empty?

      # A grouped type — ("a" | "b") — is the group's content.
      text = text[1..-2].to_s.strip while text.start_with?("(") && text.end_with?(")")
      # nilable / optional
      text = text.delete_suffix("?")
      # literal unions: "a" | "b"
      parts = split_union(text)
      if parts.size > 1
        if parts.all? { literal_string?(_1) }
          return { "type" => "string", "enum" => parts.map { unquote(_1) } }
        end

        return json_type_from_string(parts.first)
      end
      return { "type" => "string", "enum" => [unquote(text)] } if literal_string?(text)
      return { "type" => "integer", "enum" => [text.to_i] } if /\A-?\d+\z/.match?(text)

      if (m = /\AArray\[(.+)\]\z/m.match(text))
        return { "type" => "array", "items" => json_type_from_string(m[1]) }
      end
      return { "type" => "object" } if text.start_with?("Hash[", "{")

      SCALARS[text.delete_prefix("::")] || { "type" => "string" }
    end

    def split_union(text)
      split_top_level(text.tr("|", ",")).map(&:strip).reject(&:empty?)
    end

    def literal_string?(text)
      (text.start_with?('"') && text.end_with?('"')) ||
        (text.start_with?("'") && text.end_with?("'")) ||
        text.start_with?(":")
    end

    def unquote(text)
      text = text.strip
      return text[1..-2].to_s if text.length > 1 && (text.start_with?('"') || text.start_with?("'"))

      text.delete_prefix(":")
    end
  end
end
