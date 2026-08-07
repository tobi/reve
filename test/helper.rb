# frozen_string_literal: true

require "json"
require "fileutils"
require "tmpdir"
require "stringio"
require "open3"

# The suite mocks the model, always. No /v1/models probe is permitted, so a test
# cannot reach somebody's real endpoint by accident. Every harness receives a
# `fake_model` object directly; models.yml lookup is not involved.
ENV["REVE_NO_PROBE"] = "1"

require_relative "../lib/reve"

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

  # A tiny Ruby VM used by behavior tests. It implements reve's sandbox boundary;
  # the microsandbox-rb adapter is covered separately. Commands really run in
  # the temporary workspace, but no image, provisioning, native runtime, or KVM
  # is involved.
  class FakeVM
    def initialize(root)
      @root = root
    end

    def create(_name, _options) = { "handle" => 1 }
    def stop = true

    def exec(command, args: [], cwd: nil, timeout: 120, cancel: nil)
      directory = guest_path(cwd || "/workspace")
      FileUtils.mkdir_p(directory)
      reader, writer = IO.pipe
      pid = Process.spawn(command, *args, chdir: directory, out: writer, err: writer, pgroup: true)
      writer.close
      output = +""
      deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + timeout
      cancelled = false
      status = nil
      until status
        begin
          output << reader.read_nonblock(16_384)
        rescue IO::WaitReadable
          if cancel&.call || Process.clock_gettime(Process::CLOCK_MONOTONIC) >= deadline
            cancelled = true
            Process.kill("TERM", -pid) rescue nil
          end
          _, status = Process.waitpid2(pid, Process::WNOHANG)
          IO.select([reader], nil, nil, 0.01) unless status
        rescue EOFError
          _, status = Process.waitpid2(pid)
        end
      end
      output << reader.read.to_s
      { "stdout" => output, "stderr" => "", "exitCode" => cancelled ? 130 : status.exitstatus.to_i,
        "cancelled" => cancelled }
    ensure
      reader&.close
      writer&.close
      Process.kill("KILL", -pid) rescue nil if pid && !status
      Process.waitpid(pid) rescue nil if pid && !status
    end

    def read_file(path) = File.binread(guest_path(path))

    def write_file(path, content)
      target = guest_path(path)
      FileUtils.mkdir_p(File.dirname(target))
      File.binwrite(target, content)
      { "ok" => true }
    end

    private

    def guest_path(path)
      suffix = path.to_s.delete_prefix("/workspace").delete_prefix("/")
      File.join(@root, suffix)
    end
  end

  def fake_sandbox(root)
    cfg = Reve::Sandbox.config("hostWorkspace" => root, "provision" => false,
                                  "githubAuth" => false, "bootstrap" => [])
    Reve::Sandbox::Client.new(FakeVM.new(root), cfg)
  end

  # All behavior tests enter through this helper: both external dependencies are
  # mocked by default. A caller can still supply a scripted fake model.
  def test_harness(cwd:, model: nil, sandbox: nil, **options)
    model ||= fake_model(cwd, [assistant_text("ok")])
    sandbox ||= fake_sandbox(File.join(cwd, "workspace"))
    Reve::Harness.create(cwd: cwd, model: model, sandbox: sandbox, **options)
  end

  # A scripted fake model. The script is a file, so it survives a crash and a
  # restart, and the cursor with it.

  def fake_model(dir, responses, extra = {})
    path = File.join(dir, "script-#{COUNT[0]}-#{rand(1 << 30)}.json")
    File.write(path, JSON.generate({ "responses" => responses }.merge(extra)))
    File.delete("#{path}.cursor") if File.exist?("#{path}.cursor")
    ENV["REVE_FAKE_SCRIPT"] = path
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
