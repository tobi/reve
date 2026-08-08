# frozen_string_literal: true

require_relative "helper"
include TestKit

Dir.mktmpdir do |dir|
  group "follow-ups continue the same run; before_run_end can add one" do
    model = fake_model(dir, [assistant_text("first answer"), assistant_text("second answer"),
                             assistant_text("third answer")])
    h, = test_harness(storage: "memory", model: model, cwd: dir)
    once = [true]
    h.on_hook("before_run_end") do |_e|
      if once[0]
        once[0] = false
        { "followUp" => "and now the follow-up" }
      end
    end
    r = h.prompt("go")
    eq "one run, two assistant messages", true, r["ok"]
    roles = entries_of(h.session).map { _1.dig("message", "role") }
    eq "follow-up continued the same run", %w[user assistant user assistant], roles
    ops = records_of(h.session).count { _1["type"] == "operation_started" }
    eq "still a single operation", 1, ops
    h.close
  end

  group "next-run messages survive abort and seed the next run" do
    model = fake_model(dir, [{ "role" => "assistant", "content" => [{ "type" => "text", "text" => "slow" }],
                               "stopReason" => "stop", "sleep" => 2.0 },
                             assistant_text("with the seeded message")])
    h, = test_harness(storage: "memory", model: model, cwd: dir)
    t = Thread.new { h.prompt("first") }
    sleep 0.3
    eq "nextRun accepted during a run", true, h.next_run("remember this for later")["ok"]
    eq "steer accepted too", true, h.steer("this one dies on abort")["ok"]
    h.abort!
    eq "run aborted", "aborted", t.value["outcome"]
    st = h.state
    eq "steer payload was cleared", [], st.dig("queues", "steer")
    eq "nextRun survived", ["remember this for later"],
       st.dig("queues", "nextRun").map { _1.dig("content", 0, "text") }
    h.prompt("second")
    texts = entries_of(h.session).select { _1.dig("message", "role") == "user" }
                                 .map { _1.dig("message", "content", 0, "text") }
    eq "the seeded message entered the second run", true, texts.include?("remember this for later")
    eq "the aborted steer never entered the transcript", false, texts.include?("this one dies on abort")
    h.close
  end

  group "auto-compaction at a checkpoint, inside the run's own records" do
    long = "x " * 4000
    model = fake_model(dir, [assistant_text(long), assistant_text("SUMMARY"), assistant_text("done")])
    h, = test_harness(storage: "memory", model: model, cwd: dir,
                                 compaction: { "threshold" => 0.00002, "keepRecentTokens" => 200 })
    h.on_hook("before_run_end") do |_e|
      @once ||= 0
      @once += 1
      @once == 1 ? { "followUp" => "keep going" } : nil
    end
    r = h.prompt("write a lot")
    eq "run completed", true, r["ok"]
    types = entries_of(h.session).map { _1["type"] }
    eq "a compaction entry appeared mid-run", true, types.include?("compaction")
    ops = records_of(h.session).select { _1["type"] == "operation_started" }
    eq "auto-compaction is not a separate operation", 1, ops.size
    tasks = records_of(h.session).select { _1["type"] == "task_attempt" }.map { _1["task"] }
    eq "it used a compaction task inside the run", true, tasks.include?("compaction")
    eq "the context now starts at the compaction entry", "compaction", h.session.context_entries.first["type"]
    h.close
  end

  group "fork: entries only, no records, starts idle" do
    model = fake_model(dir, [assistant_tool("ls", { "path" => dir }), assistant_text("listed")])
    h, = test_harness(storage: "memory", model: model, cwd: dir)
    h.prompt("list the dir")
    forked = File.join(dir, "forked.jsonl")
    Leve::Fork.to_file(h.session, forked)
    lines = File.readlines(forked).map { JSON.parse(_1) }
    eq "no records were copied", 0, lines.count { _1["kind"] == "record" }
    eq "entries were copied", 4, lines.count { _1["kind"] == "entry" }
    eq "parent linkage recorded", h.session.metadata["id"], lines.first["parentSessionId"]

    h2, susp2 = test_harness(storage: "jsonl", path: forked, model: model, cwd: dir)
    eq "the fork opens idle", [], susp2
    eq "and carries the conversation", 4, entries_of(h2.session).size
    eq "leaf is the copied tip", true, !h2.state["leafId"].nil?
    h2.close
    h.close
  end

  group "watch_session(): inventory without transcripts" do
    model = fake_model(dir, [assistant_text("ok"), assistant_text("ok")])
    h, = test_harness(storage: "memory", model: model, cwd: dir)
    h.create_lane("slack:9", nil)
    w = h.watch_session
    eq "lists every lane, main included", %w[main slack:9], w.snapshot["lanes"].map { _1["name"] }.sort
    eq "no transcripts in a session snapshot", false, w.snapshot.key?("transcript")
    w.close
    h.close
  end

  group "lane deletion keeps entries, drops the pointer" do
    model = fake_model(dir, [assistant_text("ok")])
    h, = test_harness(storage: "memory", model: model, cwd: dir)
    h.create_lane("tmp", nil)
    h.lane("tmp").prompt("hello from the lane")
    before = h.session.find_entries.size
    eq "main cannot be deleted", "invalid_lane", h.delete_lane("main").dig("error", "code")
    eq "lane deleted", true, h.delete_lane("tmp")["ok"]
    eq "entries survive", before, h.session.find_entries.size
    eq "pointer gone", %w[main], h.session.lanes.map { _1["lane"] }
    h.close
  end

  group "tool declarations and replay safety are declared, not guessed" do
    eq "read is replay-safe", "safe", Leve::Tools.replay_of("read")
    eq "bash is never replayed", "never", Leve::Tools.replay_of("bash")
    eq "every tool has a schema", true,
       Leve::Tools.declarations.all? { _1["parameters"]["type"] == "object" }
    eq "the registry is shareable across Ractors", true,
       Ractor.new { Leve::Tools.names.size }.value == Leve::Tools.names.size
  end
end

done
