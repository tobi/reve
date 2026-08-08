# frozen_string_literal: true

require "json"

module Leve
  # JSON-only, Port-based request/reply between Ractors.
  #
  # Every message on the wire is a frozen Array of shareable objects:
  #   [op_string, payload_json, reply_port_or_nil]
  # Nothing else crosses a Ractor boundary, so no deep copies and no
  # IsolationError surprises.
  module IPC
    module_function

    def encode(obj) = JSON.generate(obj)
    def decode(json) = json.nil? ? nil : JSON.parse(json)

    # Reply ports are per-thread: a lane Ractor has a control thread and a
    # worker thread talking to the store concurrently, and they must not steal
    # each other's answers.
    def reply_port
      Thread.current[:durable_reply_port] ||= Ractor::Port.new
    end

    # A target is either a Ractor (default port) or a Ractor::Port.
    def post(target, msg)
      target.is_a?(Ractor::Port) ? target << msg : target.send(msg)
      nil
    end

    # Fire-and-forget.
    def cast(target, op, payload = nil)
      post(target, [op.to_s, payload.nil? ? nil : encode(payload), nil].freeze)
    end

    # Request/reply. Returns the decoded payload, raises RemoteError on a
    # server-side exception.
    def call(target, op, payload = nil, port: reply_port)
      post(target, [op.to_s, payload.nil? ? nil : encode(payload), port].freeze)
      status, body = port.receive
      raise Leve::RemoteError, body if status == "error"

      decode(body)
    end

    # Handlers return this when they take ownership of the reply port: the
    # answer arrives later, from another thread (a lane's worker).
    DEFER = :durable_defer

    # Answer a port that a handler took ownership of.
    def reply(port, payload)
      port << ["ok", payload.nil? ? nil : encode(payload)].freeze if port
      nil
    end

    # Server side: run the handler and answer the reply port if there is one.
    def serve(msg)
      op, payload_json, port = msg
      begin
        result = yield(op, decode(payload_json), port)
        return if result == DEFER

        port << ["ok", result.nil? ? nil : encode(result)].freeze if port
      rescue StandardError, Ractor::Error => e
        detail = "#{e.class}: #{e.message}\n#{(e.backtrace || []).first(8).join("\n")}"
        if port
          port << ["error", detail].freeze
        else
          warn "[durable] unhandled in #{op}: #{detail}"
        end
      end
    end
  end

  class RemoteError < StandardError; end
end
