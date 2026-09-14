# frozen_string_literal: true

require "rbconfig"

module Sadr
  module Testing
    class FakeServer
      DEFAULT_CAPABILITIES = {
        "positionEncoding" => "utf-16",
        "textDocumentSync" => {"openClose" => true, "change" => 2, "save" => {"includeText" => true}}
      }.freeze

      SCRIPT = <<~'RUBY'
        require "json"
        STDIN.binmode
        STDOUT.binmode
        STDOUT.sync = true

        def send_message(message)
          body = JSON.generate(message)
          STDOUT.write("Content-Length: #{body.bytesize}\r\n\r\n#{body}")
        end

        range = {start: {line: 0, character: 0}, end: {line: 0, character: 1}}
        command = {title: "Run", command: "run", arguments: []}
        messages = []
        semantic_refreshed = false
        pending_semantic = nil
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
            if ENV["SADR_SEMANTIC_REVERSE"]
              unless pending_semantic
                pending_semantic = message
                send_message(jsonrpc: "2.0", method: "semantic_started", params: {})
                next
              end
              send_message(jsonrpc: "2.0", id: message["id"], result: {resultId: "new", data: [0, 0, 2, 0, 0]})
              send_message(jsonrpc: "2.0", id: pending_semantic["id"], result: {resultId: "old", data: [0, 0, 1, 0, 0]})
              pending_semantic = nil
              next
            end
            if ENV["SADR_SEMANTIC_REFRESH"] && !semantic_refreshed
              semantic_refreshed = true
              send_message(jsonrpc: "2.0", id: "semantic-refresh", method: "workspace/semanticTokens/refresh", params: {})
              sleep(0.02)
            end
            if ENV["SADR_SEMANTIC_DELAY"]
              send_message(jsonrpc: "2.0", method: "semantic_started", params: {})
              sleep(Float(ENV["SADR_SEMANTIC_DELAY"]))
            end
            result = {resultId: "first", data: [0, 0, 1, 0, 0]}
          when "textDocument/semanticTokens/full/delta"
            result = {resultId: "second", edits: [{start: 2, deleteCount: 1, data: [2]}]}
          when "shutdown"
            result = nil
          when "textDocument/completion"
            result = {isIncomplete: false, items: [{label: "x", detail: "optional"}], itemDefaults: {commitCharacters: ["."]}}
          when "textDocument/hover"
            result = {contents: {kind: "markdown", value: "hover"}, range: range, extension: true}
          when "textDocument/signatureHelp"
            result = {signatures: [{label: "f(x)", parameters: [{label: [2, 3]}]}], activeSignature: 0}
          when "textDocument/documentSymbol"
            result = [{name: "x", kind: 13, range: range, selectionRange: range, children: []}]
          when "workspace/symbol"
            result = [{name: "x", kind: 13, location: {uri: "file:///tmp/test.rb"}, data: {optional: true}}]
          when "textDocument/codeAction"
            result = [{title: "Fix", command: command}]
          when "textDocument/codeLens"
            result = [{range: range, command: command, data: {optional: true}}]
          when "textDocument/inlayHint"
            result = [{position: {line: 0, character: 0}, label: [{value: "x", tooltip: "optional"}]}]
          when "textDocument/definition", "textDocument/typeDefinition", "textDocument/implementation", "textDocument/references", "textDocument/formatting"
            result = []
          when "textDocument/rename"
            result = {changes: {}}
          when "textDocument/diagnostic"
            result = {kind: "full", items: []}
          else
            result = message["params"]
          end
          if ENV["SADR_INVALID_METHOD"] == message["method"]
            result = message["method"] == "textDocument/formatting" ? [{range: {}, newText: "x"}] : "invalid"
          end
          if ENV["SADR_INVALID_ELEMENTS"]
            result = case message["method"]
            when "textDocument/completion" then [{}]
            when "textDocument/definition" then {}
            when "textDocument/codeAction", "textDocument/codeLens", "textDocument/inlayHint" then [1]
            when "textDocument/diagnostic" then {}
            else result
            end
          end
          if ENV["SADR_INVALID_STRUCTURES"]
            result = case message["method"]
            when "textDocument/completion" then {items: [{label: "x"}]}
            when "textDocument/hover" then {contents: {}}
            when "textDocument/signatureHelp" then {signatures: [{}]}
            when "textDocument/documentSymbol" then [{name: "x", kind: 13, range: range}]
            when "workspace/symbol" then [{name: "x", kind: 13, location: {}}]
            when "completionItem/resolve" then {}
            when "textDocument/codeLens" then [{range: range, command: {title: "Run"}}]
            else result
            end
          end
          send_message(jsonrpc: "2.0", id: message["id"], result: result)
        end
      RUBY

      def self.command = [RbConfig.ruby, "-e", SCRIPT]

      attr_reader :capabilities, :messages

      def initialize(responses: {}, capabilities: DEFAULT_CAPABILITIES)
        raise ArgumentError, "responses must be a Hash" unless responses.is_a?(Hash)
        raise ArgumentError, "capabilities must be a Hash" unless capabilities.is_a?(Hash)

        @responses = responses.transform_keys(&:to_s)
        @capabilities = capabilities
        @messages = []
        @lock = Mutex.new
      end

      def transport(&receive) = FakeTransport.new(self, &receive)

      def dispatch(message)
        @lock.synchronize { @messages << message }
        return [] unless message.key?("id") && message.key?("method")

        result = case message["method"]
        when "initialize" then {"capabilities" => @capabilities}
        when "shutdown" then nil
        else
          response = @responses.fetch(message["method"], message["params"])
          response.respond_to?(:call) ? response.call(message["params"], message) : response
        end
        [{"jsonrpc" => "2.0", "id" => message["id"], "result" => result}]
      end
    end
  end
end
