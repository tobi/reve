# frozen_string_literal: true

require_relative "helper"
include TestKit

def user_entry(text) = { "type" => "message", "id" => "u#{text.hash.abs}", "seq" => 0,
                         "message" => { "role" => "user", "content" => [{ "type" => "text", "text" => text }] } }

def assistant_entry(text, id = nil)
  { "type" => "message", "id" => id || "a#{text.hash.abs}", "seq" => 0,
    "message" => { "role" => "assistant", "content" => [{ "type" => "text", "text" => text }],
                   "stopReason" => "stop" } }
end

def tool_entries(name, path, id)
  [{ "type" => "message", "id" => "c#{id}", "seq" => 0,
     "message" => { "role" => "assistant", "stopReason" => "toolUse",
                    "content" => [{ "type" => "toolCall", "id" => id, "name" => name,
                                    "arguments" => { "path" => path } }] } },
   { "type" => "message", "id" => "r#{id}", "seq" => 0,
     "message" => { "role" => "toolResult", "toolCallId" => id, "toolName" => name,
                    "content" => [{ "type" => "text", "text" => "result" }] } }]
end

group "cut point: keep the recent suffix, summarize the head" do
  entries = []
  6.times { |i| entries << user_entry("turn #{i} " + ("word " * 40)) << assistant_entry("reply #{i} " + ("word " * 40)) }
  prep = Reve::Compaction.prepare(entries, { "keepRecentTokens" => 200 })
  eq "something to compact", true, !prep.nil?
  kept_index = entries.index { _1["id"] == prep["firstKeptEntryId"] }
  eq "cuts at a user message (a turn boundary)", "user", entries[kept_index].dig("message", "role")
  eq "keeps a suffix, not everything", true, kept_index > 0 && kept_index < entries.size - 1
  eq "summarizes exactly the head", kept_index, prep["messagesToSummarize"].size
  eq "not a split turn", false, prep["splitTurn"]
  eq "tokensBefore measured", true, prep["tokensBefore"] > 500
end

group "split turn: one turn too big to keep whole" do
  entries = [user_entry("small first turn"), assistant_entry("ok")]
  entries << user_entry("the big turn")
  6.times { |i| entries.concat(tool_entries("read", "/f#{i}.rb", "t#{i}")) }
  entries << assistant_entry("done with the big turn " + ("word " * 300), "final")
  prep = Reve::Compaction.prepare(entries, { "keepRecentTokens" => 100 })
  eq "prepared", true, !prep.nil?
  eq "detected a split turn", true, prep["splitTurn"]
  eq "the turn prefix is summarized separately", true, prep["turnPrefixMessages"].size.positive?
  eq "the kept entry is inside the turn", true,
     entries.index { _1["id"] == prep["firstKeptEntryId"] } > entries.index { _1["id"] == "u#{"the big turn".hash.abs}" }
end

group "file operations are extracted exactly, not summarized" do
  entries = [user_entry("do work")]
  entries.concat(tool_entries("read", "/a/read-only.rb", "t1"))
  entries.concat(tool_entries("edit", "/a/changed.rb", "t2"))
  entries.concat(tool_entries("read", "/a/changed.rb", "t3"))
  entries << assistant_entry("done " + ("word " * 200))
  prep = Reve::Compaction.prepare(entries, { "keepRecentTokens" => 50 })
  ops = prep["fileOps"]
  eq "read-only files listed", ["/a/read-only.rb"], ops["readFiles"]
  eq "modified files listed", ["/a/changed.rb"], ops["modifiedFiles"]
  eq "a file that was edited is not also 'read'", false, ops["readFiles"].include?("/a/changed.rb")
  eq "and they are rendered for the summary", true,
     Reve::Compaction.format_file_operations(ops).include?("<modified-files>")
end

group "a second compaction updates the previous summary" do
  entries = [{ "type" => "compaction", "id" => "c1", "seq" => 0, "summary" => "OLD SUMMARY",
               "firstKeptEntryId" => "keep", "tokensBefore" => 100,
               "details" => { "readFiles" => ["/old.rb"], "modifiedFiles" => [] } }]
  entries << user_entry("next thing " + ("word " * 100)) << assistant_entry("did it " + ("word " * 100))
  entries << user_entry("and more") << assistant_entry("also did it")
  prep = Reve::Compaction.prepare(entries, { "keepRecentTokens" => 60 })
  eq "previous summary carried in", "OLD SUMMARY", prep["previousSummary"]
  msg = Reve::Compaction.request_message(prep["messagesToSummarize"],
                                            previous_summary: prep["previousSummary"])
  text = msg.dig("content", 0, "text")
  eq "the update prompt is used", true, text.include?("NEW conversation messages to incorporate")
  eq "the old summary is provided", true, text.include?("<previous-summary>")
  eq "history from the old compaction survives", true, prep["fileOps"]["readFiles"].include?("/old.rb")
  eq "nothing to compact right after a compaction", nil,
     Reve::Compaction.prepare([entries.first], {})
