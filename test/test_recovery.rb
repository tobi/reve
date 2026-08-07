# frozen_string_literal: true

require_relative "helper"
include TestKit

# Crash-site tests (§6). A child process runs until the scripted crash, or is
# killed mid-tool; the parent then reopens the JSONL session and resumes.
CHILD = File.expand_path("crash_child.rb", __dir__)

def run_child(script_path, session_path, prompt, extra_env = {})
  env = { "REVE_FAKE_SCRIPT" => script_path, "REVE_SESSION" => session_path,
          "REVE_PROMPT" => prompt }.merge(extra_env)
  # The recovering parent uses the same script: a resumed run continues where
  # the dead process stopped, including the provider's response cursor.
  ENV["REVE_FAKE_SCRIPT"] = script_path
  out = IO.popen(env, ["ruby", CHILD], err: [:child, :out], &:read)
  [out, $?.exitstatus]
end

def open_session(path)
  h, susp = test_harness(storage: "jsonl", path: path,
                                    model: { "provider" => "fake", "modelId" => "fake-1", "api" => "fake",
                                             "baseUrl" => "", "apiKey" => "", "contextWindow" => 200_000,
                                             "maxTokens" => 4096, "name" => "fake" },
                                    system_prompt: "test", cwd: File.dirname(path))
  [h, susp]
end

