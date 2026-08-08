# frozen_string_literal: true

require "json"
require "fileutils"

module Leve
  module Provider
    # Scripted provider for tests. The script is a JSON file — never a closure —
    # so it crosses Ractor boundaries as configuration, and a crashed process
    # picks the script up where it left off (the cursor is a file too).
    #
    # Script: { "responses": [ <assistant message> | {"crash": "..."} , ... ] }
    module Fake
      module_function

      def script_path = ENV["LEVE_FAKE_SCRIPT"]

      def stream(model:, messages:, system: nil, tools: [], thinking: nil, max_tokens: nil,
                 abort_check: nil, timeout: nil, &on_event)
        script = JSON.parse(File.read(script_path))
        cursor_file = "#{script_path}.cursor"
        n = File.exist?(cursor_file) ? File.read(cursor_file).to_i : 0
        File.write(cursor_file, (n + 1).to_s)
        File.write("#{script_path}.requests", "#{JSON.generate({ n: n, messages: messages, system: system })}\n", mode: "a")
        spec = script["responses"][n] || { "role" => "assistant", "content" => [{ "type" => "text", "text" => "done" }],
                                           "stopReason" => "stop" }
        if spec["crash"]
          $stderr.puts "[fake] crashing: #{spec["crash"]}"
          exit!(9)
        end
        if spec["sleep"]
          slept = 0.0
          while slept < spec["sleep"].to_f
            return aborted(model) if abort_check&.call

            sleep 0.05
            slept += 0.05
          end
        end
        msg = spec.reject { |k, _| %w[crash sleep].include?(k) }
        (msg["content"] || []).each do |c|
          on_event&.call({ "type" => "text_delta", "text" => c["text"] }) if c["type"] == "text"
        end
        base(model).merge(msg)
      end

      def fetch_deferred(model:, handle:, wait: 0)
        script = JSON.parse(File.read(script_path))
        key = "deferred:#{handle["id"]}"
        spec = script[key] or return base(model).merge("stopReason" => "error",
                                                       "errorMessage" => "unknown handle", "retryable" => false)
        pending_file = "#{script_path}.#{handle["id"]}.polls"
        polls = File.exist?(pending_file) ? File.read(pending_file).to_i : 0
        File.write(pending_file, (polls + 1).to_s)
        if polls < (spec["pendingPolls"] || 0)
          return base(model).merge("stopReason" => "deferred", "deferred" => handle)
        end

        base(model).merge(spec["result"])
      end

      def cancel_deferred(model:, handle:) = nil

      def base(model)
        { "role" => "assistant", "content" => [], "usage" => { "input" => 10, "output" => 5 },
          "provider" => model["provider"], "model" => model["modelId"], "timestamp" => Leve::Ids.now_ms }
      end

      def aborted(model) = base(model).merge("stopReason" => "aborted")
    end
  end
end
