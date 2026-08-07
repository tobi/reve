# frozen_string_literal: true

module Reve
  module Sandbox
    # The sandbox receives credentials only through explicit environment
    # variables. Reve never consults a home-directory credential store, a git
    # helper, or a global CLI configuration.
    module HostAuth
      GITHUB_HOSTS = %w[github.com api.github.com codeload.github.com
                        objects.githubusercontent.com raw.githubusercontent.com].freeze
      ENV_VARS = %w[GITHUB_TOKEN GH_TOKEN GITHUB_API_TOKEN].freeze

      module_function

      # => { "token" =>, "source" => } or nil
      def github_token
        ENV_VARS.each do |var|
          value = ENV[var].to_s
          return { "token" => value, "source" => "$#{var}" } unless value.empty?
        end
        nil
      end


      # The secret entry microsandbox expects: the token is substituted into
      # requests to allow_hosts, so `git clone https://github.com/...` and
      # `curl api.github.com` work while the value never enters the VM.
      def github_secret(placeholder: "reve-github-token")
        found = github_token or return nil

        { "entry" => { "env_var" => "GITHUB_TOKEN", "value" => found["token"],
                       "allow_hosts" => GITHUB_HOSTS, "placeholder" => placeholder },
          "source" => found["source"] }
      end
    end
  end
end
