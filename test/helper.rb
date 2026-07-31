# frozen_string_literal: true

require "json"
require "fileutils"
require "tmpdir"
require_relative "../lib/durable"

module TestKit
  FAILURES = []
  COUNT = [0]

  module_function

  def check(desc)
    COUNT[0] += 1
    ok = yield
    if ok
      puts "  ok   #{desc}"
    else
      puts "  FAIL #{desc}"
      FAILURES << desc
    end
  rescue StandardError => e
    puts "  FAIL #{desc} — #{e.class}: #{e.message}"
    puts "       #{(e.backtrace || []).first(5).join("\n       ")}"
    FAILURES << desc
  end

  def eq(desc, expected, actual)
    check("#{desc} (expected #{expected.inspect}, got #{actual.inspect})") { expected == actual }
  end

  def group(name)
    puts "\n#{name}"
    yield
  end

  def done
    puts
    if FAILURES.empty?
      puts "#{COUNT[0]} checks passed"
      exit 0
    else
      puts "#{FAILURES.size}/#{COUNT[0]} checks FAILED"
      exit 1
    end
  end

  # A scripted fake model. The script is a file, so it survives a crash and a
  # restart, and the cursor with it.
  def fake_model(dir, responses, extra = {})
    path = File.join(dir, "script-#{COUNT[0]}-#{rand(1 << 30)}.json")
    File.write(path, JSON.generate({ "responses" => responses }.merge(extra)))
    File.delete("#{path}.cursor") if File.exist?("#{path}.cursor")
    ENV["DURABLE_FAKE_SCRIPT"] = path
    { "provider" => "fake", "modelId" => "fake-1", "api" => "fake", "baseUrl" => "", "apiKey" => "",
      "reasoning" => false, "contextWindow" => 200_000, "maxTokens" => 4096, "name" => "fake" }
  end

  def text(msg) = "text: #{msg}"

  def assistant_text(t) = { "role" => "assistant", "content" => [{ "type" => "text", "text" => t }],
                            "stopReason" => "stop" }

  def assistant_tool(name, args, id: "tc1")
    { "role" => "assistant",
      "content" => [{ "type" => "toolCall", "id" => id, "name" => name, "arguments" => args }],
      "stopReason" => "toolUse" }
  end

  def entries_of(session) = session.find_entries("order" => "oldestFirst")
  def records_of(session) = session.find_records("lane" => "main")
end
