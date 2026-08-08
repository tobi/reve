# frozen_string_literal: true

require_relative "tools"

module Leve
  # `tools/` is a folder of Ruby. One file, one (or more) tools:
  #
  #   tool "weather" do
  #     description "Get the weather for a city"
  #     string  :city, "City name", required: true
  #     integer :days, "Forecast length"
  #     replay  :safe            # safe to re-run after a crash
  #     sandbox true             # run inside the sandbox, not on the host
  #
  #     run do |args, ctx|
  #       ctx.sh("curl -s wttr.in/#{args["city"]}")
  #     end
  #   end
  #
  # A project tool's body is a Ruby block, and a block cannot cross a Ractor
  # boundary — so project tools run in the host Ractor and lanes reach them by
  # RPC, exactly like hooks. Built-in tools keep running in their own Ractors.
  module ToolDSL
    module_function

    TYPES = { string: "string", integer: "integer", number: "number",
              boolean: "boolean", array: "array", object: "object" }.freeze

    class Definition
      attr_reader :name, :handler

      def initialize(name)
        @name = name.to_s
        @description = ""
        @properties = {}
        @required = []
        @replay = "never"
        @sandbox = false
        @timeout = nil
      end

      def description(text = nil)
        return @description if text.nil?

        @description = text.to_s
      end

      TYPES.each do |ruby_name, json_type|
        define_method(ruby_name) do |field, desc = nil, required: false, **extra|
          prop = { "type" => json_type }
          prop["description"] = desc.to_s if desc
          prop.merge!(extra.transform_keys(&:to_s))
          @properties[field.to_s] = prop
          @required << field.to_s if required
          prop
        end
      end

      # "safe" means: recovery may re-execute this call with the persisted
      # arguments after a crash. Default is never, because that is the safe
      # default for anything with an effect.
      def replay(value) = @replay = value.to_s
      def sandbox(flag = true) = @sandbox = !!flag
      def sandboxed? = @sandbox
      def timeout(seconds) = @timeout = seconds

      # The block is the tool's implementation. It is always called with
      # `|args, ctx|`: a hash of validated arguments and a Context. The schema
      # the model sees comes solely from the explicit `string`/`integer`/...
      # declarations above, so nothing is written twice.
      def run(&blk)
        @handler = blk
        blk
      end

      def declaration
        { "name" => @name, "description" => @description.to_s, "replay" => @replay,
          "runner" => "host", "sandbox" => @sandbox, "timeout" => @timeout,
          "parameters" => parameters_schema }
      end

      # The schema is built only from explicit declarations: each `string`/
      # `integer`/... call adds a property, and `required: true` marks it.
      def parameters_schema
        { "type" => "object", "properties" => @properties,
          "required" => @required.select { @properties.key?(_1) } }
      end
    end

    # The file-level DSL. Each file is evaluated in a fresh collector, so a
    # syntax or load error is reported per file and the others still load.
    class Collector
      attr_reader :definitions, :diagnostics

      def initialize
        @definitions = []
        @diagnostics = []
      end

      def tool(name, &blk)
        d = Definition.new(name)
        d.instance_eval(&blk)
        if d.handler.nil?
          @diagnostics << { "type" => "warning", "message" => "tool #{name} has no run block" }
          return nil
        end
        @definitions << d
        d
      end

      def load_file(path)
        instance_eval(File.read(path), path)
      rescue SyntaxError, StandardError => e
        @diagnostics << { "type" => "error", "path" => path, "message" => "#{e.class}: #{e.message}" }
      end
    end

    # Load every tools/*.rb in a directory. Returns definitions (with live
    # handlers, host-side) plus diagnostics.
    def load_dir(dir)
      collector = Collector.new
      return { "tools" => [], "diagnostics" => [] } unless File.directory?(dir)

      Dir.glob(File.join(dir, "**", "*.rb")).sort.each { |f| collector.load_file(f) }
      names = {}
      tools = []
      diagnostics = collector.diagnostics.dup
      collector.definitions.each do |d|
        if names[d.name] || Tools.spec(d.name)
          diagnostics << { "type" => "collision", "message" => "tool #{d.name.inspect} already defined" }
          next
        end
        names[d.name] = true
        tools << d
      end
      { "tools" => tools, "diagnostics" => diagnostics }
    end

    # What a project tool's block is handed as its second argument.
    class Context
      attr_reader :sandbox, :cwd, :lane, :harness

      def initialize(sandbox:, cwd:, lane: "main", harness: nil)
        @sandbox = sandbox
        @cwd = cwd
        @lane = lane
        @harness = harness
      end

      # Convenience so a tool body reads like a shell script when it wants to.
      # Runs through the sandbox handle, never on the host.
      def sh(command, timeout: 120)
        r = @sandbox.exec(command, timeout: timeout)
        raise "command failed (exit #{r["exitCode"]}): #{r["stderr"]}#{r["stdout"]}" unless r["exitCode"].zero?

        r["stdout"]
      end

      def read(path) = @sandbox.read_file(path)
      def write(path, content) = @sandbox.write_file(path, content)
    end

    # Run a project tool's block and normalise whatever it returns into a tool
    # result. A raised exception is an error result, never a crashed run. The
    # block is always called with `|args, ctx|`.
    def invoke(definition, args, context)
      value = definition.handler.call(args, context)
      normalise(value)
    rescue StandardError => e
      Tools.error("#{e.class}: #{e.message}")
    end

    def normalise(value)
      case value
      when nil then Tools.ok("(no output)")
      when String then Tools.ok(value)
      when Hash
        return value if value.key?("content")

        Tools.ok(JSON.pretty_generate(value))
      when Array then Tools.ok(value.map(&:to_s).join("\n"))
      else Tools.ok(value.to_s)
      end
    end
  end
end
