# frozen_string_literal: true

module Sadr
  class Transport
    MAX_MESSAGE = 32 << 20
    MAX_TRY_FRAME = 512
    private_constant :MAX_TRY_FRAME

    attr_reader :stderr_lines, :pid

    def initialize(command, cwd: nil, env: {}, on_spawn: nil, &receive)
      valid = command.is_a?(Array) && !command.empty? && command.all? do |part|
        part.is_a?(String) && !part.include?("\0")
      end
      raise ArgumentError, "command must be a nonempty argument array" unless valid
      raise ArgumentError, "receiver required" unless receive

      options = cwd ? {chdir: cwd} : {}
      @close_lock = Mutex.new
      @closing = false
      @reader = @logger = nil
      @write_lock = Mutex.new
      @stderr_lines = []
      @stdin, @stdout, @stderr, @process = Open3.popen3(env, *command, **options)
      @pid = @process.pid
      begin
        on_spawn&.call(self)
        @close_lock.synchronize do
          raise Error, "language server connection was cancelled" if @closing

          @stdin.binmode
          @stdout.binmode
          @reader = Thread.new { read(receive) }
          @logger = Thread.new { read_stderr }
        end
      rescue StandardError
        close
        raise
      end
    end

    def self.read_message(io)
      headers = {}
      count = 0
      loop do
        line = io.gets("\r\n", 8193)
        return nil if line.nil? && headers.empty?
        raise Error, "truncated or oversized LSP header" unless line && line.end_with?("\r\n") && line.bytesize <= 8192
        break if line == "\r\n"

        count += line.bytesize
        raise Error, "oversized LSP headers" if count > 16_384
        raise Error, "non-ASCII LSP header" unless line.ascii_only?

        key, value = line.strip.split(":", 2)
        raise Error, "invalid LSP header" unless value && key.match?(/\A[A-Za-z][A-Za-z0-9-]*\z/)

        key = key.downcase
        raise Error, "duplicate LSP header" if headers.key?(key)

        headers[key] = value.strip
      end
      raw_length = headers["content-length"]
      raise Error, "missing or invalid Content-Length" unless raw_length&.match?(/\A\d+\z/)

      length = Integer(raw_length, 10)
      raise Error, "oversized LSP message" unless length.between?(1, MAX_MESSAGE)

      charset = headers["content-type"]&.match(/charset\s*=\s*"?([^;"\s]+)/i)&.[](1)
      raise Error, "unsupported LSP character encoding" if charset && !%w[utf-8 utf8].include?(charset.downcase)

      body = io.read(length)
      raise Error, "truncated LSP body" unless body && body.bytesize == length

      body.force_encoding(Encoding::UTF_8)
      raise Error, "invalid LSP UTF-8 body" unless body.valid_encoding?

      validate_message(JSON.parse(body))
    rescue JSON::ParserError => error
      raise Error, "invalid LSP JSON: #{error.message.byteslice(0, 256)}"
    end

    def self.validate_message(message)
      raise Error, "invalid JSON-RPC message" unless message.is_a?(Hash) && message["jsonrpc"] == "2.0"
      if message.key?("method")
        raise Error, "invalid JSON-RPC method" unless message["method"].is_a?(String) && !message["method"].empty?
        invalid_params = message.key?("params") && !message["params"].is_a?(Hash) && !message["params"].is_a?(Array)
        raise Error, "invalid JSON-RPC parameters" if invalid_params
        raise Error, "request contains a response" if message.key?("result") || message.key?("error")
      else
        valid_response = message.key?("id") && (message.key?("result") ^ message.key?("error"))
        raise Error, "invalid JSON-RPC response" unless valid_response
        if message.key?("error")
          error = message["error"]
          valid_error = error.is_a?(Hash) && error["code"].is_a?(Integer) && error["message"].is_a?(String)
          raise Error, "invalid JSON-RPC error" unless valid_error
        end
      end
      id = message["id"]
      valid_id = id.is_a?(Integer) || id.is_a?(String) || (id.nil? && !message.key?("method"))
      raise Error, "invalid JSON-RPC id" if message.key?("id") && !valid_id

      message
    end

    def write(message)
      frame = frame(message)

      @write_lock.synchronize do
        @stdin.write(frame)
        @stdin.flush
      end
    rescue IOError, Errno::EPIPE => error
      raise Error, "language server write failed: #{error.message}"
    end

    def try_write(message)
      value = frame(message)
      return false if value.bytesize > MAX_TRY_FRAME || !@write_lock.try_lock

      begin
        written = @stdin.write_nonblock(value, exception: false)
        return false if written == :wait_writable
        return true if written == value.bytesize

        @stdin.close unless @stdin.closed?
        false
      rescue IOError, SystemCallError
        false
      ensure
        @write_lock.unlock
      end
    end

    def alive? = @process.alive?

    def close
      closing = @close_lock.synchronize do
        next false if @closing

        @closing = true
      end
      return unless closing

      @stdin.close unless @stdin.closed?
      unless @process.join(1)
        begin
          Process.kill("TERM", @pid)
        rescue Errno::ESRCH
          nil
        end
        unless @process.join(1)
          begin
            Process.kill("KILL", @pid)
          rescue Errno::ESRCH
            nil
          end
          @process.join
        end
      end
      [@stdout, @stderr].each { |io| io.close unless io.closed? }
      [@reader, @logger].compact.each do |thread|
        next if thread == Thread.current

        thread.kill unless thread.join(1)
      end
    end

    private

    def frame(message)
      raise Error, "expected JSON-RPC object" unless message.is_a?(Hash)

      normalized = message.transform_keys(&:to_s)
      normalized["error"] = normalized["error"].transform_keys(&:to_s) if normalized["error"].is_a?(Hash)
      self.class.validate_message(normalized)
      body = JSON.generate(message).b
      raise Error, "oversized LSP message" unless body.bytesize.between?(1, MAX_MESSAGE)

      "Content-Length: #{body.bytesize}\r\n\r\n".b + body
    rescue JSON::GeneratorError => error
      raise Error, "invalid LSP JSON: #{error.message.byteslice(0, 256)}"
    end

    def read(receive)
      loop do
        message = self.class.read_message(@stdout)
        break unless message

        receive.call(message, nil)
      end
      receive.call(nil, Error.new("language server closed stdout")) unless @closing
    rescue StandardError => error
      begin
        receive.call(nil, error) unless @closing
      rescue StandardError
        nil
      end
    end

    def read_stderr
      while (line = @stderr.gets("\n", 8192))
        @stderr_lines << line.scrub.byteslice(0, 8192).scrub("")
        @stderr_lines.shift if @stderr_lines.length > 200
      end
    rescue IOError
      nil
    end
  end
end