Dir.mktmpdir do |dir|
  group "crash between the assistant entry and the tool result (X3): safe tool replays" do
    session = File.join(dir, "x3.jsonl")
    script = File.join(dir, "x3.json")
    target = File.join(dir, "readme.txt")
    File.write(target, "content\n")
    File.write(script, JSON.generate({ "responses" => [
                                        assistant_tool("read", { "path" => target }),
                                        assistant_text("recovered and finished")
                                      ], "crashAfterToolStart" => true }))
    _out, status = run_child(script, session, "read the file")
    eq "child died", 9, status

    h, susp = open_session(session)
    eq "one suspended operation", 1, susp.size
    eq "suspension reason", "crash", susp.first["reason"]
    eq "the operation is a run", "run", susp.first["kind"]
    recs = records_of(h.session).map { _1["type"] }
    eq "tool_started is durable, the operation is not finished", true,
       recs.include?("tool_started") && !recs.include?("operation_finished")
    eq "no tool result yet", 0, entries_of(h.session).count { _1.dig("message", "role") == "toolResult" }

    r = h.resume
    eq "resume completes the run", true, r["ok"]
    eq "final message", "recovered and finished", r.dig("finalMessage", "content", 0, "text")
    result = entries_of(h.session).find { _1.dig("message", "role") == "toolResult" }
    eq "replay-safe tool re-executed with the persisted args", true,
       result.dig("message", "content", 0, "text").include?("content")
    eq "result landed on the provisioned id", true,
       records_of(h.session).find { _1["type"] == "tool_started" }["resultEntryId"] == result["id"]
    eq "operation now finished", "completed", records_of(h.session).last["outcome"]
    h.close
  end

  group "same crash site, replay: never → synthetic interrupted result" do
    session = File.join(dir, "x3b.jsonl")
    script = File.join(dir, "x3b.json")
    File.write(script, JSON.generate({ "responses" => [
                                        assistant_tool("bash", { "command" => "echo side-effect" }),
                                        assistant_text("moved on")
                                      ], "crashAfterToolStart" => true }))
    run_child(script, session, "run a command")
    h, susp = open_session(session)
    eq "suspended", 1, susp.size
    r = h.resume
    eq "resume completes", true, r["ok"]
    result = entries_of(h.session).find { _1.dig("message", "role") == "toolResult" }
    eq "unsafe tool is not re-executed", true, result.dig("message", "content", 0, "text").include?("Interrupted")
    eq "synthetic result is an error", true, result.dig("message", "isError")
    h.close
  end

  group "crash before before_tool (X1): the whole call path runs again" do
    session = File.join(dir, "x1.jsonl")
    script = File.join(dir, "x1.json")
    out = File.join(dir, "x1-out.txt")
    File.write(script, JSON.generate({ "responses" => [
                                        assistant_tool("write", { "path" => out, "content" => "written on resume" }),
                                        assistant_text("done")
                                      ], "crashBeforeTool" => true }))
    run_child(script, session, "write a file")
    eq "the effect did not happen", false, File.exist?(out)
    h, = open_session(session)
    recs = records_of(h.session).map { _1["type"] }
    eq "no tool_started record exists", false, recs.include?("tool_started")
    r = h.resume
    eq "resume completes", true, r["ok"]
    eq "the tool executed on the recovery path", "written on resume", File.read(out)
    eq "exactly one tool_started after recovery", 1,
       records_of(h.session).count { _1["type"] == "tool_started" }
    h.close
  end

  group "crash between operation_started and the user message: input is never lost" do
    session = File.join(dir, "x0.jsonl")
    script = File.join(dir, "x0.json")
    File.write(script, JSON.generate({ "responses" => [assistant_text("late but here")],
                                       "crashAfterAccept" => true }))
    run_child(script, session, "this prompt must survive")
    h, susp = open_session(session)
    eq "suspended", 1, susp.size
    eq "the prompt is only in the record so far", 0, entries_of(h.session).size
    r = h.resume
    eq "resume completes", true, r["ok"]
    roles = entries_of(h.session).map { _1.dig("message", "role") }
    eq "the missing initial message was appended", %w[user assistant], roles
    eq "with the provisioned id", true,
       records_of(h.session).first.dig("intent", "initialMessages", 0, "id") == entries_of(h.session).first["id"]
    h.close
  end

  group "recovery is idempotent: resuming twice changes nothing" do
    session = File.join(dir, "idem.jsonl")
    script = File.join(dir, "idem.json")
    File.write(script, JSON.generate({ "responses" => [assistant_text("one"), assistant_text("two")],
                                       "crashAfterAccept" => true }))
    run_child(script, session, "hello")
    h, = open_session(session)
    h.resume
    entries = entries_of(h.session).size
    second = h.resume
    eq "second resume is rejected: nothing to resume", "rejected", second["outcome"]
    eq "no entries added", entries, entries_of(h.session).size
    h.close
  end

  group "abort accepted before the crash: recovery finishes the reconciliation" do
    session = File.join(dir, "abrt.jsonl")
    script = File.join(dir, "abrt.json")
    File.write(script, JSON.generate({ "responses" => [
                                        assistant_tool("bash", { "command" => "sleep 30" })
                                      ], "crashAfterAbort" => true }))
    run_child(script, session, "long job")
    h, susp = open_session(session)
    eq "suspended", 1, susp.size
    r = h.resume
    eq "resume closes the operation as aborted", "aborted", r["outcome"]
    eq "operation_finished aborted", "aborted", records_of(h.session).last["outcome"]
    result = entries_of(h.session).find { _1.dig("message", "role") == "toolResult" }
    eq "the interrupted tool call got a synthetic result", true,
       result.dig("message", "content", 0, "text").include?("Interrupted")
    eq "closing assistant message", "aborted", entries_of(h.session).last.dig("message", "stopReason")
    h.close
  end

  group "steer accepted before the crash lands on resume" do
    session = File.join(dir, "steer.jsonl")
    script = File.join(dir, "steer.json")
    File.write(script, JSON.generate({ "responses" => [
                                        assistant_tool("read", { "path" => __FILE__ }),
                                        assistant_text("with the steer in context")
                                      ], "crashAfterToolStart" => true, "steerBeforeCrash" => "focus on tests" }))
    run_child(script, session, "look around")
    h, = open_session(session)
    st = h.state
    eq "the queued steer is restored from its record", ["focus on tests"],
       st.dig("queues", "steer").map { _1.dig("content", 0, "text") }
    h.resume
    texts = entries_of(h.session).select { _1.dig("message", "role") == "user" }
                                .map { _1.dig("message", "content", 0, "text") }
    eq "the steering message reached the transcript", true, texts.include?("focus on tests")
    h.close
  end

  group "deferred request: the lane parks, a later process redeems the handle" do
    session = File.join(dir, "defer.jsonl")
    script = File.join(dir, "defer.json")
    handle = { "provider" => "fake", "api" => "fake", "id" => "batch-1" }
    File.write(script, JSON.generate({
                                       "responses" => [
                                         { "role" => "assistant", "content" => [], "stopReason" => "deferred",
                                           "deferred" => handle },
                                         assistant_text("this is never used"),
                                         assistant_text("after redemption")
                                       ],
                                       "deferred:batch-1" => { "pendingPolls" => 1,
                                                               "result" => assistant_text("the batch answer") }
                                     }))
    out, = run_child(script, session, "analyze this mailbox")
    eq "prompt resolved as suspended", true, out.include?('"outcome":"suspended"')

    h, susp = open_session(session)
    eq "restored as suspended", 1, susp.size
    eq "reason is deferred, not crash", "deferred", susp.first["reason"]
    eq "the handle came from the persisted assistant entry", "batch-1", susp.first.dig("deferred", "id")

    first = h.resume
    eq "still pending → parks again", "suspended", first["outcome"]
    second = h.resume
    eq "redeemed and the run continues", true, second["ok"]
    texts = entries_of(h.session).select { _1.dig("message", "role") == "assistant" }
                                 .filter_map { _1.dig("message", "content", 0, "text") }
    eq "the redeemed answer is in the transcript", true, texts.include?("the batch answer")
    eq "no extra provider request was paid for", 1,
       records_of(h.session).count { _1["type"] == "task_attempt" }
    h.close
  end

  group "hard kill mid-tool (SIGKILL, no scripted crash) is recoverable" do
    session = File.join(dir, "kill.jsonl")
    script = File.join(dir, "kill.json")
    File.write(script, JSON.generate({ "responses" => [
                                        assistant_tool("bash", { "command" => "sleep 20" }),
                                        assistant_text("after the kill")
                                      ] }))
    env = { "REVE_FAKE_SCRIPT" => script, "REVE_SESSION" => session, "REVE_PROMPT" => "sleep a lot" }
    ENV["REVE_FAKE_SCRIPT"] = script
    pid = Process.spawn(env, "ruby", CHILD, out: "/dev/null", err: "/dev/null")
    sleep 2.5
    Process.kill("KILL", pid)
    Process.wait(pid)
    h, susp = open_session(session)
    eq "restored as suspended after SIGKILL", 1, susp.size
    eq "the log is a valid prefix", true, File.readlines(session).all? { |l| (JSON.parse(l) rescue false) }
    r = h.resume
    eq "resume completes the run", true, r["ok"]
    eq "the interrupted call was reconciled", 1,
       entries_of(h.session).count { _1.dig("message", "role") == "toolResult" }
    h.close
  end

  group "deleting every record leaves a valid conversation" do
    session = File.join(dir, "x3.jsonl")
    lines = File.readlines(session).map { JSON.parse(_1) }
    entries = lines.select { _1["kind"] == "entry" }
    eq "entries alone form a chain", true,
       entries.all? { |e| e["parentId"].nil? || entries.any? { _1["id"] == e["parentId"] } }
    eq "and the conversation is complete (user → assistant → toolResult → assistant)",
       %w[user assistant toolResult assistant],
       entries.map { _1.dig("message", "role") }
  end
end

group "detaching is not aborting: an open operation stays resumable" do
  Dir.mktmpdir do |dir|
    session = File.join(dir, "detach.jsonl")
    script = File.join(dir, "detach.json")
    File.write(script, JSON.generate({ "responses" => [
                                        { "role" => "assistant",
                                          "content" => [{ "type" => "text", "text" => "slow" }],
                                          "stopReason" => "stop", "sleep" => 30 },
                                        assistant_text("finished after resume")
                                      ] }))
    ENV["REVE_FAKE_SCRIPT"] = script
    h, = open_session(session)
    Thread.new { h.prompt("start something slow") }
    sleep 1.0
    h.close      # the harness-v2 close(): detach, do not abort

    records = File.readlines(session).map { JSON.parse(_1) }.select { _1["kind"] == "record" }
    eq "no abort was recorded", false, records.any? { _1["type"] == "abort_requested" }
    eq "the operation is still open", false, records.any? { _1["type"] == "operation_finished" }

    h2, susp = open_session(session)
    eq "it restores as suspended", 1, susp.size
    eq "and resume finishes it", true, h2.resume["ok"]
    h2.close
  end
end

done
