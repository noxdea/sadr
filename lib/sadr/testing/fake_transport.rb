# frozen_string_literal: true

module Sadr
  module Testing
    class FakeTransport < Transport
      MAX_TRY_FRAME = 512
      private_constant :MAX_TRY_FRAME

      attr_reader :stderr_lines, :pid

      def initialize(server, &receive)
        raise ArgumentError, "receiver required" unless receive

        @server = server
        @receive = receive
        @stderr_lines = []
        @pid = Process.pid
        @lock = Mutex.new
        @write_lock = Mutex.new
        @alive = true
      end

      def write(message)
        message, = wire(message)
        responses = @write_lock.synchronize do
          raise Error, "language server write failed: closed transport" unless alive?

          @server.dispatch(message)
        end
        deliver(responses)
        nil
      end

      def try_write(message)
        message, bytesize = wire(message)
        return false if bytesize > MAX_TRY_FRAME || !@write_lock.try_lock

        begin
          return false unless alive?

          responses = @server.dispatch(message)
        ensure
          @write_lock.unlock
        end
        deliver(responses)
        true
      end

      def alive? = @lock.synchronize { @alive }

      def close
        @lock.synchronize { @alive = false }
        nil
      end

      private

      def wire(message)
        body = JSON.generate(message)
        normalized = Transport.validate_message(JSON.parse(body))
        [normalized, body.bytesize + "Content-Length: #{body.bytesize}\r\n\r\n".bytesize]
      rescue JSON::GeneratorError, JSON::ParserError => error
        raise Error, "invalid LSP JSON: #{error.message.byteslice(0, 256)}"
      end

      def deliver(responses)
        responses.each { |response| @receive.call(wire(response).first, nil) }
      end
    end
  end
end
