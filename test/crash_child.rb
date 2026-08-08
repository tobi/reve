# frozen_string_literal: true

# A child process that runs one prompt against a JSONL session and dies at a
# scripted crash site. Used by test_recovery.rb: recovery must be provable
# against real process death, not a simulated one.
require_relative "helper"
require "json"
include TestKit

script = JSON.parse(File.read(ENV.fetch("LEVE_FAKE_SCRIPT")))
session_path = ENV.fetch("LEVE_SESSION")
prompt = ENV.fetch("LEVE_PROMPT")

crash_at =
  if script["crashAfterAccept"] then { "site" => "after_accept" }
  elsif script["crashBeforeTool"] then { "site" => "before_tool" }
  elsif script["crashAfterToolStart"]
    { "site" => "after_tool_started", "delayMs" => script["steerBeforeCrash"] ? 1500 : 0 }
  elsif script["crashAfterAbort"] then { "site" => "after_abort_requested" }
  end

model = { "provider" => "fake", "modelId" => "fake-1", "api" => "fake", "baseUrl" => "", "apiKey" => "",
          "contextWindow" => 200_000, "maxTokens" => 4096, "name" => "fake" }

harness, suspended = test_harness(storage: "jsonl", path: session_path, model: model,
                                  system_prompt: "test", cwd: File.dirname(session_path))
harness.main.update_runtime("crashAt" => crash_at) if crash_at

unless suspended.empty?
  puts JSON.generate(harness.resume)
  harness.close
  exit 0
end

thread = Thread.new { harness.prompt(prompt) }

if script["steerBeforeCrash"]
  sleep 0.6
  harness.steer(script["steerBeforeCrash"])
end

if script["crashAfterAbort"]
  sleep 0.8
  harness.abort!
end

puts JSON.generate(thread.value)
harness.close
