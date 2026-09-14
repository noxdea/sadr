# frozen_string_literal: true

module Sadr
  module Testing
    class FakeServer
      SCRIPT = <<~'RUBY'
        require "json"
        STDIN.binmode
        STDOUT.binmode
        STDOUT.sync = true

        def send_message(message)
          body = JSON.generate(message)
          STDOUT.write("Content-Length: #{body.bytesize}\r\n\r\n#{body}")
        end

        messages = []
        loop do
          headers = {}
          while (line = STDIN.gets) && line != "\r\n"
            key, value = line.strip.split(":", 2)
            headers[key] = value.strip
          end
          break unless line

          message = JSON.parse(STDIN.read(headers.fetch("Content-Length").to_i))
          messages << message
          break if message["method"] == "exit"
          next unless message.key?("id") && message.key?("method")

          case message["method"]
          when "initialize"
            result = {capabilities: {positionEncoding: "utf-16", textDocumentSync: {openClose: true, change: 2, save: {includeText: true}}, semanticTokensProvider: {legend: {tokenTypes: ["variable"], tokenModifiers: []}, full: {delta: true}}}}
          when "probe"
            result = messages
          when "server_request"
            send_message(jsonrpc: "2.0", id: "server-1", method: message["params"]["method"], params: message["params"].fetch("params", {}))
            result = true
          when "server_notification"
            send_message(jsonrpc: "2.0", method: message["params"]["method"], params: message["params"].fetch("params", {}))
            result = true
          when "stderr"
            STDERR.write("x" * (2 << 20))
            STDERR.flush
            result = true
          when "never"
            next
          when "crash"
            exit!(1)
          when "textDocument/semanticTokens/full"
            result = {resultId: "first", data: [0, 0, 1, 0, 0]}
          when "textDocument/semanticTokens/full/delta"
            result = {resultId: "second", edits: [{start: 2, deleteCount: 1, data: [2]}]}
          when "shutdown"
            result = nil
          else
            result = message["params"]
          end
          send_message(jsonrpc: "2.0", id: message["id"], result: result)
        end
      RUBY

      def self.command = [RbConfig.ruby, "-e", SCRIPT]
    end
  end
end
