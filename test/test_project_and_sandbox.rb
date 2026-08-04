# frozen_string_literal: true

require_relative "helper"
include TestKit

group "rbagent init scaffolds an agent directory" do
  Dir.mktmpdir do |dir|
    result = Durable::Project.init(dir, name: "notes-bot")
    eq "instructions.md is the centre of it", true, result["created"].include?("instructions.md")
    eq "with tools, skills, a soul and a sandbox alongside",
       %w[AGENTS.md SOUL.md sandbox/sandbox.rb skills/release-notes/SKILL.md tools/example.rb],
       (result["created"] & %w[tools/example.rb skills/release-notes/SKILL.md sandbox/sandbox.rb
                               SOUL.md AGENTS.md]).sort
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
    eq "sandbox is auto: a microVM when one is available", "auto", p.sandbox_config["backend"]
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

group "the prompt is a list of files, so SOUL.md can join it" do
  Dir.mktmpdir do |root|
    Durable::Project.init(root, name: "soulful")
    File.write(File.join(root, "SOUL.md"), "You are terse and dry.")
    p = Durable::Project.load(root, user_skills: false)
    eq "SOUL.md joins on its own", %w[instructions.md SOUL.md],
       p.prompt_sources.map { File.basename(_1["path"]) }
    prompt = p.system_prompt(tools: %w[read])
    eq "each file gets its own block", ["instructions.md", "SOUL.md"],
       prompt.scan(/<agent_instructions source="([^"]+)">/).flatten
    eq "in order", true, prompt.index("instructions.md") < prompt.index("SOUL.md")

    File.write(File.join(root, "docs", "style.md").tap { FileUtils.mkdir_p(File.dirname(_1)) },
               "Tables over prose.")
    File.write(File.join(root, "agent.rb"), <<~RUBY)
      agent do
        model "vllm"
        instructions "instructions.md", "SOUL.md", "docs/style.md"
      end
    RUBY
    p2 = Durable::Project.load(root, user_skills: false)
    eq "agent.rb names the list", %w[instructions.md SOUL.md style.md],
       p2.prompt_sources.map { File.basename(_1["path"]) }
    eq "nested paths keep their path in the tag", true,
       p2.system_prompt(tools: %w[read]).include?('source="docs/style.md"')
    eq "config from agent.rb still applies", "vllm", p2.config["model"]

    File.write(File.join(root, "agent.rb"), <<~RUBY)
      agent do
        instructions "instructions.md", "nope.md"
      end
    RUBY
    p3 = Durable::Project.load(root, user_skills: false)
    eq "a missing prompt file is a diagnostic", true,
       p3.diagnostics.any? { _1["message"] == "prompt file not found" }
    eq "and the rest still load", 1, p3.prompt_sources.size
  end
end

group "inline instructions in agent.rb work too" do
  Dir.mktmpdir do |root|
    File.write(File.join(root, "agent.rb"), <<~RUBY)
      agent do
        model "vllm"
        instructions <<~TXT
          You are a one-file agent. No instructions.md needed.
        TXT
      end
    RUBY
    p = Durable::Project.load(root, user_skills: false)
    eq "it counts as an agent", true, p.agent?
    eq "the prose is a source", "agent.rb", p.prompt_sources.first["path"]
    eq "and reaches the prompt", true,
       p.system_prompt(tools: %w[read]).include?("one-file agent")
  end
end

group "sandbox: default image comes with the tools an agent reaches for" do
  cfg = Durable::Sandbox.config({})
  eq "debian", "debian:trixie-slim", cfg["image"]
  eq "ripgrep and fd are in the package list", true,
     (cfg["packages"] & %w[ripgrep fd-find]).size == 2
  eq "mise supplies runtimes", ["node@lts"], cfg["mise"]
  script = Durable::Sandbox.provision_script(cfg)
  eq "mise is installed", true, script.include?("https://mise.run")
  eq "and activated for every shell", true, script.include?("/etc/profile.d/10-mise.sh")
  eq "shims go on PATH, because /bin/sh is dash", true, script.include?("mise/shims")
  eq "fd gets its familiar name", true, script.include?("ln -sf /usr/bin/fdfind")
  eq "provisioning is idempotent", true, script.include?("[ -f /var/lib/rbagent/provisioned ]")
  eq "runtimes installed globally", true, script.include?("mise use -g node@lts")
