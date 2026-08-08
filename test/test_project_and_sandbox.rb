# frozen_string_literal: true

require_relative "helper"
require "open3"
include TestKit

group "leve init scaffolds an agent directory" do
  Dir.mktmpdir do |dir|
    result = Leve::Project.init(dir, name: "notes-bot")
    eq "instructions.md is the centre of it", true, result["created"].include?("instructions.md")
    eq "agent.rb carries the configuration", true, result["created"].include?("agent.rb")
    agent_path = File.join(dir, "agent.rb")
    eq "agent.rb has the Leve shebang", "#!/usr/bin/env leve", File.open(agent_path, &:gets).strip
    eq "agent.rb is executable", true, File.executable?(agent_path)
    env = { "PATH" => "#{File.expand_path("../bin", __dir__)}:#{ENV.fetch("PATH")}" }
    stdout, stderr, status = Open3.capture3(env, agent_path, "--version", chdir: "/tmp")
    eq "executing agent.rb launches Leve from its own directory", [true, "leve #{Leve::VERSION}", ""],
       [status.success?, stdout.strip, stderr.strip]
    eq "with tools, mutable skills and a sandbox alongside",
       %w[sandbox.rb tools/example.rb workspace/AGENTS.md workspace/skills/heartbeat/SKILL.md],
       (result["created"] & %w[tools/example.rb workspace/skills/heartbeat/SKILL.md
                               sandbox.rb workspace/AGENTS.md]).sort
    eq "SOUL.md is editable inside the VM", true, result["created"].include?("workspace/SOUL.md")
    eq "memory and heartbeat files ship in workspace", true,
       %w[workspace/KNOWLEDGE.md workspace/DREAM.md workspace/HEARTBEAT.yml].all? do |file|
         result["created"].include?(file)
       end
    eq "the directory is now an agent directory", true, Leve::Project.agent_dir?(dir)
    eq "sessions live with the agent", true, File.directory?(File.join(dir, ".leve", "sessions"))
    eq "workspace/ is where the work goes", true, File.directory?(File.join(dir, "workspace"))
    eq "with a mutable skills directory", true, File.directory?(File.join(dir, "workspace", "skills"))
    eq "with its own AGENTS.md naming the tools", true,
       %w[fd rg ast-grep jq gh mise].all? { File.read(File.join(dir, "workspace", "AGENTS.md")).include?("`#{_1}`") }
    eq "and are not committed", true, File.read(File.join(dir, ".gitignore")).include?(".leve/")
    again = Leve::Project.init(dir)
    eq "running init twice changes nothing", [], again["created"] - [".gitignore"]
    eq "identical files are classified as unchanged", true, again["unchanged"].include?("instructions.md")
    eq "and says what it skipped", true, again["skipped"].include?("instructions.md")

    sandbox_path = File.join(dir, "sandbox.rb")
    File.write(sandbox_path, "# an older or user-edited policy\n")
    offered = Leve::Project.init(dir)
    eq "a changed generated file is offered for update", true,
       offered["updateCandidates"].include?("sandbox.rb")
    eq "it is not overwritten without approval", "# an older or user-edited policy\n",
       File.read(sandbox_path)
    applied = Leve::Project.init(dir, update: ["sandbox.rb"])
    eq "an approved candidate is updated", ["sandbox.rb"], applied["updated"]
    eq "the current mandatory sandbox template was installed", true,
       File.read(sandbox_path).include?("Microsandbox is mandatory")
    sandbox_template = File.read(sandbox_path)
    eq "GitHub auth is not enabled implicitly", false, sandbox_template.include?("github_auth true")
    eq "ast-grep avoids mise's GitHub API lookup", true,
       sandbox_template.include?('mise "node@lts"') && sandbox_template.include?('npm "@ast-grep/cli"')
  end
end

group "leve init moves the legacy nested sandbox without overwriting it" do
  Dir.mktmpdir do |root|
    legacy = File.join(root, "sandbox", "sandbox.rb")
    FileUtils.mkdir_p(File.dirname(legacy))
    File.write(legacy, "# custom policy\n")
    result = Leve::Project.init(root)
    eq "the policy moved to the agent root", "# custom policy\n", File.read(File.join(root, "sandbox.rb"))
    eq "the legacy path is gone", false, File.exist?(legacy)
    eq "the custom policy is still only an update candidate", true,
       result["updateCandidates"].include?("sandbox.rb")
  end