end

group "serialization stops the model from continuing the chat" do
  text = Reve::Compaction.serialize([
                                         { "role" => "user", "content" => [{ "type" => "text", "text" => "fix it" }] },
                                         { "role" => "assistant",
                                           "content" => [{ "type" => "toolCall", "id" => "1", "name" => "edit",
                                                           "arguments" => { "path" => "/x.rb" } }] },
                                         { "role" => "toolResult", "toolCallId" => "1", "toolName" => "edit",
                                           "content" => [{ "type" => "text", "text" => "y" * 5000 }] }
                                       ])
  eq "roles are labelled", true, text.include?("[User]: fix it")
  eq "tool calls are rendered as calls", true, text.include?('[Assistant tool calls]: edit(path="/x.rb")')
  eq "long tool results are truncated", true, text.include?("more characters truncated")
end

Dir.mktmpdir do |dir|
  group "compaction end to end: context is summary + kept suffix" do
    replies = Array.new(4) { |i| assistant_text("reply #{i} " + ("word " * 60)) }
    model = fake_model(dir, replies + [assistant_text("STRUCTURED SUMMARY")])
    h, = test_harness(storage: "memory", model: model, cwd: dir,
                                 compaction: { "keepRecentTokens" => 120 })
    4.times { |i| h.prompt("turn #{i} " + ("word " * 60)) }
    before = h.session.context_entries.size
    r = h.compact
    eq "compacted", true, r["ok"]
    comp = h.session.context_entries.first
    eq "the summary leads the context", "compaction", comp["type"]
    eq "summary text from the model", true, comp["summary"].include?("STRUCTURED SUMMARY")
    eq "context shrank", true, h.session.context_entries.size < before
    eq "the kept suffix follows the summary", comp["firstKeptEntryId"], h.session.context_entries[1]["id"]
    eq "the whole branch is still on disk", true, h.session.path_entries.size > h.session.context_entries.size
    eq "the next request sees the summary", true,
       Reve::Context.messages(h.session.context_entries).first["content"][0]["text"].include?("STRUCTURED SUMMARY")
    h.close
  end

  group "/goal: durable, branch-scoped, in every system prompt, survives compaction" do
    model = fake_model(dir, [assistant_text("one"), assistant_text("two"), assistant_text("SUMMARY")])
    h, = test_harness(storage: "memory", model: model, cwd: dir,
                                 compaction: { "keepRecentTokens" => 8 })
    eq "no goal initially", nil, h.goal
    eq "goal set", true, h.set_goal("ship the parser rewrite")["ok"]
    eq "goal readable", "ship the parser rewrite", h.goal
    eq "goal is a custom entry, not a message", "custom",
       h.session.find_entry("type" => "custom")["type"]
    h.prompt("first")
    sent = File.readlines("#{ENV["REVE_FAKE_SCRIPT"]}.requests").map { JSON.parse(_1) }
    eq "the model sees it in the system prompt", true, sent.last["system"].include?("ship the parser rewrite")
    eq "tagged for the model", true, sent.last["system"].include?("<session_goal>")
    eq "and it is not a conversation message", %w[user assistant],
       entries_of(h.session).select { _1["type"] == "message" }.map { _1.dig("message", "role") }
    h.prompt("second")
    h.compact
    eq "still there after compaction", "ship the parser rewrite", h.goal
    h.prompt("third")
    sent = File.readlines("#{ENV["REVE_FAKE_SCRIPT"]}.requests").map { JSON.parse(_1) }
    eq "and still in the prompt after compaction", true, sent.last["system"].include?("ship the parser rewrite")
    h.close
  end

  group "a goal set mid-run is a deferred write" do
    model = fake_model(dir, [{ "role" => "assistant", "content" => [{ "type" => "text", "text" => "working" }],
                               "stopReason" => "stop", "sleep" => 1.0 }])
    h, = test_harness(storage: "memory", model: model, cwd: dir)
    t = Thread.new { h.prompt("go") }
    sleep 0.3
    h.set_goal("keep it small")
    t.value
    types = entries_of(h.session).map { _1["type"] }
    eq "the goal entry lands after the assistant message", %w[message message custom], types
    eq "recorded as a deferred write", true, records_of(h.session).any? { _1["type"] == "write_deferred" }
    eq "and is readable afterwards", "keep it small", h.goal
    h.close
  end

  group "goals are per lane, because they are branch state" do
    model = fake_model(dir, [assistant_text("a"), assistant_text("b")])
    h, = test_harness(storage: "memory", model: model, cwd: dir)
    h.set_goal("main goal")
    h.create_lane("side", nil)
    eq "the new lane has no goal", nil, h.lane("side").goal
    h.lane("side").set_goal("side goal")
    eq "each lane keeps its own", ["main goal", "side goal"], [h.goal, h.lane("side").goal]
    h.close
  end
end

done
