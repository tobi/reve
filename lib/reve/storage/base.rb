# frozen_string_literal: true

require_relative "../ids"

module Reve
  module Storage
    class Corrupt < StandardError; end

    # In-memory core of every backend (harness-v2 §13). Owns the four parts of
    # a session — tree, lanes, lane operation logs, global facts — and the one
    # monotonic sequence shared by all of them.
    #
    # Instances live inside the store Ractor and nowhere else.
    class Base
      FORMAT_VERSION = 4

      attr_reader :metadata

      def initialize(metadata: {})
        @seq = 0
        @entries = {}          # id => entry
        @order = []            # entry ids in seq order
        @records = []          # append-only
        @lanes = { "main" => nil }
        @lane_moves = []
        @facts = []            # {"seq","fact",...}
        @log = []              # every mutation, in seq order (kind-tagged lines)
        @metadata = {
          "version" => FORMAT_VERSION,
          "id" => metadata["id"] || Ids.session,
          "createdAt" => metadata["createdAt"] || Ids.now_ms,
          "cwd" => metadata["cwd"] || Dir.pwd,
          "parentSessionId" => metadata["parentSessionId"]
        }
      end

      # ── writes ────────────────────────────────────────────────────────────

      # Storage assigns parentId (the lane's current leaf), seq and timestamp.
      # The entry becomes the lane's new leaf in the same operation.
      def append_entry(entry, lane)
        raise Corrupt, "unknown lane #{lane}" unless @lanes.key?(lane)

        e = entry.dup
        e["id"] ||= Ids.entry
        raise Corrupt, "duplicate id #{e["id"]}" if @entries.key?(e["id"])

        e["parentId"] = @lanes[lane]
        e["seq"] = (@seq += 1)
        e["timestamp"] ||= Ids.now_ms
        e.freeze
        @entries[e["id"]] = e
        @order << e["id"]
        @lanes[lane] = e["id"]
        persist(e.merge("kind" => "entry", "lane" => lane))
        e
      end

      # options[:move_lane] = {"lane" =>, "to" =>} makes the leaf move and the
      # record one atomic write (navigation, §6).
      def append_record(record, move_lane: nil)
        r = record.dup
        r["id"] ||= Ids.record
        raise Corrupt, "duplicate id #{r["id"]}" if @records.any? { _1["id"] == r["id"] }

        r["lane"] ||= "main"
        r["seq"] = (@seq += 1)
        r["timestamp"] ||= Ids.now_ms
        r.freeze
        @records << r
        line = r.merge("kind" => "record")
        if move_lane
          lane = move_lane["lane"] || move_lane[:lane]
          to = move_lane.key?("to") ? move_lane["to"] : move_lane[:to]
          raise Corrupt, "unknown lane #{lane}" unless @lanes.key?(lane)

          @lanes[lane] = to
          @lane_moves << { "seq" => r["seq"], "lane" => lane, "leafId" => to }
          line = line.merge("moveLane" => { "lane" => lane, "leafId" => to })
        end
        persist(line)
        r
      end

      def create_entry_id = Ids.entry

      def lanes
        @lanes.map { |lane, leaf| { "lane" => lane, "leafId" => leaf } }
      end

      def create_lane(lane, at)
        raise Corrupt, "lane exists: #{lane}" if @lanes.key?(lane)
        raise Corrupt, "unknown entry #{at}" if at && !@entries.key?(at)

        @lanes[lane] = at
        @seq += 1
        @lane_moves << { "seq" => @seq, "lane" => lane, "leafId" => at }
        persist({ "kind" => "lane", "lane" => lane, "leafId" => at })
        nil
      end

      def delete_lane(lane)
        raise Corrupt, "main cannot be deleted" if lane == "main"
        raise Corrupt, "unknown lane #{lane}" unless @lanes.key?(lane)

        @lanes.delete(lane)
        @seq += 1
        persist({ "kind" => "lane", "lane" => lane, "deleted" => true })
        nil
      end

      def move_lane(lane, to)
        raise Corrupt, "unknown lane #{lane}" unless @lanes.key?(lane)
        raise Corrupt, "unknown entry #{to}" if to && !@entries.key?(to)

        @lanes[lane] = to
        @seq += 1
        @lane_moves << { "seq" => @seq, "lane" => lane, "leafId" => to }
        persist({ "kind" => "lane", "lane" => lane, "leafId" => to })
        nil
      end

      # ── global facts: append-only history, latest by seq wins ──────────────

      def set_name(name)
        @seq += 1
        fact = { "seq" => @seq, "fact" => "name", "name" => name }
        @facts << fact
        persist(fact.merge("kind" => "fact"))
        nil
      end

      def name
        @facts.reverse.find { _1["fact"] == "name" }&.dig("name")
      end

      def set_label(target_id, label)
        @seq += 1
        fact = { "seq" => @seq, "fact" => "label", "targetId" => target_id, "label" => label }
        @facts << fact
        persist(fact.merge("kind" => "fact"))
        nil
      end

      def label(target_id)
        @facts.reverse.find { _1["fact"] == "label" && _1["targetId"] == target_id }&.dig("label")
      end

      def labels
        @facts.each_with_object({}) do |f, acc|
          next unless f["fact"] == "label"

          f["label"].nil? ? acc.delete(f["targetId"]) : acc[f["targetId"]] = f["label"]
        end
      end

      # ── reads ─────────────────────────────────────────────────────────────

      def entry(id) = @entries[id]

      def find_entries(query = {})
        list = @order.map { @entries[_1] }
        select_entries(list, query)
      end

      # Branch scan: the path from start toward root, then order, stop, filter.
      def find_entries_on_branch(query = {})
        start = query["start"] || query[:start]
        return [] unless start

        path = []
        cur = start
        while cur
          e = @entries[cur] or break
          path << e
          break if stop_hit?(e, query) && path.size.positive? && stop_after_first?(query)

          cur = e["parentId"]
        end
        # path is newest-first from start
        list = path
        order = query["order"] || query[:order] || "newestFirst"
        list = list.reverse if order == "oldestFirst"
        select_entries(list, query.merge("order" => "asis"))
      end

      def find_records(query = {})
        q = stringify(query)
        list = @records
        list = list.select { _1["lane"] == q["lane"] } if q["lane"]
        list = list.select { _1["type"] == q["type"] } if q["type"]
        list = list.select { _1["runId"] == q["runId"] } if q["runId"]
        list = list.select { _1["seq"] > q["afterSeq"] } if q["afterSeq"]
        list = list.reverse if q["order"] == "newestFirst"
        list = list.first(q["limit"]) if q["limit"]
        list
      end

      def log(after_seq: nil, limit: nil)
        list = @log
        list = list.select { _1["seq"].to_i > after_seq } if after_seq
        list = list.first(limit) if limit
        list
      end

      def stats
        {
          "entries" => @entries.size,
          "records" => @records.size,
          "lanes" => @lanes.size,
          "seq" => @seq,
          "messages" => @entries.each_value.count { _1["type"] == "message" }
        }
      end

      # Copy primitive (§17). scope "branch" keeps one root path.
      def fork_lines(scope: "branch", entry_id: nil, lane: "main")
        entries =
          if scope == "tree"
            @order.map { @entries[_1] }
          else
            start = entry_id || @lanes[lane]
            find_entries_on_branch("start" => start, "order" => "oldestFirst")
          end
        kept = entries.map { _1["id"] }.to_set
        lines = entries.map { |e| e.merge("kind" => "entry", "lane" => "main") }
        lines << { "kind" => "fact", "fact" => "name", "name" => name } if name
        labels.each do |target, lbl|
          lines << { "kind" => "fact", "fact" => "label", "targetId" => target, "label" => lbl } if kept.include?(target)
        end
        lines
      end

      private

      def stop_after_first?(_query) = true

      def stop_hit?(entry, query)
        q = stringify(query)
        return true if q["stopAtId"] && entry["id"] == q["stopAtId"]
        return true if q["stopAtType"] && entry["type"] == q["stopAtType"]

        false
      end

      def select_entries(list, query)
        q = stringify(query)
        order = q["order"] || "newestFirst"
        list = list.reverse if order == "newestFirst"
        list = list.select { _1["type"] == q["type"] } if q["type"]
        list = list.select { _1["customType"] == q["customType"] } if q["customType"]
        if (cursor = q["cursor"])
          list = order == "newestFirst" ? list.select { _1["seq"] < cursor } : list.select { _1["seq"] > cursor }
        end
        list = list.first(q["limit"]) if q["limit"]
        list
      end

      def stringify(h)
        return {} if h.nil?

        h.each_with_object({}) { |(k, v), acc| acc[k.to_s] = v }
      end

      # Backends override to make the mutation durable. The in-memory log is
      # the "full chronological view" of §12 either way.
      def persist(line)
        @log << line
        nil
      end

      # Replay a decoded line during open (used by JSONL).
      def replay(line)
        case line["kind"]
        when "entry"
          e = line.reject { |k, _| %w[kind lane].include?(k) }.freeze
          @entries[e["id"]] = e
          @order << e["id"]
          @lanes[line["lane"] || "main"] = e["id"]
          @seq = [@seq, e["seq"].to_i].max
        when "record"
          r = line.reject { |k, _| %w[kind moveLane].include?(k) }.freeze
          @records << r
          @seq = [@seq, r["seq"].to_i].max
          if (mv = line["moveLane"])
            @lanes[mv["lane"]] = mv["leafId"]
            @lane_moves << { "seq" => r["seq"], "lane" => mv["lane"], "leafId" => mv["leafId"] }
          end
        when "lane"
          if line["deleted"]
            @lanes.delete(line["lane"])
          else
            @lanes[line["lane"]] = line["leafId"]
            @lane_moves << { "seq" => @seq, "lane" => line["lane"], "leafId" => line["leafId"] }
          end
        when "fact"
          @facts << line.reject { |k, _| k == "kind" }
          @seq = [@seq, line["seq"].to_i].max if line["seq"]
        else
          raise Corrupt, "unknown line kind #{line["kind"].inspect}"
        end
        @log << line
        nil
      end
    end
  end
end
