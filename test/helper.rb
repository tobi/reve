# frozen_string_literal: true

require "json"
require "fileutils"
require "tmpdir"
require "stringio"
require "open3"

# The suite mocks the model, always. No /v1/models probe is permitted, so a test
# cannot reach somebody's real endpoint by accident. Every harness receives a
# `fake_model` object directly; models.yml lookup is not involved.
ENV["LEVE_NO_PROBE"] = "1"

require_relative "../lib/leve"

module TestKit
  FAILURES = []
  COUNT = [0]

  module_function

  def check(desc)
    COUNT[0] += 1
    ok = yield
    if ok
      puts "  ok   #{desc}"
    else
      puts "  FAIL #{desc}"
      FAILURES << desc
    end
  rescue StandardError => e
    puts "  FAIL #{desc} — #{e.class}: #{e.message}"
    puts "       #{(e.backtrace || []).first(5).join("\n       ")}"
    FAILURES << desc
  end

  def eq(desc, expected, actual)
    check("#{desc} (expected #{expected.inspect}, got #{actual.inspect})") { expected == actual }
  end

  def group(name)
    puts "\n#{name}"
    yield
  end

  def done
    puts
    if FAILURES.empty?
      puts "#{COUNT[0]} checks passed"
      exit 0
    else
      puts "#{FAILURES.size}/#{COUNT[0]} checks FAILED"
      exit 1
    end
  end

  # A tiny Ruby stand-in for the native extension.
  #
  # `Leve::Sandbox::Client` takes its transport through an injectable `native:`
  # seam, so the whole sandbox layer — spec building, fingerprinting, restart
  # reuse, provisioning, workdir resolution — is exercised here with no image,
  # no KVM, and no compiled extension. Commands really run, in the temporary
  # workspace. The real binding is covered separately by the opt-in microVM
  # suite, and there is still exactly one production transport.
  #
  # It mirrors the extension's contract exactly: JSON strings in and out, and a
  # non-zero exit is data rather than an exception.
  class FakeNative
    attr_reader :created, :started

    def initialize(root)
      @root = root
      @created = []
      @started = []
      @running = {}
    end

    def microsandbox_version = "fake"
    def installed? = true
    def install = true
    def exists?(name) = @running.key?(name)
    def running?(name) = !!@running[name]

    def create(spec_json)
      spec = JSON.parse(spec_json)
      @created << spec
      @running[spec["name"]] = true
      FakeVm.new(@root, spec["name"], self)
    end

    def start(name)
      raise "no such sandbox #{name}" unless @running.key?(name)

      @started << name
      FakeVm.new(@root, name, self)
    end

    def remove(name)
      @running.delete(name)
      true
    end

    def stopped(name) = @running[name] = false
  end

  # For doubles that only care about `#exec`: wraps an already-computed result
  # in the session interface `Client#exec` uses when a cancel flag is present.
  class ImmediateExec
    def initialize(result) = @result = result
    def collect = @result
    def kill = nil
  end

  # Mirrors the extension's `Exec`: `collect` blocks until the command ends,
  # `kill` stops it from another thread.
  class FakeExec
    def initialize(directory, cmd, opts_json)
      opts = JSON.parse(opts_json)
      FileUtils.mkdir_p(directory)
      @reader, writer = IO.pipe
      @pid = Process.spawn(opts["env"] || {}, cmd, *(opts["args"] || []),
                           chdir: directory, out: writer, err: writer, pgroup: true)
      writer.close
    end

    def collect
      output = @reader.read.to_s
      _, status = Process.waitpid2(@pid)
      code = status.exitstatus.to_i
      JSON.generate({ "stdout" => output, "stderr" => "", "exitCode" => code,
                      "success" => code.zero? })
    ensure
      @reader.close unless @reader.closed?
    end

    def kill
      Process.kill("TERM", -@pid)
    rescue StandardError
      nil
    end
  end

  class FakeVm
    attr_reader :name

    def initialize(root, name, owner)
      @root = root
      @name = name
      @owner = owner
      @stopped = false
    end

    def alive? = !@stopped

    def exec(cmd, opts_json)
      raise "sandbox #{@name} is stopped" if @stopped

      opts = JSON.parse(opts_json)
      directory = guest_path(opts["cwd"] || "/workspace")
      FileUtils.mkdir_p(directory)
      timeout = (opts["timeout_ms"] || 120_000) / 1000.0
      env = opts["env"] || {}
      reader, writer = IO.pipe
      pid = Process.spawn(env, cmd, *(opts["args"] || []),
                          chdir: directory, out: writer, err: writer, pgroup: true)
      writer.close
      output = +""
      deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + timeout
      status = nil
      until status
        begin
          output << reader.read_nonblock(16_384)
        rescue IO::WaitReadable
          Process.kill("TERM", -pid) rescue nil if Process.clock_gettime(Process::CLOCK_MONOTONIC) >= deadline
          _, status = Process.waitpid2(pid, Process::WNOHANG)
          IO.select([reader], nil, nil, 0.01) unless status
        rescue EOFError
          _, status = Process.waitpid2(pid)
        end
      end
      output << reader.read.to_s
      code = status.exitstatus.to_i
      JSON.generate({ "stdout" => output, "stderr" => "", "exitCode" => code, "success" => code.zero? })
    ensure
      reader&.close
      writer&.close
      if pid && !status
        Process.kill("KILL", -pid) rescue nil
        Process.waitpid(pid) rescue nil
      end
    end

    # The cancellable seam. `Client#exec` uses this whenever a cancel flag is
    # supplied, so the abort path under test is the same code the real binding
    # drives — the fake kills a real process group, the extension kills the
    # guest command.
    def exec_session(cmd, opts_json)
      raise "sandbox #{@name} is stopped" if @stopped

      FakeExec.new(guest_path(JSON.parse(opts_json)["cwd"] || "/workspace"), cmd, opts_json)
    end

    def shell(script, opts_json) = exec("sh", JSON.generate(JSON.parse(opts_json).merge("args" => ["-lc", script])))

    def read_file(path) = File.binread(guest_path(path))

    def write_file(path, content)
      target = guest_path(path)
      FileUtils.mkdir_p(File.dirname(target))
      File.binwrite(target, content)
      nil
    end

    def stop
      @stopped = true
      @owner.stopped(@name)
      nil
    end

    private

    def guest_path(path)
      suffix = path.to_s.delete_prefix("/workspace").delete_prefix("/")
      File.join(@root, suffix)
    end
  end

  def fake_native(root) = FakeNative.new(root)

  def fake_sandbox(root, native: nil)
    cfg = Leve::Sandbox.config("hostWorkspace" => root, "provision" => false,
                               "githubAuth" => false, "bootstrap" => [])
    Leve::Sandbox::Client.new(cfg, native: native || FakeNative.new(root))
  end

  # All behavior tests enter through this helper: both external dependencies are
  # mocked by default. A caller can still supply a scripted fake model.
  def test_harness(cwd:, model: nil, sandbox: nil, **options)
    model ||= fake_model(cwd, [assistant_text("ok")])
    sandbox ||= fake_sandbox(File.join(cwd, "workspace"))
    Leve::Harness.create(cwd: cwd, model: model, sandbox: sandbox, **options)
  end

  # A scripted fake model. The script is a file, so it survives a crash and a
  # restart, and the cursor with it.

  def fake_model(dir, responses, extra = {})
    path = File.join(dir, "script-#{COUNT[0]}-#{rand(1 << 30)}.json")
    File.write(path, JSON.generate({ "responses" => responses }.merge(extra)))
    File.delete("#{path}.cursor") if File.exist?("#{path}.cursor")
    ENV["LEVE_FAKE_SCRIPT"] = path
    { "provider" => "fake", "modelId" => "fake-1", "api" => "fake", "baseUrl" => "", "apiKey" => "",
      "reasoning" => false, "contextWindow" => 200_000, "maxTokens" => 4096, "name" => "fake" }
  end

  def text(msg) = "text: #{msg}"

  def assistant_text(t) = { "role" => "assistant", "content" => [{ "type" => "text", "text" => t }],
                            "stopReason" => "stop" }

  def assistant_tool(name, args, id: "tc1")
    { "role" => "assistant",
      "content" => [{ "type" => "toolCall", "id" => id, "name" => name, "arguments" => args }],
      "stopReason" => "toolUse" }
  end

  def entries_of(session) = session.find_entries("order" => "oldestFirst")
  def records_of(session) = session.find_records("lane" => "main")
end
