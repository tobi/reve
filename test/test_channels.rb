# frozen_string_literal: true

require_relative "helper"
include TestKit

load File.expand_path("../examples/telegram.rb", __dir__)

group "channels are one-file registrations with prompt guidance" do
  registration = Reve::Channels.registrations.find { _1.name == "telegram" }
  eq "the example registers itself", Reve::Channels::Telegram, registration.adapter
  eq "the channel teaches the model its transport style", true,
     registration.system_prompt.include?("[channel=telegram]") &&
       registration.system_prompt.include?("Telegram Rich Markdown")

  Dir.mktmpdir do |dir|
    h, = test_harness(cwd: dir, project: false,
                      channel_instructions: Reve::Channels.system_prompts)
    eq "channel guidance is in the stable system message", true,
       h.system_prompt.include?("<channel_instructions>") && h.system_prompt.include?("Telegram")
    h.close
  end
end

group "channel KV is durable, namespaced, and private" do
  Dir.mktmpdir do |dir|
    first = Reve::Channels::KV.new(dir, "telegram")
    other = Reve::Channels::KV.new(dir, "other")
    first.set("bot_token", "token-value")
    other.set("bot_token", "other-value")
    eq "a new instance reads the stored channel value", "token-value",
       Reve::Channels::KV.new(dir, "telegram").get("bot_token")
    eq "namespaces do not collide", "other-value", other.get("bot_token")
    eq "the host-side store is mode 0600", 0o600,
       File.stat(File.join(dir, ".reve", "channels.json")).mode & 0o777
  end
end

group "Telegram rich output uses a monotonic state machine" do
  calls = []
  tick = 0.0
  api = ->(method, body) { calls << [method, body]; { "message_id" => calls.size } }
  machine = Reve::Channels::Telegram::RichMessageStateMachine.new(
    42, api, clock: -> { tick += 1.0 }
  ).start
  machine.accept("type" => "tool_start", "toolName" => "bash",
                 "args" => { "command" => "git status" })
  machine.accept("type" => "message_update",
                 "event" => { "type" => "text_delta", "text" => "**Done**" })
  # A late tool event cannot move the renderer back out of answering.
  machine.accept("type" => "tool_start", "toolName" => "read",
                 "args" => { "path" => "README.md" })
  machine.finish

  eq "the state finishes", :done, machine.phase
  eq "draft starts with a private thinking placeholder", Reve::Channels::Telegram::THINKING,
     calls.first.last.dig("rich_message", "markdown")
  eq "tool and answer content reach the persisted rich message", true,
     calls.last.first == "sendRichMessage" &&
       calls.last.last.dig("rich_message", "markdown").include?("git status") &&
       calls.last.last.dig("rich_message", "markdown").include?("**Done**")
end

group "Telegram permanently locks input and output to the first private sender" do
  Dir.mktmpdir do |dir|
    kv = Reve::Channels::KV.new(dir, "telegram-pairing-test")
    harness = Struct.new(:main).new(Object.new)
    context = Struct.new(:kv, :harness) do
      def command(*) = nil
    end.new(kv, harness)
    telegram = Reve::Channels::Telegram.new(context)
    sends = []
    telegram.define_singleton_method(:api) do |_token, method, body|
      sends << [method, body]
      { "message_id" => sends.size }
    end
    first = { "chat" => { "type" => "private", "id" => 101 },
              "from" => { "id" => 101 }, "text" => "/start" }
    stranger = { "chat" => { "type" => "private", "id" => 202 },
                 "from" => { "id" => 202 }, "text" => "hello" }
    telegram.send(:receive, first)
    telegram.send(:receive, stranger)

    eq "the first sender and chat are persisted", [101, 101],
       [kv.get("allowed_user_id"), kv.get("allowed_chat_id")]
    eq "a stranger receives absolutely nothing", 1, sends.size
    blocked = begin
      telegram.send(:call_api, "sendRichMessage", "chat_id" => 202,
                    "rich_message" => { "markdown" => "no" })
      false
    rescue RuntimeError
      true
    end
    eq "every outbound send independently enforces the paired chat", true, blocked
  end
end

group "channel commands parse JSON objects" do
  project = Struct.new(:root).new(Dir.mktmpdir)
  lane = Class.new do
    attr_reader :prompts
    def initialize = @prompts = []
    def state = { "operation" => nil }
    def prompt(text) = (@prompts << text; { "ok" => true })
    def steer(text) = (@prompts << text; { "ok" => true })
  end.new
  harness = Struct.new(:main, :channel_runtime) do
    def lane(_name) = main
    def watch(_lane = nil) = nil
  end.new(lane, nil)
  runtime = Reve::Channels::Runtime.new(harness, project)
  harness.channel_runtime = runtime

  eq "Telegram commands are exported", true, runtime.command_names.include?("telegram-connect")
  bad = runtime.invoke("telegram-connect", "not-json")
  eq "invalid command arguments are useful", true, !bad["ok"] && bad["error"].include?("JSON object")
  context = Reve::Channels::Context.new(runtime, Reve::Channels.registrations.first)
  context.prompt("hello")
  eq "channel prompts carry transport metadata", "[channel=telegram] hello", lane.prompts.last
ensure
  runtime&.close
  FileUtils.rm_rf(project&.root)
end

done
