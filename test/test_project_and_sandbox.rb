# frozen_string_literal: true

require_relative "helper"
include TestKit

group "rbagent init scaffolds an agent directory" do
  Dir.mktmpdir do |dir|
    result = Durable::Project.init(dir, name: "notes-bot")
    eq "instructions.md is the centre of it", true, result["created"].include?("instructions.md")
    eq "with tools, skills and a sandbox alongside", %w[AGENTS.md sandbox/sandbox.rb skills/release-notes/SKILL.md
                                                        tools/example.rb],
       (result["created"] & %w[tools/example.rb skills/release-notes/SKILL.md sandbox/sandbox.rb AGENTS.md]).sort
    eq "sessions live with the agent", true, File.directory?(File.join(dir, ".rbagent", "sessions"))
    eq "and are not committed", true, File.read(File.join(dir, ".gitignore")).include?(".rbagent/")
    again = Durable::Project.init(dir)
    eq "running init twice changes nothing", [], again["created"] - [".gitignore"]
    eq "and says what it skipped", true, again["skipped"].include?("instructions.md")
  end
end

Dir.mktmpdir do |root|
  Durable::Project.init(root, name: "notes-bot")

  group "the directory is the agent" do
    p = Durable::Project.load(root, user_skills: false)
    eq "it knows it is an agent", true, p.agent?
    eq "name from frontmatter", "notes-bot", p.name
    eq "model from frontmatter", "vllm", p.config["model"]
    eq "instructions are the body, not the frontmatter", false, p.instructions.include?("name: notes-bot")
    eq "tools/ loaded", %w[sandboxed_uname word_count], p.tools.map(&:name).sort
    eq "skills/ loaded", ["release-notes"], p.skills.map { _1["name"] }
    eq "sandbox configured", "local", p.sandbox_config["backend"]
    eq "no diagnostics for the scaffold", [], p.diagnostics
    eq "sessions dir", File.join(root, ".rbagent", "sessions"), p.sessions_dir
  end

  group "the system prompt carries the instructions as the authority" do
    p = Durable::Project.load(root, user_skills: false)
    prompt = p.system_prompt(tools: %w[read bash], sandbox: Durable::Sandbox.resolve(p.sandbox_config, warn_io: nil))
    eq "instructions are tagged", true, prompt.include?("<agent_instructions source=\"instructions.md\">")
    eq "and declared to outrank the defaults", true, prompt.include?("outrank")
    eq "tools still described", true, prompt.include?("- bash:")
    eq "skills still listed", true, prompt.include?("<name>release-notes</name>")
    eq "the sandbox is named", true, prompt.include?("Your sandbox: local")
  end

  group "tool DSL: schema from typed declarations" do
    p = Durable::Project.load(root, user_skills: false)
    d = p.tool("word_count").declaration
    eq "name", "word_count", d["name"]
    eq "description", "Count words in a file in the workspace", d["description"]
    eq "typed property", "string", d.dig("parameters", "properties", "path", "type")
    eq "required list", ["path"], d.dig("parameters", "required")
    eq "replay safety declared", "safe", d["replay"]
    eq "runs on the host, not in a tool Ractor", "host", d["runner"]
    eq "sandbox flag", true, p.tool("sandboxed_uname").declaration["sandbox"]
  end

  group "a project tool runs, and its return value is normalised" do
    File.write(File.join(root, "sample.txt"), "one two three\nfour five\n")
    sandbox = Durable::Sandbox.resolve(Durable::Sandbox.config("hostWorkspace" => root), warn_io: nil)
    ctx = Durable::ToolDSL::Context.new(sandbox: sandbox, cwd: root)
    p = Durable::Project.load(root, user_skills: false)
    result = Durable::ToolDSL.invoke(p.tool("word_count"), { "path" => "sample.txt" }, ctx)
    eq "string return becomes text content", "5 words, 2 lines", result.dig("content", 0, "text")
    eq "not an error", false, result["isError"]

    shell = Durable::ToolDSL.invoke(p.tool("sandboxed_uname"), {}, ctx)
    eq "ctx.sh runs a command", true, shell.dig("content", 0, "text").include?("Linux")
  end

  group "a broken tool file is a diagnostic, not a crash" do
    File.write(File.join(root, "tools", "broken.rb"), "tool \"nope\" do\n  description 'x'\n")
    File.write(File.join(root, "tools", "nohandler.rb"), "tool(\"idle\") { description 'no run block' }\n")
    p = Durable::Project.load(root, user_skills: false)
    eq "the good tools still load", true, p.tools.map(&:name).include?("word_count")
    eq "the syntax error is reported", true,
       p.diagnostics.any? { _1["type"] == "error" && _1["path"].to_s.end_with?("broken.rb") }
    eq "a tool with no run block is reported", true,
       p.diagnostics.any? { _1["message"].to_s.include?("no run block") }
    File.delete(File.join(root, "tools", "broken.rb"), File.join(root, "tools", "nohandler.rb"))
  end

  group "a tool may not shadow a built-in" do
    File.write(File.join(root, "tools", "shadow.rb"), <<~RUBY)
      tool "bash" do
        description "nope"
        run { "no" }
      end
    RUBY
    p = Durable::Project.load(root, user_skills: false)
    eq "collision reported", true, p.diagnostics.any? { _1["type"] == "collision" }
    eq "and the built-in wins", false, p.tools.map(&:name).include?("bash")
    File.delete(File.join(root, "tools", "shadow.rb"))
  end

  group "the harness picks the whole directory up" do
    model = fake_model(root, [assistant_tool("word_count", { "path" => "sample.txt" }),
                              assistant_text("five words")])
    h, = Durable::Harness.create(storage: "memory", model: model, cwd: root, user_skills: false)
    eq "project tools are active", true, h.state["activeTools"].include?("word_count")
    eq "built-ins are still there", true, h.state["activeTools"].include?("bash")
    eq "sandbox reported", "local (no isolation) → #{root}", h.sandbox.describe
    r = h.prompt("count the words in sample.txt")
    eq "the run completed", true, r["ok"]
    result = entries_of(h.session).find { _1.dig("message", "role") == "toolResult" }
    eq "the project tool ran through the host", "5 words, 2 lines",
       result.dig("message", "content", 0, "text")
    eq "and its declaration reached the provider", true,
       File.readlines("#{ENV["DURABLE_FAKE_SCRIPT"]}.requests")
           .last.include?("word_count")
    h.close
  end
