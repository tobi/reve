# frozen_string_literal: true

require_relative "lib/reve/version"

Gem::Specification.new do |spec|
  spec.name = "reve"
  spec.version = Reve::VERSION
  spec.summary = "A durable coding agent in pure Ruby, on Ractors"
  spec.description = <<~TEXT.strip
    reve is a coding agent built on a durable harness: every message, tool call and
    tool result is recorded before it happens, so an interrupted session resumes exactly
    where it stopped. An agent is a directory — instructions.md, tools/*.rb, skills/,
    sandbox/ — and model-authored commands run in mandatory microsandbox microVMs.
  TEXT
  spec.authors = ["Tobi Lutke"]
  spec.license = "MIT"
  spec.homepage = "https://github.com/tobi/reve"

  spec.required_ruby_version = ">= 4.0"

  spec.files = Dir[
    "lib/**/*.rb",
    "sig/**/*.rbs",
    "bin/reve",
    "channels/tui.rb",
    # The bundled model configuration: without it an installed gem has no
    # providers and every launch fails with "unknown model".
    "models.yml",
    "README.md",
    "PLAN.md",
    "AGENTS.md",
    "LICENSE"
  ]
  spec.bindir = "bin"
  spec.executables = ["reve"]
  spec.require_paths = ["lib"]

  spec.add_dependency "microsandbox-rb", "~> 0.12"

  spec.metadata = {
    "source_code_uri" => spec.homepage,
    "rubygems_mfa_required" => "false"
  }
end
