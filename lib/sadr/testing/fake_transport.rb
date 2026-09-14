# frozen_string_literal: true

module Sadr
  module Testing
    class FakeTransport < Transport
      MAX_TRY_FRAME = 512
      STOP = Object.new.freeze
      private_constant :MAX_TRY_FRAME, :STOP

      attr_reader :stderr_lines, :pid

      def initialize(server, &receive)
        raise ArgumentError, "receiver required" unless receive

        @server = server
        @receive = receive
        @stderr_lines = []
        @pid = Process.pid
        @lock = Mutex.new
        @write_lock = Mutex.new
        @responses = Queue.new
        @alive = true
        @reader = Thread.new { read }
        @reader.report_on_exception = false
      end

      def write(message)
        message, = wire(message)
        responses = @write_lock.synchronize do
          raise Error, "language server write failed: closed transport" unless alive?

          @server.dispatch(message)
        end
        enqueue(responses)
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
        enqueue(responses)
        true
      end

      def alive? = @lock.synchronize { @alive }

      def close
        reader = @lock.synchronize do
          @responses.clear
          if @alive
            @alive = false
            @responses << STOP
          end
          @reader
        end
        return if reader == Thread.current

        reader.kill unless reader.join(1)
        reader.join
        nil
      end

      private

      def wire(message)
        value = frame(message)
        body_start = value.index("\r\n\r\n") + 4
        [JSON.parse(value.byteslice(body_start, value.bytesize - body_start)), value.bytesize]
      rescue JSON::ParserError => error
        raise Error, "invalid LSP JSON: #{error.message.byteslice(0, 256)}"
      end

      def enqueue(responses)
        messages = responses.map { |response| wire(response).first }
        @lock.synchronize do
          return unless @alive

          messages.each { |message| @responses << message }
        end
      end

      def read
        loop do
          message = @responses.pop
          break if message.equal?(STOP)

          @receive.call(message, nil)
        end
      rescue StandardError => error
        begin
          @receive.call(nil, error) if alive?
        rescue StandardError
          nil
        end
      ensure
        @lock.synchronize { @alive = false }
      end
    end
  end
end
