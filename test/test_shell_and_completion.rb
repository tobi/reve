# frozen_string_literal: true

require_relative "helper"
require_relative "../lib/durable/tui"
include TestKit

group "exec_stream: one shell runner for the tool and for !" do
  chunks = []
  r = Durable::Tools.exec_stream("echo one; echo two >&2; exit 3", Dir.pwd) { |c| chunks << c }
  eq "captures both streams", %w[one two], r["output"].split("\n")
  eq "reports the exit code", 3, r["exitCode"]
  eq "streamed while running", true, chunks.any?
  eq "runs in the given directory", "/tmp\n", Durable::Tools.exec_stream("pwd", "/tmp")["output"]

  t0 = Time.now
  timed = Durable::Tools.exec_stream("sleep 30", Dir.pwd, timeout: 0.5)
  eq "timeout kills the child", true, (Time.now - t0) < 3 && timed["timedOut"]

  cancelled = false
  t1 = Time.now
  killer = Thread.new do
    sleep 0.4
    cancelled = true
  end
  c = Durable::Tools.exec_stream("sleep 30", Dir.pwd, cancel: -> { cancelled })
  killer.join
  eq "cancellation kills the child", true, (Time.now - t1) < 3 && c["cancelled"]
end

group "a shell execution projects into context as the user's action" do
  entry = { "type" => "custom", "customType" => "bash_execution",
            "data" => { "command" => "rake test", "output" => "3 failures", "exitCode" => 1 } }
  msg = Durable::Context.project(entry)
  eq "it is a user message", "user", msg["role"]
  text = msg.dig("content", 0, "text")
  eq "attributed to the user", true, text.start_with?("The user ran a shell command.")
  eq "command included", true, text.include?('command="rake test"')
  eq "exit code included", true, text.include?("exit=1")
  eq "output included", true, text.include?("3 failures")
  eq "custom entries without a projector stay out of context", nil,
     Durable::Context.project({ "type" => "custom", "customType" => "something-else" })
end

Dir.mktmpdir do |dir|
  group "!command is durable and reaches the model" do
    model = fake_model(dir, [assistant_text("I see the test output")])
    h, = Durable::Harness.create(storage: "memory", model: model, cwd: dir, user_skills: false)
    r = h.main.append_bash("rake test", "2 runs, 0 failures", 0)
    eq "accepted", true, r["ok"]
    entry = h.session.find_entry("type" => "custom")
    eq "stored as a custom entry", "bash_execution", entry["customType"]
    eq "with the exit code", 0, entry.dig("data", "exitCode")
    h.prompt("what happened?")
    sent = File.readlines("#{ENV["DURABLE_FAKE_SCRIPT"]}.requests").map { JSON.parse(_1) }
    texts = sent.last["messages"].flat_map { |m| (m["content"] || []).map { _1["text"] } }.compact
    eq "the model saw the command and its output", true,
       texts.any? { _1.include?("rake test") && _1.include?("2 runs") }
    eq "it is not a tool result", false, texts.any? { _1.to_s.include?("toolResult") }
    h.close
  end

  group "!command during a run is a deferred write" do
    model = fake_model(dir, [{ "role" => "assistant", "content" => [{ "type" => "text", "text" => "busy" }],
                               "stopReason" => "stop", "sleep" => 1.0 }])
    h, = Durable::Harness.create(storage: "memory", model: model, cwd: dir, user_skills: false)
    t = Thread.new { h.prompt("go") }
    sleep 0.3
    h.main.append_bash("git status", "clean", 0)
    t.value
    types = entries_of(h.session).map { _1["type"] }
    eq "it lands after the in-flight assistant message", %w[message message custom], types
    eq "recorded as a deferred write", true, records_of(h.session).any? { _1["type"] == "write_deferred" }
    h.close
  end
end

