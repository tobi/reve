# frozen_string_literal: true

module Durable
  module Sandbox
    # The sandbox needs to reach github.com as *you*, without holding your
    # token. This finds the credential on the host, in the order a developer
    # would expect, and hands it to the sandbox as a microsandbox secret: the
    # value stays on the host and its proxy injects it into requests to the
    # allowed hosts only. The VM sees a placeholder.
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
        if (token = gh_cli_token)
          return { "token" => token, "source" => "gh auth token" }
        end
        if (token = git_credential_token)
          return { "token" => token, "source" => "git credential helper" }
        end

        nil
      end

      def gh_cli_token
        return nil unless which("gh")

        out = capture(["gh", "auth", "token"], timeout: 5)
        out && !out.strip.empty? ? out.strip : nil
      end

      # git's credential helper protocol: ask, do not store.
      def git_credential_token
        return nil unless which("git")

        out = capture(["git", "credential", "fill"], stdin: "protocol=https\nhost=github.com\n\n", timeout: 5)
        return nil unless out

        password = out.lines.map(&:chomp).find { _1.start_with?("password=") }
        password ? password.delete_prefix("password=") : nil
      end

      def which(cmd)
        ENV["PATH"].to_s.split(File::PATH_SEPARATOR).any? do |dir|
          path = File.join(dir, cmd)
          File.file?(path) && File.executable?(path)
        end
      end

      def capture(argv, stdin: nil, timeout: 5)
        r, w = IO.pipe
        in_r, in_w = IO.pipe
        pid = Process.spawn(*argv, out: w, err: File::NULL, in: in_r)
        w.close
        in_r.close
        in_w.write(stdin) if stdin
        in_w.close
        out = +""
        deadline = Time.now + timeout
        while Time.now < deadline
          break unless IO.select([r], nil, nil, 0.2)

          begin
            out << r.readpartial(4096)
          rescue EOFError
            break
          end
        end
        begin
          Process.kill("KILL", pid) if Process.waitpid(pid, Process::WNOHANG).nil?
        rescue StandardError
          nil
        end
        begin
          Process.waitpid(pid)
        rescue StandardError
          nil
        end
        r.close
        out
      rescue StandardError
        nil
      end

      # The secret entry microsandbox expects: the token is substituted into
      # requests to allow_hosts, so `git clone https://github.com/...` and
      # `curl api.github.com` work while the value never enters the VM.
      def github_secret(placeholder: "rbagent-github-token")
        found = github_token or return nil

        { "entry" => { "env_var" => "GITHUB_TOKEN", "value" => found["token"],
                       "allow_hosts" => GITHUB_HOSTS, "placeholder" => placeholder },
          "source" => found["source"] }
      end
    end
  end
end
