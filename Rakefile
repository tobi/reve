# frozen_string_literal: true

# rake is a default gem, so this adds no dependency — the stdlib-only rule is
# about what leve needs at runtime, and that is still nothing.
require "rake/clean"
require_relative "lib/leve/version"

GEM_NAME = "leve"
GEMSPEC = "leve.gemspec"
GEM_FILE = "#{GEM_NAME}-#{Leve::VERSION}.gem"
CLOBBER.include(GEM_FILE, "pkg")

task default: %i[lint rbs test]

# Compile the leve_sandbox native extension. rb_sys is a development
# dependency, so it is present under Bundler but may be absent in a bare
# checkout; the guard keeps `rake -T` usable and turns a missing rb_sys (or a
# missing cargo toolchain) into a clear message instead of a load-time crash.
#
# The crate's Cargo.toml lives at ext/leve_sandbox/, with no root workspace
# manifest. RbSys::ExtensionTask eagerly runs `cargo metadata` from the
# current directory at load time, so we chdir into the crate directory for the
# instantiation only: that makes `cargo metadata` succeed and caches absolute
# paths on the task. Dir.chdir's block form restores the working directory
# (even on error) before the rest of the Rakefile loads.
begin
  require "rb_sys/extensiontask"

  Dir.chdir("ext/leve_sandbox") do
    RbSys::ExtensionTask.new("leve_sandbox") do |ext|
      # Land the cdylib at lib/leve/leve_sandbox.so, where
      # lib/leve/sandbox/native.rb requires it first.
      ext.lib_dir = "lib/leve"
    end
  end
rescue LoadError
  # rb_sys is not installed. Define a stub so `rake -T` still lists `compile`
  # and `rake compile` fails with an actionable message.
  desc "compile the leve_sandbox native extension"
  task :compile do
    abort <<~MSG.strip
      rb_sys is not installed, so the native extension cannot be built.

        gem install rb_sys

      then re-run `rake compile`.
    MSG
  end
rescue RbSys::CargoMetadataError
  # rb_sys loaded but `cargo metadata` failed (no Rust toolchain, unreadable
  # manifest). Same stub treatment so a bare checkout without cargo still gets
  # a usable `rake -T`.
  desc "compile the leve_sandbox native extension"
  task :compile do
    abort <<~MSG.strip
      the leve_sandbox Rust crate metadata could not be read. Building the
      native extension needs a Rust toolchain and ext/leve_sandbox/Cargo.toml.

        rustup install stable

      then re-run `rake compile`.
    MSG
  end
end

desc "run every suite, each in its own process"
task :test do
  sh RbConfig.ruby, "bin/test"
end

desc "syntax-check every ruby file"
task :lint do
  files = Dir["lib/**/*.rb", "ext/**/*.rb", "test/**/*.rb", "examples/**/*.rb",
              "channels/**/*.rb", "bin/*", "Rakefile", "*.gemspec"].select do |f|
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
  # gem install keeps every older version around; one installed leve is
  # enough, and a stale one on PATH is a confusing bug report.
  sh "gem", "cleanup", GEM_NAME do |ok, _|
    warn "gem cleanup failed; older versions are still installed" unless ok
  end
  puts
  puts "installed #{GEM_NAME} #{Leve::VERSION} — run `leve init` in a directory to start one"

  # rubygems warns that the executable will not run and then leaves it there.
  # Say what to do about it, with the actual path.
  bindir = Gem.bindir
  on_path = ENV["PATH"].to_s.split(File::PATH_SEPARATOR).include?(bindir)
  next if on_path

  puts
  puts "  \e[33mleve is installed in #{bindir}, which is not on your PATH\e[0m"
  hints = [["export PATH=\"#{bindir}:$PATH\"", "add this to your shell profile"],
           ["#{bindir}/leve --help", "or run it directly"]]
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
  sh "leve", "--help"
end

desc "print the version"
task :version do
  puts Leve::VERSION
end

desc "assert microsandbox is pinned exactly and matches the bound version"
task :version_check do
  cargo = File.read("ext/leve_sandbox/Cargo.toml")

  # `^microsandbox\s*=` matches the crate, not `microsandbox-network`, whose
  # name continues with `-`. The `"=` right after the opening quote is the
  # exact-version requirement: anything else (`~>`, `>=`, bare) fails.
  cargo_version = cargo[/^microsandbox\s*=\s*"=(\d[\d.]*)"/, 1]
  unless cargo_version
    raise "microsandbox is not pinned with an exact `=` requirement in " \
          "ext/leve_sandbox/Cargo.toml (expected `microsandbox = \"=X.Y.Z\"`)"
  end

  librs = File.read("ext/leve_sandbox/src/lib.rs")
  bound = librs[/MICROSANDBOX_VERSION:\s*&str\s*=\s*"([^"]+)"/, 1]
  unless bound
    raise "MICROSANDBOX_VERSION constant not found in ext/leve_sandbox/src/lib.rs"
  end

  if cargo_version != bound
    raise "version drift: Cargo.toml pins microsandbox =#{cargo_version} but " \
          "lib.rs binds MICROSANDBOX_VERSION = #{bound}"
  end

  puts "microsandbox pinned to =#{cargo_version}; matches lib.rs " \
       "MICROSANDBOX_VERSION (#{bound})"
end