Dir.mktmpdir do |dir|
  FileUtils.mkdir_p(File.join(dir, "lib", "deep"))
  File.write(File.join(dir, "lib", "alpha.rb"), "")
  File.write(File.join(dir, "lib", "alto.rb"), "")
  File.write(File.join(dir, ".hidden"), "")

  group "tab completion knows where the cursor is" do
    model = fake_model(dir, [assistant_text("ok")])
    h, = Durable::Harness.create(storage: "memory", model: model, cwd: dir, user_skills: false)
    tui = Durable::TUI.new(h, [])
    line = Durable::Term::Line.new
    tui.instance_variable_set(:@line, line)
    complete = lambda do |text|
      line.replace_all(text)
      tok, start = line.token
      c, = tui.completion_for(text, tok, start)
      [c || [], start]
    end

    eq "command prefix", ["/goal"], complete.call("/go").first
    eq "bare slash lists commands", true, complete.call("/").first.include?("/compact")
    eq "think levels", %w[off low medium high], complete.call("/think ").first
    eq "tool names", %w[read], complete.call("/tools re").first
    eq "lane names", ["main"], complete.call("/lane ").first
    Dir.chdir(dir) do
      eq "unknown command falls through to paths", ["lib/"], complete.call("/nope li").first
      eq "paths after !", ["lib/"], complete.call("!ls li").first
      eq "paths inside a directory", %w[lib/alpha.rb lib/alto.rb lib/deep/],
         complete.call("!cat lib/a").first + complete.call("!cat lib/").first.select { _1.include?("deep") }
      eq "dotfiles only when asked", true, complete.call("!cat .hid").first == [".hidden"]
      eq "and not otherwise", false, complete.call("!cat ").first.include?(".hidden")
    end
    eq "common prefix is what gets inserted", "lib/al", tui.common_prefix(%w[lib/alpha.rb lib/alto.rb])
    h.close
  end

  group "the prompt announces shell mode as you type" do
    model = fake_model(dir, [assistant_text("ok")])
    h, = Durable::Harness.create(storage: "memory", model: model, cwd: dir, user_skills: false)
    tui = Durable::TUI.new(h, [])
    tui.instance_variable_set(:@busy, false)
    eq "idle prompt", true, Durable::Term.visible(tui.prompt_for("")).include?("›")
    tui.instance_variable_set(:@shell_mode, true)
    eq "shell prompt is the marker itself", "! ", Durable::Term.visible(tui.prompt_for(""))
    tui.instance_variable_set(:@shell_mode, false)
    tui.instance_variable_set(:@busy, true)
    eq "steering prompt while busy", true, Durable::Term.visible(tui.prompt_for("")).include?("steer")
    h.close
  end

  group "the editor splices a completion in at the token" do
    line = Durable::Term::Line.new
    "!cat lib/a".each_char { line.feed(_1) }
    token, start = line.token
    eq "token is the last word", ["lib/a", 5], [token, start]
    line.replace_token("lib/alpha.rb ", start)
    eq "spliced", "!cat lib/alpha.rb ", line.buffer
    eq "tab asks for completion", :complete, line.feed("\t")
  end
end

group "every tool survives being run inside a Ractor" do
  # An unfrozen String constant is unreachable from a non-main Ractor and every
  # tool runs in one — a mistake that only shows up at runtime, in the tool
  # result, as an IsolationError. So: exercise all of them through spawn.
  Dir.mktmpdir do |dir|
    File.write(File.join(dir, "a.txt"), "hello\n")
    args = { "bash" => { "command" => "echo hi" }, "read" => { "path" => "a.txt" },
             "write" => { "path" => "w.txt", "content" => "x" },
             "edit" => { "path" => "a.txt", "oldText" => "hello", "newText" => "bye" },
             "ls" => { "path" => "." }, "glob" => { "pattern" => "*.txt" },
             "grep" => { "pattern" => "bye" } }
    Durable::Tools.names.each do |name|
      result = Durable::IPC.decode(Durable::Tools.spawn(name, args.fetch(name), dir).value)
      text = result["content"].map { _1["text"] }.join
      check("#{name} runs in a Ractor without isolation errors") do
        !text.include?("IsolationError") && !text.include?("ractor failed")
      end
    end
  end
end

group "big output spills to a file instead of the context window" do
  r = Durable::Tools.invoke("bash", { "command" => "seq 1 5000" }, Dir.pwd)
  text = r["content"][0]["text"]
  eq "the result is capped", 2001, text.lines.size
  eq "it keeps the tail", true, text.include?("5000")
  eq "and says where the rest is", true, text.lines.last.start_with?("[Full output: /tmp/rbagent/")
  eq "with the counts", true, text.lines.last.include?("3000 earlier lines omitted")
  path = r.dig("details", "logPath")
  eq "the file has everything", 5000, File.readlines(path).size
  eq "details carry the totals", [5000, 2000], [r.dig("details", "totalLines"), r.dig("details", "shownLines")]
  eq "small output is untouched", "hi\n", Durable::Tools.invoke("bash", { "command" => "echo hi" }, Dir.pwd)
                                                        .dig("content", 0, "text")
  eq "slow commands report their duration", true,
     Durable::Tools.invoke("bash", { "command" => "sleep 1.2" }, Dir.pwd).dig("content", 0, "text").include?("Took")
end

done
