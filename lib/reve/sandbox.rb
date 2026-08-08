# frozen_string_literal: true

require "fileutils"
require "json"
require "digest"
require_relative "sandbox/microsandbox"
require_relative "sandbox/host_auth"

module Reve
  # Every agent has a sandbox — the place its commands actually run.
  #
  # Agent-root `sandbox.rb` customises one mandatory backend: microsandbox-rb's
  # embedded microVM runtime. There is no local mode and no fallback. If the gem
  # or runtime cannot start, the agent refuses to execute model-authored code.
  #
  # The sandbox lives in the host Ractor: it holds a live connection, so tools
  # that need it are dispatched there instead of into a tool Ractor.
  module Sandbox
    # A sandbox nobody has to configure: debian plus the tools an agent reaches
    # for on its first turn. mise supplies the language runtimes (and is
    # activated in /etc/profile.d, so `sh -lc` picks it up like a login shell).
    APT_PACKAGES = %w[ca-certificates curl git gh build-essential jq unzip
                      ripgrep fd-find file less].freeze
    # gh comes from Debian and Node from mise. ast-grep stays on npm because
    # mise's aqua backend queries GitHub's rate-limited releases API even for
    # pinned versions; npm needs no implicit GitHub credential.
    MISE_TOOLS = %w[node@lts].freeze
    NPM_TOOLS = %w[@ast-grep/cli].freeze

    DEFAULTS = Ractor.make_shareable({
      "backend" => "microsandbox",
      "image" => "debian:trixie-slim",
      "cpus" => 2,
      "memory" => 2048,
      "security" => "restricted",
      "name" => nil,
      "workdir" => "/workspace",
      "mountWorkspace" => true,
      "provision" => true,
      "packages" => APT_PACKAGES,
      "mise" => MISE_TOOLS,
      "npm" => NPM_TOOLS,
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
      "githubAuth" => false,
      "secrets" => [],
      "bootstrap" => [],
      "env" => { "DEBIAN_FRONTEND" => "noninteractive", "MISE_YES" => "1" }
    })

    module_function

    # The provisioning script. It runs once per named sandbox (guarded by a
    # marker file) and is a single shell command so one exec covers it, keeping
    # the boot path short.
    PROVISION_MARKER = "/var/lib/reve/provisioned"

    # The create options, in microsandbox's wire shape (memory_mib, volumes as a
    # map, network policy, secrets).
    def create_options(config, host_workspace, workdir)
      opts = {
        "image" => config["image"],
        "cpus" => config["cpus"],
        "memory_mib" => config["memory"],
        "workdir" => workdir,
        "security" => config["security"],
        "env" => config["env"] || {}
      }
      if config["mountWorkspace"]
        # A bind mount, explicitly: the guest writes straight through to the
        # host directory (that is the point — you can read the work afterwards),
        # with nosuid/nodev because nothing in a workspace needs either.
        opts["volumes"] = {
          workdir => { "bind" => host_workspace, "readonly" => false,
                       "nosuid" => true, "nodev" => true }
        }
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
      # microsandbox-rb's public Rule.allow_dns shape: DNS is the sandbox
      # gateway (`host`), UDP+TCP port 53. `dns` is not a destination group in
      # the runtime wire format.
      rules = [
        { "action" => "allow", "direction" => "egress", "destination_kind" => "group",
          "destination" => "host", "protocols" => %w[udp tcp], "ports" => ["53"] }
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
      npm_tools = (config["npm"] || []).join(" ")
      <<~SH.strip
        set -e
        [ -f #{PROVISION_MARKER} ] && exit 0
        mkdir -p /var/lib/reve
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
        [ -n "$BASH_VERSION" ] && command -v mise > /dev/null && eval "$(mise activate bash)" || true
        PROFILE
        sed -i 's/^        //' /etc/profile.d/10-mise.sh
        chmod +x /etc/profile.d/10-mise.sh
        . /etc/profile.d/10-mise.sh
        #{tools.empty? ? "" : "mise use -g #{tools} > /dev/null"}
        #{npm_tools.empty? ? "" : "npm install -g #{npm_tools} > /dev/null"}
        touch #{PROVISION_MARKER}
      SH
    end

    def config(overrides = nil) = DEFAULTS.merge(stringify(overrides || {}))

    def stringify(h)
      h.each_with_object({}) { |(k, v), acc| acc[k.to_s] = v }
    end

    # The DSL for an agent's ./sandbox.rb:
    #
    #   sandbox do
    #     backend :microsandbox
    #     image "python:3.12"
    #     cpus 2
    #     memory 2048
    #     bootstrap "pip install -r requirements.txt"
    #   end
    class Definition
      ATTRIBUTES = %w[image cpus memory security name workdir].freeze

      def initialize
        @config = {}
        @bootstrap = []
        @env = {}
      end

      # apt packages and mise tools on top of (or instead of) the defaults.
      def packages(*names) = @config["packages"] = names.flatten.map(&:to_s)
      def mise(*tools) = @config["mise"] = tools.flatten.map(&:to_s)
      def npm(*tools) = @config["npm"] = tools.flatten.map(&:to_s)
      def provision(flag) = @config["provision"] = !!flag

      # Network. `allow` adds hosts to the deny-by-default egress policy;
      # `allow_all` opts out of it entirely and says so in the UI.
      def allow(*hosts, &block)
        names = hosts.flatten.map(&:to_s)
        (@allow ||= []).concat(names)
        return names unless block

        previous = @secret_scope
        @secret_scope = names
        instance_eval(&block)
      ensure
        @secret_scope = previous if block
      end

      def allow_all(flag = true) = @config["allowAll"] = !!flag
      def github_auth(flag) = @config["githubAuth"] = !!flag

      # A host credential the sandbox may use without holding it: the value
      # stays outside the VM and is injected into requests to `hosts`.
      def secret(env_var, hosts: nil, value:, placeholder: nil)
        scoped_hosts = hosts.nil? ? Array(@secret_scope) : Array(hosts).map(&:to_s)
        raise ArgumentError, "secret #{env_var} requires at least one host" if scoped_hosts.empty?
        raise ArgumentError, "secret #{env_var} requires a non-empty value" if value.to_s.empty?

        entry = { "env_var" => env_var.to_s, "value" => value.to_s,
                  "allow_hosts" => scoped_hosts }
        entry["placeholder"] = placeholder.to_s unless placeholder.to_s.empty?
        (@secrets ||= []) << entry
      end

      ATTRIBUTES.each do |attr|
        define_method(attr) { |value| @config[attr] = value.is_a?(Symbol) ? value.to_s : value }
      end

      def mount_workspace(flag) = @config["mountWorkspace"] = !!flag
      def env(key, value) = @env[key.to_s] = value.to_s
      def bootstrap(*commands) = @bootstrap.concat(commands.flatten.map(&:to_s))

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

    # Startup happens before the TUI exists, so long image pulls and first-time
    # provisioning need their own small renderer instead of looking hung.
    class Progress
      FRAMES = %w[⠋ ⠙ ⠹ ⠸ ⠼ ⠴ ⠦ ⠧ ⠇ ⠏].freeze

      def initialize(io)
        @io = io
        @mutex = Mutex.new
      end

      def stage(label)
        return unless @io&.tty?

        @mutex.synchronize do
          @label = label
          @started ||= Process.clock_gettime(Process::CLOCK_MONOTONIC)
          next if @thread&.alive?

          @stop = false
          @thread = Thread.new do
            index = 0
            until @stop
              current = @mutex.synchronize { @label }
              @io.print("\r\e[2K#{FRAMES[index % FRAMES.size]} #{current}")
              @io.flush
              index += 1
              sleep 0.08
            end
          end
        end
      end

      def finish(label = "sandbox ready") = settle("\e[32m✓\e[0m", label)
      def fail(label) = settle("\e[31m✗\e[0m", label)

      def settle(mark, label)
        return unless @io&.tty?

        @stop = true
        @thread&.join(0.3)
        elapsed = @started && Process.clock_gettime(Process::CLOCK_MONOTONIC) - @started
        suffix = elapsed ? " (#{elapsed.round(1)}s)" : ""
        @io.puts("\r\e[2K#{mark} #{label}#{suffix}")
        @io.flush
        @thread = nil
        @started = nil
      end
    end

    # One interface, whichever backend is underneath.
    class Client
      attr_reader :config, :backend_name

      def initialize(vm, config, progress: nil)
        raise ArgumentError, "a microsandbox runtime is required" unless vm

        @vm = vm
        @config = config
        @backend_name = "microsandbox-rb"
        @progress = progress
        @provisioned = false
        @started = false
        @mutex = Mutex.new
      end

      def isolated? = true

      # Stable per workspace, so a second launch reuses the provisioned VM
      # instead of installing the toolchain again.
      def sandbox_name
        return @config["name"] if @config["name"]

        root = File.expand_path(File.dirname(host_workspace))
        label = File.basename(root).gsub(/[^a-zA-Z0-9_-]/, "-")
        "reve-#{label}-#{Digest::SHA256.hexdigest(root)[0, 10]}"
      end
      def workdir = @config["workdir"] || "/workspace"
      def host_workspace = @config["hostWorkspace"] || Dir.pwd

      # Restart an unchanged persisted VM. Creation and provisioning happen
      # only on the first launch or after sandbox policy/toolchain changes.
      def start
        return self if @started

        @mutex.synchronize do
          return self if @started

          ensure_workspace!
          if reusable?
            begin
              @progress&.stage("restarting microVM #{sandbox_name}")
              @vm.connect(sandbox_name)
              @started = true
              @progress&.finish
              return self
            rescue StandardError => e
              # A running sandbox belongs to another live Reve. Replacing it
              # would violate isolation for both processes.
              raise if e.respond_to?(:kind) && e.kind == "in_use"
            end
          end

          @progress&.stage("building microVM #{sandbox_name} from #{@config["image"]}")
          opts = Sandbox.create_options(@config, host_workspace, workdir).merge("replace" => true)
          @vm.create(sandbox_name, opts)
          @started = true
          if @config["provision"]
            tools = ((@config["mise"] || []) + (@config["npm"] || [])).join(", ")
            @progress&.stage("provisioning APT packages#{tools.empty? ? "" : " and #{tools}"}")
          end
          provision_ok = !@config["provision"] || provision!
          bootstrap_ok = (@config["bootstrap"] || []).each_with_index.all? do |cmd, index|
            @progress&.stage("running bootstrap #{index + 1}/#{@config["bootstrap"].size}: #{cmd.to_s.lines.first.strip}")
            exec(cmd)["exitCode"].to_i.zero?
          end
          save_fingerprint if provision_ok && bootstrap_ok
          @progress&.finish(provision_ok && bootstrap_ok ? "sandbox ready" : "sandbox ready with provisioning errors")
        end
        self
      rescue StandardError => e
        @progress&.fail("sandbox startup failed: #{e.message}")
        raise
      end

      def fingerprint_path
        File.join(File.dirname(host_workspace), ".reve", "sandbox-fingerprint")
      end

      def fingerprint
        scrub = lambda do |value|
          case value
          when Hash
            value.keys.sort.each_with_object({}) do |key, out|
              out[key] = key.to_s == "value" ? "[secret]" : scrub.call(value[key])
            end
          when Array then value.map { scrub.call(_1) }
          else value
          end
        end
        Digest::SHA256.hexdigest(JSON.generate(scrub.call(@config)))
      end

      def reusable?
        File.file?(fingerprint_path) && File.read(fingerprint_path).strip == fingerprint
      rescue SystemCallError
        false
      end

      def save_fingerprint
        FileUtils.mkdir_p(File.dirname(fingerprint_path))
        tmp = "#{fingerprint_path}.tmp-#{Process.pid}"
        File.write(tmp, "#{fingerprint}\n")
        File.rename(tmp, fingerprint_path)
      end

      # The bind source has to exist before the mount does — and a local run
      # needs the same directory for the same reason.
      def ensure_workspace!
        FileUtils.mkdir_p(host_workspace) unless File.directory?(host_workspace)
      rescue SystemCallError
        nil
      end

      # => { "stdout", "stderr", "exitCode" }
      def exec(command, timeout: 120, cancel: nil)
        ensure_workspace!
        start
        @vm.exec("sh", args: ["-lc", command], cwd: workdir, timeout: timeout, cancel: cancel)
      end

      # Install the default toolchain, once per sandbox. Failure is reported but
      # not fatal: an agent with a bare debian is still an agent.
      def provision!
        return true if @provisioned

        @provisioned = true
        script = Sandbox.provision_script(@config)
        r = @vm.exec("sh", args: ["-lc", script], cwd: "/", timeout: 900)
        return true if r["exitCode"].zero?

        warn "\e[33m sandbox provisioning failed (exit #{r["exitCode"]}): " \
             "#{r["stderr"].to_s.lines.last(3).join.strip}\e[0m"
        false
      rescue StandardError => e
        warn "\e[33m sandbox provisioning failed: #{e.message}\e[0m"
        false
      end

      def read_file(path)
        ensure_workspace!
        start
        @vm.read_file(absolute(path))
      end

      def write_file(path, content)
        ensure_workspace!
        start
        @vm.write_file(absolute(path), content)
      end

      def absolute(path) = path.to_s.start_with?("/") ? path.to_s : File.join(workdir, path.to_s)

      def stop
        @vm.stop
        @started = false
      rescue StandardError
        nil
      end

      def mount_description
        return "no workspace mount" unless @config["mountWorkspace"]

        "bind #{host_workspace} → #{workdir} (rw)"
      end

      def describe
        extras = []
        extras << "provisioned" if @config["provision"]
        extras << "mise #{(@config["mise"] || []).join(",")}" unless (@config["mise"] || []).empty?
        extras << (@config["allowAll"] ? "network open" : "net #{(@config["allowHosts"] || []).size} hosts")
        "microsandbox-rb #{@config["image"]} (#{@config["cpus"]} cpu, #{@config["memory"]}MB" \
          "#{extras.empty? ? "" : ", #{extras.join(", ")}"}) #{mount_description}"
      end
    end

    # Resolve the only supported backend. Missing dependencies are fatal: never
    # turn a model-authored command into host execution as a convenience.
    def resolve(config, warn_io: $stderr)
      cfg = config(config)
      backend = cfg["backend"].to_s
      unless backend.empty? || backend == "microsandbox"
        raise Unavailable, "unsupported sandbox backend #{backend.inspect}; microsandbox is mandatory"
      end

      progress = Progress.new(warn_io)
      Client.new(Microsandbox.new, cfg.merge("backend" => "microsandbox"), progress: progress).tap(&:start)
    rescue Microsandbox::Error => e
      warn_io&.puts("\e[31m sandbox: #{e.message}\e[0m")
      raise Unavailable, e.message
    end

    def available? = Microsandbox.available?

    class Unavailable < StandardError; end
  end
end
