# frozen_string_literal: true

require_relative "ipc"
require_relative "store"

module Durable
  # The observer hub (§9, §10). One Ractor, therefore single-threaded, therefore
  # "capture the snapshot and register the watcher" is one atomic operation and
  # a watcher cannot miss an event that happened after its snapshot.
  #
  # The watcher's own reply port *is* its subscription: the snapshot is the first
  # message on it, every later message is an event, in order. The Port is the
  # buffer, so there is no registration race and no sequence numbers.
  module Observer
    module_function

    def spawn(store:)
      Ractor.new(store, name: "observer") do |st|
        session = Durable::Session.new(st)
        watchers = []       # [{port:, lane: nil|String}]
        mirrors = {}        # lane => mirror hash
        closed = false

        mirror_for = lambda do |lane|
          mirrors[lane] ||= { "lane" => lane, "operation" => nil, "streamingMessage" => nil,
                              "runningTools" => {}, "queues" => { "steer" => [], "followUp" => [], "nextRun" => [] } }
        end

        apply = lambda do |ev|
          m = mirror_for.call(ev["lane"] || "main")
          case ev["type"]
          when "run_start", "run_resume", "compaction_start", "navigation_start"
            kind = { "run" => "run", "compaction" => "compaction", "navigation" => "navigation" }[ev["type"].split("_").first]
            m["operation"] = { "id" => ev["runId"], "kind" => kind, "status" => "running",
                               "startedAt" => Durable::Ids.now_ms }
          when "run_abort" then m["operation"]&.[]=("status", "aborting")
          when "run_suspend"
            m["operation"]&.[]=("status", "suspended")
            m["operation"]&.[]=("deferred", ev["deferred"])
          when "run_end", "compaction_end", "navigation_end"
            m["operation"] = nil
            m["streamingMessage"] = nil
            m["runningTools"] = {}
          when "message_start" then m["streamingMessage"] = { "role" => "assistant", "content" => [] }
          when "message_update"
            d = ev["event"]
            if d && d["type"] == "text_delta"
              sm = m["streamingMessage"] ||= { "role" => "assistant", "content" => [] }
              last = sm["content"].last
              if last && last["type"] == "text"
                last["text"] = last["text"] + d["text"].to_s
              else
                sm["content"] << { "type" => "text", "text" => d["text"].to_s.dup }
              end
            end
          when "message_end" then m["streamingMessage"] = nil
          when "tool_start"
            m["runningTools"][ev["toolCallId"]] = { "toolCallId" => ev["toolCallId"], "toolName" => ev["toolName"],
                                                    "args" => ev["args"] }
          when "tool_end" then m["runningTools"].delete(ev["toolCallId"])
          when "queue_update"
            m["queues"] = { "steer" => ev["steer"] || [], "followUp" => ev["followUp"] || [],
                            "nextRun" => ev["nextRun"] || [] }
          when "retry_scheduled"
            m["operation"]&.[]=("retry", { "attempt" => ev["attempt"], "maxAttempts" => ev["maxAttempts"],
                                           "delayMs" => ev["delayMs"] })
          end
        end

        snapshot = lambda do |lane|
          m = mirror_for.call(lane)
          leaf = session.lanes.find { _1["lane"] == lane }&.dig("leafId")
          { "lane" => lane, "leafId" => leaf,
            "transcript" => leaf ? session.view(lane).context_entries(start: leaf) : [],
            "operation" => m["operation"], "queues" => m["queues"],
            "streamingMessage" => m["streamingMessage"], "runningTools" => m["runningTools"].values,
            "faulted" => false }
        end

        until closed
          msg = Ractor.receive
          Durable::IPC.serve(msg) do |op, arg, port|
            case op
            when "emit"
              apply.call(arg)
              json = Durable::IPC.encode(arg)
              dead = []
              watchers.each do |w|
                next if w[:lane] && w[:lane] != arg["lane"]

                begin
                  w[:port] << ["event", json].freeze
                rescue Ractor::ClosedError, Ractor::Error
                  dead << w
                end
              end
              watchers -= dead
              nil
            when "watch"
              watchers << { port: port, lane: arg["lane"] }
              # The snapshot is the first message on the subscription port.
              payload = arg["lane"] ? snapshot.call(arg["lane"]) : Durable::Observer.session_snapshot(session, mirrors)
              Durable::IPC.reply(port, payload)
              Durable::IPC::DEFER
            when "unwatch"
              watchers.reject! { _1[:port] == port }
              true
            when "lane_state" then mirrors[arg["lane"]]
            when "close"
              closed = true
              true
            else raise ArgumentError, "unknown observer op #{op}"
            end
          end
        end
      end
    end

    # Session-wide observer: lane inventory, no transcripts.
    def session_snapshot(session, mirrors)
      { "lanes" => session.lanes.map do |l|
        m = mirrors[l["lane"]]
        { "name" => l["lane"], "leafId" => l["leafId"], "operation" => m && m["operation"] }
      end, "faulted" => false }
    end
  end

  # Client-side subscription: a Port whose first message was the snapshot.
  class Watch
    attr_reader :snapshot, :port

    def initialize(hub, lane: nil)
      @hub = hub
      @port = Ractor::Port.new
      status, body = nil
      IPC.post(hub, ["watch", IPC.encode({ "lane" => lane }), @port].freeze)
      status, body = @port.receive
      raise RemoteError, body if status == "error"

      @snapshot = IPC.decode(body)
    end

    # Blocking iteration over live events, in order, exactly once each.
    def each_event
      loop do
        kind, json = @port.receive
        next unless kind == "event"

        yield IPC.decode(json)
      end
    end

    def next_event
      kind, json = @port.receive
      kind == "event" ? IPC.decode(json) : nil
    end

    def close
      IPC.post(@hub, ["unwatch", IPC.encode({}), @port].freeze)
    end
  end
end
