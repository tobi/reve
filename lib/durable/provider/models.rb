# frozen_string_literal: true

require "json"

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

      # "provider/model-id" or just "model-id" (first provider that has it).
      def resolve(config, spec)
        providers = config["providers"] || {}
        if spec.to_s.include?("/")
          pname, mid = spec.split("/", 2)
          pcfg = providers[pname] or return nil
          model = (pcfg["models"] || []).find { _1["id"] == mid } or return nil
          return build(pname, pcfg, model)
        end
        providers.each do |pname, pcfg|
          model = (pcfg["models"] || []).find { _1["id"] == spec }
          return build(pname, pcfg, model) if model
        end
        nil
      end

      def list(config)
        (config["providers"] || {}).flat_map do |pname, pcfg|
          (pcfg["models"] || []).map { build(pname, pcfg, _1) }
        end
      end

      def build(pname, pcfg, model)
        {
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
