# frozen_string_literal: true

require_relative "lib/durable/version"

Gem::Specification.new do |spec|
  spec.name = "rbagent"
  spec.version = Durable::VERSION
  spec.summary = "A durable coding agent in pure Ruby, on Ractors"
  spec.description = <<~TEXT.strip
    rbagent is a coding agent built on a durable harness: every message, tool call and
    tool result is recorded before it happens, so an interrupted session resumes exactly
    where it stopped. An agent is a directory — instructions.md, tools/*.rb, skills/,
    sandbox/ — and the whole thing runs on Ractors with no gem dependencies at all.
  TEXT
  spec.authors = ["Tobi Lutke"]
  spec.license = "MIT"
  spec.homepage = "https://github.com/tobi/rbagent"

  spec.required_ruby_version = ">= 4.0"

  spec.files = Dir[
    "lib/**/*.rb",
    "bin/rbagent",
    # The bundled model configuration: without it an installed gem has no
    # providers and every launch fails with "unknown model".
    "models.yml",
    "README.md",
    "PLAN.md",
    "AGENTS.md",
    "LICENSE"
  ]
  spec.bindir = "bin"
  spec.executables = ["rbagent"]
  spec.require_paths = ["lib"]

  # No runtime dependencies, by design: stdlib only.
  spec.metadata = {
    "source_code_uri" => spec.homepage,
    "rubygems_mfa_required" => "false"
  }
end
