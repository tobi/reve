# frozen_string_literal: true

require "json"
require "yaml"
require "net/http"
require "uri"

module Durable
  module Provider
    # Model registry. Providers and models are configuration, never live
    # objects: a Ractor gets a JSON hash and can construct everything it needs.
    #
    # Config is YAML (models.yml). Source order: a user override file, then the
    # bundled models.yml in the repo root — so the agent is self-contained and
    # works with no user configuration at all. A legacy .json file is still read
    # if it exists (YAML parses it too).
    #
    # omp-style env resolution: a string value in `apiKey` or in `headers`
    # that is an all-caps identifier (e.g. PI_PROXY_API_KEY) names an
    # environment variable and is resolved at build time. A value that is already a
    # literal key passes through untouched.
    module Models
      DEFAULT_CONFIG_PATHS = [
        File.expand_path("~/.agent/models.yml"),
        File.expand_path("~/.config/rbagent/models.yml"),
        File.expand_path("~/.config/rbagent/models.json"),
        File.expand_path("../../../models.yml", __dir__)
      ].freeze

      ENV_NAMED = /\A[A-Z][A-Z0-9_]*\z/

      module_function

      def load(path = nil)
        file = path || config_path
        return { "providers" => {} } unless file && File.exist?(file)

        YAML.safe_load(File.read(file), permitted_classes: [], aliases: false) || {}
      end

      # First existing path wins. Exposed for tests: the precedence order is
      # deterministic, so it can be checked without touching a real home.
      def config_path(paths = nil)
        (paths || DEFAULT_CONFIG_PATHS).find { File.exist?(_1) }
      end

      # Accepts "provider/model-id", "model-id", or just "provider" — the last
      # form asks the provider what it is serving right now (an inference
      # server that got restarted with a different checkpoint is normal), and
      # falls back to the configured list when it cannot be reached.
      def resolve(config, spec, probe: true)
        providers = config["providers"] || {}
        spec = spec.to_s
        if spec.include?("/")
          pname, mid = spec.split("/", 2)
          pcfg = providers[pname] or return nil
          model = (pcfg["models"] || []).find { _1["id"] == mid }
          return model ? build(pname, pcfg, model) : build(pname, pcfg, { "id" => mid })
        end
        if (pcfg = providers[spec])
          return resolve_provider(spec, pcfg, probe: probe)
        end

        providers.each do |pname, pc|
          model = (pc["models"] || []).find { _1["id"] == spec }
          return build(pname, pc, model) if model
        end
        nil
      end

      # What is this endpoint serving? Ask it; keep the configured entry for
      # the metadata (context window, costs) when the ids line up.
      def resolve_provider(pname, pcfg, probe: true)
        configured = (pcfg["models"] || [])
        live = probe ? live_ids(pcfg) : []
        chosen =
          if live.empty?
            configured.first
          else
            configured.find { live.include?(_1["id"]) } || { "id" => live.first }
          end
        return nil unless chosen

        build(pname, pcfg, chosen)
      end

      def live_ids(pcfg, timeout: 2.0)
        base = pcfg["baseUrl"].to_s
        return [] if base.empty? || (pcfg["api"] || "").start_with?("anthropic")

        uri = URI("#{base.chomp("/")}/models")
        http = Net::HTTP.new(uri.host, uri.port)
        http.use_ssl = uri.scheme == "https"
        http.open_timeout = timeout
        http.read_timeout = timeout
        req = Net::HTTP::Get.new(uri)
        key = pcfg["apiKey"].to_s
        key = resolve_env_named(key)
        req["authorization"] = "Bearer #{key}" unless key.empty?
        res = http.request(req)
        return [] unless res.code.to_i == 200

        (JSON.parse(res.body)["data"] || []).map { _1["id"] }.compact
      rescue StandardError
        []
      end

      def list(config)
        (config["providers"] || {}).flat_map do |pname, pcfg|
          (pcfg["models"] || []).map { build(pname, pcfg, _1) }
        end
      end

      def build(pname, pcfg, model)
        {
          "compat" => pcfg["compat"] || {},
          "provider" => pname,
          "modelId" => model["id"],
          "name" => model["name"] || model["id"],
          "api" => pcfg["api"] || "anthropic-messages",
          "baseUrl" => pcfg["baseUrl"],
          "apiKey" => resolve_env_named(
            pcfg["apiKey"] || (pcfg.dig("env", "apiKeyEnv") && ENV[pcfg.dig("env", "apiKeyEnv")])
          ),
          "headers" => resolve_headers(pcfg),
          "reasoning" => !!model["reasoning"],
          "contextWindow" => model["contextWindow"] || 200_000,
          "maxTokens" => model["maxTokens"] || 8192,
          "cost" => model["cost"] || {}
        }
      end

      # A value that looks like an env-var name is one (omp convention).
      # Anything else — a literal key, a shell-expanded string — passes through.
      # An unresolved or empty name resolves to "", which providers read as "no
      # auth": vLLM's local endpoint is configured with `apiKey: EMPTY`.
      def resolve_env_named(value)
        value.is_a?(String) && value.match?(ENV_NAMED) ? ENV[value].to_s : value
      end

      # Header values follow the same convention as apiKey.
      def resolve_headers(pcfg)
        (pcfg["headers"] || {}).each_with_object({}) do |(k, v), out|
          out[k] = resolve_env_named(v)
        end
      end
    end
  end
end
