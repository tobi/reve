# frozen_string_literal: true

require_relative "ipc"
require_relative "storage/memory"
require_relative "storage/jsonl"

module Durable
  # The single writer. The storage instance lives inside this Ractor and is
  # unreachable from anywhere else, so harness-v2's "one harness writes a
  # session at a time" is a property of the runtime, not a convention.
  module Store
    OPS = %w[
      metadata stats lanes create_lane delete_lane move_lane
      append_entry append_record create_entry_id
      get_entry find_entries find_entries_on_branch find_records get_log
      get_name set_name get_label set_label fork_lines close
    ].freeze

    module_function

    def spawn(kind: "memory", path: nil, metadata: {})
      Ractor.new(kind.to_s, path, IPC.encode(metadata), name: "store") do |k, p, meta_json|
        store =
          if k == "jsonl"
            Durable::Storage::Jsonl.open(p, metadata: JSON.parse(meta_json))
          else
            Durable::Storage::Memory.open(nil, metadata: JSON.parse(meta_json))
          end
        loop do
          msg = Ractor.receive
          stop = false
          Durable::IPC.serve(msg) do |op, arg|
            case op
            when "metadata" then store.metadata
            when "stats" then store.stats
            when "lanes" then store.lanes
            when "create_lane" then store.create_lane(arg["lane"], arg["at"])
            when "delete_lane" then store.delete_lane(arg["lane"])
            when "move_lane" then store.move_lane(arg["lane"], arg["to"])
            when "append_entry" then store.append_entry(arg["entry"], arg["lane"])
            when "append_record" then store.append_record(arg["record"], move_lane: arg["moveLane"])
            when "create_entry_id" then store.create_entry_id
            when "get_entry" then store.entry(arg["id"])
            when "find_entries" then store.find_entries(arg || {})
            when "find_entries_on_branch" then store.find_entries_on_branch(arg || {})
            when "find_records" then store.find_records(arg || {})
            when "get_log" then store.log(after_seq: arg && arg["afterSeq"], limit: arg && arg["limit"])
            when "get_name" then store.name
            when "set_name" then store.set_name(arg["name"])
            when "get_label" then store.label(arg["targetId"])
            when "set_label" then store.set_label(arg["targetId"], arg["label"])
            when "fork_lines"
              store.fork_lines(scope: arg["scope"] || "branch", entry_id: arg["entryId"], lane: arg["lane"] || "main")
            when "close"
              store.close
              stop = true
              true
            else raise ArgumentError, "unknown store op #{op}"
            end
          end
          break if stop
        end
      end
    end
  end

  # The copy primitive of §17: entries only, no records, no queues — a fork
  # starts idle, and every lane question answers "no open operation".
  # scope "branch" keeps one root path and only lane "main".
  module Fork
    module_function

    def to_file(session, path, scope: "branch", entry_id: nil, lane: "main")
      lines = IPC.call(session.store, "fork_lines",
                       { "scope" => scope, "entryId" => entry_id, "lane" => lane })
      meta = session.metadata
      header = { "kind" => "header", "version" => Storage::Base::FORMAT_VERSION, "id" => Ids.session,
                 "createdAt" => Ids.now_ms, "cwd" => meta["cwd"], "parentSessionId" => meta["id"] }
      FileUtils.mkdir_p(File.dirname(path))
      File.open(path, "w") do |io|
        io.write("#{JSON.generate(header)}\n")
        lines.each { |l| io.write("#{JSON.generate(l)}\n") }
      end
      path
    end
  end

  # SessionTree / Session (§12) over the store Ractor. Cheap, stateless,
  # constructible in any Ractor: it holds only the Ractor handle and a lane
  # binding.
  class Session
    attr_reader :lane, :store

    def initialize(store, lane: "main")
      @store = store
      @lane = lane
    end

    def view(lane) = self.class.new(@store, lane: lane)

    # ── tree reads ────────────────────────────────────────────────────────
    def metadata = call("metadata")
    def stats = call("stats")
    def leaf_id = lanes.find { _1["lane"] == @lane }&.dig("leafId")
    def entry(id) = call("get_entry", { "id" => id })
    def find_entries(query = {}) = call("find_entries", query)
    def find_entry(query = {}) = find_entries(query.merge("limit" => 1)).first

    def find_entries_on_branch(query = {})
      q = query.transform_keys(&:to_s)
      q["start"] ||= leaf_id
      return [] unless q["start"]

      call("find_entries_on_branch", q)
    end

    def find_entry_on_branch(query = {}) = find_entries_on_branch(query.merge("limit" => 1)).first

    # The whole branch, oldest first. What compaction summarizes.
    def path_entries(start: nil)
      s = start || leaf_id
      return [] unless s

      find_entries_on_branch("start" => s, "order" => "newestFirst").reverse
    end

    # The context window, oldest first: [compaction summary] + the kept suffix
    # it names + everything appended after it. Without a compaction entry it is
    # simply the branch.
    def context_entries(start: nil)
      leaf = start || leaf_id
      return [] unless leaf

      comp = find_entry_on_branch("start" => leaf, "type" => "compaction", "order" => "newestFirst")
      unless comp
        return find_entries_on_branch("start" => leaf, "order" => "newestFirst").reverse
      end

      kept_from = comp["firstKeptEntryId"]
      unless kept_from
        return find_entries_on_branch("start" => leaf, "stopAtType" => "compaction",
                                      "order" => "newestFirst").reverse
      end

      path = find_entries_on_branch("start" => leaf, "stopAtId" => kept_from, "order" => "newestFirst").reverse
      idx = path.index { _1["id"] == comp["id"] }
      return path unless idx

      [path[idx]] + path[0...idx] + path[(idx + 1)..].to_a
    end

    # ── tree writes ───────────────────────────────────────────────────────
    def append_entry(entry) = call("append_entry", { "entry" => entry, "lane" => @lane })
    def append_message(message) = append_entry({ "type" => "message", "message" => message })

    def append_custom_entry(custom_type, data = nil)
      append_entry({ "type" => "custom", "customType" => custom_type, "data" => data })
    end

    def create_entry_id = call("create_entry_id")

    def append_if_missing(provisioned)
      return entry(provisioned["id"]) if provisioned["id"] && entry(provisioned["id"])

      append_entry(provisioned)
    end

    # ── lanes ─────────────────────────────────────────────────────────────
    def lanes = call("lanes")
    def create_lane(lane, at) = call("create_lane", { "lane" => lane, "at" => at })
    def delete_lane(lane) = call("delete_lane", { "lane" => lane })
    def move_lane(lane, to) = call("move_lane", { "lane" => lane, "to" => to })

    # ── records ───────────────────────────────────────────────────────────
    def append_record(record, move_lane: nil)
      call("append_record", { "record" => record.merge("lane" => record["lane"] || @lane), "moveLane" => move_lane })
    end

    def find_records(query = {}) = call("find_records", query)
    def log(after_seq: nil, limit: nil) = call("get_log", { "afterSeq" => after_seq, "limit" => limit })

    # ── facts ─────────────────────────────────────────────────────────────
    def name = call("get_name")
    def set_name(value)
      call("set_name", { "name" => value })
    end
    def label(target_id) = call("get_label", { "targetId" => target_id })
    def set_label(target_id, label) = call("set_label", { "targetId" => target_id, "label" => label })

    def close = call("close")

    private

    def call(op, payload = nil) = IPC.call(@store, op, payload)
  end
end
