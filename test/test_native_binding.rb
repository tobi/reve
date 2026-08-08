# frozen_string_literal: true

require_relative "helper"
include TestKit

# The Ruby<->binding contract. `Leve::Sandbox::Client` talks to its microVM
# through an injectable `native:` seam; `TestKit::FakeNative` mirrors the
# extension's wire shape exactly (JSON strings in and out, a non-zero exit is
# data). These checks hold the seam to that shape, without requiring the
# compiled extension. The opt-in group at the bottom boots a real VM when the
# extension is built and the caller asks for it.

group "create_spec speaks the binding's wire shape" do
  cfg = Leve::Sandbox.config("hostWorkspace" => "/host/ws", "provision" => false,
                             "githubAuth" => false,
                             "secrets" => [{ "env" => "TOKEN", "value" => "secret-value",
                                             "hosts" => ["github.com"], "placeholder" => "masked" }])
  spec = Leve::Sandbox.create_spec(cfg, "leve-test", "/host/ws", "/workspace")
  eq "spec has exactly the keys the extension accepts",
     %w[cpus env image memory mounts name network replace secrets workdir].sort,
     spec.keys.sort
  eq "memory is a plain integer", 2048, spec["memory"]
  eq "workdir travels", "/workspace", spec["workdir"]
  eq "env travels", "noninteractive", spec.dig("env", "DEBIAN_FRONTEND")
  eq "replace is set so the stable named sandbox is rebuilt", true, spec["replace"]

  mount = spec["mounts"].first
  eq "the workspace is a single bind mount", ["/workspace"], spec["mounts"].map { _1["guest"] }
  eq "mount carries guest, host and readonly",
     { "guest" => "/workspace", "host" => "/host/ws", "readonly" => false }, mount

  eq "network is enabled", true, spec.dig("network", "enabled")
  eq "with an explicit allowlist of hosts", Array, spec.dig("network", "allow").class
  eq "and the github defaults are admitted while not provisioning",
     true, spec.dig("network", "allow").include?("github.com")
  eq "provisioning mirrors are absent when provision is off",
     false, spec.dig("network", "allow").include?("deb.debian.org")

  secret = spec["secrets"].first
  eq "a secret entry uses the binding's keys",
     %w[env hosts placeholder value].sort, secret.keys.sort
  eq "the real value travels to the proxy", "secret-value", secret["value"]
  eq "scoped to its hosts", ["github.com"], secret["hosts"]
  eq "with a placeholder the VM sees", "masked", secret["placeholder"]

  bare = Leve::Sandbox.config("hostWorkspace" => "/host/ws", "provision" => false, "githubAuth" => false)
  bare_spec = Leve::Sandbox.create_spec(bare, "leve-test", "/host/ws", "/workspace")
  eq "no secrets key when there are none", false, bare_spec.key?("secrets")

  nomount = Leve::Sandbox.config("hostWorkspace" => "/host/ws", "mountWorkspace" => false,
                                 "provision" => false, "githubAuth" => false)
  eq "no mounts key when the workspace is not mounted",
     false, Leve::Sandbox.create_spec(nomount, "leve-test", "/host/ws", "/workspace").key?("mounts")
end

group "deny-by-default: provisioning hosts appear only while provisioning" do
  off = Leve::Sandbox.network_spec(Leve::Sandbox.config("provision" => false))
  on = Leve::Sandbox.network_spec(Leve::Sandbox.config("provision" => true))
  eq "network is always enabled", true, off["enabled"]
  eq "without provisioning, only github hosts are allowed",
     Leve::Sandbox::HostAuth::GITHUB_HOSTS.sort, off["allow"].sort
  eq "provisioning admits the package mirrors", true, on["allow"].include?("deb.debian.org")
  eq "and mise's installer", true, on["allow"].include?("mise.run")
  eq "but the github baseline remains", true, on["allow"].include?("github.com")
  eq "nothing widens to a public policy", true, on["allow"].all? { _1.is_a?(String) && !_1.include?("*") }
end

group "exec options round-trip through the JSON wire" do
  opts = { "args" => ["-c", "echo $LEVE_TEST"], "cwd" => "/workspace",
           "env" => { "LEVE_TEST" => "env-ok" }, "timeout_ms" => 5000, "stdin" => "piped-in" }
  eq "all five options survive serialize/parse", opts, JSON.parse(JSON.generate(opts))

  Dir.mktmpdir do |root|
    native = fake_native(root)
    cfg = Leve::Sandbox.config("hostWorkspace" => root, "provision" => false,
                               "githubAuth" => false, "bootstrap" => [])
    vm = native.create(JSON.generate(Leve::Sandbox.create_spec(cfg, "leve-test", root, "/workspace")))

    r = JSON.parse(vm.exec("sh", JSON.generate({ "args" => ["-c", "echo args-ok"], "cwd" => "/workspace" })))
    eq "args reach the command", "args-ok\n", r["stdout"]

    r = JSON.parse(vm.exec("sh", JSON.generate({ "args" => ["-c", "pwd"], "cwd" => "/workspace" })))
    eq "cwd is honored", root, r["stdout"].strip

    r = JSON.parse(vm.exec("sh", JSON.generate({ "args" => ["-c", "echo $LEVE_TEST"], "cwd" => "/workspace",
                                                 "env" => { "LEVE_TEST" => "env-ok" } })))
    eq "env is honored", "env-ok\n", r["stdout"]

    t0 = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    r = JSON.parse(vm.exec("sh", JSON.generate({ "args" => ["-c", "sleep 5"], "cwd" => "/workspace",
                                                 "timeout_ms" => 200 })))
    elapsed = Process.clock_gettime(Process::CLOCK_MONOTONIC) - t0
    eq "timeout_ms terminates a runaway command promptly", true, elapsed < 1.0
    eq "and still returns a result, not an exception", Hash, r.class

    r = JSON.parse(vm.exec("sh", JSON.generate({ "args" => ["-c", "echo stdin-accepted"], "cwd" => "/workspace",
                                                 "stdin" => "data" })))
    eq "a stdin key is accepted, not rejected", true, r["success"]
  end
