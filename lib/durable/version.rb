# frozen_string_literal: true

# Kept in its own file so the gemspec can read the version without loading the
# agent (and everything it requires).
module Durable
  VERSION = "0.5.0"
end
