# frozen_string_literal: true

require_relative "helper"
include TestKit

module FakeMicrosandboxGem
  Output = Struct.new(:stdout, :stderr, :exit_code)

  class Fs
    attr_reader :files

    def initialize = @files = {}
    def write(path, content) = @files[path] = content
    def read(path) = @files.fetch(path)
    def copy_from_host(host, guest) = write(guest, File.binread(host))
    def copy_to_host(guest, host) = File.binwrite(host, read(guest))
  end

  class Running
    attr_reader :fs, :calls

    def initialize
      @fs = Fs.new
      @calls = []
    end

    def exec(command, args, **options)
      @calls << [command, args, options]
      Output.new("gem stdout\n", "gem stderr\n", 7)
    end

    def stop = true
  end

  class Handle
    def running? = false
  end

  class Sandbox
    class << self
      attr_reader :name, :options, :running

      def create(name, **options)
        @name = name
        @options = options
        @running = Running.new
      end

      def get(_name) = Handle.new
      def start(name)
        @name = name
        @running ||= Running.new
      end
    end
  end

  def self.version = "0.12.0-test"
  def self.runtime_version = "v0.6.8-test"
end

group "microsandbox-rb adapter" do
  vm = Reve::Sandbox::Microsandbox.new(api: FakeMicrosandboxGem)
  eq "reports gem and runtime versions",
     { "version" => "0.12.0-test", "runtimeVersion" => "v0.6.8-test" }, vm.version

  result = vm.create("reve-test", {
    "image" => "debian:trixie-slim", "cpus" => 2, "memory_mib" => 2048,
    "security" => "restricted", "workdir" => "/workspace",
    "env" => { "A" => "B" },
    "volumes" => { "/workspace" => { "bind" => "/host/work", "readonly" => false,
                                       "nosuid" => true, "nodev" => true } },
    "network" => { "custom_policy" => { "rules" => [
      { "action" => "allow", "destination_kind" => "group", "destination" => "host",
        "protocols" => %w[udp tcp], "ports" => ["53"] },
      { "action" => "allow", "destination_kind" => "domain",
        "destination" => "github.com", "protocol" => "tcp", "port" => "443" }
    ] } },
    "secrets" => [{ "env_var" => "TOKEN", "value" => "secret",
                     "allow_hosts" => ["github.com"], "placeholder" => "masked" }],
    "replace" => true
  })
  eq "captures the live gem sandbox", FakeMicrosandboxGem::Sandbox.running, result["handle"]
  opts = FakeMicrosandboxGem::Sandbox.options
  eq "resources use gem keywords", ["debian:trixie-slim", 2, 2048, "restricted"],
     [opts[:image], opts[:cpus], opts[:memory], opts[:security]]
  eq "workspace is a hardened bind mount",
     { bind: "/host/work", readonly: false, nosuid: true, nodev: true },
     opts.dig(:volumes, "/workspace")
  eq "network remains deny by default", :deny, opts.dig(:network, :default_egress)
  eq "DNS reaches the gem as the host gateway rule", ["host", %w[udp tcp], ["53"]],
     [opts.dig(:network, :rules, 0, "destination"), opts.dig(:network, :rules, 0, "protocols"),
      opts.dig(:network, :rules, 0, "ports")]
  eq "domain rules reach the gem", "github.com", opts.dig(:network, :rules, 1, "destination")
  eq "secrets use the gem vocabulary",
     { env: "TOKEN", value: "secret", hosts: ["github.com"], placeholder: "masked" },
     opts.dig(:secrets, 0)
  eq "create replaces the stable named sandbox", true, opts[:replace]

  out = vm.exec("sh", args: ["-lc", "exit 7"], cwd: "/workspace", timeout: 30)
  eq "exec output is normalized",
     { "stdout" => "gem stdout\n", "stderr" => "gem stderr\n", "exitCode" => 7,
       "cancelled" => false }, out
  eq "exec arguments reach the gem", ["sh", ["-lc", "exit 7"],
                                      { cwd: "/workspace", timeout: 30 }],
     FakeMicrosandboxGem::Sandbox.running.calls.last

  vm.write_file("/workspace/a.txt", "hello")
  eq "filesystem writes and reads use Sandbox#fs", "hello", vm.read_file("/workspace/a.txt")
  eq "stop delegates to the gem", { "ok" => true }, vm.stop
  reconnected = vm.connect("reve-test")
  eq "connect restarts the persisted sandbox", "reve-test", reconnected["name"]
  vm.stop
end

group "sandbox is mandatory" do
  cfg = Reve::Sandbox.config("backend" => "local")
  raised = begin
    Reve::Sandbox.resolve(cfg, warn_io: nil)
    nil
  rescue Reve::Sandbox::Unavailable => e
    e
  end
  eq "local mode is rejected", true, raised&.message&.include?("microsandbox is mandatory")
  eq "a client cannot be constructed without a runtime", true,
     begin
       Reve::Sandbox::Client.new(nil, Reve::Sandbox.config)
       false
     rescue ArgumentError
       true
     end
end

done