end

Dir.mktmpdir do |root|
  Leve::Project.init(root, name: "notes-bot")

  group "the directory is the agent" do
    p = Leve::Project.load(root)
    eq "it knows it is an agent", true, p.agent?
    eq "name from frontmatter", "notes-bot", p.name
    eq "model comes from agent.rb", "openai/gpt-5.6-luna", p.config["model"]
    eq "thinking defaults low", "low", p.config["thinkingLevel"]
    eq "instructions are the body, not the frontmatter", false, p.instructions.include?("name: notes-bot")
    eq "tools/ loaded", %w[sandboxed_uname word_count], p.tools.map(&:name).sort
    eq "workspace skills loaded", %w[heartbeat release-notes], p.skills.map { _1["name"] }.sort
    eq "no diagnostics for the scaffold", [], p.diagnostics
    eq "sessions dir", File.join(root, ".leve", "sessions"), p.sessions_dir
    eq "workspace is the working directory", File.join(root, "workspace"), p.workspace_dir
    eq "and it is what the sandbox mounts", File.join(root, "workspace"), p.sandbox_config["hostWorkspace"]
    eq "at /workspace", "/workspace", p.sandbox_config["workdir"]
  end

  group "the system prompt carries the instructions as the authority" do
    p = Leve::Project.load(root)
    prompt = p.system_prompt(tools: %w[read bash], sandbox: fake_sandbox(p.workspace_dir))
    eq "instructions are tagged", true, prompt.include?("<agent_instructions source=\"instructions.md\">")
    eq "and declared to outrank the defaults", true, prompt.include?("outrank")
    eq "tools still described", true, prompt.include?("- bash:")
    eq "skills still listed", true, prompt.include?("<name>release-notes</name>")
    eq "the sandbox is named", true, prompt.include?("Your sandbox: microsandbox")
  end

  group "tool DSL: schema from typed declarations" do
    p = Leve::Project.load(root)
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
    File.write(File.join(root, "workspace", "sample.txt"), "one two three\nfour five\n")
    sandbox = fake_sandbox(File.join(root, "workspace"))
    ctx = Leve::ToolDSL::Context.new(sandbox: sandbox, cwd: root)
    p = Leve::Project.load(root)
    result = Leve::ToolDSL.invoke(p.tool("word_count"), { "path" => "sample.txt" }, ctx)
    eq "string return becomes text content", "5 words, 2 lines", result.dig("content", 0, "text")
    eq "not an error", false, result["isError"]

    shell = Leve::ToolDSL.invoke(p.tool("sandboxed_uname"), {}, ctx)
    eq "ctx.sh runs a command", true, shell.dig("content", 0, "text").include?("Linux")
  end

  group "a broken tool file is a diagnostic, not a crash" do
    File.write(File.join(root, "tools", "broken.rb"), "tool \"nope\" do\n  description 'x'\n")
    File.write(File.join(root, "tools", "nohandler.rb"), "tool(\"idle\") { description 'no run block' }\n")
    p = Leve::Project.load(root)
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
    p = Leve::Project.load(root)
    eq "collision reported", true, p.diagnostics.any? { _1["type"] == "collision" }
    eq "and the built-in wins", false, p.tools.map(&:name).include?("bash")
    File.delete(File.join(root, "tools", "shadow.rb"))
  end

  group "the harness picks the whole directory up" do
    model = fake_model(root, [assistant_tool("word_count", { "path" => "sample.txt" }),
                              assistant_text("five words")])
    h, = test_harness(storage: "memory", model: model, cwd: root)
    eq "project tools are active", true, h.state["activeTools"].include?("word_count")
    eq "built-ins are still there", true, h.state["activeTools"].include?("bash")
    eq "sandbox reported", true, h.sandbox.describe.start_with?("microsandbox")
    r = h.prompt("count the words in sample.txt")
    eq "the run completed", true, r["ok"]
    result = entries_of(h.session).find { _1.dig("message", "role") == "toolResult" }
    eq "the project tool ran through the host", "5 words, 2 lines",
       result.dig("message", "content", 0, "text")
    eq "and its declaration reached the provider", true,
       File.readlines("#{ENV["LEVE_FAKE_SCRIPT"]}.requests")
           .last.include?("word_count")
    h.close
  end
end

