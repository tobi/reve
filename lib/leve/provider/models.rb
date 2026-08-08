# frozen_string_literal: true

require "json"
require "yaml"
require "net/http"
require "uri"

module Leve
  module Provider
    # Model registry. Providers and models are configuration, never live
    # objects: a Ractor gets a JSON hash and can construct everything it needs.
    #
    # Models are part of the agent directory. There is no home-directory
    # fallback, global config, or machine-wide override.
    module Models
      TEMPLATE = File.expand_path("../../../models.yml", __dir__).freeze
      FILENAME = "models.yml"

      ENV_NAMED = /\A\$[A-Z][A-Z0-9_]*\z/
      BASE_ENV_NAMED = ENV_NAMED

      module_function

      def load(path = nil, root: nil)
        file = path || config_path(config_paths(root))
        return { "providers" => {} } unless file && File.file?(file)

        config = YAML.safe_load(File.read(file), permitted_classes: [], aliases: false) || {}
        validate_references!(config, file)
        config
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

      def live_ids(pcfg, timeout: 2.0, strict: false)
        base = resolve_base_url(pcfg["baseUrl"]).to_s
        if base.empty?
          raise ArgumentError, "baseUrl #{pcfg["baseUrl"].inspect} resolved to an empty value"
        end
        return [] if (pcfg["api"] || "").start_with?("anthropic")

        uri = URI("#{base.chomp("/")}/models")
        unless uri.is_a?(URI::HTTP) && uri.host
          raise ArgumentError, "models endpoint is not HTTP: #{uri}"
        end
        http = Net::HTTP.new(uri.host, uri.port)
        http.use_ssl = uri.scheme == "https"
        http.open_timeout = timeout
        http.read_timeout = timeout
        req = Net::HTTP::Get.new(uri)
        key = resolve_env_named(pcfg["apiKey"].to_s)
        if pcfg["apiKey"].to_s.start_with?("$") && key.empty?
          raise ArgumentError, "apiKey #{pcfg["apiKey"]} is not set in the environment"
        end
        req["authorization"] = "Bearer #{key}" unless key.empty?
        resolve_headers(pcfg).each { |name, value| req[name] = value }
        res = http.request(req)
        unless res.code.to_i == 200
          raise ArgumentError, "GET #{uri} returned HTTP #{res.code} #{res.message}\n" \
                               "Response body (#{res.body.to_s.bytesize} bytes):\n#{res.body}"
        end

        model_ids(JSON.parse(res.body))
      rescue StandardError
        raise if strict

        []
      end

      def model_ids(document)
        rows = if document.is_a?(Array)
                 document
               elsif document.is_a?(Hash)
                 document["data"] || document["models"] || []
               else
                 []
               end
        rows.filter_map do |row|
          row.is_a?(Hash) ? (row["id"] || row["model"] || row["name"]) : row.to_s
        end.reject(&:empty?).uniq
      end

      def catalog(config, probe: true)
        diagnostics = []
        models = (config["providers"] || {}).flat_map do |pname, pcfg|
          configured = pcfg["models"] || []
          live = if probe && !ENV["LEVE_NO_PROBE"]
                   begin
                     live_ids(pcfg, strict: true)
                   rescue StandardError => e
                     diagnostics << { "provider" => pname, "message" => e.message }
                     []
                   end
                 else
                   []
                 end
          configured_by_id = configured.to_h { [_1["id"], _1] }
          combined = configured + live.reject { configured_by_id.key?(_1) }.map { { "id" => _1 } }
          combined.map { build(pname, pcfg, _1) }
        end
        { "models" => models, "diagnostics" => diagnostics }
      end

      # `/model` and `/models` query every configured provider's model-catalog
      # JSON endpoint. Static declarations survive an unavailable endpoint.
      def list(config, probe: true) = catalog(config, probe: probe)["models"]

      def build(pname, pcfg, model)
        {
          "compat" => pcfg["compat"] || {},
          "provider" => pname,
          "modelId" => model["id"],
          "name" => model["name"] || model["id"],
          "api" => pcfg["api"] || "anthropic-messages",
          "baseUrl" => resolve_base_url(pcfg["baseUrl"]),
          "baseUrlSource" => pcfg["baseUrl"],
          "apiKeySource" => pcfg["apiKey"] || pcfg.dig("env", "apiKeyEnv"),
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

      # Environment references are explicit: only `$OPENAI_API_KEY` names ENV.
      def resolve_env_named(value)
        return value unless value.is_a?(String) && value.match?(ENV_NAMED)

        ENV[value.delete_prefix("$")].to_s
      end

      def resolve_base_url(value)
        return value unless value.is_a?(String) && value.match?(BASE_ENV_NAMED)

        ENV[value.delete_prefix("$")].to_s
      end

      def validate_references!(config, file)
        (config["providers"] || {}).each do |provider, provider_config|
          if provider_config.key?("apiKey")
            value = provider_config["apiKey"]
            unless value.is_a?(String) && value.match?(ENV_NAMED)
              raise ArgumentError,
                    "#{file}: provider #{provider.inspect} apiKey must be a $ENV_VAR reference"
            end
          end
          base = provider_config["baseUrl"]
          if base.is_a?(String) && base.match?(/\A[A-Z][A-Z0-9_]*\z/)
            raise ArgumentError,
                  "#{file}: provider #{provider.inspect} baseUrl environment reference must start with $"
          end
        end
      end

      # Header values follow the same explicit-$ convention as apiKey.
      def resolve_headers(pcfg)
        (pcfg["headers"] || {}).each_with_object({}) do |(k, v), out|
          out[k] = resolve_env_named(v)
        end
      end
    end
  end
end
