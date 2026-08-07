# frozen_string_literal: true

require "json"
require "yaml"
require "net/http"
require "uri"

module Reve
  module Provider
    # Model registry. Providers and models are configuration, never live
    # objects: a Ractor gets a JSON hash and can construct everything it needs.
    #
    # Models are part of the agent directory. There is no home-directory
    # fallback, global config, or machine-wide override.
    module Models
      TEMPLATE = File.expand_path("../../../models.yml", __dir__).freeze
      FILENAME = "models.yml"

      ENV_NAMED = /\A\$?[A-Z][A-Z0-9_]*\z/

      module_function

      def load(path = nil, root: nil)
        file = path || config_path(config_paths(root))
        return { "providers" => {} } unless file && File.file?(file)

        YAML.safe_load(File.read(file), permitted_classes: [], aliases: false) || {}
      end

      def config_paths(root = nil)
        [root && File.join(File.expand_path(root), FILENAME)].compact
      end

      def template
        File.file?(TEMPLATE) ? File.read(TEMPLATE) : "providers: {}\n"
      end

      # First existing path wins. The only candidate is inside the agent.
      def config_path(paths = nil)
        (paths || config_paths).find { File.file?(_1) }
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
        base = resolve_env_named(pcfg["baseUrl"]).to_s
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
        resolve_headers(pcfg).each { |name, value| req[name] = value }
        res = http.request(req)
        return [] unless res.code.to_i == 200

        (JSON.parse(res.body)["data"] || []).map { _1["id"] }.compact
      rescue StandardError
        []
      end

      # Configured models are listed immediately. Providers with no local list
      # are queried at `/models`, which is the common OpenAI-compatible
      # discovery endpoint. A failed probe is harmless and leaves the list empty.
      def list(config, probe: true)
        (config["providers"] || {}).flat_map do |pname, pcfg|
          configured = pcfg["models"] || []
          models = configured
          if models.empty? && probe && !ENV["REVE_NO_PROBE"]
            models = live_ids(pcfg).map { { "id" => _1 } }
          end
          models.map { build(pname, pcfg, _1) }
        end
      end

      def build(pname, pcfg, model)
        {
          "compat" => pcfg["compat"] || {},
          "provider" => pname,
          "modelId" => model["id"],
          "name" => model["name"] || model["id"],
          "api" => pcfg["api"] || "anthropic-messages",
          "baseUrl" => resolve_env_named(pcfg["baseUrl"]),
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

      # A value that looks like an env-var name is one. `$OPENAI_API_KEY` and
      # `OPENAI_API_KEY` both name ENV["OPENAI_API_KEY"].
      def resolve_env_named(value)
        return value unless value.is_a?(String) && value.match?(ENV_NAMED)

        ENV[value.delete_prefix("$")].to_s
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
