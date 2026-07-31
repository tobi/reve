# frozen_string_literal: true

require "json"
require "net/http"
require "uri"

module Durable
  module Provider
    # Model registry. Providers and models are configuration, never live
    # objects: a Ractor gets a JSON hash and can construct everything it needs.
    module Models
      DEFAULT_CONFIG_PATHS = [
        File.expand_path("~/.pi/agent/models.json"),
        File.expand_path("~/.config/rbagent/models.json")
      ].freeze

      module_function

      def load(path = nil)
        paths = path ? [path] : DEFAULT_CONFIG_PATHS
        file = paths.find { File.exist?(_1) }
        return { "providers" => {} } unless file

        JSON.parse(File.read(file))
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
          "apiKey" => pcfg["apiKey"] || (pcfg.dig("env", "apiKeyEnv") && ENV[pcfg.dig("env", "apiKeyEnv")]),
          "reasoning" => !!model["reasoning"],
          "contextWindow" => model["contextWindow"] || 200_000,
          "maxTokens" => model["maxTokens"] || 8192,
          "cost" => model["cost"] || {}
        }
      end
    end
  end
end
