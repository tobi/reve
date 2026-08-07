# frozen_string_literal: true

module Reve
  module Sandbox
    # The sole microsandbox transport: the microsandbox-rb gem's embedded Rust
    # runtime. Reve deliberately has no CLI, Fiddle, daemon, or host fallback.
    class Microsandbox
      class Error < StandardError
        attr_reader :kind

        def initialize(message, kind: "internal")
          @kind = kind
          super(message)
        end
      end

      class NotAvailable < Error; end

      class << self
        def load_gem!
          return ::Microsandbox if defined?(::Microsandbox::Sandbox)

          require "microsandbox"
          ::Microsandbox
        rescue LoadError => e
          raise NotAvailable.new(
            "microsandbox-rb is required (install the bundle with `bundle install`): #{e.message}",
            kind: "not_available"
          )
        end

        def available?
          load_gem!
          true
        rescue NotAvailable
          false
        end
      end

      def initialize(api: nil)
        @api = api || self.class.load_gem!
        @sandbox = nil
        @name = nil
      end

      attr_reader :name
      def handle = @sandbox

      def version
        { "version" => @api.version.to_s, "runtimeVersion" => @api.runtime_version.to_s }
      end

      def create(name, opts = {})
        @name = name
        @sandbox = @api::Sandbox.create(name, **create_keywords(opts))
        { "handle" => @sandbox, "name" => name }
      rescue StandardError => e
        raise wrapped(e)
      end

      # Restart the persisted named sandbox. A running instance belongs to
      # another Reve process; never replace or steal it.
      def connect(name)
        handle = @api::Sandbox.get(name)
        if handle.running?
          raise Error.new("sandbox #{name.inspect} is already in use by another Reve process", kind: "in_use")
        end

        @name = name
        @sandbox = @api::Sandbox.start(name)
        { "handle" => @sandbox, "name" => name }
      rescue StandardError => e
        raise e if e.is_a?(Error)

        raise wrapped(e)
      end

      def exec(command, args: [], cwd: nil, timeout: nil, cancel: nil)
        raise Error.new("sandbox has not been created", kind: "not_started") unless @sandbox

        output, cancelled = cancel ? cancellable_exec(command, args, cwd, timeout, cancel) :
                                     [@sandbox.exec(command, args, cwd: cwd, timeout: timeout), false]
        {
          "stdout" => output.stdout.to_s,
          "stderr" => output.stderr.to_s,
          "exitCode" => output.exit_code.to_i,
          "cancelled" => cancelled
        }
      rescue StandardError => e
        raise e if e.is_a?(Error)

        raise wrapped(e)
      end

      def read_file(path)
        ensure_started!
        @sandbox.fs.read(path)
      rescue StandardError => e
        raise wrapped(e)
      end

      def write_file(path, content)
        ensure_started!
        @sandbox.fs.write(path, content)
        { "ok" => true }
      rescue StandardError => e
        raise wrapped(e)
      end

      def copy_in(host_path, guest_path)
        ensure_started!
        @sandbox.fs.copy_from_host(host_path, guest_path)
        { "ok" => true }
      rescue StandardError => e
        raise wrapped(e)
      end

      def copy_out(guest_path, host_path)
        ensure_started!
        @sandbox.fs.copy_to_host(guest_path, host_path)
        { "ok" => true }
      rescue StandardError => e
        raise wrapped(e)
      end

      def stop(timeout_ms: 10_000)
        return unless @sandbox

        @sandbox.stop
        { "ok" => true }
      rescue StandardError => e
        raise wrapped(e)
      ensure
        @sandbox = nil
      end

      def detach
        raise Error.new("detaching is unsupported; reve owns sandbox lifecycle", kind: "unsupported")
      end

      private

      def ensure_started!
        raise Error.new("sandbox has not been created", kind: "not_started") unless @sandbox
      end

      def create_keywords(opts)
        keywords = {
          image: opts["image"],
          cpus: opts["cpus"],
          memory: opts["memory_mib"] || opts["memory"],
          workdir: opts["workdir"],
          security: opts["security"],
          env: opts["env"],
          volumes: normalize_volumes(opts["volumes"]),
          network: normalize_network(opts["network"]),
          secrets: normalize_secrets(opts["secrets"]),
          replace: !!opts["replace"]
        }
        keywords.reject { |_, value| value.nil? || value.respond_to?(:empty?) && value.empty? }
      end

      def normalize_volumes(volumes)
        return nil if !volumes || volumes.empty?

        volumes.transform_values do |spec|
          {
            bind: spec["bind"],
            readonly: !!spec["readonly"],
            nosuid: !!spec["nosuid"],
            nodev: !!spec["nodev"]
          }.compact
        end
      end

      # Reve's policy is already normalized; adapt its older wire wrapper to the
      # gem's public `network:` Hash.
      def normalize_network(network)
        policy = network && (network["custom_policy"] || network)
        return nil unless policy

        {
          default_egress: :deny,
          default_ingress: :allow,
          rules: policy["rules"] || []
        }
      end

      def normalize_secrets(secrets)
        Array(secrets).map do |entry|
          {
            env: entry["env_var"],
            value: entry["value"],
            hosts: entry["allow_hosts"],
            placeholder: entry["placeholder"]
          }.compact
        end
      end

      # The synchronous native call releases the GVL but cannot be interrupted.
      # When a cancellation callback is present, use the gem's stream handle so
      # we can kill only the guest command, not the VM.
      def cancellable_exec(command, args, cwd, timeout, cancel)
        handle = @sandbox.exec_stream(command, args, cwd: cwd)
        cancelled = false
        deadline = timeout && Process.clock_gettime(Process::CLOCK_MONOTONIC) + timeout.to_f
        watcher = Thread.new do
          loop do
            timed_out = deadline && Process.clock_gettime(Process::CLOCK_MONOTONIC) >= deadline
            if cancel.call || timed_out
              cancelled = true
              handle.kill
              break
            end
            sleep 0.05
          end
        rescue StandardError
          nil
        end
        [handle.collect, cancelled]
      ensure
        watcher&.kill
      end

      def wrapped(error)
        code = error.respond_to?(:code) ? error.code.to_s : "internal"
        Error.new(error.message, kind: code)
      end
    end
  end
end