end

group "sandbox: local backend is honest about what it is" do
  Dir.mktmpdir do |dir|
    s = Durable::Sandbox.resolve(Durable::Sandbox.config("hostWorkspace" => dir), warn_io: nil)
    eq "not isolated", false, s.isolated?
    eq "describes itself plainly", true, s.describe.start_with?("local (no isolation)")
    r = s.exec("echo hello")
    eq "runs commands", "hello\n", r["stdout"]
    eq "reports exit codes", 3, s.exec("exit 3")["exitCode"]
    s.write_file("a/b.txt", "written")
    eq "writes files under the workspace", "written", File.read(File.join(dir, "a", "b.txt"))
    eq "and reads them back", "written", s.read_file("a/b.txt")
  end
end

group "sandbox DSL" do
  Dir.mktmpdir do |dir|
    path = File.join(dir, "sandbox.rb")
    File.write(path, <<~RUBY)
      sandbox do
        backend :microsandbox
        image "python:3.12"
        cpus 4
        memory 2048
        env "TZ", "UTC"
        bootstrap "pip install -r requirements.txt", "pytest --version"
      end
    RUBY
    cfg = Durable::Sandbox.config(Durable::Sandbox.load_definition(path))
    eq "backend", "microsandbox", cfg["backend"]
    eq "image", "python:3.12", cfg["image"]
    eq "resources", [4, 2048], [cfg["cpus"], cfg["memory"]]
    eq "env", { "TZ" => "UTC" }, cfg["env"]
    eq "bootstrap commands in order", ["pip install -r requirements.txt", "pytest --version"], cfg["bootstrap"]
    eq "defaults filled in", "/workspace", cfg["workdir"]
  end
end

group "microsandbox: unavailable is a warning and a fallback, not a failure" do
  ENV.delete("MICROSANDBOX_LIB")
  captured = StringIO.new
  s = Durable::Sandbox.resolve({ "backend" => "microsandbox" }, warn_io: captured)
  if Durable::Sandbox::Microsandbox.available?
    eq "library present, so we get a real sandbox client", true, s.isolated?
  else
    eq "falls back to local", false, s.isolated?
    eq "and says why", true, captured.string.include?("falling back to local")
    eq "the reason is kept", true, s.config["fallbackReason"].to_s.include?("not found")
  end
end

done
