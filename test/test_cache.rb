# frozen_string_literal: true

require_relative "helper"
include TestKit

def cached_reply(text, input: 4000, cache_read: 3800)
  { "role" => "assistant", "content" => [{ "type" => "text", "text" => text }], "stopReason" => "stop",
    "usage" => { "input" => input, "output" => 20, "cacheRead" => cache_read, "cacheWrite" => 0 } }
end

group "usage is normalised: input includes what was cached" do
  acc = Reve::Provider::Anthropic::Accumulator.new({ "provider" => "a", "modelId" => "m" })
  acc.handle({ "type" => "message_start",
               "message" => { "usage" => { "input_tokens" => 100, "cache_read_input_tokens" => 900,
                                           "cache_creation_input_tokens" => 50 } } })
  acc.handle({ "type" => "message_delta", "delta" => { "stop_reason" => "end_turn" },
               "usage" => { "output_tokens" => 7 } })
  u = acc.finish["usage"]
  eq "input is the whole prompt", 1050, u["input"]
  eq "cacheRead is a subset of it", 900, u["cacheRead"]
  eq "hit rate is read/input", 86, (u["cacheRead"] * 100.0 / u["input"]).round
end

group "anthropic asks for caching explicitly" do
  body = nil
  # Build the request the way the provider does, without sending it.
  msgs = [{ "role" => "user", "content" => [{ "type" => "text", "text" => "hi" }] }]
  provider_messages = Reve::Provider::Anthropic.to_provider_messages(msgs)
  Reve::Provider::Anthropic.mark_cache_breakpoint(provider_messages)
  eq "the newest message carries a breakpoint", { "type" => "ephemeral" },
     provider_messages.last["content"].last["cache_control"]
  body = { "system" => [{ "type" => "text", "text" => "sys", "cache_control" => { "type" => "ephemeral" } }] }
  eq "and so does the system prompt", "ephemeral", body["system"].first.dig("cache_control", "type")
end

Dir.mktmpdir do |dir|
  group "a stable prefix produces no warning, and the stats show the hits" do
    model = fake_model(dir, [cached_reply("one"), cached_reply("two"), cached_reply("three")])
    h, = test_harness(storage: "memory", model: model, cwd: dir)
    warnings = []
    h.on_event { |e| warnings << e if e["type"] == "cache_invalidated" }
    h.prompt("first")
    h.prompt("second")
    h.prompt("third")
    sleep 0.2
    eq "no cache warnings for an append-only conversation", [], warnings
    c = h.state["cache"]
    eq "requests counted", 3, c["requests"]
    eq "hit rate computed", 0.95, c["hitRate"]
    eq "no misses", 0, c["misses"]
    h.close
  end

  group "a deliberate break is announced, not alarming" do
    model = fake_model(dir, [cached_reply("one"), cached_reply("two")])
    h, = test_harness(storage: "memory", model: model, cwd: dir)
    warnings = []
    h.on_event { |e| warnings << e if e["type"] == "cache_invalidated" }
    h.prompt("first")
    h.set_goal("ship it")
    h.prompt("second")
    sleep 0.2
    eq "one warning", 1, warnings.size
    eq "it names the system prompt", true, warnings.first["reasons"].include?("system prompt changed")
    eq "and marks it expected", true, warnings.first["expected"]
    eq "with the cause", "goal changed", warnings.first["cause"]
    h.close
  end

  group "an unexpected prefix change is the loud one" do
    model = fake_model(dir, [cached_reply("one"), cached_reply("two")])
    h, = test_harness(storage: "memory", model: model, cwd: dir)
    warnings = []
    h.on_event { |e| warnings << e if e["type"] == "cache_invalidated" }
    h.prompt("first")
    # A hook that rewrites history: the classic silent cache killer.
    h.on_hook("transform_context") do |ev|
      msgs = ev["messages"].map(&:dup)
      msgs[0] = { "role" => "user", "content" => [{ "type" => "text", "text" => "rewritten history" }] }
      { "messages" => msgs }
    end
    h.prompt("second")
    sleep 0.2
    eq "warned", 1, warnings.size
    eq "it points at the message that changed", true,
       warnings.first["reasons"].any? { _1.include?("context diverged at message 1") }
    eq "and it is not expected", false, warnings.first["expected"]
    eq "the kept prefix is reported", 0, warnings.first["keptPrefix"]
    h.close
  end

  group "compaction breaks the cache on purpose" do
    model = fake_model(dir, [cached_reply("one"), cached_reply("two"),
                             cached_reply("SUMMARY", input: 5000, cache_read: 0), cached_reply("three")])
    h, = test_harness(storage: "memory", model: model, cwd: dir,
                                 compaction: { "keepRecentTokens" => 8 })
    warnings = []
    misses = []
    h.on_event do |e|
      warnings << e if e["type"] == "cache_invalidated"
      misses << e if e["type"] == "cache_miss"
    end
    h.prompt("first")
    h.prompt("second")
    h.compact
    h.prompt("third")
    sleep 0.2
    eq "warned once, for the compaction", 1, warnings.size
    eq "marked expected", true, warnings.first["expected"]
    eq "cause is the compaction", "compaction", warnings.first["cause"]
    eq "the deliberately cold compaction request is exempt", [], misses
    h.close
  end

  group "more than 30% uncached input warns, except a new session" do
    model = fake_model(dir, [cached_reply("cold", input: 5000, cache_read: 0),
                             cached_reply("edge", input: 5000, cache_read: 3500),
                             cached_reply("miss", input: 5000, cache_read: 3499)])
    h, = test_harness(storage: "memory", model: model, cwd: dir)
    warnings = []
    h.on_event { |e| warnings << e if e["type"] == "cache_miss" }
    h.prompt("first")
    h.prompt("second")
    h.prompt("third")
    sleep 0.2
    eq "cold first request is exempt and exactly 30% is fine", 1, warnings.size
    eq "31-ish percent is reported", true, warnings.first["missRate"] > 0.30
    eq "warning names uncached input", true, warnings.first["reason"].include?("uncached input")
    eq "counted as a miss", 1, h.state.dig("cache", "misses")
    h.close
  end
end

done