end

group "a non-zero exit is data, not an exception" do
  Dir.mktmpdir do |root|
    native = fake_native(root)
    cfg = Leve::Sandbox.config("hostWorkspace" => root, "provision" => false,
                               "githubAuth" => false, "bootstrap" => [])
    vm = native.create(JSON.generate(Leve::Sandbox.create_spec(cfg, "leve-test", root, "/workspace")))
    r = JSON.parse(vm.exec("sh", JSON.generate({ "args" => ["-c", "exit 7"], "cwd" => "/workspace" })))
    eq "the exit code is returned as data", 7, r["exitCode"]
    eq "success is false", false, r["success"]
    eq "stdout and stderr are still present", true, r.key?("stdout") && r.key?("stderr")

    client = Leve::Sandbox::Client.new(cfg, native: native)
    eq "Client#exec surfaces the exit code without raising", 7, client.exec("exit 7")["exitCode"]
    client.stop
  end
end

group "stop is idempotent" do
  Dir.mktmpdir do |root|
    native = fake_native(root)
    cfg = Leve::Sandbox.config("hostWorkspace" => root, "provision" => false,
                               "githubAuth" => false, "bootstrap" => [])
    client = Leve::Sandbox::Client.new(cfg, native: native)
    client.start
    name = client.sandbox_name
    eq "the VM is running", true, native.running?(name)
    client.stop
    eq "stop halts the VM", false, native.running?(name)
    raised = begin
      client.stop
      nil
    rescue StandardError => e
      e
    end
    eq "a second stop is a no-op, not an error", nil, raised
  end
end

group "restart reuse calls start, not create, when the fingerprint matches" do
  Dir.mktmpdir do |root|
    native = fake_native(root)
    cfg = Leve::Sandbox.config("hostWorkspace" => root, "provision" => false,
                               "githubAuth" => false, "bootstrap" => [])
    first = Leve::Sandbox::Client.new(cfg, native: native)
    first.start
    first.stop
    second = Leve::Sandbox::Client.new(cfg, native: native)
    second.start
    eq "only the first launch creates", 1, native.created.size
    eq "reuse restarts the persisted VM", 1, native.started.size
    second.stop

    changed = Leve::Sandbox::Client.new(cfg.merge("memory" => 4096), native: native)
    changed.start
    eq "a changed policy forces create", 2, native.created.size
    changed.stop
  end
end

group "Client#start refuses a VM another process owns" do
  Dir.mktmpdir do |root|
    native = fake_native(root)
    cfg = Leve::Sandbox.config("hostWorkspace" => root, "provision" => false,
                               "githubAuth" => false, "bootstrap" => [])
    owner = Leve::Sandbox::Client.new(cfg, native: native)
    owner.start
    eq "the owning process has the VM running", true, native.running?(owner.sandbox_name)

    other = Leve::Sandbox::Client.new(cfg, native: native)
    raised = begin
      other.start
      nil
    rescue Leve::Sandbox::Unavailable => e
      e
    end
    eq "a second process is refused with Unavailable", Leve::Sandbox::Unavailable, raised&.class
    owner.stop
  end
end

# Opt-in: boot an actual microVM through the real native extension. This needs
# Linux/KVM (or macOS on Apple Silicon), the built extension (`rake compile`),
# and the microsandbox runtime. It is skipped unless the caller opts in.
group "real microVM through Leve::Sandbox::Native (opt-in)" do
  unless ENV["LEVE_MICROVM_TESTS"]
    puts "  SKIP — set LEVE_MICROVM_TESTS=1 to boot an actual VM"
    next
  end
  begin
    Leve::Sandbox::NativeLoader.load!
  rescue Leve::Sandbox::Unavailable
    puts "  SKIP — the native extension is not built (run `rake compile`)"
    next
  end

  Dir.mktmpdir do |root|
    workspace = File.join(root, "workspace")
    FileUtils.mkdir_p(workspace)
    cfg = Leve::Sandbox.config("hostWorkspace" => workspace, "provision" => false,
                               "githubAuth" => false, "bootstrap" => [])
    client = Leve::Sandbox.resolve(cfg, warn_io: $stderr, native: Leve::Sandbox::Native)
    begin
      eq "exec runs inside the real VM", "hello\n", client.exec("echo hello")["stdout"]
      File.write(File.join(workspace, "mount.txt"), "from-host")
      eq "the workspace bind mount is live",
         "from-host", client.exec("cat /workspace/mount.txt")["stdout"].strip
    ensure
      client.stop
    end
  end
end

done