group "a directory has to look like an agent" do
  Dir.mktmpdir do |dir|
    eq "an empty directory is not one", false, Leve::Project.agent_dir?(dir)
    File.write(File.join(dir, "instructions.md"), "Be useful.")
    eq "instructions.md is enough", true, Leve::Project.agent_dir?(dir)
    File.delete(File.join(dir, "instructions.md"))
    File.write(File.join(dir, "agent.rb"), "agent { model \"vllm\" }")
    eq "so is agent.rb", true, Leve::Project.agent_dir?(dir)
  end
end

group "the prompt is a list of files, so SOUL.md can join it" do
  Dir.mktmpdir do |root|
    Leve::Project.init(root, name: "soulful")
    File.write(File.join(root, "SOUL.md"), "You are terse and dry.")
    p = Leve::Project.load(root)
    eq "the generated workspace soul wins over a duplicate root file",
       ["instructions.md", "workspace/SOUL.md"],
       p.prompt_sources.map { _1["path"].delete_prefix("#{root}/") }
    prompt = p.system_prompt(tools: %w[read])
    eq "only immutable root instructions enter the stable prompt", ["instructions.md"],
       prompt.scan(/<agent_instructions source="([^"]+)">/).flatten
    eq "workspace soul stays out of the cache prefix", false, prompt.include?("workspace/SOUL.md")

    File.write(File.join(root, "docs", "style.md").tap { FileUtils.mkdir_p(File.dirname(_1)) },
               "Tables over prose.")
    File.write(File.join(root, "agent.rb"), <<~RUBY)
      agent do
        model "vllm"
        instructions "instructions.md", "SOUL.md", "docs/style.md"
      end
    RUBY
    p2 = Leve::Project.load(root)
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
    p3 = Leve::Project.load(root)
    eq "a missing prompt file is a diagnostic", true,
       p3.diagnostics.any? { _1["message"] == "prompt file not found" }
    eq "and the rest still load", %w[instructions.md SOUL.md],
       p3.prompt_sources.map { File.basename(_1["path"]) }
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
    p = Leve::Project.load(root)
    eq "it counts as an agent", true, p.agent?
    eq "the prose is a source", "agent.rb", p.prompt_sources.first["path"]
    eq "and reaches the prompt", true,
       p.system_prompt(tools: %w[read]).include?("one-file agent")
  end
end

group "workspace AGENTS, SOUL and bounded KNOWLEDGE are reread for every run" do
  Dir.mktmpdir do |root|
    Leve::Project.init(root, name: "memory-agent")
    workspace = File.join(root, "workspace")
    File.write(File.join(workspace, "AGENTS.md"), "AGENT RULE V1\n")
    File.write(File.join(workspace, "SOUL.md"), "SOUL V1\n")
    File.write(File.join(workspace, "KNOWLEDGE.md"), (1..105).map { "knowledge line #{_1}\n" }.join)
    model = fake_model(root, [assistant_text("one"), assistant_text("two")])
    h, = test_harness(cwd: root, storage: "memory", model: model)
    stable = h.system_prompt
    eq "editable memory stays out of the stable prefix", false, stable.include?("AGENT RULE V1")

    h.prompt("first")
    requests = File.readlines("#{ENV["LEVE_FAKE_SCRIPT"]}.requests").map { JSON.parse(_1) }
    first = requests.first["messages"].flat_map { _1["content"] }.filter_map { _1["text"] }.join("\n")
    eq "AGENTS is included", true, first.include?("AGENT RULE V1")
    eq "SOUL is included", true, first.include?("SOUL V1")
    eq "the first 100 knowledge lines are included", true,
       first.include?("knowledge line 100") && !first.include?("knowledge line 101")

    File.write(File.join(workspace, "AGENTS.md"), "AGENT RULE V2\n")
    File.write(File.join(workspace, "SOUL.md"), "SOUL V2\n")
    h.prompt("second")
    requests = File.readlines("#{ENV["LEVE_FAKE_SCRIPT"]}.requests").map { JSON.parse(_1) }
    second = requests.last["messages"].flat_map { _1["content"] }.filter_map { _1["text"] }.join("\n")
    eq "edits are visible on the next run", true,
       second.include?("AGENT RULE V2") && second.include?("SOUL V2")
    eq "the system cache prefix remains identical", stable, requests.last["system"]
    h.close
  end
end

