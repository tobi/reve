# frozen_string_literal: true

require_relative "helper"
include TestKit

# Parity: the memory backend is the reference; JSONL must behave identically,
# including across a reopen.
def exercise(store)
  a = store.append_entry({ "type" => "message", "message" => { "role" => "user", "content" => [] } }, "main")
  b = store.append_entry({ "type" => "message", "message" => { "role" => "assistant", "content" => [] } }, "main")
  store.create_lane("t1", a["id"])
  c = store.append_entry({ "type" => "custom", "customType" => "note", "data" => { "x" => 1 } }, "t1")
  store.append_record({ "type" => "operation_started", "lane" => "main", "intent" => { "kind" => "run" } })
  store.set_name("parity")
  store.set_label(b["id"], "checkpoint")
  [a, b, c]
end

group "storage parity: memory vs jsonl" do
  Dir.mktmpdir do |dir|
    mem = Durable::Storage::Memory.new
    path = File.join(dir, "s.jsonl")
    jsonl = Durable::Storage::Jsonl.open(path)
    a_m, b_m, c_m = exercise(mem)
    a_j, b_j, c_j = exercise(jsonl)

    eq "entry count", mem.stats["entries"], jsonl.stats["entries"]
    eq "seq", mem.stats["seq"], jsonl.stats["seq"]
    eq "lane leaf main", mem.lanes.find { _1["lane"] == "main" }["leafId"] == b_m["id"],
       jsonl.lanes.find { _1["lane"] == "main" }["leafId"] == b_j["id"]
    eq "lane leaf t1", true, jsonl.lanes.find { _1["lane"] == "t1" }["leafId"] == c_j["id"]
    eq "branch of t1 is a,c", %w[a c].size,
       jsonl.find_entries_on_branch("start" => c_j["id"], "order" => "oldestFirst").size
    eq "name fact", "parity", jsonl.name
    eq "label fact", "checkpoint", jsonl.label(b_j["id"])
    eq "record count", mem.find_records.size, jsonl.find_records.size
    eq "parent chain", a_j["id"], b_j["parentId"]
    eq "custom entry chains to a (branch point)", a_j["id"], c_j["parentId"]

    jsonl.close
    re = Durable::Storage::Jsonl.open(path)
    eq "reopen: entries", jsonl.stats["entries"], re.stats["entries"]
    eq "reopen: seq", jsonl.stats["seq"], re.stats["seq"]
    eq "reopen: t1 leaf", c_j["id"], re.lanes.find { _1["lane"] == "t1" }["leafId"]
    eq "reopen: name", "parity", re.name
    eq "reopen: label", "checkpoint", re.label(b_j["id"])
    eq "reopen: records", jsonl.find_records.size, re.find_records.size
    re.close
  end
end

group "torn tail is truncated, valid prefix survives" do
  Dir.mktmpdir do |dir|
    path = File.join(dir, "torn.jsonl")
    s = Durable::Storage::Jsonl.open(path)
    e = s.append_entry({ "type" => "message", "message" => { "role" => "user", "content" => [] } }, "main")
    s.close
    File.open(path, "a") { _1.write('{"kind":"entry","id":"broken') } # died mid-write
    re = Durable::Storage::Jsonl.open(path)
    eq "torn line dropped", 1, re.stats["entries"]
    eq "leaf intact", e["id"], re.lanes.find { _1["lane"] == "main" }["leafId"]
    n = re.append_entry({ "type" => "message", "message" => { "role" => "user", "content" => [] } }, "main")
    eq "appends resume after truncation", e["id"], n["parentId"]
    re.close
    eq "file is valid json throughout", true,
       File.readlines(path).all? { |l| JSON.parse(l) rescue false }
  end
end

group "malformed line in the middle is corruption" do
  Dir.mktmpdir do |dir|
    path = File.join(dir, "bad.jsonl")
    s = Durable::Storage::Jsonl.open(path)
    s.append_entry({ "type" => "message", "message" => { "role" => "user", "content" => [] } }, "main")
    s.close
    body = File.read(path)
    File.write(path, body.lines.insert(1, "not json\n").join)
    raised = begin
      Durable::Storage::Jsonl.open(path)
      false
    rescue Durable::Storage::Corrupt
      true
    end
    eq "open rejects", true, raised
  end
end

group "records never affect the tree" do
  mem = Durable::Storage::Memory.new
  exercise(mem)
  tree = mem.find_entries("order" => "oldestFirst")
  eq "every entry has a parent chain to root", true,
     tree.all? { |e| e["parentId"].nil? || tree.any? { _1["id"] == e["parentId"] } }
  eq "no record leaked into the tree", true, tree.none? { _1["type"].start_with?("operation_") }
end

group "single writer: the store Ractor is the only mutator" do
  st = Durable::Store.spawn(kind: "memory")
  session = Durable::Session.new(st)
  session.append_message({ "role" => "user", "content" => [{ "type" => "text", "text" => "hi" }] })
  eq "append via ractor", 1, session.stats["entries"]
  from_other_ractor = Ractor.new(st) do |s|
    sess = Durable::Session.new(s)
    sess.append_message({ "role" => "user", "content" => [] })
    sess.stats["entries"]
  end.value
  eq "another ractor writes through the same single writer", 2, from_other_ractor
  eq "seq is shared and monotonic", true, session.find_entries.map { _1["seq"] }.then { _1 == _1.sort.reverse }
  session.close
end

done
