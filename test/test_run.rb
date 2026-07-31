# frozen_string_literal: true

require_relative "helper"
include TestKit

Dir.mktmpdir do |dir|
  group "run with one tool call writes the §6 trace" do
    model = fake_model(dir, [
                         assistant_tool("write", { "path" => File.join(dir, "hello.txt"), "content" => "hi" }),
                         assistant_text("wrote it")
                       ])
    h, susp = Durable::Harness.create(storage: "memory", model: model, system_prompt: "test", cwd: dir)
    eq "nothing suspended on a fresh session", [], susp
    r = h.prompt("create hello.txt")
    eq "run completed", true, r["ok"]
    eq "final message", "wrote it", r.dig("finalMessage", "content", 0, "text")
    eq "the tool actually ran", "hi", File.read(File.join(dir, "hello.txt"))

    types = records_of(h.session).map { _1["type"] }
    eq "record trace", %w[operation_started task_attempt tool_started task_attempt operation_finished], types
    entries = entries_of(h.session).map { _1.dig("message", "role") }
    eq "entry trace", %w[user assistant toolResult assistant], entries

    rec = records_of(h.session)
    started = rec.find { _1["type"] == "tool_started" }
    result_entry = h.session.entry(started["resultEntryId"])
    eq "provisioned result id is the tool result entry", "toolResult", result_entry.dig("message", "role")
    eq "replay safety snapshotted", "never", started["replay"]
    eq "operation outcome", "completed", rec.last["outcome"]
    h.close
  end

  group "busy lane rejects a second operation" do
    model = fake_model(dir, [{ "role" => "assistant", "content" => [{ "type" => "text", "text" => "slow" }],
                               "stopReason" => "stop", "sleep" => 1.0 }])
    h, = Durable::Harness.create(storage: "memory", model: model, cwd: dir)
    t = Thread.new { h.prompt("slow one") }
    sleep 0.3
    second = h.prompt("me too")
    eq "second prompt rejected", "rejected", second["outcome"]
    eq "rejection code", "busy", second.dig("error", "code")
    eq "first still completes", true, t.value["ok"]
    h.close
  end

  group "steering while a tool runs lands at the checkpoint" do
    model = fake_model(dir, [
                         assistant_tool("bash", { "command" => "sleep 1; echo done" }),
                         assistant_text("saw the steer")
                       ])
    h, = Durable::Harness.create(storage: "memory", model: model, cwd: dir)
    t = Thread.new { h.prompt("run something slow") }
    sleep 0.5
    eq "steer accepted while the tool runs", true, h.steer("focus on the tests")["ok"]
    r = t.value
    eq "run completed", true, r["ok"]
    roles = entries_of(h.session).map { _1.dig("message", "role") }
    eq "steer message is appended after the tool result", %w[user assistant toolResult user assistant], roles
    rec = records_of(h.session).map { _1["type"] }
    eq "queue_enqueued recorded before the entry", true, rec.include?("queue_enqueued")
    steer_rec = records_of(h.session).find { _1["type"] == "queue_enqueued" }
    eq "provisioned steer id is the appended entry",
       "focus on the tests",
       h.session.entry(steer_rec["target"]["id"]).dig("message", "content", 0, "text")
    h.close
  end

  group "abort during a tool: synthetic result, closing message, aborted outcome" do
    model = fake_model(dir, [assistant_tool("bash", { "command" => "sleep 5; echo never" })])
    h, = Durable::Harness.create(storage: "memory", model: model, cwd: dir)
    t = Thread.new { h.prompt("start a long job") }
    sleep 0.6
    a = h.abort!
    eq "abort resolves durably", true, a["ok"]
    r = t.value
    eq "run outcome", "aborted", r["outcome"]
    rec = records_of(h.session)
    eq "abort_requested written", true, rec.any? { _1["type"] == "abort_requested" }
    eq "operation_finished aborted", "aborted", rec.last["outcome"]
    roles = entries_of(h.session).map { _1.dig("message", "role") }
    eq "batch closed with a tool result and a closing assistant message",
       %w[user assistant toolResult assistant], roles
    last = entries_of(h.session).last
    eq "closing message stop reason", "aborted", last.dig("message", "stopReason")
    h.close
  end

  group "retry: the durable attempt count caps retries" do
    err = { "role" => "assistant", "content" => [], "stopReason" => "error",
            "errorMessage" => "overloaded", "retryable" => true }
    model = fake_model(dir, [err, err, assistant_text("third time")])
    h, = Durable::Harness.create(storage: "memory", model: model, cwd: dir,
                                 retry_policy: { "maxAttempts" => 5, "baseMs" => 10 })
    r = h.prompt("flaky")
    eq "run recovers", true, r["ok"]
    attempts = records_of(h.session).select { _1["type"] == "task_attempt" }
    eq "three attempts recorded", [1, 2, 3], attempts.map { _1["attempt"] }
    eq "attempts are consecutive within the task", true,
       attempts.each_cons(2).all? { |a, b| b["attempt"] == a["attempt"] + 1 }
    h.close
  end

  group "retries exhausted fails the operation with a transcript entry" do
    err = { "role" => "assistant", "content" => [], "stopReason" => "error",
            "errorMessage" => "nope", "retryable" => true }
    model = fake_model(dir, [err, err])
    h, = Durable::Harness.create(storage: "memory", model: model, cwd: dir,
                                 retry_policy: { "maxAttempts" => 2, "baseMs" => 10 })
    r = h.prompt("hopeless")
    eq "outcome failed", "failed", r["outcome"]
    eq "operation_finished failed", "failed", records_of(h.session).last["outcome"]
    eq "give-up recorded in the transcript", true,
       entries_of(h.session).last.dig("message", "content", 0, "text").to_s.include?("Retries exhausted")
    h.close
  end

  group "parallel tool batch: real Ractors, source-ordered records" do
    calls = 3.times.map do |i|
      { "type" => "toolCall", "id" => "tc#{i}", "name" => "bash",
        "arguments" => { "command" => "sleep 0.5; echo #{i}" } }
    end
    model = fake_model(dir, [{ "role" => "assistant", "content" => calls, "stopReason" => "toolUse" },
                             assistant_text("all three done")])
    h, = Durable::Harness.create(storage: "memory", model: model, cwd: dir)
    t0 = Time.now
    r = h.prompt("three things at once")
    elapsed = Time.now - t0
    eq "completed", true, r["ok"]
    eq "ran in parallel (3 × 0.5s sleep in under 1.2s)", true, elapsed < 1.2
    started = records_of(h.session).select { _1["type"] == "tool_started" }
    eq "tool_started in source order", %w[tc0 tc1 tc2], started.map { _1["toolCallId"] }
    eq "tool indexes", [0, 1, 2], started.map { _1["toolIndex"] }
    results = entries_of(h.session).select { _1.dig("message", "role") == "toolResult" }
    eq "results in source order", %w[tc0 tc1 tc2], results.map { _1.dig("message", "toolCallId") }
    h.close
  end

  group "hooks: before_tool blocks, after_tool patches, before_run injects" do
    model = fake_model(dir, [assistant_tool("bash", { "command" => "echo secret" }),
                             assistant_tool("read", { "path" => __FILE__ }, id: "tc2"),
                             assistant_text("ok")])
    h, = Durable::Harness.create(storage: "memory", model: model, cwd: dir)
    h.on_hook("before_run") { |_e| { "messages" => [{ "role" => "user",
                                                      "content" => [{ "type" => "text", "text" => "injected" }] }] } }
    h.on_hook("before_tool") { |e| e["toolName"] == "bash" ? { "block" => { "reason" => "no shell today" } } : nil }
    h.on_hook("after_tool") { |e| { "content" => [{ "type" => "text", "text" => "patched" }] } }
    r = h.prompt("try the shell")
    eq "run completed", true, r["ok"]
    injected = entries_of(h.session)[1]
    eq "before_run injection persisted as an entry", "injected",
       injected.dig("message", "content", 0, "text")
    results = entries_of(h.session).select { _1.dig("message", "role") == "toolResult" }
    eq "blocked call has no tool_started record", 1,
       records_of(h.session).count { _1["type"] == "tool_started" }
    eq "block is durable as an error tool result", true,
       results.first.dig("message", "content", 0, "text").include?("no shell today")
    eq "blocked call is an error", true, results.first.dig("message", "isError")
    eq "after_tool patch applied to the executed call", "patched",
       results.last.dig("message", "content", 0, "text")
    h.close
  end

  group "deferred writes apply at the checkpoint, after the assistant entry" do
    model = fake_model(dir, [{ "role" => "assistant", "content" => [{ "type" => "text", "text" => "thinking" }],
                               "stopReason" => "stop", "sleep" => 0.8 }])
    h, = Durable::Harness.create(storage: "memory", model: model, cwd: dir)
    t = Thread.new { h.prompt("hello") }
    sleep 0.3
    h.main.set_persisted("thinkingLevel", "high")
    t.value
    types = entries_of(h.session).map { _1["type"] }
    eq "config entry lands after the assistant message (append-only context)",
       %w[message message thinking_level_change], types
    eq "write_deferred recorded", true, records_of(h.session).any? { _1["type"] == "write_deferred" }
    eq "effective thinking level now comes from the path", "high", h.state["thinkingLevel"]
    h.close
  end

  group "lanes run in parallel over shared history" do
    model = fake_model(dir, Array.new(6) { { "role" => "assistant",
                                             "content" => [{ "type" => "text", "text" => "lane reply" }],
                                             "stopReason" => "stop", "sleep" => 0.6 } })
    h, = Durable::Harness.create(storage: "memory", model: model, cwd: dir)
    base = h.session.append_message({ "role" => "user", "content" => [{ "type" => "text", "text" => "shared" }] })
    res = h.create_lane("slack:1", base["id"])
    eq "lane created", true, res["ok"]
    t0 = Time.now
    threads = [Thread.new { h.prompt("main work") }, Thread.new { h.lane("slack:1").prompt("thread work") }]
    r1, r2 = threads.map(&:value)
    elapsed = Time.now - t0
    eq "both completed", [true, true], [r1["ok"], r2["ok"]]
    eq "they ran in parallel", true, elapsed < 1.1
    main_leaf = h.session.lanes.find { _1["lane"] == "main" }["leafId"]
    t1_leaf = h.session.lanes.find { _1["lane"] == "slack:1" }["leafId"]
    eq "lanes diverged", true, main_leaf != t1_leaf
    shared = h.session.find_entries_on_branch("start" => t1_leaf, "order" => "oldestFirst").map { _1["id"] }
    eq "the thread's branch contains the shared prefix", true, shared.include?(base["id"])
    eq "records are lane-scoped", true,
       h.session.find_records("lane" => "slack:1").all? { _1["lane"] == "slack:1" }
    h.close
  end

  group "watch(): snapshot first, then a gapless event stream" do
    model = fake_model(dir, [assistant_text("hi there")])
    h, = Durable::Harness.create(storage: "memory", model: model, cwd: dir)
    w = h.watch("main")
    eq "snapshot is lane-scoped", "main", w.snapshot["lane"]
    eq "snapshot has no operation", nil, w.snapshot["operation"]
    seen = []
    reader = Thread.new do
      loop do
        ev = w.next_event
        seen << ev["type"]
        break if ev["type"] == "run_end"
      end
    end
    h.prompt("say hi")
    reader.join(5)
    eq "run_start first", "run_start", seen.first
    eq "run_end last", "run_end", seen.last
    eq "step brackets are balanced and nested inside the run", true,
       seen.index("step_start") && seen.index("step_end") &&
       seen.index("step_start") > 0 && seen.index("step_end") < seen.size - 1
    eq "the committed message is announced", true, seen.include?("message_end")
    eq "every event arrives once", 1, seen.count("run_end")
    w.close
    h.close
  end

  group "manual compaction: summary entry, kept suffix, nothing-to-compact" do
    model = fake_model(dir, [assistant_text("one"), assistant_text("two"), assistant_text("SUMMARY OF EVERYTHING")])
    h, = Durable::Harness.create(storage: "memory", model: model, cwd: dir,
                                 compaction: { "keepRecentTokens" => 8 })
    empty = h.compact
    eq "nothing to compact on an empty session", "nothing_to_compact", empty.dig("error", "code")
    h.prompt("first")
    h.prompt("second")
    r = h.compact
    eq "compaction ok", true, r["ok"]
    comp = entries_of(h.session).last
    eq "compaction entry appended", "compaction", comp["type"]
    eq "summary from the model", true, comp["summary"].include?("SUMMARY OF EVERYTHING")
    eq "it names the first kept entry", true, !comp["firstKeptEntryId"].nil?
    eq "tokensBefore recorded", true, comp["tokensBefore"].to_i.positive?
    ops = records_of(h.session).select { _1["type"] == "operation_started" }
    eq "compaction is a separate operation", %w[compaction run run compaction], ops.map { _1.dig("intent", "kind") }
    ctx = h.session.context_entries
    eq "context starts with the summary", "compaction", ctx.first["type"]
    eq "and keeps the recent suffix verbatim", true, ctx.size > 1
    eq "the kept suffix starts at firstKeptEntryId", comp["firstKeptEntryId"], ctx[1]["id"]
    eq "the summarized head is gone from context", true,
       ctx.none? { _1.dig("message", "content", 0, "text") == "first" }
    h.close
  end

  group "navigation moves the leaf atomically with operation_finished" do
    model = fake_model(dir, [assistant_text("one"), assistant_text("two"), assistant_text("BRANCH SUMMARY")])
    h, = Durable::Harness.create(storage: "memory", model: model, cwd: dir)
    h.prompt("first")
    target = entries_of(h.session).last["id"]
    h.prompt("second")
    r = h.navigate(target, summarize: true, label: "before-refactor")
    eq "navigation ok", true, r["ok"]
    eq "label written as a global fact", "before-refactor", h.session.label(target)
    eq "summary entry chained to the target", "BRANCH SUMMARY", r.dig("summaryEntry", "summary")
    fin = records_of(h.session).last
    eq "leaf moved with the finish record", target, h.session.lanes.find { _1["lane"] == "main" }["leafId"]
    eq "finish outcome", "completed", fin["outcome"]
    h.close
  end
end

done
