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
  FileUtils.mkdir_p(File.join(project, ".agents/skills"))
  FileUtils.mkdir_p(File.join(project, ".pi/skills"))
  skill_file(File.join(project, ".agents/skills"), "release-notes", "Write release notes from a git log range.")
  skill_file(File.join(project, ".pi/skills"), "db-migrate", "Create and run a database migration.",
             "Use bin/rails db:migrate.\n")

  group "frontmatter parsing" do
    fm, body = Durable::Frontmatter.parse(<<~MD)
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
    eq "no frontmatter is left alone", [{}, "just text"], Durable::Frontmatter.parse("just text")
  end

  group "discovery across .agents/skills and .pi/skills" do
    loaded = Durable::Skills.load(cwd: project, user: false)
    names = loaded["skills"].map { _1["name"] }.sort
    eq "both roots scanned", %w[db-migrate release-notes], names
    eq "no diagnostics for well-formed skills", [], loaded["diagnostics"]
    eq "body captured", true, Durable::Skills.find(loaded["skills"], "db-migrate")["body"].include?("db:migrate")
    eq "baseDir is the skill directory", true,
       Durable::Skills.find(loaded["skills"], "db-migrate")["baseDir"].end_with?("db-migrate")
  end

  group "validation warns, but still loads what it can" do
    bad = File.join(root, "bad", "skills")
    FileUtils.mkdir_p(bad)
    skill_file(bad, "Way-Too-Long-#{"x" * 70}", "fine description")
    skill_file(bad, "verbose", "y" * 1500)
    skill_file(bad, "nodesc", "")
    loaded = Durable::Skills.load(cwd: root, extra_dirs: [bad], user: false)
    msgs = loaded["diagnostics"].map { _1["message"] }
    eq "name length warned", true, msgs.any? { _1.include?("name exceeds 64") }
    eq "name charset warned", true, msgs.any? { _1.include?("lowercase") }
    eq "over-long description warned", true, msgs.any? { _1.include?("description exceeds 1024") }
    eq "missing description warned", true, msgs.any? { _1.include?("description is required") }
    eq "the over-long one still loads", true, loaded["skills"].map { _1["name"] }.include?("verbose")
    eq "the description-less one does not", false, loaded["skills"].map { _1["name"] }.include?("nodesc")
  end

  group "collisions: first root wins, loser is reported" do
    other = File.join(root, "other", "skills")
    FileUtils.mkdir_p(other)
    skill_file(other, "release-notes", "A different release-notes skill.")
    loaded = Durable::Skills.load(cwd: project, extra_dirs: [other], user: false)
    winner = Durable::Skills.find(loaded["skills"], "release-notes")
    eq "project skill wins", true, winner["path"].include?("/proj/.agents/skills/")
    eq "collision reported", true,
       loaded["diagnostics"].any? { _1["type"] == "collision" && _1["path"].include?("/other/") }
  end

  group "prompt section is the Agent Skills XML shape" do
    loaded = Durable::Skills.load(cwd: project, user: false)
    text = Durable::Skills.format_for_prompt(loaded["skills"])
    eq "opens the block", true, text.include?("<available_skills>")
    eq "names each skill", true, text.include?("<name>db-migrate</name>")
    eq "points at the file", true, text.include?("<location>")
    eq "tells the model how to load it", true, text.include?("read tool")
    hidden = [{ "name" => "x", "description" => "d", "path" => "/p", "disableModelInvocation" => true }]
    eq "hidden skills are excluded", "", Durable::Skills.format_for_prompt(hidden)
  end

  group "the harness loads skills into the system prompt" do
    model = fake_model(root, [assistant_text("ok")])
    h, = Durable::Harness.create(storage: "memory", model: model, cwd: project, user_skills: false)
    eq "skills discovered", %w[db-migrate release-notes], h.skills.map { _1["name"] }.sort
    eq "system prompt carries them", true, h.system_prompt.include?("<name>release-notes</name>")
    eq "diagnostics exposed", [], h.skill_diagnostics
    h.prompt("hi")
    sent = File.readlines("#{ENV["DURABLE_FAKE_SCRIPT"]}.requests").map { JSON.parse(_1) }
    eq "the provider saw the skills section", true, sent.first["system"].include?("<available_skills>")
    h.close
  end

  group "running a skill puts its instructions in the transcript" do
    model = fake_model(root, [assistant_text("migrating")])
    h, = Durable::Harness.create(storage: "memory", model: model, cwd: project, user_skills: false)
    r = h.run_skill("db-migrate", "target the staging database")
    eq "run completed", true, r["ok"]
    first = entries_of(h.session).first
    text = first.dig("message", "content", 0, "text")
    eq "the skill body is in the user message", true, text.include?("db:migrate")
    eq "with its path for relative resolution", true, text.include?(".pi/skills/db-migrate")
    eq "and the extra instructions", true, text.include?("staging database")
    eq "unknown skill is rejected", "unknown_skill", h.run_skill("nope").dig("error", "code")
    h.close
  end
end

done
