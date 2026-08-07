# frozen_string_literal: true

require_relative "helper"
require_relative "../lib/reve/tui"
include TestKit

group "there is no host shell fallback" do
  r = Reve::Tools.invoke("bash", { "command" => "uname -a" }, Dir.pwd)
  eq "generic tool invocation fails closed", true, r["isError"]
  eq "the reason is explicit", true, r.dig("content", 0, "text").include?("host execution is forbidden")
  eq "bash is marked for sandbox dispatch", true, Reve::Tools.sandboxed?("bash")
end

group "file tools are confined to the workspace bind source" do
  Dir.mktmpdir do |root|
    outside = Dir.mktmpdir
    File.write(File.join(outside, "secret"), "host secret")
    File.symlink(outside, File.join(root, "escape"))
    absolute = Reve::Tools.invoke("read", { "path" => "/etc/hosts" }, root)
    traversal = Reve::Tools.invoke("write", { "path" => "../escaped", "content" => "no" }, root)
    symlink = Reve::Tools.invoke("read", { "path" => "escape/secret" }, root)
    eq "absolute host reads fail", true, absolute["isError"]
    eq "parent traversal fails", true, traversal["isError"]
    eq "symlink escapes fail", true, symlink["isError"]
    eq "nothing was written outside", false, File.exist?(File.join(File.dirname(root), "escaped"))
  ensure
    FileUtils.rm_rf(outside) if outside
  end
end

group "a shell execution projects into context as the user's action" do
  entry = { "type" => "custom", "customType" => "bash_execution",
            "data" => { "command" => "rake test", "output" => "3 failures", "exitCode" => 1 } }
  msg = Reve::Context.project(entry)
  eq "it is a user message", "user", msg["role"]
  text = msg.dig("content", 0, "text")
  eq "attributed to the user", true, text.start_with?("The user ran a shell command.")
  eq "command included", true, text.include?('command="rake test"')
  eq "exit code included", true, text.include?("exit=1")
  eq "output included", true, text.include?("3 failures")
  eq "custom entries without a projector stay out of context", nil,
     Reve::Context.project({ "type" => "custom", "customType" => "something-else" })
end

Dir.mktmpdir do |dir|
  group "!command is durable and reaches the model" do
    model = fake_model(dir, [assistant_text("I see the test output")])
    h, = test_harness(storage: "memory", model: model, cwd: dir)
    r = h.main.append_bash("rake test", "2 runs, 0 failures", 0)
    eq "accepted", true, r["ok"]
    entry = h.session.find_entry("type" => "custom")
    eq "stored as a custom entry", "bash_execution", entry["customType"]
    eq "with the exit code", 0, entry.dig("data", "exitCode")
    h.prompt("what happened?")
    sent = File.readlines("#{ENV["REVE_FAKE_SCRIPT"]}.requests").map { JSON.parse(_1) }
    texts = sent.last["messages"].flat_map { |m| (m["content"] || []).map { _1["text"] } }.compact
    eq "the model saw the command and its output", true,
       texts.any? { _1.include?("rake test") && _1.include?("2 runs") }
    eq "it is not a tool result", false, texts.any? { _1.to_s.include?("toolResult") }
    h.close
  end

  group "!command during a run is a deferred write" do
    model = fake_model(dir, [{ "role" => "assistant", "content" => [{ "type" => "text", "text" => "busy" }],
                               "stopReason" => "stop", "sleep" => 1.0 }])
    h, = test_harness(storage: "memory", model: model, cwd: dir)
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
    h, = test_harness(storage: "memory", model: model, cwd: dir)
    tui = Reve::InteractiveAgentTUI.new(h, [])
    line = Reve::Term::Line.new
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
    h, = test_harness(storage: "memory", model: model, cwd: dir)
    tui = Reve::InteractiveAgentTUI.new(h, [])
    tui.instance_variable_set(:@busy, false)
    eq "idle prompt", true, Reve::Term.visible(tui.prompt_for("")).include?("›")
    tui.instance_variable_set(:@shell_mode, true)
    eq "shell prompt is the marker itself", "! ", Reve::Term.visible(tui.prompt_for(""))
    tui.instance_variable_set(:@shell_mode, false)
    tui.instance_variable_set(:@busy, true)
    eq "steering prompt while busy", true, Reve::Term.visible(tui.prompt_for("")).include?("steer")
    h.close
  end

  group "the editor splices a completion in at the token" do
    line = Reve::Term::Line.new
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
    Reve::Tools.names.each do |name|
      result = Reve::IPC.decode(Reve::Tools.spawn(name, args.fetch(name), dir).value)
      text = result["content"].map { _1["text"] }.join
      check("#{name} runs in a Ractor without isolation errors") do
        !text.include?("IsolationError") && !text.include?("ractor failed")
      end
    end
  end
