# frozen_string_literal: true

# Kept in its own file so the gemspec can read the version without loading the
# agent (and everything it requires).
module Reve
  VERSION = "0.8.0"
end
