# frozen_string_literal: true

require_relative "helper"
include TestKit

# The bindings are exercised against a stub shared library that implements the
# same C ABI (test/support/msb_stub.c). That covers everything the Ruby side is
# responsible for — argument marshalling, the output buffer, the NULL-or-error
# convention, base64 payloads, cancellation tokens — on a machine with no
# microsandbox and no KVM.
STUB_SRC = File.expand_path("support/msb_stub.c", __dir__)

def build_stub(dir)
  cc = %w[cc gcc clang].find { |c| system("which #{c} > /dev/null 2>&1") }
  return nil unless cc

  lib = File.join(dir, RUBY_PLATFORM.include?("darwin") ? "libmsbstub.dylib" : "libmsbstub.so")
  ok = system(cc, "-shared", "-fPIC", "-o", lib, STUB_SRC, err: File::NULL)
  ok ? lib : nil
end

Dir.mktmpdir do |dir|
  lib = build_stub(dir)

  if lib.nil?
    puts "\nmicrosandbox ffi: no C compiler, skipping the ABI tests"
    done
  end

  group "loading and the call convention" do
    eq "library discovery honours MICROSANDBOX_LIB", lib,
       (ENV["MICROSANDBOX_LIB"] = lib) && Durable::Sandbox::Microsandbox.library_path
    eq "available? follows discovery", true, Durable::Sandbox::Microsandbox.available?
    ms = Durable::Sandbox::Microsandbox.new(path: lib)
    eq "a synchronous call reads json out of the buffer", "stub-0.1", ms.version["version"]
  end

  group "sandbox lifecycle marshals options as json" do
    ms = Durable::Sandbox::Microsandbox.new(path: lib)
    result = ms.create("my-sandbox", { "image" => "python", "cpus" => 2, "memory" => 512 })
    eq "handle captured", 42, ms.handle
    eq "name passed through", "my-sandbox", result["name"]
    eq "options arrived as json", %w[cpus image memory], result["opts"].keys.sort
    eq "and kept their types", [2, 512], [result.dig("opts", "cpus"), result.dig("opts", "memory")]
    eq "stop is clean", true, (ms.stop || {})["ok"]
    eq "and clears the handle", nil, ms.handle
  end

  group "exec: base64 out, exit code, opts" do
    ms = Durable::Sandbox::Microsandbox.new(path: lib)
    ms.create("s", {})
    out = ms.exec("sh", args: ["-lc", "echo ok"], cwd: "/workspace", timeout: 30)
    eq "stdout is decoded from base64", "ok\n", out["stdout"]
    eq "exit code", 0, out["exitCode"]
    raw = ms.call("msb_sandbox_exec", ms.handle, "sh", JSON.generate({ "args" => %w[-lc true],
                                                                      "cwd" => "/workspace" }))
    eq "the handle is passed as a u64", 42, raw["handle"]
    eq "opts json reached the library", "/workspace", raw.dig("opts", "cwd")
  end

  group "an error comes back as an exception, not a result" do
    ms = Durable::Sandbox::Microsandbox.new(path: lib)
    ms.create("s", {})
    raised =
      begin
        ms.exec("sh", args: ["-lc", "boom"])
        nil
      rescue Durable::Sandbox::Microsandbox::Error => e
        e
      end
    eq "raised", true, !raised.nil?
    eq "with the library's message", "command exploded", raised.message
    eq "and its kind", "exec_failed", raised.kind
  end

  group "files cross the boundary base64-encoded" do
    ms = Durable::Sandbox::Microsandbox.new(path: lib)
    ms.create("s", {})
    eq "read decodes", "guest file contents", ms.read_file("/workspace/x.txt")
    written = ms.call("msb_fs_write", ms.handle, "/workspace/y.txt", Base64.strict_encode64("hello"))
    eq "write encodes", "hello", Base64.decode64(written["data_b64"])
  end

  group "cancellation triggers the library's token" do
    ms = Durable::Sandbox::Microsandbox.new(path: lib)
    ms.create("s", {})
    flag = false
    t = Thread.new do
      sleep 0.15
      flag = true
    end
    out = ms.exec("sh", args: ["-lc", "true"], cancel: -> { flag })
    t.join
    eq "the call still returns its result", 0, out["exitCode"]
    eq "and a cancel token was allocated", true, ms.alloc_cancel.positive?
  end

  group "the sandbox client speaks to it like any backend" do
    client = Durable::Sandbox::Client.new(Durable::Sandbox::Microsandbox.new(path: lib),
                                          Durable::Sandbox.config("backend" => "microsandbox",
                                                                  "image" => "debian",
                                                                  "hostWorkspace" => dir,
                                                                  "bootstrap" => ["echo boot"]))
    eq "it reports isolation", true, client.isolated?
    eq "describes the vm", true, client.describe.start_with?("microsandbox debian")
    r = client.exec("echo hi")
    eq "commands run through the vm", "ok\n", r["stdout"]
    eq "files too", "guest file contents", client.read_file("thing.txt")
    client.stop
  end

  group "resolve() prefers the real backend when the library is there" do
    ENV["MICROSANDBOX_LIB"] = lib
    s = Durable::Sandbox.resolve({ "backend" => "microsandbox", "hostWorkspace" => dir }, warn_io: nil)
    eq "isolated", true, s.isolated?
    ENV.delete("MICROSANDBOX_LIB")
    fallback = Durable::Sandbox.resolve({ "backend" => "microsandbox" }, warn_io: nil)
    eq "and falls back when it is gone", false,
       Durable::Sandbox::Microsandbox.available? ? true : fallback.isolated?
  end
end

done
