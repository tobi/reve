# frozen_string_literal: true

require_relative "helper"
require_relative "../lib/leve/term"
include TestKit

VLLM = { "provider" => "vllm", "modelId" => "glm52", "api" => "openai-responses",
         "baseUrl" => "http://gb300:8000/v1", "apiKey" => "dummy", "reasoning" => true,
         "maxTokens" => 4096, "contextWindow" => 250_000,
         "compat" => { "supportsStore" => false, "supportsDeveloperRole" => false,
                       "supportsReasoningEffort" => false, "maxTokensField" => "max_tokens" } }.freeze

R = Leve::Provider::OpenAIResponses

group "openai-responses: message conversion" do
  input = R.to_input([
                       { "role" => "user", "content" => [{ "type" => "text", "text" => "hi" }] },
                       { "role" => "assistant", "stopReason" => "toolUse",
                         "content" => [{ "type" => "text", "text" => "on it" },
                                       { "type" => "toolCall", "id" => "c1", "name" => "ls",
                                         "arguments" => { "path" => "." } }] },
                       { "role" => "toolResult", "toolCallId" => "c1", "toolName" => "ls",
                         "content" => [{ "type" => "text", "text" => "a.rb" }] }
                     ])
  eq "user text becomes input_text", "input_text", input[0].dig("content", 0, "type")
  eq "assistant text goes in as a plain string", "on it", input[1]["content"]
  eq "tool calls become function_call items", "function_call", input[2]["type"]
  eq "arguments are a json string", '{"path":"."}', input[2]["arguments"]
  eq "results are function_call_output", %w[function_call_output c1],
     [input[3]["type"], input[3]["call_id"]]
  eq "deferred assistant messages project to nothing", [],
     R.to_input([{ "role" => "assistant", "stopReason" => "deferred", "content" => [] }])
end

group "openai-responses: orphaned tool calls are healed" do
  input = R.to_input([
                       { "role" => "assistant", "stopReason" => "toolUse",
                         "content" => [{ "type" => "toolCall", "id" => "c9", "name" => "bash",
                                         "arguments" => {} }] }
                     ])
  eq "a synthetic output is inserted", %w[function_call function_call_output], input.map { _1["type"] }
  eq "for the same call", "c9", input[1]["call_id"]
end

group "openai-responses: streaming accumulation" do
  acc = R::Accumulator.new(VLLM)
  events = [
    { "type" => "response.reasoning_text.delta", "delta" => "thinking…" },
    { "type" => "response.output_text.delta", "delta" => "Hello " },
    { "type" => "response.output_text.delta", "delta" => "world" },
    { "type" => "response.output_item.added",
      "item" => { "type" => "function_call", "id" => "i1", "call_id" => "call_1", "name" => "read" } },
    { "type" => "response.function_call_arguments.delta", "item_id" => "i1", "delta" => '{"path":' },
    { "type" => "response.function_call_arguments.done", "item_id" => "i1", "arguments" => '{"path":"x.rb"}' },
    { "type" => "response.completed",
      "response" => { "status" => "completed",
                      "usage" => { "input_tokens" => 100, "output_tokens" => 20,
                                   "input_tokens_details" => { "cached_tokens" => 40 } } } }
  ]
  deltas = []
  events.each { |e| acc.handle(e) { |d| deltas << d["type"] } }
  msg = acc.finish
  eq "streamed both kinds of delta", %w[thinking_delta text_delta text_delta tool_call_start],
     deltas.uniq.sort.then { deltas.first(4) }
  eq "thinking captured", "thinking…", msg["content"][0]["thinking"]
  eq "text captured", "Hello world", msg["content"][1]["text"]
  eq "tool call parsed from the done event", { "path" => "x.rb" }, msg["content"][2]["arguments"]
  eq "call id is the provider's call_id", "call_1", msg["content"][2]["id"]
  eq "stop reason is toolUse", "toolUse", msg["stopReason"]
  eq "usage mapped", [100, 20, 40], [msg["usage"]["input"], msg["usage"]["output"], msg["usage"]["cacheRead"]]
end

group "openai-responses: truncation and failure are in-band" do
  acc = R::Accumulator.new(VLLM)
  acc.handle({ "type" => "response.output_text.delta", "delta" => "partial" })
  acc.handle({ "type" => "response.incomplete",
               "response" => { "status" => "incomplete",
                               "incomplete_details" => { "reason" => "max_output_tokens" }, "usage" => {} } })
  eq "hitting the token cap is 'length'", "length", acc.finish["stopReason"]

  failed = R::Accumulator.new(VLLM)
  failed.handle({ "type" => "response.failed",
                  "response" => { "status" => "failed", "error" => { "message" => "boom" }, "usage" => {} } })
  m = failed.finish
  eq "a failure never raises", "error", m["stopReason"]
  eq "and carries the message", "boom", m["errorMessage"]
end