group "the workspace directory is created for the bind mount" do
  Dir.mktmpdir do |root|
    File.write(File.join(root, "instructions.md"), "Be useful.")
    p = Leve::Project.load(root)
    eq "loading a project creates nothing", false, File.directory?(File.join(root, "workspace"))
    eq "but the workspace never falls back to the agent directory",
       File.join(root, "workspace"), p.workspace_dir
    model = fake_model(root, [assistant_text("ok")])
    h, = test_harness(storage: "memory", model: model, cwd: root)
    eq "opening the agent makes it, because it is a mount source and a cwd", true,
       File.directory?(File.join(root, "workspace"))
    h.close
    eq "which is what the sandbox binds", File.join(root, "workspace"), p.sandbox_config["hostWorkspace"]

    FileUtils.rm_rf(File.join(root, "workspace"))
    client = fake_sandbox(p.workspace_dir)
    r = client.exec("pwd")
    eq "a sandbox run recreates the workspace", true, File.directory?(File.join(root, "workspace"))
    eq "and starts there", File.join(root, "workspace"), r["stdout"].strip
  end
end

group "the workspace is mapped, and the agent's own files are not" do
  Dir.mktmpdir do |root|
    Leve::Project.init(root, name: "mapped")
    model = fake_model(root, [assistant_tool("bash", { "command" => "pwd" }), assistant_text("done")])
    h, = test_harness(storage: "memory", model: model, cwd: root)
    eq "tools run in workspace/", File.join(root, "workspace"), h.config["cwd"]
    eq "the agent directory is remembered separately", root, h.config["agentRoot"]
    spec = Leve::Sandbox.create_spec(h.sandbox.config, h.sandbox.sandbox_name,
                                     h.sandbox.host_workspace, h.sandbox.workdir)
    eq "workspace/ is bind-mounted at /workspace, read-write",
       { "guest" => "/workspace", "host" => File.join(root, "workspace"), "readonly" => false },
       spec["mounts"].first
    eq "and it is the only mount", ["/workspace"], spec["mounts"].map { _1["guest"] }
    eq "the mount is what the client reports",
       "bind #{File.join(root, "workspace")} → /workspace (rw)", h.sandbox.mount_description
    eq "only the VM-editable workspace AGENTS.md is in scope",
       [File.join(root, "workspace", "AGENTS.md")], h.agents_md.map { _1["path"] }
    h.prompt("where are you?")
    result = entries_of(h.session).find { _1.dig("message", "role") == "toolResult" }
    eq "and a command really starts there", true,
       result.dig("message", "content", 0, "text").lines.first.strip == File.join(root, "workspace")
    h.close
  end
end

group "sandbox: default image comes with the tools an agent reaches for" do
  cfg = Leve::Sandbox.config({})
  eq "debian", "debian:trixie-slim", cfg["image"]
  eq "ripgrep and fd are in the package list", true,
     (cfg["packages"] & %w[ripgrep fd-find]).size == 2
  eq "gh comes from Debian, avoiding GitHub API discovery", true, cfg["packages"].include?("gh")
  eq "mise supplies Node", %w[node@lts], cfg["mise"]
  eq "ast-grep comes from npm without GitHub API discovery", ["@ast-grep/cli"], cfg["npm"]
  script = Leve::Sandbox.provision_script(cfg)
  eq "mise is installed", true, script.include?("https://mise.run")
  eq "fresh-VM network operations retry while DNS settles", true,
     script.include?("Acquire::Retries=5") && script.include?("retry mise use") &&
       script.include?("retry npm install")
  eq "and activated for every shell", true, script.include?("/etc/profile.d/10-mise.sh")
  eq "a non-bash profile source cannot trip set -e", true,
     script.include?('eval "$(mise activate bash)" || true')
  eq "shims go on PATH, because /bin/sh is dash", true, script.include?("mise/shims")
  eq "fd gets its familiar name", true, script.include?("ln -sf /usr/bin/fdfind")
  eq "provisioning is idempotent", true, script.include?("[ -f /var/lib/leve/provisioned ]")
  eq "mise tools installed globally", true, script.include?("mise use -g node@lts")
  eq "npm installs ast-grep globally", true, script.include?("npm install -g @ast-grep/cli")
end

