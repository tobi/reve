# frozen_string_literal: true

require "json"
require "fileutils"
require_relative "base"

module Reve
  module Storage
    # One file per session, one JSON object per line, in seq order. A line is
    # the atomic unit (§13). A malformed final line is the append that died
    # mid-write: it is truncated on open. A malformed line anywhere else is
    # corruption and open rejects.
    class Jsonl < Base
      attr_reader :path

      def self.open(path, metadata: {})
        if File.exist?(path)
          lines, truncate_at = read_lines(path)
          header = lines.first
          raise Corrupt, "missing header in #{path}" unless header && header["kind"] == "header"

          store = allocate
          store.send(:boot, path, header)
          lines.drop(1).each { |line| store.send(:replay, line) }
          File.truncate(path, truncate_at) if truncate_at
          store
        else
          new(path, metadata: metadata)
        end
      end

      def self.read_lines(path)
        out = []
        offset = 0
        truncate_at = nil
        File.foreach(path) do |raw|
          begin
            out << JSON.parse(raw)
          rescue JSON::ParserError
            # Torn tail? Only if this is the last line of the file.
            if offset + raw.bytesize >= File.size(path)
              truncate_at = offset
            else
              raise Corrupt, "malformed line at offset #{offset} in #{path}"
            end
          end
          offset += raw.bytesize
        end
        [out, truncate_at]
      end

      def initialize(path, metadata: {})
        @path = path
        FileUtils.mkdir_p(File.dirname(path))
        @io = File.open(path, "a")
        @io.sync = true
        super(metadata: metadata)
        write_line(@metadata.merge("kind" => "header"))
      end

      def close
        @io&.close
        @io = nil
      end

      private

      def boot(path, header)
        @path = path
        @io = File.open(path, "a")
        @io.sync = true
        @seq = 0
        @entries = {}
        @order = []
        @records = []
        @lanes = { "main" => nil }
        @lane_moves = []
        @facts = []
        @log = []
        @metadata = header.reject { |k, _| k == "kind" }
      end

      def persist(line)
        write_line(line)
        @log << line
        nil
      end

      def write_line(line)
        @io.write("#{JSON.generate(line)}\n")
        nil
      end
    end
  end
end