end

group "ctrl-c and ctrl-d escalate the way a terminal user expects" do
  t = Reve::InteractiveAgentTUI.allocate
  i = ->(**kw) { t.interrupt_decision(**{ shell_running: false, busy: false, aborting: false,
                                          has_text: false, repeat: false }.merge(kw)) }
  eq "^C with text on the line clears it", :clear_line, i.call(has_text: true)
  eq "^C during a run aborts it", :abort_run, i.call(busy: true)
  eq "^C again while aborting quits", :force_quit, i.call(busy: true, aborting: true, repeat: true)
  eq "^C while aborting, but not a repeat, just aborts again", :abort_run,
     i.call(busy: true, aborting: true, repeat: false)
  eq "^C during a ! command cancels the command", :cancel_shell, i.call(shell_running: true, busy: true)
  eq "^C on an empty idle line asks first", :hint_quit, i.call
  eq "^C twice exits", :quit, i.call(repeat: true)

  d = ->(**kw) { t.eof_decision(**{ busy: false, has_text: false, repeat: false }.merge(kw)) }
  eq "^D mid-line deletes a character", :delete_char, d.call(has_text: true)
  eq "^D on an empty idle line exits", :quit, d.call
  eq "^D during a run warns first", :hint_leave, d.call(busy: true)
  eq "^D twice leaves the run open", :leave_running, d.call(busy: true, repeat: true)
end

group "the editor's own ctrl-d" do
  l = Reve::Term::Line.new
  eq "empty line reports eof", :eof, l.feed("\u0004")
  "abc".each_char { l.feed(_1) }
  l.feed("\u0001")
  eq "with text it deletes forward", nil, l.feed("\u0004")
  eq "and the character is gone", "bc", l.buffer
end

group "big output spills to a file instead of the context window" do
  Dir.mktmpdir do |cwd|
    output = (1..5000).map { "#{_1}\n" }.join
    text, details = Reve::Tools.overspill(output, "bash", root: cwd)
    eq "the result is capped", 2001, text.lines.size
    eq "it keeps the tail", true, text.include?("5000")
    eq "and says where the rest is", true, text.lines.last.include?("/.reve/logs/bash-")
    eq "with the counts", true, text.lines.last.include?("3000 earlier lines omitted")
    eq "the file has everything", 5000, File.readlines(details["logPath"]).size
    eq "details carry the totals", [5000, 2000], [details["totalLines"], details["shownLines"]]
    eq "small output is untouched", "hi\n", Reve::Tools.overspill("hi\n", "bash", root: cwd).first
  end
end

group "/compact runs durable manual compaction" do
  Dir.mktmpdir do |cwd|
    model = fake_model(cwd, [assistant_text("history " * 100), assistant_text("compact summary")])
    h, = test_harness(cwd: cwd, storage: "memory", model: model,
                      compaction: { "keepRecentTokens" => 8 })
    h.prompt("remember this detailed conversation " * 20)
    tui = Reve::InteractiveAgentTUI.new(h, [])
    tui.instance_variable_set(:@out, StringIO.new)
    tui.submit("/compact preserve decisions")
    tui.instance_variable_get(:@run_thread).join
    compaction = entries_of(h.session).find { _1["type"] == "compaction" }
    eq "the command appends a compaction entry", true, !compaction.nil?
    eq "the compaction is durable", "completed",
       records_of(h.session).select { _1["type"] == "operation_finished" }.last["outcome"]
    h.close
  end
end

group "/new replaces the current conversation without replacing the VM" do
  Dir.mktmpdir do |cwd|
    first, = test_harness(cwd: cwd, storage: "memory")
    first.prompt("old conversation")
    sandbox = first.sandbox
    first.new_session_factory = lambda do |current|
      fresh, suspended = test_harness(cwd: cwd, storage: "memory", sandbox: current.sandbox)
      fresh.new_session_factory = first.new_session_factory
      [fresh, suspended]
    end
    tui = Reve::InteractiveAgentTUI.new(first, [])
    tui.instance_variable_set(:@out, StringIO.new)
    tui.submit("/new")
    fresh = tui.instance_variable_get(:@h)
    eq "the harness changed", true, fresh != first
    eq "the new session has no conversation", [], entries_of(fresh.session)
    eq "the live sandbox was transferred", sandbox.object_id, fresh.sandbox.object_id
    fresh.close
  end
end

done
