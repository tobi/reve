# frozen_string_literal: true

# rake is a default gem, so this adds no dependency — the stdlib-only rule is
# about what rbagent needs at runtime, and that is still nothing.
require "rake/clean"
require_relative "lib/durable/version"

GEM_NAME = "rbagent"
GEM_FILE = "#{GEM_NAME}-#{Durable::VERSION}.gem"
CLOBBER.include(GEM_FILE, "pkg")

task default: :test

desc "run every suite, each in its own process"
task :test do
  sh RbConfig.ruby, "bin/test"
end

desc "syntax-check every ruby file"
task :lint do
  files = Dir["lib/**/*.rb", "test/**/*.rb", "bin/*", "Rakefile", "*.gemspec"].select do |f|
    File.file?(f) && (f.end_with?(".rb", ".gemspec", "Rakefile") || File.read(f, 64).start_with?("#!"))
  end
  bad = files.reject { |f| system(RbConfig.ruby, "-c", f, out: File::NULL, err: File::NULL) }
  raise "syntax errors in: #{bad.join(", ")}" unless bad.empty?

  puts "#{files.size} files parse"
end

desc "build #{GEM_FILE}"
task :build do
  sh "gem", "build", "#{GEM_NAME}.gemspec"
end

desc "build and install the gem locally"
task install: :build do
  sh "gem", "install", "--local", GEM_FILE
  puts
  puts "installed #{GEM_NAME} #{Durable::VERSION} — run `rbagent init` in a directory to start one"
end

desc "remove the locally installed gem"
task :uninstall do
  sh "gem", "uninstall", "-x", "-a", GEM_NAME
end

desc "build, install, and check the installed binary runs"
task verify: :install do
  sh "rbagent", "--help"
end

desc "print the version"
task :version do
  puts Durable::VERSION
end
