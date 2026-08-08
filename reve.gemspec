# frozen_string_literal: true

require_relative "lib/reve/version"

Gem::Specification.new do |spec|
  # `reve` on RubyGems is an unrelated Eve Online library. Keep Reve as the
  # project, namespace, and executable while publishing under an unambiguous name.
  spec.name = "reve-agent"
  spec.version = Reve::VERSION
  spec.summary = "A durable, microVM-sandboxed coding agent in Ruby"
  spec.description = <<~TEXT.strip
    Reve is a coding agent built on a durable harness: every message, tool call, and
    tool result is recorded so interrupted sessions can recover. An agent is a portable
    directory containing its instructions, models, tools, workspace skills, sandbox
    policy, and history. Model-authored commands run only in microsandbox microVMs.
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
    "examples/**/*.rb",
    # The bundled model configuration: without it an installed gem has no
    # providers and every launch fails with "unknown model".
    "models.yml",
    "README.md",
    "PLAN.md",
    "AGENTS.md",
    "CHANGELOG.md",
    "CODE_OF_CONDUCT.md",
    "CONTRIBUTING.md",
    "SECURITY.md",
    "LICENSE"
  ]
  spec.bindir = "bin"
  spec.executables = ["reve"]
  spec.require_paths = ["lib"]

  spec.add_dependency "microsandbox-rb", "~> 0.12"

  spec.metadata = {
    "source_code_uri" => spec.homepage,
    "bug_tracker_uri" => "#{spec.homepage}/issues",
    "changelog_uri" => "#{spec.homepage}/blob/master/CHANGELOG.md",
    "documentation_uri" => "#{spec.homepage}#readme",
    "rubygems_mfa_required" => "true"
  }
end
