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
  prep = Leve::Compaction.prepare(entries, { "keepRecentTokens" => 200 })
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
  prep = Leve::Compaction.prepare(entries, { "keepRecentTokens" => 100 })
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
  prep = Leve::Compaction.prepare(entries, { "keepRecentTokens" => 50 })
  ops = prep["fileOps"]
  eq "read-only files listed", ["/a/read-only.rb"], ops["readFiles"]
  eq "modified files listed", ["/a/changed.rb"], ops["modifiedFiles"]
  eq "a file that was edited is not also 'read'", false, ops["readFiles"].include?("/a/changed.rb")
  eq "and they are rendered for the summary", true,
     Leve::Compaction.format_file_operations(ops).include?("<modified-files>")
end

group "a second compaction updates the previous summary" do
  entries = [{ "type" => "compaction", "id" => "c1", "seq" => 0, "summary" => "OLD SUMMARY",
               "firstKeptEntryId" => "keep", "tokensBefore" => 100,
               "details" => { "readFiles" => ["/old.rb"], "modifiedFiles" => [] } }]
  entries << user_entry("next thing " + ("word " * 100)) << assistant_entry("did it " + ("word " * 100))
  entries << user_entry("and more") << assistant_entry("also did it")
  prep = Leve::Compaction.prepare(entries, { "keepRecentTokens" => 60 })
  eq "previous summary carried in", "OLD SUMMARY", prep["previousSummary"]
  msg = Leve::Compaction.request_message(prep["messagesToSummarize"],
                                            previous_summary: prep["previousSummary"])
  text = msg.dig("content", 0, "text")
  eq "the update prompt is used", true, text.include?("NEW conversation messages to incorporate")
  eq "the old summary is provided", true, text.include?("<previous-summary>")
  eq "history from the old compaction survives", true, prep["fileOps"]["readFiles"].include?("/old.rb")
  eq "nothing to compact right after a compaction", nil,
     Leve::Compaction.prepare([entries.first], {})
end

group "serialization stops the model from continuing the chat" do
  text = Leve::Compaction.serialize([
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
       Leve::Context.messages(h.session.context_entries).first["content"][0]["text"].include?("STRUCTURED SUMMARY")
    h.close
  end
end

done
