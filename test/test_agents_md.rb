# frozen_string_literal: true

require_relative "helper"
include TestKit

Dir.mktmpdir do |root|
  repo = File.join(root, "repo")
  nested = File.join(repo, "lib", "deep")
  FileUtils.mkdir_p(nested)
  FileUtils.mkdir_p(File.join(repo, ".git"))
  File.write(File.join(repo, "AGENTS.md"), "Root rule: always use tabs.")
  File.write(File.join(nested, "AGENTS.md"), "Deep rule: this directory is generated, do not edit.")
  File.write(File.join(nested, "gen.rb"), "# generated\n")

  group "discovery: repo root down to cwd, outermost first" do
    files = Leve::AgentsMd.discover(repo)
    eq "found the root file", [File.join(repo, "AGENTS.md")], files.map { _1["path"] }
    eq "content read", true, files.first["content"].include?("always use tabs")
    deeper = Leve::AgentsMd.discover(File.join(repo, "lib"), root: repo)
    eq "from a subdirectory the root file is still found", true,
       deeper.map { _1["path"] }.include?(File.join(repo, "AGENTS.md"))
    eq "and it comes before the closer ones", File.join(repo, "AGENTS.md"), deeper.first["path"]
  end

  group "the system prompt carries them" do
    sp = Leve::Prompt.system_prompt(cwd: repo)
    eq "instructions embedded", true, sp.include?("always use tabs")
    eq "path is attributed", true, sp.include?("<project_instructions path=")
    eq "no AGENTS.md → plain prompt", false,
       Leve::Prompt.system_prompt(cwd: root).include?("<project_instructions")
  end

  group "a fresh harness loads them without being asked" do
    model = fake_model(root, [assistant_text("ok")])
    h, = test_harness(storage: "memory", model: model, cwd: repo)
    eq "harness reports the files", [File.join(repo, "AGENTS.md")], h.agents_md.map { _1["path"] }
    h.prompt("hello")
    requests = File.readlines("#{ENV["LEVE_FAKE_SCRIPT"]}.requests").map { JSON.parse(_1) }
    eq "the provider actually saw them", true, requests.first["system"].include?("always use tabs")
    h.close
  end

  group "nested AGENTS.md rides along on the tool result that touched it" do
    model = fake_model(root, [assistant_tool("read", { "path" => File.join(nested, "gen.rb") }),
                              assistant_tool("read", { "path" => File.join(nested, "gen.rb") }, id: "tc2"),
                              assistant_text("understood")])
    h, = test_harness(storage: "memory", model: model, cwd: repo)
    h.prompt("read the generated file")
    results = entries_of(h.session).select { _1.dig("message", "role") == "toolResult" }
    texts = results.map { |r| r.dig("message", "content").map { _1["text"] }.join }
    eq "the deep rule arrived with the first touch", true, texts.first.include?("do not edit")
    eq "it is appended, not substituted", true, texts.first.include?("# generated")
    eq "and it is not repeated on the second touch", false, texts.last.include?("do not edit")
    eq "it never becomes a separate entry", %w[user assistant toolResult assistant toolResult assistant],
       entries_of(h.session).map { _1.dig("message", "role") }
    h.close
  end

  group "nested files outside the workspace are ignored" do
    eq "no injection above cwd", nil,
       Leve::AgentsMd.nested_for(File.join(root, "elsewhere.rb"), repo, [])
    eq "cwd's own file is not 'nested'", nil,
       Leve::AgentsMd.nested_for(File.join(repo, "x.rb"), repo, [])
  end
end

done