group "provider configuration failures are contextual and in-band" do
  bad = VLLM.merge("baseUrl" => "", "baseUrlSource" => "$LLAMA_CPP_BASE",
                    "apiKey" => "", "apiKeySource" => "$LLAMA_API_KEY")
  message = R.stream(model: bad, messages: [], system: "test", tools: [])
  eq "the lane receives an error message", "error", message["stopReason"]
  eq "it names provider, model, source and resolved URL", true,
     message["errorMessage"].include?("vllm/glm52") &&
       message["errorMessage"].include?("$LLAMA_CPP_BASE") &&
       message["errorMessage"].include?('resolved=""')
  eq "it tells the user which environment variable to set", true,
     message["errorMessage"].include?("Set environment variable $LLAMA_CPP_BASE")

  body = "complete provider detail " * 300
  response = Struct.new(:code, :message) do
    define_method(:read_body) { body }
  end.new("400", "Bad Request")
  transport = Object.new
  transport.define_singleton_method(:request) { |_request, &block| block.call(response) }
  request = Net::HTTP::Post.new(URI("https://models.example/v1/responses"))
  failed = R::Accumulator.new(VLLM)
  result = Leve::Provider::HTTP.pump(transport, request, failed, nil)
  eq "HTTP failures retain the complete response", true,
     result["errorMessage"].include?(body) && result["errorMessage"].include?("URL: https://models.example/v1/responses")
end

group "model resolution: provider-only asks the endpoint" do
  cfg = { "providers" => { "vllm" => { "baseUrl" => "http://127.0.0.1:1", "api" => "openai-responses",
                                       "models" => [{ "id" => "glm52", "contextWindow" => 250_000 }] } } }
  m = Leve::Provider::Models.resolve(cfg, "vllm")
  eq "unreachable endpoint falls back to the config", "glm52", m["modelId"]
  eq "compat travels with the model", true, m.key?("compat")
  eq "provider/model still works", "glm52", Leve::Provider::Models.resolve(cfg, "vllm/glm52")["modelId"]
  eq "bare id still works", "glm52", Leve::Provider::Models.resolve(cfg, "glm52")["modelId"]
  eq "unknown provider is nil", nil, Leve::Provider::Models.resolve(cfg, "nope/x")
end

group "term: right-aligned columns, like an RPROMPT" do
  line = Leve::Term.two_column("left", "right", 20)
  eq "padded to the column", 20, line.length
  eq "right edge is the right text", true, line.end_with?("right")
  eq "colour codes do not count toward width", 20,
     Leve::Term.visible(Leve::Term.two_column("\e[1mleft\e[0m", "\e[2mright\e[0m", 20)).length
  eq "no room means two lines", true, Leve::Term.two_column("x" * 18, "y" * 10, 20).include?("\n")
  eq "clip keeps the ellipsis inside the budget", 10, Leve::Term.clip("x" * 40, 10).length
  eq "wide glyphs count as two cells", 2, Leve::Term.display_width("✓")
  eq "so a line with them still fits", true,
     Leve::Term.display_width(Leve::Term.two_column("✓ ok", "✗ no", 20)) <= 20
end

group "term: the line editor" do
  l = Leve::Term::Line.new
  "hello".each_char { l.feed(_1) }
  eq "typing", "hello", l.buffer
  l.feed("\u007F")
  eq "backspace", "hell", l.buffer
  l.feed("\u0001")           # home
  l.feed("Y")
  eq "insert at the cursor", "Yhell", l.buffer
  l.feed("\u0015")           # kill to start
  eq "ctrl-u", "hell", l.buffer
  eq "enter submits", :submit, l.feed("\r")
  eq "take clears and returns", ["hell", ""], [l.take, l.buffer]
  eq "ctrl-c interrupts", :interrupt, l.feed("\u0003")
  eq "ctrl-d on an empty line is eof", :eof, l.feed("\u0004")

  "one".each_char { l.feed(_1) }
  l.take
  "two".each_char { l.feed(_1) }
  l.take
  l.feed_escape("[A")
  eq "history up", "two", l.buffer
  l.feed_escape("[A")
  eq "history up again", "one", l.buffer
  l.feed_escape("[B")
  eq "history down", "two", l.buffer
end

group "the tui's own state is initialised, so the first turn cannot crash" do
  require_relative "../lib/leve/tui"
  Dir.mktmpdir do |dir|
    model = fake_model(dir, [assistant_text("ok")])
    h, = test_harness(storage: "memory", model: model, cwd: dir,
                                 project: false)
    tui = Leve::InteractiveAgentTUI.new(h, [])
    # A separator before any turn, an expand with nothing to expand, and a
    # claimed echo that was never echoed: each of these read an ivar that used
    # to be nil on the first keystroke.
    %i[turn_separator note_turn].each { |m| tui.send(m) }
    eq "a separator before the first turn is a no-op, not a NoMethodError", true,
       tui.instance_variable_get(:@turns).to_i.positive?
    eq "expanding nothing is safe", true, (tui.expand_last_output || true) && true
    eq "claiming an echo nobody made is false", false, tui.claim_echo("never typed")
    eq "and every collection starts empty, not nil", [[], {}, {}, []],
       %i[@outputs @tool_args @tool_started_at @echoed].map { tui.instance_variable_get(_1) }
    h.close
  end
end

done
