# frozen_string_literal: true

require "json"
require "net/http"
require "uri"

module Leve
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
      def stream_json(url:, headers:, body:, acc:, timeout:, abort_check: nil, model: nil, &on_event)
        if (message = configuration_error(model, url))
          return acc.error(message, retryable: false)
        end

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
      rescue URI::Error, ArgumentError => e
        acc.error("Provider endpoint configuration error: url=#{url.inspect}; #{e.class}: #{e.message}",
                  retryable: false)
      rescue StandardError => e
        provider = model && model["provider"] || "unknown"
        model_id = model && model["modelId"] || "unknown"
        acc.error("Provider transport setup error for #{provider}/#{model_id}: " \
                  "url=#{url.inspect}; #{e.class}: #{e.message}", retryable: false)
      end

      def configuration_error(model, url)
        uri = URI.parse(url.to_s)
        valid = uri.is_a?(URI::HTTP) && !uri.host.to_s.empty?
        provider = model && model["provider"] || "unknown"
        model_id = model && model["modelId"] || "unknown"
        source = model && model["baseUrlSource"]
        resolved = model && model["baseUrl"]
        unless valid
          hint = source.to_s.start_with?("$") ? " Set environment variable #{source}." : ""
          return "Provider configuration error for #{provider}/#{model_id}: " \
                 "baseUrl source=#{source.inspect} resolved=#{resolved.inspect}; " \
                 "expected an http:// or https:// URL.#{hint}"
        end
        key_source = model && model["apiKeySource"]
        if key_source.to_s.start_with?("$") && model["apiKey"].to_s.empty?
          return "Provider configuration error for #{provider}/#{model_id}: " \
                 "apiKey #{key_source} is not set in the environment."
        end
        nil
      rescue URI::Error
        "Provider configuration error for #{provider}/#{model_id}: " \
          "baseUrl source=#{source.inspect} resolved=#{resolved.inspect}; expected an HTTP URL."
      end

      # The blocking part, so it can run in a killable thread.
      def pump(http, req, acc, abort_check, &on_event)
        http.request(req) do |res|
          code = res.code.to_i
          unless code == 200
            body = res.read_body.to_s
            message = "HTTP #{code} #{res.message}\nURL: #{req.uri}\n" \
                      "Response body (#{body.bytesize} bytes):\n#{body}"
            return acc.error(message, retryable: RETRYABLE_STATUS.include?(code))
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
