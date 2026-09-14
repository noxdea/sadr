# frozen_string_literal: true

module Sadr
  module Testing
    class FakeClient < Client
      attr_reader :server

      def initialize(server: FakeServer.new, **options)
        @server = server
        super(**{command: FakeServer.command, restart: false}.merge(options))
      end

      private

      def build_transport(epoch)
        @server.transport { |message, error| receive(message, error, epoch) }
      end
    end
  end
end
