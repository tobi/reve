# frozen_string_literal: true

# Build the leve_sandbox native extension with rb_sys, which drives cargo and
# installs the compiled cdylib into the load path. The target name
# "leve/leve_sandbox" makes the artifact land at lib/leve/leve_sandbox.so,
# which is exactly where lib/leve/sandbox/native.rb looks for it first
# (`require "leve/leve_sandbox"`).
require "mkmf"
require "rb_sys/mkmf"

create_rust_makefile("leve/leve_sandbox")