group "sandbox: egress is deny-by-default, github only" do
  cfg = Leve::Sandbox.config("provision" => false)
  net = Leve::Sandbox.network_spec(cfg)
  eq "network is always enabled", true, net["enabled"]
  eq "only github hosts are allowed", Leve::Sandbox::HostAuth::GITHUB_HOSTS.sort, net["allow"].sort
  eq "the allowlist is the whole policy; there is no rules array", %w[allow enabled], net.keys.sort

  provisioning = Leve::Sandbox.network_spec(Leve::Sandbox.config({}))
  eq "package mirrors are allowed only while provisioning", true,
     provisioning["allow"].include?("deb.debian.org")
  eq "and mise's installer with them", true, provisioning["allow"].include?("mise.run")
  eq "github remains reachable while provisioning", true, provisioning["allow"].include?("github.com")
end

group "sandbox: the host's github auth is lent, not copied" do
  entry = { "env" => "GITHUB_TOKEN", "value" => "github-token-value", "hosts" => %w[github.com] }
  cfg = Leve::Sandbox.config("githubAuth" => false, "secrets" => [entry])
  secrets = Leve::Sandbox.secret_entries(cfg)
  eq "declared secrets pass through", ["GITHUB_TOKEN"], secrets.map { _1["env"] }
  eq "scoped to their hosts", %w[github.com], secrets.first["hosts"]
  eq "a secret with no value is dropped", [],
     Leve::Sandbox.secret_entries(Leve::Sandbox.config("githubAuth" => false,
                                                             "secrets" => [{ "env" => "X", "value" => "",
                                                                             "hosts" => ["github.com"] }]))

  with_token = Leve::Sandbox.config("githubAuth" => true, "secrets" => [])
  found = Leve::Sandbox::HostAuth.github_secret
  if found
    entries = Leve::Sandbox.secret_entries(with_token)
    eq "the host token is offered to the sandbox", "GITHUB_TOKEN", entries.first["env"]
    eq "scoped to github only", true, entries.first["hosts"].all? { _1.include?("github") }
    eq "with a placeholder, so the VM never sees the value", "leve-github-token",
       entries.first["placeholder"]
    eq "and we know where it came from", true,
       Leve::Sandbox::HostAuth::ENV_VARS.map { "$#{_1}" }.include?(found["source"])
  else
    eq "no host credential, no secret", [], Leve::Sandbox.secret_entries(with_token)
  end
end

group "sandbox: the create spec speaks the binding's wire shape" do
  cfg = Leve::Sandbox.config("provision" => false, "githubAuth" => false)
  spec = Leve::Sandbox.create_spec(cfg, "leve-test", "/host/ws", "/workspace")
  eq "memory is a plain integer", 2048, spec["memory"]
  eq "the workspace is a bind mount, read-write",
     { "guest" => "/workspace", "host" => "/host/ws", "readonly" => false },
     spec["mounts"].first
  eq "env travels", "noninteractive", spec.dig("env", "DEBIAN_FRONTEND")
  eq "network policy attached", true, spec.key?("network")
  eq "no empty secrets key", false, spec.key?("secrets")
  eq "replace is set so the stable named sandbox is rebuilt", true, spec["replace"]
end

group "sandbox client contract" do
  Dir.mktmpdir do |dir|
    s = fake_sandbox(dir)
    eq "the test transport still presents an isolated client", true, s.isolated?
    r = s.exec("echo hello")
    eq "runs commands", "hello\n", r["stdout"]
    eq "reports exit codes", 3, s.exec("exit 3")["exitCode"]
    s.write_file("a/b.txt", "written")
    eq "writes files under the workspace", "written", File.read(File.join(dir, "a", "b.txt"))
    eq "and reads them back", "written", s.read_file("a/b.txt")
  end
end

group "rotating a scoped secret invalidates the persisted VM" do
  Dir.mktmpdir do |root|
    workspace = File.join(root, "workspace")
    FileUtils.mkdir_p(workspace)
    base = { "hostWorkspace" => workspace, "provision" => false, "githubAuth" => false,
             "secrets" => [{ "env" => "GITHUB_TOKEN", "value" => "token-one",
                             "hosts" => ["github.com"], "placeholder" => "leve-github-token" }] }
    first = Leve::Sandbox::Client.new(Leve::Sandbox.config(base), native: fake_native(workspace))
    rotated = Marshal.load(Marshal.dump(base))
    rotated["secrets"].first["value"] = "token-two"
    second = Leve::Sandbox::Client.new(Leve::Sandbox.config(rotated), native: fake_native(workspace))
    eq "secret values are hashed into the fingerprint", true,
       first.send(:fingerprint) != second.send(:fingerprint)
    eq "the raw token is never persisted in the fingerprint", false,
       first.send(:fingerprint).include?("token-one")
  end
