# frozen_string_literal: true

require_relative "helper"
include TestKit

M = Reve::Provider::Models

group "models.yml belongs to the agent directory" do
  Dir.mktmpdir do |root|
    eq "config paths stay inside the agent", [File.join(root, "models.yml")], M.config_paths(root)
    eq "missing models are empty", { "providers" => {} }, M.load(root: root)

    result = Reve::Project.init(root, name: "portable")
    eq "init writes models.yml", true, result["created"].include?("models.yml")
    eq "models.yml is inside the agent", true, File.file?(File.join(root, "models.yml"))
    config = M.load(root: root)
    eq "the copied template has active providers",
       %w[llamacpp openai], config.fetch("providers").keys.sort
    eq "OpenAI's default model is explicit", "gpt-5.6-luna",
       config.dig("providers", "openai", "models", 0, "id")
    eq "llama.cpp uses explicit-$ environment references", ["$LLAMA_CPP_BASE", "$LLAMA_API_KEY"],
       [config.dig("providers", "llamacpp", "baseUrl"), config.dig("providers", "llamacpp", "apiKey")]
  end
end

group "explicit config is local and deterministic" do
  Dir.mktmpdir do |root|
    explicit = File.join(root, "fixture.yml")
    File.write(explicit, <<~YAML)
      providers:
        local:
          api: openai-responses
          baseUrl: http://127.0.0.1:9999/v1
          models:
            - id: tiny
              contextWindow: 1234
              maxTokens: 55
    YAML
    eq "a differently named file is not discovered", nil, M.config_path(M.config_paths(root))
    model = M.resolve(M.load(explicit), "local/tiny", probe: false)
    eq "explicit config resolves", ["local", "tiny", 1234],
       [model["provider"], model["modelId"], model["contextWindow"]]
    eq "explicit path is parsed", "http://127.0.0.1:9999/v1", M.load(explicit).dig("providers", "local", "baseUrl")
  end
end

group "/model catalog discovery queries every provider" do
  calls = []
  original = M.method(:live_ids)
  no_probe = ENV.delete("REVE_NO_PROBE")
  M.define_singleton_method(:live_ids) do |provider, **_options|
    calls << provider["baseUrl"]
    ["live-model"]
  end
  cfg = { "providers" => { "endpoint" => {
    "api" => "openai-responses", "baseUrl" => "https://models.example/v1",
    "models" => [{ "id" => "configured-model" }]
  } } }
  found = M.list(cfg, probe: true).map { _1["modelId"] }
  eq "the configured endpoint is queried", ["https://models.example/v1"], calls
  eq "live ids augment configured ids", %w[configured-model live-model], found
  eq "OpenAI data JSON is parsed", ["a"], M.model_ids({ "data" => [{ "id" => "a" }] })
  eq "models JSON accepts id, model, name and strings", %w[a b c d],
     M.model_ids({ "models" => [{ "id" => "a" }, { "model" => "b" }, { "name" => "c" }, "d"] })
ensure
  ENV["REVE_NO_PROBE"] = no_probe if no_probe
  M.define_singleton_method(:live_ids, original)
end

group "missing and unknown choices fail locally" do
  eq "missing explicit file is graceful", { "providers" => {} }, M.load("/definitely/missing.yml")
  cfg = { "providers" => { "fake" => { "api" => "fake", "models" => [{ "id" => "one" }] } } }
  eq "unknown provider/model is nil", nil, M.resolve(cfg, "missing/nope", probe: false)
  eq "listing is configuration only", [["fake", "one"]], M.list(cfg).map { [_1["provider"], _1["modelId"]] }
end

group "provider URLs, API keys and headers resolve only through model construction" do
  ENV["REVE_TEST_BASE"] = "http://resolved.invalid/v1"
  ENV["REVE_TEST_KEY"] = "resolved-key"
  ENV["REVE_TEST_HEADER"] = "resolved-header"
  config = { "providers" => { "test" => {
    "api" => "openai-responses",
    "baseUrl" => "$REVE_TEST_BASE",
    "apiKey" => "$REVE_TEST_KEY",
    "headers" => { "X-Resolved" => "$REVE_TEST_HEADER", "X-Literal" => "literal" },
    "models" => [{ "id" => "tiny" }]
  } } }
  model = M.resolve(config, "test/tiny", probe: false)
  eq "base URL resolves", "http://resolved.invalid/v1", model["baseUrl"]
  eq "api key resolves", "resolved-key", model["apiKey"]
  eq "env header resolves", "resolved-header", model.dig("headers", "X-Resolved")
  eq "literal header remains literal", "literal", model.dig("headers", "X-Literal")
  eq "missing env name becomes empty", "", M.resolve({ "providers" => { "x" => {
    "apiKey" => "$REVE_MISSING_KEY", "models" => [{ "id" => "m" }]
  } } }, "x/m", probe: false)["apiKey"]
  eq "literal key remains literal for programmatic configuration", "sk-literal", M.resolve({ "providers" => { "x" => {
    "apiKey" => "sk-literal", "models" => [{ "id" => "m" }]
  } } }, "x/m", probe: false)["apiKey"]
end

group "models.yml requires explicit dollar-prefixed environment references" do
  Dir.mktmpdir do |root|
    path = File.join(root, "models.yml")
    File.write(path, "providers:\n  bad:\n    baseUrl: API_BASE\n    apiKey: API_KEY\n")
    error = begin
      M.load(path)
      nil
    rescue ArgumentError => e
      e.message
    end
    eq "bare API key names are rejected", true, error.include?("apiKey must be a $ENV_VAR")

    File.write(path, "providers:\n  bad:\n    baseUrl: API_BASE\n    apiKey: $API_KEY\n")
    error = begin
      M.load(path)
      nil
    rescue ArgumentError => e
      e.message
    end
    eq "bare base URL names are rejected", true, error.include?("baseUrl environment reference must start with $")

    File.write(path, "providers:\n  bad:\n    baseUrl: https://example.test/v1\n    apiKey: $(cat /tmp/key)\n")
    error = begin
      M.load(path)
      nil
    rescue ArgumentError => e
      e.message
    end
    eq "shell substitutions are never executed", true, error.include?("apiKey must be a $ENV_VAR")
  end
end

done
