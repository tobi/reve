# frozen_string_literal: true

require "fileutils"
require "json"

module Leve
  # Channels are trusted, host-side adapters. Dropping one Ruby file into
  # channels/ can add an input/output transport, slash commands, durable local
  # settings, and stable system-prompt guidance without changing the harness.
  module Channels
    Registration = Data.define(:name, :adapter, :system_prompt)
    Command = Data.define(:name, :description, :schema, :handler)

    @registrations = {}

    module_function

    def register(name, adapter, system_prompt: nil)
      key = name.to_s
      raise ArgumentError, "invalid channel name #{key.inspect}" unless key.match?(/\A[a-z][a-z0-9_-]*\z/)
      raise ArgumentError, "channel #{key.inspect} is already registered" if @registrations.key?(key)

      @registrations[key] = Registration.new(name: key, adapter: adapter,
                                               system_prompt: system_prompt.to_s.strip)
    end

    def registrations = @registrations.values
    def system_prompts = registrations.map(&:system_prompt).reject(&:empty?)

    def load_directory(root)
      Dir.glob(File.join(root, "channels", "*.rb")).sort.each { |path| load path }
    end

    # A tiny namespaced JSON KV store under the agent's durable control plane.
    # Channel credentials stay on the host and outside the VM bind mount.
    class KV
      def initialize(root, namespace)
        @path = File.join(root, ".leve", "channels.json")
        @namespace = namespace.to_s
        @mutex = Mutex.new
      end

      def get(key, default = nil)
        synchronize { read.fetch(@namespace, {}).fetch(key.to_s, default) }
      end

      def set(key, value)
        synchronize do
          all = read
          (all[@namespace] ||= {})[key.to_s] = value
          write(all)
        end
        value
      end

      def delete(key)
        synchronize do
          all = read
          value = all.fetch(@namespace, {}).delete(key.to_s)
          write(all)
          value
        end
      end

      def to_h = synchronize { read.fetch(@namespace, {}).dup }

      private

      def synchronize(&block)
        @mutex.synchronize do
          FileUtils.mkdir_p(File.dirname(@path))
          File.open("#{@path}.lock", File::RDWR | File::CREAT, 0o600) do |lock|
            lock.flock(File::LOCK_EX)
            block.call
          end
        end
      end

      def read
        File.file?(@path) ? JSON.parse(File.read(@path)) : {}
      rescue JSON::ParserError => e
        raise ArgumentError, "invalid #{@path}: #{e.message}"
      end

      def write(value)
        FileUtils.mkdir_p(File.dirname(@path))
        tmp = "#{@path}.tmp-#{Process.pid}-#{Thread.current.object_id}"
        File.write(tmp, "#{JSON.pretty_generate(value)}\n")
        File.chmod(0o600, tmp)
        File.rename(tmp, @path)
      ensure
        FileUtils.rm_f(tmp) if defined?(tmp)
      end
    end

    class Context
      attr_reader :harness, :project, :name, :kv

      def initialize(runtime, registration)
        @runtime = runtime
        @harness = runtime.harness
        @project = runtime.project
        @name = registration.name
        @kv = KV.new(project.root, name)
      end

      def command(name, description:, schema: {}, &handler)
        @runtime.register_command(name, description: description, schema: schema, &handler)
      end

      def prompt(text, lane: "main")
        message = "[channel=#{name}] #{text}"
        handle = harness.lane(lane) || harness.main
        handle.state["operation"] ? handle.steer(message) : handle.prompt(message)
      end

      def watch(lane = nil) = harness.watch(lane)
    end

    class Runtime
      attr_reader :harness, :project

      def initialize(harness, project, reserved: [])
        @harness = harness
        @project = project
        # The front-end that dispatches slash commands owns the names it takes
        # first; it hands them over so a shadowed channel command fails loudly
        # at boot instead of quietly never running.
        @reserved = reserved.map(&:to_s).freeze
        @commands = {}
        @instances = []
        Channels.registrations.each do |registration|
          context = Context.new(self, registration)
          @instances << registration.adapter.new(context)
        end
      end

      def start
        @instances.each { _1.start if _1.respond_to?(:start) }
        self
      end

      def close
        @instances.reverse_each { _1.close if _1.respond_to?(:close) }
      end

      def register_command(name, description:, schema: {}, &handler)
        key = name.to_s.delete_prefix("/")
        raise ArgumentError, "invalid channel command #{key.inspect}" unless key.match?(/\A[a-z][a-z0-9_-]*\z/)
        raise ArgumentError, "channel command /#{key} is already registered" if @commands.key?(key)
        raise ArgumentError, "channel command /#{key} is reserved by the harness" if @reserved.include?(key)

        @commands[key] = Command.new(name: key, description: description.to_s,
                                     schema: schema, handler: handler)
      end

      def command_names = @commands.keys.sort
      def command_help = @commands.values.sort_by(&:name)
      def command?(name) = @commands.key?(name.to_s.delete_prefix("/"))

      def invoke(name, raw = nil)
        command = @commands.fetch(name.to_s.delete_prefix("/"))
        args = parse_args(raw, command.schema)
        command.handler.call(args)
      rescue JSON::ParserError => e
        { "ok" => false, "error" => "arguments must be a JSON object: #{e.message}" }
      rescue StandardError => e
        { "ok" => false, "error" => "#{e.class}: #{e.message}" }
      end

      private

      def parse_args(raw, schema)
        text = raw.to_s.strip
        args = text.empty? ? {} : JSON.parse(text)
        raise JSON::ParserError, "expected an object" unless args.is_a?(Hash)

        required = Array(schema["required"] || schema[:required]).map(&:to_s)
        missing = required - args.keys
        raise ArgumentError, "missing required argument(s): #{missing.join(", ")}" unless missing.empty?

        args
      end
    end
  end
end
