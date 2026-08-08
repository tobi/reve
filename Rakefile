# frozen_string_literal: true

# rake is a default gem, so this adds no dependency — the stdlib-only rule is
# about what reve needs at runtime, and that is still nothing.
require "rake/clean"
require_relative "lib/reve/version"

GEM_NAME = "reve-agent"
GEMSPEC = "reve.gemspec"
GEM_FILE = "#{GEM_NAME}-#{Reve::VERSION}.gem"
CLOBBER.include(GEM_FILE, "pkg")

task default: %i[lint rbs test]

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

desc "validate the RBS signatures in sig/"
task :rbs do
  require "rbs"
  loader = RBS::EnvironmentLoader.new
  loader.add(path: Pathname("sig"))
  env = RBS::Environment.from_loader(loader)
  # resolve_type_names is the real check: it fails on an unknown class, a bad
  # generic arity, or a type that does not exist.
  resolved = env.resolve_type_names
  puts "sig/ parses and resolves (#{resolved.class_decls.size} classes/modules, " \
       "#{Dir["sig/**/*.rbs"].size} file(s))"
rescue LoadError
  puts "rbs is not available; skipping"
end

desc "build #{GEM_FILE}"
task :build do
  sh "gem", "build", GEMSPEC
end

desc "build and install the gem locally"
task install: :build do
  sh "gem", "install", "--local", GEM_FILE
  # gem install keeps every older version around; one installed reve is
  # enough, and a stale one on PATH is a confusing bug report.
  sh "gem", "cleanup", GEM_NAME do |ok, _|
    warn "gem cleanup failed; older versions are still installed" unless ok
  end
  puts
  puts "installed #{GEM_NAME} #{Reve::VERSION} — run `reve init` in a directory to start one"

  # rubygems warns that the executable will not run and then leaves it there.
  # Say what to do about it, with the actual path.
  bindir = Gem.bindir
  on_path = ENV["PATH"].to_s.split(File::PATH_SEPARATOR).include?(bindir)
  next if on_path

  puts
  puts "  \e[33mreve is installed in #{bindir}, which is not on your PATH\e[0m"
  hints = [["export PATH=\"#{bindir}:$PATH\"", "add this to your shell profile"],
           ["#{bindir}/reve --help", "or run it directly"]]
  hints << ["mise reshim", "if ruby comes from mise"] if which("mise")
  width = hints.map { _1.first.length }.max
  hints.each { |cmd, note| puts "    #{cmd.ljust(width)}   \e[2m# #{note}\e[0m" }
end

def which(cmd)
  ENV["PATH"].to_s.split(File::PATH_SEPARATOR).any? { |d| File.executable?(File.join(d, cmd)) }
end

desc "remove the locally installed gem"
task :uninstall do
  sh "gem", "uninstall", "-x", "-a", GEM_NAME
end

desc "build, install, and check the installed binary runs"
task verify: :install do
  sh "reve", "--help"
end

desc "print the version"
task :version do
  puts Reve::VERSION
end
