# frozen_string_literal: true

require "json"
require "base64"
require "fiddle"
require "fiddle/import"

module Durable
  module Sandbox
    # Ruby bindings for microsandbox (https://github.com/superradcompany/microsandbox),
    # written against its C ABI with fiddle — the stdlib's FFI, because this
    # project takes no gems.
    #
    # The ABI is pleasant to bind: every call takes an opaque cancellation id,
    # JSON-encoded options, and a caller-provided output buffer. It returns NULL
    # on success (with NUL-terminated JSON in the buffer) or a char* JSON error
    # that the caller frees with msb_free_string.
    #
    #   char *msb_sandbox_create(uint64 cancel_id, const char *name,
    #                            const char *opts_json, uint8 *buf, size_t len);
    #
    # The library ships with the SDKs as libmicrosandbox_go_ffi.{so,dylib}.
    class Microsandbox
      class Error < StandardError
        attr_reader :kind

        def initialize(message, kind: "internal")
          @kind = kind
          super(message)
        end
      end

      class NotAvailable < Error; end

      LIB_NAMES = %w[libmicrosandbox_go_ffi.so libmicrosandbox_go_ffi.dylib
                     libmicrosandbox.so libmicrosandbox.dylib].freeze
      SEARCH_DIRS = [
        ENV["MICROSANDBOX_LIB_DIR"],
        File.expand_path("~/.microsandbox/lib"),
        File.expand_path("~/.microsandbox/bin"),
        "/usr/local/lib", "/usr/lib", "/opt/homebrew/lib"
      ].compact.freeze
      BUF_SIZE = 1 << 20

      # ── library loading ───────────────────────────────────────────────────

      def self.library_path
        return ENV["MICROSANDBOX_LIB"] if ENV["MICROSANDBOX_LIB"] && File.exist?(ENV["MICROSANDBOX_LIB"])

        SEARCH_DIRS.each do |dir|
          LIB_NAMES.each do |name|
            path = File.join(dir, name)
            return path if File.exist?(path)
          end
        end
        nil
      end

      def self.available? = !library_path.nil?

      # The subset of the ABI this agent needs: create/connect, exec, files,
      # lifecycle. Everything else stays behind the same call convention and can
      # be added in one line.
      SIGNATURES = {
        "msb_free_string" => [Fiddle::TYPE_VOID, [Fiddle::TYPE_VOIDP]],
        "msb_cancel_alloc" => [Fiddle::TYPE_LONG_LONG, []],
        "msb_cancel_trigger" => [Fiddle::TYPE_VOID, [Fiddle::TYPE_LONG_LONG]],
        "msb_cancel_unregister" => [Fiddle::TYPE_VOID, [Fiddle::TYPE_LONG_LONG]],
        "msb_version" => [Fiddle::TYPE_VOIDP, [Fiddle::TYPE_VOIDP, Fiddle::TYPE_SIZE_T]],
        "msb_sandbox_create" => [Fiddle::TYPE_VOIDP,
                                 [Fiddle::TYPE_LONG_LONG, Fiddle::TYPE_VOIDP, Fiddle::TYPE_VOIDP,
                                  Fiddle::TYPE_VOIDP, Fiddle::TYPE_SIZE_T]],
        "msb_sandbox_connect" => [Fiddle::TYPE_VOIDP,
                                  [Fiddle::TYPE_LONG_LONG, Fiddle::TYPE_VOIDP,
                                   Fiddle::TYPE_VOIDP, Fiddle::TYPE_SIZE_T]],
        "msb_sandbox_exec" => [Fiddle::TYPE_VOIDP,
                               [Fiddle::TYPE_LONG_LONG, Fiddle::TYPE_LONG_LONG, Fiddle::TYPE_VOIDP,
                                Fiddle::TYPE_VOIDP, Fiddle::TYPE_VOIDP, Fiddle::TYPE_SIZE_T]],
        "msb_sandbox_stop" => [Fiddle::TYPE_VOIDP,
                               [Fiddle::TYPE_LONG_LONG, Fiddle::TYPE_LONG_LONG, Fiddle::TYPE_LONG_LONG,
                                Fiddle::TYPE_VOIDP, Fiddle::TYPE_SIZE_T]],
        "msb_sandbox_detach" => [Fiddle::TYPE_VOIDP,
                                 [Fiddle::TYPE_LONG_LONG, Fiddle::TYPE_LONG_LONG,
                                  Fiddle::TYPE_VOIDP, Fiddle::TYPE_SIZE_T]],
        "msb_fs_read" => [Fiddle::TYPE_VOIDP,
                          [Fiddle::TYPE_LONG_LONG, Fiddle::TYPE_LONG_LONG, Fiddle::TYPE_VOIDP,
                           Fiddle::TYPE_VOIDP, Fiddle::TYPE_SIZE_T]],
        "msb_fs_write" => [Fiddle::TYPE_VOIDP,
                           [Fiddle::TYPE_LONG_LONG, Fiddle::TYPE_LONG_LONG, Fiddle::TYPE_VOIDP,
                            Fiddle::TYPE_VOIDP, Fiddle::TYPE_VOIDP, Fiddle::TYPE_SIZE_T]],
        "msb_fs_copy_from_host" => [Fiddle::TYPE_VOIDP,
                                    [Fiddle::TYPE_LONG_LONG, Fiddle::TYPE_LONG_LONG, Fiddle::TYPE_VOIDP,
                                     Fiddle::TYPE_VOIDP, Fiddle::TYPE_VOIDP, Fiddle::TYPE_SIZE_T]],
        "msb_fs_copy_to_host" => [Fiddle::TYPE_VOIDP,
                                  [Fiddle::TYPE_LONG_LONG, Fiddle::TYPE_LONG_LONG, Fiddle::TYPE_VOIDP,
                                   Fiddle::TYPE_VOIDP, Fiddle::TYPE_VOIDP, Fiddle::TYPE_SIZE_T]]
      }.freeze

      def initialize(path: nil)
        path ||= self.class.library_path
        raise NotAvailable, "microsandbox library not found (set MICROSANDBOX_LIB)" unless path

        @lib = Fiddle.dlopen(path)
        @fns = {}
        SIGNATURES.each do |name, (ret, args)|
          @fns[name] = Fiddle::Function.new(@lib[name], args, ret)
        rescue Fiddle::DLError
          @fns[name] = nil # optional symbol; calls report it as unsupported
        end
        @mutex = Mutex.new
      end

      # => { "version" => "…" }
      def version = call("msb_version", buffer_only: true)

      # ── the call convention ───────────────────────────────────────────────

      # Every ABI call routes through here: allocate a cancel token, hand the
      # library a buffer, decode JSON out of it, and turn a returned char* into
      # a Ruby exception.
      def call(name, *args, buffer_only: false, cancel: nil)
        fn = @fns[name] or raise Error, "microsandbox library has no #{name}"

        buf = Fiddle::Pointer.malloc(BUF_SIZE, Fiddle::RUBY_FREE)
        cancel_id = buffer_only ? 0 : alloc_cancel
        watcher = cancel && start_cancel_watcher(cancel_id, cancel)
        begin
          argv = buffer_only ? [buf, BUF_SIZE] : [cancel_id, *args.map { to_c(_1) }, buf, BUF_SIZE]
          err = fn.call(*argv)
          raise_error(err) if err && !err.null?

          decode(buf)
        ensure
          watcher&.kill
          free_cancel(cancel_id) unless buffer_only
        end
      end

      def to_c(value)
        case value
        when nil then Fiddle::NULL
        when String then value
        when Hash, Array then JSON.generate(value)
        else value
        end
      end

      def decode(buf)
        str = buf.to_s(BUF_SIZE)
        nul = str.index("\0") || str.bytesize
        text = str[0, nul]
        return {} if text.empty?

        JSON.parse(text)
      rescue JSON::ParserError
        { "raw" => text }
      end

      def raise_error(ptr)
        message = ptr.to_s
        @fns["msb_free_string"]&.call(ptr)
        parsed = begin
          JSON.parse(message)
        rescue JSON::ParserError
          nil
        end
        raise Error.new(parsed ? parsed["message"].to_s : message, kind: parsed ? parsed["kind"].to_s : "internal")
      end

      def alloc_cancel = @fns["msb_cancel_alloc"] ? @fns["msb_cancel_alloc"].call : 0

      def free_cancel(id)
        @fns["msb_cancel_unregister"]&.call(id) if id.to_i.positive?
      end

      # Abort has to reach into a blocking VM call, and the ABI's answer is a
      # cancellation token: poll the flag, trigger the token.
      def start_cancel_watcher(id, cancel)
        Thread.new do
          sleep 0.1 until cancel.call
          @fns["msb_cancel_trigger"]&.call(id)
        rescue StandardError
          nil
        end
      end

      # ── sandbox lifecycle ─────────────────────────────────────────────────

      # opts: image, cpus, memory, mounts, env, workdir …  (passed through as
      # the ABI's opts_json, so anything microsandbox accepts works)
      def create(name, opts = {})
        result = call("msb_sandbox_create", name, JSON.generate(opts))
        @handle = result["handle"] || result["sandbox_handle"] || result.dig("sandbox", "handle")
        raise Error, "no handle in create response: #{result.inspect}" unless @handle

        result
      end

      def connect(name)
        result = call("msb_sandbox_connect", name)
        @handle = result["handle"] || result["sandbox_handle"]
        result
      end

      attr_reader :handle

      def exec(command, args: [], cwd: nil, timeout: nil, cancel: nil)
        opts = {}
        opts["args"] = args unless args.empty?
        opts["cwd"] = cwd if cwd
        opts["timeout_secs"] = timeout.to_i if timeout
        out = call("msb_sandbox_exec", @handle, command, JSON.generate(opts), cancel: cancel)
        {
          "stdout" => b64(out["stdout_b64"]) || out["stdout"].to_s,
          "stderr" => b64(out["stderr_b64"]) || out["stderr"].to_s,
          "exitCode" => (out["exit_code"] || out["exitCode"] || 0).to_i
        }
      end

      def read_file(path)
        out = call("msb_fs_read", @handle, path)
        b64(out["data_b64"]) || out["data"].to_s
      end

      def write_file(path, content)
        call("msb_fs_write", @handle, path, Base64.strict_encode64(content))
      end

      def copy_in(host_path, guest_path) = call("msb_fs_copy_from_host", @handle, host_path, guest_path)
      def copy_out(guest_path, host_path) = call("msb_fs_copy_to_host", @handle, guest_path, host_path)

      def stop(timeout_ms: 10_000)
        return unless @handle

        call("msb_sandbox_stop", @handle, timeout_ms)
      ensure
        @handle = nil
      end

      def detach
        return unless @handle

        call("msb_sandbox_detach", @handle)
      ensure
        @handle = nil
      end

      def b64(value)
        return nil unless value.is_a?(String)

        Base64.decode64(value)
      end
    end
  end
end
