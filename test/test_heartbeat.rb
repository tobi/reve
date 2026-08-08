# frozen_string_literal: true

require_relative "helper"
require_relative "../lib/leve/tui"
include TestKit

def heartbeat_yaml(name: "dream", extra: "")
  <<~YAML
    tasks:
      - name: #{name}
        model: default
        channel-name: #{name}
        continue: true
        every: 4h
        prompt: Run the dream protocol.
        delivery: main
        #{extra}
  YAML
end

group "HEARTBEAT.yml is strict and VM-only" do
  Dir.mktmpdir do |dir|
    path = File.join(dir, "HEARTBEAT.yml")
    File.write(path, heartbeat_yaml)
    task = Leve::Heartbeat.load(path).first
    eq "duration parsed", 14_400, task["everySeconds"]
    eq "continuation remains boolean", true, task["continue"]

    File.write(path, heartbeat_yaml(extra: "host-exec: uname -a"))
    error = begin
      Leve::Heartbeat.load(path)
      nil
    rescue ArgumentError => e
      e.message
    end
    eq "host execution is rejected", true, error.include?("host-exec is forbidden")

    File.write(path, heartbeat_yaml(extra: "every: sometime"))
    error = begin
      Leve::Heartbeat.load(path)
      nil
    rescue ArgumentError => e
      e.message
    end
    eq "bad schedules are rejected", true, error.include?("invalid heartbeat interval")
  end
end

group "heartbeat config reload keeps the last valid revision" do
  Dir.mktmpdir do |dir|
    path = File.join(dir, "HEARTBEAT.yml")
    state = File.join(dir, "state.json")
    File.write(path, heartbeat_yaml(name: "first"))
    h, = test_harness(cwd: dir, storage: "memory")
    runner = Leve::Heartbeat::Runner.new(h, workspace: dir, config_path: path,
                                           tasks: Leve::Heartbeat.load(path), state_path: state)
    File.write(path, heartbeat_yaml(name: "second"))
    runner.reload_config
    eq "a valid edit replaces tasks", ["second"], runner.instance_variable_get(:@tasks).map { _1["name"] }
    File.write(path, "tasks: [")
    runner.reload_config
    eq "an invalid edit retains the valid set", ["second"],
       runner.instance_variable_get(:@tasks).map { _1["name"] }
    h.close
  end
end

group "a heartbeat runs on an unattached lane and delivers strictly" do
  Dir.mktmpdir do |dir|
    model = fake_model(dir, [assistant_text("Message: memory was consolidated")])
    h, = test_harness(cwd: dir, storage: "memory", model: model)
    task = Leve::Heartbeat.load(
      File.write(File.join(dir, "HEARTBEAT.yml"), heartbeat_yaml).then { File.join(dir, "HEARTBEAT.yml") }
    ).first
    runner = Leve::Heartbeat::Runner.new(h, workspace: dir,
      config_path: File.join(dir, "HEARTBEAT.yml"), tasks: [task], state_path: File.join(dir, "state.json"))
    runner.run_task(task)

    eq "the stable background lane exists", true, !h.lane("dream").nil?
    queued = h.main.state.dig("queues", "nextRun")
    eq "Message delivery enters the main inbox", true,
       queued.any? { (_1["content"] || []).any? { |part| part["text"].to_s.include?("memory was consolidated") } }
    eq "recent main context is materialized in workspace", true,
       File.read(File.join(dir, "RECENT_CONVERSATIONS.md")).include?("Recent Conversations")
    heartbeat_prompt = h.lane("dream").session.context_entries.find { _1.dig("message", "role") == "user" }
    text = heartbeat_prompt.dig("message", "content", 0, "text")
    eq "strict response grammar is appended", true, text.include?("otherwise just output the token SILENCE")
    logs = h.lane("dream").session.path_entries.select { _1["type"] == "custom" }.map { _1["customType"] }
    eq "start and delivery are durable", true,
       %w[heartbeat_started heartbeat_delivery].all? { logs.include?(_1) }
    h.instance_variable_set(:@heartbeat, runner)
    tui = Leve::InteractiveAgentTUI.new(h, [])
    output = StringIO.new
    tui.instance_variable_set(:@out, output)
    tui.render({ "type" => "message_update", "lane" => "dream",
                 "event" => { "type" => "text_delta", "text" => "private work" } })
    eq "unattached lane output stays out of the foreground", "", output.string
    h.close
  end
end

group "nonzero VM preparation skips the model turn" do
  Dir.mktmpdir do |dir|
    native = Object.new
    native.define_singleton_method(:microsandbox_version) { "fake" }
    native.define_singleton_method(:installed?) { true }
    native.define_singleton_method(:install) { true }
    native.define_singleton_method(:exists?) { |_name| true }
    native.define_singleton_method(:running?) { |_name| false }
    native.define_singleton_method(:remove) { |_name| true }
    vm = Object.new
    vm.define_singleton_method(:alive?) { true }
    vm.define_singleton_method(:exec) do |_cmd, _opts_json|
      JSON.generate({ "stdout" => "", "stderr" => "not ready", "exitCode" => 7, "success" => false })
    end
    vm.define_singleton_method(:shell) { |_script, opts_json| vm.exec("sh", opts_json) }
    vm.define_singleton_method(:read_file) { |_path| "" }
    vm.define_singleton_method(:write_file) { |_path, _content| nil }
    vm.define_singleton_method(:exec_session) do |cmd, opts_json|
      TestKit::ImmediateExec.new(vm.exec(cmd, opts_json))
    end
    vm.define_singleton_method(:stop) { nil }
    native.define_singleton_method(:create) { |_spec_json| vm }
    native.define_singleton_method(:start) { |_name| vm }
    sandbox = Leve::Sandbox::Client.new(Leve::Sandbox.config(
      "hostWorkspace" => dir, "provision" => false, "githubAuth" => false, "bootstrap" => []
    ), native: native)
    h, = test_harness(cwd: dir, storage: "memory", sandbox: sandbox)
    path = File.join(dir, "HEARTBEAT.yml")
    File.write(path, heartbeat_yaml(extra: "vm-exec: check-ready"))
    task = Leve::Heartbeat.load(path).first
    runner = Leve::Heartbeat::Runner.new(h, workspace: dir, config_path: path,
      tasks: [task], state_path: File.join(dir, "state.json"))
    runner.run_task(task)
    logs = h.lane("dream").session.path_entries.select { _1["customType"] == "heartbeat_skipped" }
    eq "skip is logged", 7, logs.first.dig("data", "exitCode")
    eq "no model operation was opened", false,
       h.lane("dream").session.path_entries.any? { _1["type"] == "operation_started" }
    h.close
  end
end

done
