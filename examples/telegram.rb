# frozen_string_literal: true

# Drop this one file into <agent>/channels/telegram.rb, restart Reve, then run:
#
#   /telegram-connect {"botToken":"123456:BotFather-token"}
#
# The token and pairing state live in .reve/channels.json (mode 0600), never in
# workspace/ and never in the microVM. Subsequent sessions can reconnect with:
#
#   /telegram-connect {}

require "json"
require "net/http"
require "uri"

module Reve
  module Channels
    class Telegram
      MAX_RICH = 32_000
      THINKING = "<tg-thinking>Working…</tg-thinking>"

      # Telegram's streamed rich reply is a small monotonic state machine:
      # thinking -> tools -> answering -> done. It is independent from polling,
      # which makes malformed or late events unable to move a draft backwards.
      class RichMessageStateMachine
        RANK = { thinking: 0, tools: 1, answering: 2, done: 3 }.freeze

        attr_reader :phase, :text, :tools

        def initialize(chat_id, api, clock: -> { Process.clock_gettime(Process::CLOCK_MONOTONIC) })
          @chat_id = chat_id
          @api = api
          @clock = clock
          @phase = :thinking
          @text = +""
          @tools = []
          @draft_id = rand(1..2_147_483_647)
          @last_flush = 0.0
          @last_frame = nil
        end

        def start
          draft(THINKING)
          self
        end

        def accept(event)
          case event["type"]
          when "tool_start"
            transition(:tools)
            @tools << summarize_tool(event["toolName"], event["args"] || {})
            flush
          when "message_update"
            delta = event["event"]
            if delta && delta["type"] == "text_delta"
              transition(:answering)
              @text << delta["text"].to_s
              flush if @clock.call - @last_flush >= 0.75
            end
          end
          self
        end

        def finish
          transition(:done)
          body = frame(final: true)
          chunks(body).each do |chunk|
            @api.call("sendRichMessage", "chat_id" => @chat_id,
                                         "rich_message" => { "markdown" => chunk })
          end
          self
        end

        private

        def transition(next_phase)
          return if RANK.fetch(next_phase) < RANK.fetch(@phase) || @phase == :done

          @phase = next_phase
        end

        def flush
          body = frame
          return if body.empty? || body == @last_frame

          draft(body)
        end

        def draft(body)
          @api.call("sendRichMessageDraft", "chat_id" => @chat_id, "draft_id" => @draft_id,
                                            "rich_message" => { "markdown" => body[0, MAX_RICH] })
          @last_frame = body
          @last_flush = @clock.call
        rescue StandardError
          # Partial Markdown and transient transport errors should not corrupt
          # the state. A later frame or the final persisted message retries.
          nil
        end

        def frame(final: false)
          return THINKING if @phase == :thinking

          parts = []
          parts << "```bash\n#{@tools.join("\n")}\n```" unless @tools.empty?
          parts << @text.strip unless @text.strip.empty?
          body = parts.join("\n\n")
          final ? body : body[0, MAX_RICH]
        end

        def summarize_tool(name, args)
          detail = case name
                   when "bash" then args["command"]
                   when "read", "write", "edit" then args["path"]
                   else args.values.find { _1.is_a?(String) }
                   end
          "#{name}: #{detail.to_s.lines.first.to_s.strip}".strip
        end

        def chunks(text)
          return [] if text.strip.empty?

          text.scan(/.{1,#{MAX_RICH}}/m).map(&:strip).reject(&:empty?)
        end
      end

      def initialize(context)
        @context = context
        @kv = context.kv
        @stop = false
        @connected = false
        @turns = Queue.new
        @context.command("telegram-connect",
                         description: "connect Telegram; accepts {\"botToken\":\"…\"} or {} for stored token",
                         schema: { "type" => "object" }) { connect(_1) }
        @context.command("telegram-disconnect", description: "stop Telegram polling") { disconnect }
        @context.command("telegram-status", description: "show Telegram bridge status") { status }
      end

      def connect(args = {})
        token = args["botToken"].to_s
        token = @kv.get("bot_token").to_s if token.empty?
        return failure("no token; pass {\"botToken\":\"…\"}") if token.empty?

        me = api(token, "getMe", {})
        @token = token
        @kv.set("bot_token", token)
        @kv.set("bot_username", me["username"])
        return status if @connected

        @stop = false
        @connected = true
        @poller = Thread.new { poll_loop }
        @worker = Thread.new { work_loop }
        success("connected @#{me["username"]}; send /start in a private chat to pair")
      rescue StandardError => e
        failure(e.message)
      end

      def disconnect
        @stop = true
        @connected = false
        @poller&.kill
        @turns << :stop
        @worker&.join(1)
        success("Telegram disconnected")
      end

      def close = disconnect

      def status
        state = if !@connected
                  "disconnected"
                elsif @kv.get("allowed_user_id")
                  "connected and paired"
                else
                  "connected; awaiting /start pairing"
                end
        success("Telegram #{state}#{@kv.get("bot_username") ? " @#{@kv.get("bot_username")}" : ""}")
      end

      private

      def poll_loop
        until @stop
          offset = @kv.get("last_update_id", 0).to_i + 1
          updates = call_api("getUpdates", "offset" => offset, "timeout" => 25,
                                           "allowed_updates" => ["message"])
          updates.each do |update|
            @kv.set("last_update_id", update["update_id"])
            receive(update["message"]) if update["message"]
          end
        end
      rescue StandardError => e
        warn "[telegram] polling stopped: #{e.class}: #{e.message}" unless @stop
        @connected = false
      end

      def receive(message)
        return unless message.dig("chat", "type") == "private"

        user_id = message.dig("from", "id")
        chat_id = message.dig("chat", "id")
        allowed = @kv.get("allowed_user_id")
        if allowed.nil? && message["text"].to_s.start_with?("/start")
          @kv.set("allowed_user_id", user_id)
          call_api("sendRichMessage", "chat_id" => chat_id,
                                      "rich_message" => { "markdown" => "Paired with Reve." })
          return
        end
        return unless allowed.to_i == user_id.to_i

        text = message["text"].to_s.strip
        if %w[/stop stop].include?(text.downcase)
          @context.harness.main.abort!("telegram")
          return
        end
        @turns << { "chat_id" => chat_id, "text" => text } unless text.empty?
      end

      def work_loop
        loop do
          watcher = nil
          event_thread = nil
          turn = @turns.pop
          break if turn == :stop

          sleep 0.1 while @context.harness.main.state["operation"] && !@stop
          break if @stop

          machine = RichMessageStateMachine.new(turn["chat_id"], method(:call_api)).start
          watcher = @context.watch("main")
          event_thread = Thread.new do
            watcher.each_event do |event|
              machine.accept(event)
              break if %w[run_end run_suspend].include?(event["type"])
            end
          end
          @context.prompt(turn["text"])
          event_thread.join(1)
          machine.finish
        rescue StandardError => e
          warn "[telegram] turn failed: #{e.class}: #{e.message}"
        ensure
          watcher&.close
          event_thread&.kill
        end
      end

      def call_api(method, body) = api(@token, method, body)

      def api(token, method, body)
        uri = URI("https://api.telegram.org/bot#{token}/#{method}")
        request = Net::HTTP::Post.new(uri)
        request["content-type"] = "application/json"
        request.body = JSON.generate(body)
        response = Net::HTTP.start(uri.host, uri.port, use_ssl: true,
                                  open_timeout: 10, read_timeout: method == "getUpdates" ? 40 : 15) do |http|
          http.request(request)
        end
        payload = JSON.parse(response.body)
        raise payload["description"].to_s unless response.is_a?(Net::HTTPSuccess) && payload["ok"]

        payload["result"]
      end

      def success(message) = { "ok" => true, "message" => message }
      def failure(message) = { "ok" => false, "error" => message }
    end

    register("telegram", Telegram, system_prompt: <<~PROMPT)
      Telegram is an active input/output channel.
      Messages received from it begin with `[channel=telegram]`. Treat that prefix as
      transport metadata, not as text written by the user. Replies are rendered as
      Telegram Rich Markdown: prefer concise paragraphs, lists, fenced code, and normal
      Markdown links. Do not emit `<tg-thinking>` tags; the channel owns draft state.
    PROMPT
  end
end
