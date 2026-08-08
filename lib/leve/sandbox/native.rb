# frozen_string_literal: true

module Leve
  module Sandbox
    # Leve's only sandbox transport: a native extension that binds the
    # `microsandbox` Rust crate directly.
    #
    # The extension itself defines `Leve::Sandbox::Native` and everything under
    # it. This file exists to load it, and to fail with an instruction rather
    # than a bare `LoadError` when it has not been compiled — Leve refuses to
    # run without a microVM, so a missing extension is a hard stop, never a
    # reason to fall back to the host shell.
    module NativeLoader
      CANDIDATES = %w[
        leve/leve_sandbox
        ../../../ext/leve_sandbox/leve_sandbox
      ].freeze

      module_function

      def load!
        return true if defined?(::Leve::Sandbox::Native)

        errors = []
        CANDIDATES.each do |candidate|
          path = candidate.start_with?("..") ? File.expand_path(candidate, __dir__) : candidate
          begin
            require path
            return true
          rescue LoadError => e
            errors << e.message
          end
        end
        raise Unavailable, <<~MSG.strip
          the leve_sandbox native extension is not built.

            rake compile

          Leve executes every model-authored command inside a microVM and has no
          host-shell fallback, so it cannot start without it. Building needs a
          Rust toolchain (>= 1.91); running needs Linux with KVM or macOS on
          Apple Silicon.

          tried: #{errors.join(" | ")}
        MSG
      end
    end
  end
end