end

group "sandbox: egress is deny-by-default, github only" do
  cfg = Durable::Sandbox.config("provision" => false)
  net = Durable::Sandbox.network_options(cfg)
  rules = net.dig("custom_policy", "rules")
  allowed = rules.select { _1["destination_kind"] == "domain" }.map { _1["destination"] }.uniq
  eq "only github hosts are allowed", %w[api.github.com codeload.github.com github.com
                                         objects.githubusercontent.com raw.githubusercontent.com],
     allowed.sort
  eq "dns is open, or nothing resolves", %w[tcp udp],
     rules.select { _1["destination"] == "dns" }.map { _1["protocol"] }.sort
  eq "every rule is an allow, so the policy denies by default", ["allow"], rules.map { _1["action"] }.uniq
  eq "egress only", ["egress"], rules.map { _1["direction"] }.uniq

  provisioning = Durable::Sandbox.network_options(Durable::Sandbox.config({}))
  hosts = provisioning.dig("custom_policy", "rules").map { _1["destination"] }
  eq "package mirrors are allowed only while provisioning", true, hosts.include?("deb.debian.org")
  eq "and mise's installer with them", true, hosts.include?("mise.run")

  open_cfg = Durable::Sandbox.config("allowAll" => true)
  eq "allow_all opts out of the policy entirely", {}, Durable::Sandbox.network_options(open_cfg)
end

group "sandbox: the host's github auth is lent, not copied" do
  entry = { "env_var" => "GITHUB_TOKEN", "value" => "ghp_secret", "allow_hosts" => %w[github.com] }
  cfg = Durable::Sandbox.config("githubAuth" => false, "secrets" => [entry])
  secrets = Durable::Sandbox.secret_entries(cfg)
  eq "declared secrets pass through", ["GITHUB_TOKEN"], secrets.map { _1["env_var"] }
  eq "scoped to their hosts", %w[github.com], secrets.first["allow_hosts"]
  eq "a secret with no value is dropped", [],
     Durable::Sandbox.secret_entries(Durable::Sandbox.config("githubAuth" => false,
                                                             "secrets" => [{ "env_var" => "X", "value" => "" }]))

  with_token = Durable::Sandbox.config("githubAuth" => true, "secrets" => [])
  found = Durable::Sandbox::HostAuth.github_secret
  if found
    entries = Durable::Sandbox.secret_entries(with_token)
    eq "the host token is offered to the sandbox", "GITHUB_TOKEN", entries.first["env_var"]
    eq "scoped to github only", true, entries.first["allow_hosts"].all? { _1.include?("github") }
    eq "with a placeholder, so the VM never sees the value", "rbagent-github-token",
       entries.first["placeholder"]
    eq "and we know where it came from", true, %w[$GITHUB_TOKEN $GH_TOKEN].include?(found["source"]) ||
                                               found["source"].include?("git") || found["source"].include?("gh ")
  else
    eq "no host credential, no secret", [], Durable::Sandbox.secret_entries(with_token)
  end
end

group "sandbox: create options speak microsandbox's wire shape" do
  cfg = Durable::Sandbox.config("provision" => false, "githubAuth" => false)
  opts = Durable::Sandbox.create_options(cfg, "/host/ws", "/workspace")
  eq "memory is memory_mib", 2048, opts["memory_mib"]
  eq "the workspace is a bind volume", { "bind" => "/host/ws" }, opts.dig("volumes", "/workspace")
  eq "env travels", "noninteractive", opts.dig("env", "DEBIAN_FRONTEND")
  eq "network policy attached", true, opts.key?("network")
  eq "no empty secrets key", false, opts.key?("secrets")
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
