# frozen_string_literal: true

require_relative "tools"
require_relative "sandbox/microsandbox"

module Durable
  # Every agent has a sandbox — the place its commands actually run.
  #
  # eve's model: `sandbox/sandbox.rb` swaps the backend or customises the setup,
  # and the rest of the agent does not care. Here the backend is one of:
  #
  #   microsandbox  a local microVM (hardware isolation), via the C ABI
  #   local         the host itself; correct for a coding agent working on your
  #                 checkout, and honest about giving no isolation
  #
  # The sandbox lives in the host Ractor: it holds a live connection, so tools
  # that need it are dispatched there instead of into a tool Ractor.
  module Sandbox
    DEFAULTS = Ractor.make_shareable({
      "backend" => "local",
      "image" => "debian",
      "cpus" => 2,
      "memory" => 1024,
      "name" => nil,
      "workdir" => "/workspace",
      "mountWorkspace" => true,
      "bootstrap" => [],
      "env" => {}
    })

    module_function

    def config(overrides = nil) = DEFAULTS.merge(stringify(overrides || {}))

    def stringify(h)
      h.each_with_object({}) { |(k, v), acc| acc[k.to_s] = v }
    end

    # The DSL for sandbox/sandbox.rb:
    #
    #   sandbox do
    #     backend :microsandbox
    #     image "python:3.12"
    #     cpus 2
    #     memory 2048
    #     bootstrap "pip install -r requirements.txt"
    #   end
    class Definition
      ATTRIBUTES = %w[backend image cpus memory name workdir].freeze

      def initialize
        @config = {}
        @bootstrap = []
        @env = {}
      end

      ATTRIBUTES.each do |attr|
        define_method(attr) { |value| @config[attr] = value.is_a?(Symbol) ? value.to_s : value }
      end

      def mount_workspace(flag) = @config["mountWorkspace"] = !!flag
      def env(key, value) = @env[key.to_s] = value.to_s
      def bootstrap(*commands) = @bootstrap.concat(commands.flatten.map(&:to_s))
      def disabled = @config["backend"] = "local"

      def to_config = @config.merge("bootstrap" => @bootstrap, "env" => @env)
    end

    def load_definition(path)
      d = Definition.new
      body = File.read(path)
      # `sandbox do … end` at the top level of the file.
      d.instance_eval do
        def sandbox(&blk) = instance_eval(&blk)
      end
      d.instance_eval(body, path)
      d.to_config
    end

    # One interface, whichever backend is underneath.
    class Client
      attr_reader :config, :backend_name

      def initialize(vm, config)
        @vm = vm
        @config = config
        @backend_name = vm ? "microsandbox" : "local"
        @started = false
        @mutex = Mutex.new
      end

      def isolated? = !@vm.nil?
      def workdir = @config["workdir"] || "/workspace"
      def host_workspace = @config["hostWorkspace"] || Dir.pwd

      # Boot the VM (idempotent) and run the bootstrap commands once.
      def start
        return self if @started || @vm.nil?

        @mutex.synchronize do
          return self if @started

          name = @config["name"] || "rbagent-#{File.basename(host_workspace)}-#{Process.pid}"
          opts = { "image" => @config["image"], "cpus" => @config["cpus"], "memory" => @config["memory"],
                   "workdir" => workdir, "env" => @config["env"] }
          if @config["mountWorkspace"]
            opts["mounts"] = [{ "host" => host_workspace, "guest" => workdir, "readonly" => false }]
          end
          @vm.create(name, opts.compact)
          @started = true
          (@config["bootstrap"] || []).each { |cmd| exec(cmd) }
        end
        self
      end

      # => { "stdout", "stderr", "exitCode" }
      def exec(command, timeout: 120, cancel: nil)
        if @vm
          start
          @vm.exec("sh", args: ["-lc", command], cwd: workdir, timeout: timeout, cancel: cancel)
        else
          r = Tools.exec_stream(command, host_workspace, timeout: timeout.to_f, cancel: cancel)
          { "stdout" => r["output"], "stderr" => "", "exitCode" => r["exitCode"],
            "cancelled" => r["cancelled"] }
        end
      end

      def read_file(path)
        @vm ? (start && @vm.read_file(absolute(path))) : File.read(File.expand_path(path, host_workspace))
      end

      def write_file(path, content)
        if @vm
          start
          @vm.write_file(absolute(path), content)
        else
          full = File.expand_path(path, host_workspace)
          FileUtils.mkdir_p(File.dirname(full))
          File.write(full, content)
        end
      end

      def absolute(path) = path.to_s.start_with?("/") ? path.to_s : File.join(workdir, path.to_s)

      def stop
        @vm&.stop
        @started = false
      rescue StandardError
        nil
      end

      def describe
        if @vm
          "microsandbox #{@config["image"]} (#{@config["cpus"]} cpu, #{@config["memory"]}MB) → #{workdir}"
        else
          "local (no isolation) → #{host_workspace}"
        end
      end
    end

    # Resolve what the project asked for against what this machine can do, and
    # say so rather than silently degrading.
    def resolve(config, warn_io: $stderr)
      cfg = config(config)
      return Client.new(nil, cfg) unless cfg["backend"] == "microsandbox"

      begin
        Client.new(Microsandbox.new, cfg)
      rescue Microsandbox::NotAvailable => e
        warn_io&.puts("\e[33m sandbox: #{e.message} — falling back to local execution (no isolation)\e[0m")
        Client.new(nil, cfg.merge("backend" => "local", "fallbackReason" => e.message))
      end
    end
  end
end
