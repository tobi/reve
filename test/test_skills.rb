# frozen_string_literal: true

require_relative "helper"
include TestKit

def skill_file(dir, name, description, body = "Steps:\n1. do the thing\n", extra = "")
  d = File.join(dir, name)
  FileUtils.mkdir_p(d)
  File.write(File.join(d, "SKILL.md"), <<~MD)
    ---
    name: #{name}
    description: #{description}
    #{extra}---

    #{body}
  MD
  File.join(d, "SKILL.md")
end

Dir.mktmpdir do |root|
  project = File.join(root, "proj")
  FileUtils.mkdir_p(File.join(project, "workspace", "skills"))
  skill_file(File.join(project, "workspace", "skills"), "release-notes", "Write release notes from a git log range.")
  skill_file(File.join(project, "workspace", "skills"), "db-migrate", "Create and run a database migration.",
             "Use bin/rails db:migrate.\n")

  group "frontmatter parsing" do
    fm, body = Leve::Frontmatter.parse(<<~MD)
      ---
      name: thing
      description: >
        A long description
        over two lines
      disable-model-invocation: true
      tags:
        - a
        - b
      ---
      Body here.
    MD
    eq "scalar", "thing", fm["name"]
    eq "block scalar joined", true, fm["description"].include?("over two lines")
    eq "boolean", true, fm["disable-model-invocation"]
    eq "list", %w[a b], fm["tags"]
    eq "body separated", "Body here.\n", body
    eq "no frontmatter is left alone", [{}, "just text"], Leve::Frontmatter.parse("just text")
  end

  group "discovery is only the VM-editable workspace skills directory" do
    loaded = Leve::Skills.load(cwd: project)
    names = loaded["skills"].map { _1["name"] }.sort
    eq "the local skills are found", %w[db-migrate release-notes], names
    eq "no diagnostics for well-formed skills", [], loaded["diagnostics"]
    eq "body captured", true, Leve::Skills.find(loaded["skills"], "db-migrate")["body"].include?("db:migrate")
    eq "baseDir is the skill directory", true,
       Leve::Skills.find(loaded["skills"], "db-migrate")["baseDir"].end_with?("db-migrate")
    eq "the only root is workspace skills",
       ["workspace/skills"], Leve::Skills::PROJECT_DIRS
    eq "nothing outside the workspace is searched",
       [File.join(project, "workspace", "skills")], Leve::Skills.roots(project)

    # A skill sitting where another tool would keep it is simply not found.
    FileUtils.mkdir_p(File.join(project, ".pi/skills"))
    skill_file(File.join(project, ".pi/skills"), "outsider", "Should not be discovered.")
    eq "no .pi, no .agents, no $HOME", false,
       Leve::Skills.load(cwd: project)["skills"].map { _1["name"] }.include?("outsider")
  end

  group "validation warns, but still loads what it can" do
    bad = File.join(root, "bad", "skills")
    FileUtils.mkdir_p(bad)
    skill_file(bad, "Way-Too-Long-#{"x" * 70}", "fine description")
    skill_file(bad, "verbose", "y" * 1500)
    skill_file(bad, "nodesc", "")
    loaded = Leve::Skills.load(cwd: root, extra_dirs: [bad])
    msgs = loaded["diagnostics"].map { _1["message"] }
    eq "name length warned", true, msgs.any? { _1.include?("name exceeds 64") }
    eq "name charset warned", true, msgs.any? { _1.include?("lowercase") }
    eq "over-long description warned", true, msgs.any? { _1.include?("description exceeds 1024") }
    eq "missing description warned", true, msgs.any? { _1.include?("description is required") }
    eq "the over-long one still loads", true, loaded["skills"].map { _1["name"] }.include?("verbose")
    eq "the description-less one does not", false, loaded["skills"].map { _1["name"] }.include?("nodesc")
  end

  group "collisions: first root wins, loser is reported" do
    other = File.join(project, "other", "skills")
    FileUtils.mkdir_p(other)
    skill_file(other, "release-notes", "A different release-notes skill.")
    loaded = Leve::Skills.load(cwd: project, extra_dirs: [other])
    winner = Leve::Skills.find(loaded["skills"], "release-notes")
    eq "workspace skill wins", true, winner["path"].include?("/proj/workspace/skills/")
    eq "collision reported", true,
       loaded["diagnostics"].any? { _1["type"] == "collision" && _1["path"].include?("/other/") }
  end

  group "prompt section is the Agent Skills XML shape" do
    loaded = Leve::Skills.load(cwd: project)
    text = Leve::Skills.format_for_prompt(loaded["skills"])
    eq "opens the block", true, text.include?("<available_skills>")
    eq "names each skill", true, text.include?("<name>db-migrate</name>")
    eq "points at the file", true, text.include?("<location>")
    eq "tells the model how to load it", true, text.include?("read tool")
    hidden = [{ "name" => "x", "description" => "d", "path" => "/p", "disableModelInvocation" => true }]
    eq "hidden skills are excluded", "", Leve::Skills.format_for_prompt(hidden)
  end

  group "the harness loads editable skills at the conversation tail" do
    model = fake_model(root, [assistant_text("ok")])
    h, = test_harness(storage: "memory", model: model, cwd: project)
    eq "skills discovered", %w[db-migrate release-notes], h.skills.map { _1["name"] }.sort
    eq "the cached system prefix excludes mutable skills", false,
       h.system_prompt.include?("<name>release-notes</name>")
    eq "diagnostics exposed", [], h.skill_diagnostics
    h.prompt("hi")
    sent = File.readlines("#{ENV["LEVE_FAKE_SCRIPT"]}.requests").map { JSON.parse(_1) }
    message_text = sent.first["messages"].flat_map { _1["content"] }.filter_map { _1["text"] }.join("\n")
    eq "the provider saw the skills update", true, message_text.include?("<available_skills_update>")
    h.close
  end

  group "workspace skills reload at turn boundaries without changing the system prompt" do
    dynamic_root = File.join(project, "workspace", "skills")
    skill_file(dynamic_root, "new-helper", "Handle a newly learned workflow.", "Version one.\n")
    model = fake_model(root, [assistant_text("one"), assistant_text("two"), assistant_text("three"),
                              assistant_text("four")])
    h, = test_harness(storage: "memory", model: model, cwd: project)
    stable_prompt = h.system_prompt
    eq "mutable skills stay out of the cached system prefix", false,
       stable_prompt.include?("new-helper")

    h.prompt("first turn")
    requests = File.readlines("#{ENV["LEVE_FAKE_SCRIPT"]}.requests").map { JSON.parse(_1) }
    first_text = requests.first["messages"].flat_map { _1["content"] }.map { _1["text"] }.join("\n")
    eq "the current workspace catalog is exposed to the model", true,
       first_text.include?("<name>new-helper</name>")
    eq "the harness API exposes it too", true, !h.skill("new-helper").nil?

    skill_file(dynamic_root, "new-helper", "Handle the revised workflow.", "Version two.\n")
    h.prompt("second turn")
    requests = File.readlines("#{ENV["LEVE_FAKE_SCRIPT"]}.requests").map { JSON.parse(_1) }
    second_text = requests.last["messages"].flat_map { _1["content"] }.map { _1["text"] }.join("\n")
    eq "a changed file reloads the catalog", true, second_text.include?("revised workflow")
    eq "the cached system prompt remains byte-identical", stable_prompt, requests.last["system"]

    h.prompt("third turn")
    requests = File.readlines("#{ENV["LEVE_FAKE_SCRIPT"]}.requests").map { JSON.parse(_1) }
    newest = requests.last["messages"].last["content"].map { _1["text"] }.join("\n")
    eq "an unchanged catalog is not injected again", false, newest.include?("available_skills_update")

    File.write(File.join(dynamic_root, "new-helper", "template.txt"), "changed support file")
    h.prompt("fourth turn")
    requests = File.readlines("#{ENV["LEVE_FAKE_SCRIPT"]}.requests").map { JSON.parse(_1) }
    newest = requests.last["messages"].last["content"].map { _1["text"] }.join("\n")
    eq "a non-SKILL file change also reloads and announces the catalog", true,
       newest.include?("available_skills_update")
    h.close
  end

  group "a skill created by the model is available on its next step" do
    body = <<~SKILL
      ---
      name: live-skill
      description: A skill learned during this turn.
      ---
      Use the newly learned procedure.
    SKILL
    model = fake_model(root, [
      assistant_tool("write", { "path" => "workspace/skills/live-skill/SKILL.md", "content" => body }),
      assistant_text("I can use it now")
    ])
    h, = test_harness(storage: "memory", model: model, cwd: project)
    h.prompt("learn a skill")
    requests = File.readlines("#{ENV["LEVE_FAKE_SCRIPT"]}.requests").map { JSON.parse(_1) }
    second_text = requests.last["messages"].flat_map { _1["content"] }.map { _1["text"] }.join("\n")
    eq "the next model request sees the new skill", true, second_text.include?("<name>live-skill</name>")
    eq "the harness reloaded it in the same turn", true, !h.skill("live-skill").nil?
    h.close
  end

  group "running a skill puts its instructions in the transcript" do
    model = fake_model(root, [assistant_text("migrating")])
    h, = test_harness(storage: "memory", model: model, cwd: project)
    r = h.run_skill("db-migrate", "target the staging database")
    eq "run completed", true, r["ok"]
    first = entries_of(h.session).first
    text = first.dig("message", "content").map { _1["text"] }.join("\n")
    eq "the skill body is in the user message", true, text.include?("db:migrate")
    eq "with its path for relative resolution", true, text.include?("skills/db-migrate")
    eq "and the extra instructions", true, text.include?("staging database")
    eq "unknown skill is rejected", "unknown_skill", h.run_skill("nope").dig("error", "code")
    h.close
  end
end

done
