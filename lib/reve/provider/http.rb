# frozen_string_literal: true

require "json"
require "net/http"
require "uri"

module Reve
  module Provider
    # The transport every protocol shares: POST a JSON body, read an SSE
    # stream, hand each event to an accumulator, and turn every failure mode
    # into an in-band assistant message.
    #
    # A provider module supplies protocol only — the request body, the
    # accumulator, and the URL path. Nothing here knows a protocol.
    module HTTP
      # Statuses worth another attempt. 529 is anthropic's "overloaded".
      RETRYABLE_STATUS = [408, 409, 425, 429, 500, 502, 503, 504, 529].freeze
      TRANSIENT = [Net::OpenTimeout, Net::ReadTimeout, Errno::ECONNRESET, Errno::ECONNREFUSED,
                   Errno::EHOSTUNREACH, Errno::EPIPE, EOFError, SocketError, IOError].freeze

      module_function

      # One streaming request. Returns the accumulator's final message; never
      # raises. `abort_check` is polled both between chunks and — via
      # run_abortable — while the socket is silent, which is where a thinking
      # model spends most of its time.
      def stream_json(url:, headers:, body:, acc:, timeout:, abort_check: nil, &on_event)
        uri = URI(url)
        http = Net::HTTP.new(uri.host, uri.port)
        http.use_ssl = uri.scheme == "https"
        http.read_timeout = timeout
        http.open_timeout = 30

        req = Net::HTTP::Post.new(uri)
        req["content-type"] = "application/json"
        req["accept"] = "text/event-stream"
        headers.each { |k, v| req[k] = v.to_s unless v.nil? || v.to_s.empty? }
        req.body = JSON.generate(body)

        Provider.run_abortable(abort_check, acc) do
          pump(http, req, acc, abort_check, &on_event)
        end
      end

      # The blocking part, so it can run in a killable thread.
      def pump(http, req, acc, abort_check, &on_event)
        http.request(req) do |res|
          code = res.code.to_i
          unless code == 200
            return acc.error("HTTP #{code}: #{res.read_body.to_s[0, 2000]}",
                             retryable: RETRYABLE_STATUS.include?(code))
          end

          buffer = +""
          res.read_body do |chunk|
            return acc.aborted if abort_check&.call

            buffer << chunk
            while (idx = buffer.index("\n\n"))
              frame = buffer.slice!(0, idx + 2)
              event = parse_event(frame) or next

              acc.handle(event, &on_event)
            end
          end
        end
        acc.finish
      rescue *TRANSIENT => e
        acc.error("#{e.class}: #{e.message}", retryable: true)
      rescue StandardError => e
        acc.error("#{e.class}: #{e.message}", retryable: false)
      end

      # One SSE frame → the parsed JSON of its data lines, or nil for comments,
      # keep-alives, the [DONE] sentinel and anything unparseable.
      def parse_event(frame)
        data = frame.lines.filter_map { |l| l.start_with?("data:") ? l[5..].strip : nil }.join
        return nil if data.empty? || data == "[DONE]"

        JSON.parse(data)
      rescue JSON::ParserError
        nil
      end

      # `apiKey: EMPTY` (vLLM's convention) resolves to "" and means no auth.
      def bearer(model)
        key = model["apiKey"].to_s
        key.empty? ? nil : "Bearer #{key}"
      end

      def endpoint(model, path) = "#{model["baseUrl"].to_s.chomp("/")}/#{path}"
    end
  end
end
