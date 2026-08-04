# frozen_string_literal: true

require_relative "tools"
require_relative "sandbox/microsandbox"
require_relative "sandbox/host_auth"

module Durable
  # Every agent has a sandbox — the place its commands actually run.
  #
  # eve's model: `sandbox/sandbox.rb` swaps the backend or customises the setup,
  # and the rest of the agent does not care. Here the backend is one of:
  #
  #   microsandbox  a local microVM (hardware isolation), via the C ABI
  #   local         the host itself; correct for a coding agent working on your
  #                 checkout, and honest about giving no isolation
  #   auto          microsandbox when its library is installed, local otherwise
  #                 — the default, so a plain checkout works and a machine with
  #                 microVMs gets them without being asked twice
  #
  # The sandbox lives in the host Ractor: it holds a live connection, so tools
  # that need it are dispatched there instead of into a tool Ractor.
  module Sandbox
    # A sandbox nobody has to configure: debian plus the tools an agent reaches
    # for on its first turn. mise supplies the language runtimes (and is
    # activated in /etc/profile.d, so `sh -lc` picks it up like a login shell).
    APT_PACKAGES = %w[ca-certificates curl git build-essential jq unzip
                      ripgrep fd-find file less].freeze
    # mise supplies what apt does not: the runtimes, plus gh and ast-grep, both
    # of which come from GitHub releases — which the egress policy already
    # allows, because that is the one place it allows.
    MISE_TOOLS = %w[node@lts gh ast-grep].freeze

    DEFAULTS = Ractor.make_shareable({
      "backend" => "auto",
      "image" => "debian:trixie-slim",
      "cpus" => 2,
      "memory" => 2048,
      "name" => nil,
      "workdir" => "/workspace",
      "mountWorkspace" => true,
      "provision" => true,
      "packages" => APT_PACKAGES,
      "mise" => MISE_TOOLS,
      # Egress is deny-by-default. The agent gets github.com and nothing else
      # until someone says otherwise — an agent that can reach the whole
      # internet is an agent that can exfiltrate the whole workspace.
      "allowHosts" => HostAuth::GITHUB_HOSTS,
      "allowAll" => false,
      # Provisioning needs package mirrors. They are allowed only because
      # provisioning is enabled; turn it off (or bake an image) and the policy
      # is github-only.
      "provisionHosts" => %w[deb.debian.org security.debian.org ftp.debian.org
                             mise.run mise.jdx.dev registry.npmjs.org nodejs.org
                             github.com objects.githubusercontent.com],
      "githubAuth" => true,
      "secrets" => [],
      "bootstrap" => [],
      "env" => { "DEBIAN_FRONTEND" => "noninteractive", "MISE_YES" => "1" }
    })

    module_function

    # The provisioning script. It runs once per named sandbox (guarded by a
    # marker file) and is a single shell command so one exec covers it, keeping
    # the boot path short.
    PROVISION_MARKER = "/var/lib/rbagent/provisioned"

    # The create options, in microsandbox's wire shape (memory_mib, volumes as a
    # map, network policy, secrets).
    def create_options(config, host_workspace, workdir)
      opts = {
        "image" => config["image"],
        "cpus" => config["cpus"],
        "memory_mib" => config["memory"],
        "workdir" => workdir,
        "env" => config["env"] || {}
      }
      if config["mountWorkspace"]
        opts["volumes"] = { workdir => { "bind" => host_workspace } }
      end
      network = network_options(config)
      opts["network"] = network unless network.empty?
      secrets = secret_entries(config)
      opts["secrets"] = secrets unless secrets.empty?
      opts.compact
    end

    # Deny-by-default egress with an explicit allowlist. DNS has to be open for
    # names to resolve at all, which is why microsandbox has a helper for it —
    # here it is two rules, spelled out.
    def network_options(config)
      return {} if config["allowAll"]

      hosts = (config["allowHosts"] || []).dup
      hosts.concat(config["provisionHosts"] || []) if config["provision"]
      rules = [
        { "action" => "allow", "direction" => "egress", "destination_kind" => "group",
          "destination" => "dns", "protocol" => "udp", "port" => "53" },
        { "action" => "allow", "direction" => "egress", "destination_kind" => "group",
          "destination" => "dns", "protocol" => "tcp", "port" => "53" }
      ]
      hosts.uniq.each do |host|
        rules << { "action" => "allow", "direction" => "egress", "destination_kind" => "domain",
                   "destination" => host, "protocol" => "tcp", "port" => "443" }
        rules << { "action" => "allow", "direction" => "egress", "destination_kind" => "domain",
                   "destination" => host, "protocol" => "tcp", "port" => "80" }
      end
      { "custom_policy" => { "rules" => rules } }
    end

    # Host credentials the VM may use but never see.
    def secret_entries(config)
      entries = (config["secrets"] || []).reject { _1["value"].to_s.empty? }
      if config["githubAuth"] && (gh = HostAuth.github_secret)
        entries = [gh["entry"]] + entries
      end
      entries
    end

    def provision_script(config)
      packages = (config["packages"] || []).join(" ")
      tools = (config["mise"] || []).join(" ")
      <<~SH.strip
        set -e
        [ -f #{PROVISION_MARKER} ] && exit 0
        mkdir -p /var/lib/rbagent
        if command -v apt-get > /dev/null; then
          apt-get update -qq
          apt-get install -y --no-install-recommends #{packages} > /dev/null
          # debian ships fd as fdfind; agents type fd
          [ -x /usr/bin/fdfind ] && ln -sf /usr/bin/fdfind /usr/local/bin/fd || true
        fi
        if ! command -v mise > /dev/null; then
          curl -fsSL https://mise.run | MISE_INSTALL_PATH=/usr/local/bin/mise sh
        fi
        # Shims first: they work in dash, which is /bin/sh here, so every
        # `sh -lc` the agent runs already has the runtimes on PATH. The eval is
        # for interactive bash sessions.
        cat > /etc/profile.d/10-mise.sh <<'PROFILE'
        export PATH="/usr/local/bin:$HOME/.local/share/mise/shims:$PATH"
        [ -n "$BASH_VERSION" ] && command -v mise > /dev/null && eval "$(mise activate bash)"
        PROFILE
        sed -i 's/^        //' /etc/profile.d/10-mise.sh
        chmod +x /etc/profile.d/10-mise.sh
        . /etc/profile.d/10-mise.sh
        #{tools.empty? ? "" : "mise use -g #{tools} > /dev/null"}
        touch #{PROVISION_MARKER}
      SH
    end

    def config(overrides = nil) = DEFAULTS.merge(stringify(overrides || {}))

    def stringify(h)
      h.each_with_object({}) { |(k, v), acc| acc[k.to_s] = v }
    end

    # The DSL for sandbox/sandbox.rb:
    #
    #   sandbox do
    #     backend :microsandbox
    #     image "python:3.12"
    #     cpus 2
    #     memory 2048
    #     bootstrap "pip install -r requirements.txt"
    #   end
    class Definition
      ATTRIBUTES = %w[backend image cpus memory name workdir].freeze

      def initialize
        @config = {}
        @bootstrap = []
        @env = {}
      end

      # apt packages and mise tools on top of (or instead of) the defaults.
      def packages(*names) = @config["packages"] = names.flatten.map(&:to_s)
      def mise(*tools) = @config["mise"] = tools.flatten.map(&:to_s)
      def provision(flag) = @config["provision"] = !!flag

      # Network. `allow` adds hosts to the deny-by-default egress policy;
      # `allow_all` opts out of it entirely and says so in the UI.
      def allow(*hosts)
        (@allow ||= []).concat(hosts.flatten.map(&:to_s))
      end

      def allow_all(flag = true) = @config["allowAll"] = !!flag
      def github_auth(flag) = @config["githubAuth"] = !!flag

      # A host credential the sandbox may use without holding it: the value
      # stays outside the VM and is injected into requests to `hosts`.
      def secret(env_var, hosts: [], value: nil)
        (@secrets ||= []) << { "env_var" => env_var.to_s,
                               "value" => value || ENV[env_var.to_s].to_s,
                               "allow_hosts" => Array(hosts).map(&:to_s) }
      end

      ATTRIBUTES.each do |attr|
        define_method(attr) { |value| @config[attr] = value.is_a?(Symbol) ? value.to_s : value }
      end

      def mount_workspace(flag) = @config["mountWorkspace"] = !!flag
      def env(key, value) = @env[key.to_s] = value.to_s
      def bootstrap(*commands) = @bootstrap.concat(commands.flatten.map(&:to_s))
      def disabled = @config["backend"] = "local"

      def to_config
        cfg = @config.merge("bootstrap" => @bootstrap, "env" => @env)
        cfg["allowHosts"] = (DEFAULTS["allowHosts"] + @allow).uniq if @allow
        cfg["secrets"] = @secrets if @secrets
        cfg
      end
    end

    def load_definition(path)
      d = Definition.new
      body = File.read(path)
      # `sandbox do … end` at the top level of the file.
      d.instance_eval do
        def sandbox(&blk) = instance_eval(&blk)
      end
      d.instance_eval(body, path)
      d.to_config
    end

    # One interface, whichever backend is underneath.
    class Client
      attr_reader :config, :backend_name

      def initialize(vm, config)
        @vm = vm
        @config = config
        @backend_name = vm ? "microsandbox" : "local"
        @provisioned = false
        @started = false
        @mutex = Mutex.new
      end

      def isolated? = !@vm.nil?

      # Stable per workspace, so a second launch reuses the provisioned VM
      # instead of installing the toolchain again.
      def sandbox_name
        @config["name"] || "rbagent-#{File.basename(host_workspace).gsub(/[^a-zA-Z0-9_-]/, "-")}"
      end
      def workdir = @config["workdir"] || "/workspace"
      def host_workspace = @config["hostWorkspace"] || Dir.pwd

      # Boot the VM (idempotent) and run the bootstrap commands once.
      def start
        return self if @started || @vm.nil?

        @mutex.synchronize do
          return self if @started

          @vm.create(sandbox_name, Sandbox.create_options(@config, host_workspace, workdir))
          @started = true
          provision! if @config["provision"]
          (@config["bootstrap"] || []).each { |cmd| exec(cmd) }
        end
        self
      end

      # => { "stdout", "stderr", "exitCode" }
      def exec(command, timeout: 120, cancel: nil)
        if @vm
          start
          @vm.exec("sh", args: ["-lc", command], cwd: workdir, timeout: timeout, cancel: cancel)
        else
          r = Tools.exec_stream(command, host_workspace, timeout: timeout.to_f, cancel: cancel)
          { "stdout" => r["output"], "stderr" => "", "exitCode" => r["exitCode"],
            "cancelled" => r["cancelled"] }
        end
      end

      # Install the default toolchain, once per sandbox. Failure is reported but
      # not fatal: an agent with a bare debian is still an agent.
      def provision!
        return if @provisioned

        @provisioned = true
        script = Sandbox.provision_script(@config)
        r = @vm.exec("sh", args: ["-lc", script], cwd: "/", timeout: 900)
        return if r["exitCode"].zero?

        warn "\e[33m sandbox provisioning failed (exit #{r["exitCode"]}): " \
             "#{r["stderr"].to_s.lines.last(3).join.strip}\e[0m"
      rescue StandardError => e
        warn "\e[33m sandbox provisioning failed: #{e.message}\e[0m"
      end

      def read_file(path)
        @vm ? (start && @vm.read_file(absolute(path))) : File.read(File.expand_path(path, host_workspace))
      end

      def write_file(path, content)
        if @vm
          start
          @vm.write_file(absolute(path), content)
        else
          full = File.expand_path(path, host_workspace)
          FileUtils.mkdir_p(File.dirname(full))
          File.write(full, content)
        end
      end

      def absolute(path) = path.to_s.start_with?("/") ? path.to_s : File.join(workdir, path.to_s)

      def stop
        @vm&.stop
        @started = false
      rescue StandardError
        nil
      end

      def describe
        if @vm
          extras = []
          extras << "provisioned" if @config["provision"]
          extras << "mise #{(@config["mise"] || []).join(",")}" unless (@config["mise"] || []).empty?
          extras << (@config["allowAll"] ? "network open" : "net #{(@config["allowHosts"] || []).size} hosts")
          "microsandbox #{@config["image"]} (#{@config["cpus"]} cpu, #{@config["memory"]}MB" \
            "#{extras.empty? ? "" : ", #{extras.join(", ")}"}) → #{workdir}"
        else
          "local (no isolation) → #{host_workspace}"
        end
      end
    end

    # Resolve what the project asked for against what this machine can do, and
    # say so rather than silently degrading. "auto" is allowed to be quiet: it
    # never promised a microVM. Asking for one explicitly and not getting it is
    # worth a warning.
    def resolve(config, warn_io: $stderr)
      cfg = config(config)
      wanted = cfg["backend"]
      return Client.new(nil, cfg) if wanted == "local"

      begin
        Client.new(Microsandbox.new, cfg.merge("backend" => "microsandbox"))
      rescue Microsandbox::NotAvailable => e
        if wanted == "microsandbox"
          warn_io&.puts("\e[33m sandbox: #{e.message} — falling back to local execution (no isolation)\e[0m")
        end
        Client.new(nil, cfg.merge("backend" => "local", "fallbackReason" => e.message))
      end
    end
  end
end