end

group "sandbox startup progress is visible before the TUI exists" do
  output = Class.new(StringIO) { def tty? = true }.new
  progress = Leve::Sandbox::Progress.new(output)
  progress.stage("building microVM")
  sleep 0.12
  progress.stage("provisioning APT packages")
  sleep 0.1
  progress.finish("sandbox ready")
  eq "the spinner names build stages", true,
     output.string.include?("building microVM") && output.string.include?("provisioning APT packages")
  eq "completion includes elapsed time", true,
     output.string.include?("sandbox ready") && output.string.match?(/\([0-9.]+s\)/)
end

group "an unchanged provisioned VM is restarted instead of replaced" do
  Dir.mktmpdir do |root|
    workspace = File.join(root, "workspace")
    FileUtils.mkdir_p(workspace)
    native = fake_native(workspace)
    config = Leve::Sandbox.config("hostWorkspace" => workspace, "provision" => false,
                                  "githubAuth" => false, "bootstrap" => [])
    first = Leve::Sandbox::Client.new(config, native: native)
    first.start
    first.stop
    second = Leve::Sandbox::Client.new(config, native: native)
    second.start
    eq "only the first launch creates", 1, native.created.size
    eq "the next launch restarts the persisted VM", 1, native.started.size
    second.stop

    changed = Leve::Sandbox::Client.new(config.merge("memory" => 4096), native: native)
    changed.start
    eq "policy changes replace the VM", 2, native.created.size
    changed.stop
  end
end

group "sandbox DSL" do
  Dir.mktmpdir do |dir|
    path = File.join(dir, "sandbox.rb")
    File.write(path, <<~RUBY)
      sandbox do
        image "python:3.12"
        cpus 4
        memory 2048
        env "TZ", "UTC"
        allow "github.com", "api.github.com" do
          secret "GITHUB_TOKEN", value: "real-token", placeholder: "fake-token"
        end
        bootstrap "pip install -r requirements.txt", "pytest --version"
      end
    RUBY
    cfg = Leve::Sandbox.config(Leve::Sandbox.load_definition(path))
    eq "image", "python:3.12", cfg["image"]
    eq "resources", [4, 2048], [cfg["cpus"], cfg["memory"]]
    eq "env", { "TZ" => "UTC" }, cfg["env"]
    eq "bootstrap commands in order", ["pip install -r requirements.txt", "pytest --version"], cfg["bootstrap"]
    secret = cfg["secrets"].first
    eq "allow block scopes its secret", %w[github.com api.github.com], secret["hosts"]
    eq "the VM receives a fake placeholder", "fake-token", secret["placeholder"]
    eq "the real value remains in the proxy config", "real-token", secret["value"]
    eq "GitHub auth is not implicit", false, cfg["githubAuth"]
    eq "default tools avoid unauthenticated GitHub release lookup", [%w[node@lts], ["@ast-grep/cli"]],
       [cfg["mise"], cfg["npm"]]
    eq "defaults filled in", "/workspace", cfg["workdir"]
  end
end

group "durable conversations are named and main adopts existing history" do
  Dir.mktmpdir do |root|
    Leve::Project.init(root)
    project = Leve::Project.load(root)
    older = File.join(project.sessions_dir, "older.jsonl")
    newer = File.join(project.sessions_dir, "newer.jsonl")
    File.write(older, "")
    File.write(newer, "")
    File.utime(Time.at(10), Time.at(10), older)
    File.utime(Time.at(20), Time.at(20), newer)
    eq "latest legacy session is selected", newer, project.latest_session_path
    eq "main adopts the latest history", newer, project.conversation_path("main")
    other = project.conversation_path("research")
    eq "a named conversation gets its own session", true, other != newer
    eq "the mapping is stable", other, project.conversation_path("research")
    fresh = project.conversation_path("main", fresh: true)
    eq "/new rotates only the named conversation", true, fresh != newer
    eq "main now resumes the fresh session", fresh, project.conversation_path("main")
    error = begin
      project.conversation_path("../escape")
      nil
    rescue ArgumentError => e
      e.message
    end
    eq "unsafe names are rejected", true, error.include?("invalid conversation name")
  end
end

done
