# frozen_string_literal: true

# Leve ships this terminal channel by default. It is deliberately small and
# intentionally boring: channels are file-drop adapters, and examples/telegram.rb
# demonstrates a second channel with commands, KV state, and prompt guidance.
#
# The process's host Ractor owns stdin/stdout and this visitor. The durable
# harness owns lane Ractors. User input becomes messages sent to a lane:
#
#   prompt    -> lane.prompt
#   /steer    -> lane.steer
#   /followup -> lane.follow_up
#   /abort    -> lane.abort!
#
# The renderer consumes the harness watch stream. It never reads session state
# directly. This keeps channels composable: Telegram, HTTP, Slack, or a test
# visitor can implement the same event handoff without changing the durable core.
module Leve
  module Channels
    class TUI
      # `renderer` is injectable so the channel itself is easy to test and so
      # another renderer can visit the same event stream without a new channel.
      def initialize(harness, suspended, lane: "main", renderer: Leve::InteractiveAgentTUI)
        @renderer = renderer.new(harness, suspended, lane: lane)
      end

      # Visitor entry point for observers and alternate adapters.
      def visit(event)
        @renderer.render(event)
      end

      # The normal interactive path. The renderer owns the inline scrollback
      # screen, cbreak input line, completion, and slash-command dispatch.
      def run
        @renderer.run
      end

      # Useful to embedding callers that already own an input loop.
      def submit(text)
        @renderer.submit(text)
      end
    end
  end
end
