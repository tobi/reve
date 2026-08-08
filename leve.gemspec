# frozen_string_literal: true

require_relative "lib/leve/version"

Gem::Specification.new do |spec|
  spec.name = "leve"
  spec.version = Leve::VERSION
  spec.summary = "A durable, microVM-sandboxed coding agent in Ruby"
  spec.description = <<~TEXT.strip
    Leve is a coding agent built on a durable harness: every message, tool call, and
    tool result is recorded so interrupted sessions can recover. An agent is a portable
    directory containing its instructions, models, tools, workspace skills, sandbox
    policy, and history. Model-authored commands run only in microsandbox microVMs.
  TEXT
  spec.authors = ["Tobi Lutke"]
  spec.license = "MIT"
  spec.homepage = "https://github.com/tobi/leve"

  spec.required_ruby_version = ">= 4.0"

  # The native extension is built from source at install time. There is no
  # Ruby gem runtime dependency for the sandbox: the extension binds the
  # `microsandbox` Rust crate directly.
  spec.extensions = ["ext/leve_sandbox/extconf.rb"]

  spec.files = Dir[
    "lib/**/*.rb",
    "ext/leve_sandbox/**/*.{rs,rb,toml}",
    "sig/**/*.rbs",
    "bin/leve",
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
  spec.executables = ["leve"]
  spec.require_paths = ["lib"]

  spec.add_development_dependency "rake"
  spec.add_development_dependency "rb_sys"

  spec.metadata = {
    "source_code_uri" => spec.homepage,
    "bug_tracker_uri" => "#{spec.homepage}/issues",
    "changelog_uri" => "#{spec.homepage}/blob/master/CHANGELOG.md",
    "documentation_uri" => "#{spec.homepage}#readme",
    "rubygems_mfa_required" => "true"
  }
end
