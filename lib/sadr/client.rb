# frozen_string_literal: true

module Sadr
  class Client
    POSITION_METHODS = {
      completion: "completion",
      hover: "hover",
      definition: "definition",
      type_definition: "typeDefinition",
      implementation: "implementation",
      signature_help: "signatureHelp"
    }.freeze
    RESPONSE_KINDS = {
      "completion" => :completion,
      "hover" => :hash_or_nil,
      "definition" => :locations,
      "typeDefinition" => :locations,
      "implementation" => :locations,
      "references" => :locations,
      "rename" => :workspace_edit,
      "signatureHelp" => :hash_or_nil,
      "documentSymbol" => :array_or_nil,
      "formatting" => :text_edits,
      "codeAction" => :code_actions,
      "codeLens" => :code_lenses,
      "inlayHint" => :inlay_hints,
      "diagnostic" => :diagnostic
    }.freeze

    attr_reader :capabilities, :transport, :diagnostics, :state, :errors, :server_info, :position_encoding

    def initialize(command:, root: Dir.pwd, dispatch: ->(&block) { block.call }, restart: true, env: {}, initialization_options: nil, configuration: {})
      @command = command
      @root = File.expand_path(root)
      @dispatch = dispatch
      @restart = restart
      @env = env
      @initialization_options = initialization_options
      @configuration = configuration
      @pending = {}
      @handlers = {}
      @documents = {}
      @diagnostics = {}
      @semantic = {}
      @sequence = 0
      @lock = Mutex.new
      @state = :stopped
      @restarts = 0
      @epoch = 0
      @errors = []
      @capabilities = {}
    end

    def start(timeout: 10)
      connect(timeout: timeout, state: :starting)
      @lock.synchronize do
        raise Error, "language server closed during initialization" unless @state == :starting

        @state = :running
      end
      @capabilities
    end

    def stop
      running = @lock.synchronize do
        @closing = true
        @state == :running
      end
      begin
        request("shutdown").await(timeout: 2) if running
        notify("exit") if @transport&.alive?
      rescue Error
        nil
      ensure
        @lock.synchronize do
          @epoch += 1
          @documents.clear
          @semantic.clear
          @diagnostics.clear
          @state = :stopped
        end
        @transport&.close
        fail_pending(Error.new("language server stopped"))
      end
    end

    def running? = @state == :running && !!@transport&.alive?

    def request(method, params = {})
      send_request(method, params, nil)
    end

    def notify(method, params = {})
      raise Error, "language server is not connected" unless @transport&.alive?

      @transport.write(jsonrpc: "2.0", method: method.to_s, params: params)
    end

    def on(method, &handler)
      raise ArgumentError, "handler required" unless handler

      @handlers[method.to_s] = handler
    end

    def supports?(capability) = !!@capabilities[capability.to_s]

    def open(document)
      validate_document(document)
      stored = Document.new(uri: document.uri.dup.freeze, language_id: document.language_id.dup.freeze,
        version: document.version, text: document.text.dup.freeze)
      @lock.synchronize do
        @documents[stored.uri] = stored
        @diagnostics.delete(stored.uri)
        @semantic.delete(stored.uri)
        notify_open(stored) if open_close?
      end
      stored.uri
    end

    def change(uri, version, changes)
      @lock.synchronize do
        document = @documents.fetch(uri) { raise Error, "document is not open" }
        unless Protocol.uint?(version) && version > document.version
          raise Error, "document version must increase"
        end
        raise Error, "content changes must be a nonempty Array" unless changes.is_a?(Array) && !changes.empty?

        text = document.text
        wire_changes = changes.map do |change|
          validate_change(change)
          if change.range
            index = DocumentIndex.new(text)
            first = Protocol.offset(index, change.range.start)
            last = Protocol.offset(index, change.range.end)
            raise Error, "invalid content change range" if last < first

            text = text.byteslice(0, first) + change.text + text.byteslice(last, text.bytesize - last)
            {range: Protocol.range_hash(change.range), text: change.text}
          else
            text = change.text
            {text: change.text}
          end
        end
        updated = Document.new(uri: document.uri, language_id: document.language_id, version: version, text: text.freeze)
        @documents[uri] = updated

        mode = sync_mode
        if [1, 2].include?(mode)
          content_changes = mode == 2 ? wire_changes : [{text: text}]
          notify("textDocument/didChange", {textDocument: {uri: uri, version: version}, contentChanges: content_changes})
        end
        updated
      end
    rescue KeyError
      raise Error, "document is not open"
    end

    def save(uri, text: nil)
      @lock.synchronize do
        document = @documents.fetch(uri) { raise Error, "document is not open" }
        sync = @capabilities["textDocumentSync"]
        save = sync.is_a?(Hash) ? sync["save"] : sync.is_a?(Integer) && sync.positive?
        return unless save

        if text
          raise Error, "saved text must be valid UTF-8" unless text.is_a?(String) && text.valid_encoding?
        end
        params = {textDocument: {uri: uri}}
        params[:text] = text || document.text if save.is_a?(Hash) && save["includeText"]
        notify("textDocument/didSave", params)
      end
    rescue KeyError
      raise Error, "document is not open"
    end

    def close(uri)
      @lock.synchronize do
        raise Error, "document is not open" unless @documents.delete(uri)

        @diagnostics.delete(uri)
        @semantic.delete(uri)
        notify("textDocument/didClose", {textDocument: {uri: uri}}) if open_close?
      end
    end

    POSITION_METHODS.each do |ruby_name, lsp_name|
      define_method(ruby_name) do |uri, position, **params|
        request_at(lsp_name, uri, position, params)
      end
    end

    def references(uri, position, include_declaration: true)
      request_at("references", uri, position, context: {includeDeclaration: !!include_declaration})
    end

    def rename(uri, position, new_name)
      raise Error, "new name must be a String" unless new_name.is_a?(String) && new_name.valid_encoding?

      request_at("rename", uri, position, newName: new_name)
    end

    def document_symbol(uri) = request_document("documentSymbol", uri)

    def formatting(uri, options)
      raise Error, "formatting options must be an object" unless options.is_a?(Hash)

      request_document("formatting", uri, options: options)
    end

    def code_action(uri, range, context)
      raise Error, "code action context must be an object" unless context.is_a?(Hash)

      request_document("codeAction", uri, range: Protocol.range_hash(range), context: context)
    end

    def code_lens(uri) = request_document("codeLens", uri)
    def inlay_hint(uri, range) = request_document("inlayHint", uri, range: Protocol.range_hash(range))

    def diagnostic(uri, previous_result_id: nil)
      params = {}
      if previous_result_id
        raise Error, "previous result id must be a String" unless previous_result_id.is_a?(String)

        params[:previousResultId] = previous_result_id
      end
      request_document("diagnostic", uri, **params)
    end

    def semantic_tokens(uri, version:)
      document, provider, previous = @lock.synchronize do
        document = @documents[uri]
        provider = @capabilities["semanticTokensProvider"]
        [document, provider, @semantic[uri]]
      end
      return [] unless document && document.version == version
      return [] unless provider.is_a?(Hash) && provider["full"]

      delta = previous && previous[0] && provider["full"].is_a?(Hash) && provider["full"]["delta"]
      method = delta ? "textDocument/semanticTokens/full/delta" : "textDocument/semanticTokens/full"
      params = {textDocument: {uri: uri}}
      params[:previousResultId] = previous[0] if delta
      result = checked_request(method, params, :semantic).await

      @lock.synchronize do
        current = @documents[uri]
        return [] unless result && current.equal?(document) && current.version == version

        raise Error, "unexpected semantic token delta" if !delta && !result.key?("data")

        data = result["data"] || Protocol.semantic_delta(previous[1], result["edits"])
        tokens = Protocol.semantic_tokens(data, legend: provider["legend"])
        @semantic[uri] = [result["resultId"], data]
        tokens
      end
    end

    def workspace_symbols(query)
      raise Error, "query must be a String" unless query.is_a?(String)

      checked_request("workspace/symbol", {query: query}, :array_or_nil)
    end

    def resolve_completion(item) = resolve("completionItem/resolve", item, :hash)
    def resolve_code_action(action) = resolve("codeAction/resolve", action, :code_action)
    def resolve_code_lens(lens) = resolve("codeLens/resolve", lens, :code_lens)

    def execute_command(command, arguments: [])
      raise Error, "command must be a nonempty String" unless command.is_a?(String) && !command.empty?
      raise Error, "arguments must be an Array" unless arguments.is_a?(Array)

      request("workspace/executeCommand", {command: command, arguments: arguments})
    end

    private

    def send_request(method, params, validator)
      id = @lock.synchronize { @sequence += 1 }
      future = Future.new(id, on_error: method(:report_error)) { |number| cancel(number) }
      @lock.synchronize { @pending[id] = [future, validator] }
      raise Error, "language server is not connected" unless @transport&.alive?

      @transport.write(jsonrpc: "2.0", id: id, method: method.to_s, params: params)
      future
    rescue StandardError => error
      @lock.synchronize { @pending.delete(id) }
      future.fulfill(error: error)
      future
    end

    def checked_request(method, params, kind)
      send_request(method, params, ->(value) { validate_response(kind, value) })
    end

    def connect(timeout:, state:)
      epoch = @lock.synchronize do
        raise Error, "language server is already started" if %i[starting restarting running].include?(@state)

        @closing = false
        @state = state
        @epoch += 1
        @semantic.clear
        @epoch
      end
      @transport = Transport.new(@command, cwd: @root, env: @env) do |message, error|
        receive(message, error, epoch)
      end
      result = checked_request("initialize", initialize_params, :initialize).await(timeout: timeout)
      @lock.synchronize do
        @capabilities = result["capabilities"]
        @server_info = result["serverInfo"]
        validate_capabilities
      end
      notify("initialized", {})
      @capabilities
    rescue StandardError => error
      @transport&.close if epoch
      fail_pending(error) if epoch
      @lock.synchronize { @state = :failed if epoch && @epoch == epoch }
      raise
    end

    def fulfill_response(entry, message)
      return unless entry

      future, validator = entry
      if message["error"]
        future.fulfill(error: ServerError.new(message["error"]))
      else
        value = validator ? validator.call(message["result"]) : message["result"]
        future.fulfill(value)
      end
    rescue StandardError => error
      future&.fulfill(error: error)
    end

    def validate_response(kind, value)
      case kind
      when :initialize
        valid = value.is_a?(Hash) && value["capabilities"].is_a?(Hash)
      when :hash
        valid = value.is_a?(Hash)
      when :hash_or_nil
        valid = value.nil? || value.is_a?(Hash)
      when :array_or_nil
        valid = value.nil? || value.is_a?(Array)
      when :locations
        valid = value.nil? || value.is_a?(Hash) || value.is_a?(Array)
      when :completion
        valid = value.nil? || value.is_a?(Array) || (value.is_a?(Hash) && value["items"].is_a?(Array))
      when :workspace_edit
        valid = value.nil?
        Protocol.workspace_edit(value) unless valid
        valid = true
      when :text_edits
        valid = value.nil?
        validate_text_edits(value) unless valid
        valid = true
      when :code_actions
        valid = value.nil? || value.is_a?(Array)
        value&.each { |action| Protocol.workspace_edit(action["edit"]) if action.is_a?(Hash) && action["edit"] }
      when :code_action
        valid = value.is_a?(Hash)
        Protocol.workspace_edit(value["edit"]) if valid && value["edit"]
      when :code_lenses
        valid = value.nil? || value.is_a?(Array)
        value&.each { |lens| Protocol.range_value(lens["range"]) if lens.is_a?(Hash) && lens["range"] }
      when :code_lens
        valid = value.is_a?(Hash)
        Protocol.range_value(value["range"]) if valid && value["range"]
      when :inlay_hints
        valid = value.nil? || value.is_a?(Array)
        value&.each { |hint| Protocol.position_value(hint["position"]) if hint.is_a?(Hash) && hint["position"] }
      when :diagnostic
        valid = value.nil? || value.is_a?(Hash)
        Protocol.diagnostics(value["items"]) if value.is_a?(Hash) && value["items"]
      when :semantic
        valid = value.nil? || (value.is_a?(Hash) &&
          (!value.key?("resultId") || value["resultId"].is_a?(String)) &&
          (!value.key?("data") || value["data"].is_a?(Array)) &&
          (!value.key?("edits") || value["edits"].is_a?(Array)))
      else
        valid = false
      end
      raise Error, "invalid LSP response" unless valid

      value
    rescue KeyError, NoMethodError
      raise Error, "invalid LSP response"
    end

    def validate_text_edits(value)
      raise Error, "invalid LSP response" unless value.is_a?(Array)

      value.each do |edit|
        valid = edit.is_a?(Hash) && edit["newText"].is_a?(String) && edit["newText"].valid_encoding?
        raise Error, "invalid LSP response" unless valid

        Protocol.range_value(edit["range"])
      end
    end

    def initialize_params
      {
        processId: Process.pid,
        rootUri: Protocol.uri(@root),
        clientInfo: {name: "Sadr", version: VERSION},
        workspaceFolders: [{uri: Protocol.uri(@root), name: File.basename(@root)}],
        initializationOptions: @initialization_options,
        capabilities: {
          general: {positionEncodings: ["utf-16"]},
          window: {workDoneProgress: true},
          textDocument: {
            synchronization: {dynamicRegistration: false, didSave: true},
            completion: {completionItem: {snippetSupport: true, documentationFormat: %w[markdown plaintext], resolveSupport: {properties: %w[documentation detail additionalTextEdits]}}},
            hover: {contentFormat: %w[markdown plaintext]},
            signatureHelp: {signatureInformation: {documentationFormat: %w[markdown plaintext], parameterInformation: {labelOffsetSupport: true}}},
            documentSymbol: {hierarchicalDocumentSymbolSupport: true},
            codeAction: {codeActionLiteralSupport: {codeActionKind: {valueSet: %w[quickfix refactor refactor.extract refactor.inline refactor.rewrite source source.organizeImports]}}, resolveSupport: {properties: ["edit"]}},
            publishDiagnostics: {relatedInformation: true, versionSupport: true},
            diagnostic: {dynamicRegistration: false, relatedDocumentSupport: false},
            inlayHint: {dynamicRegistration: false},
            codeLens: {dynamicRegistration: false},
            semanticTokens: {requests: {full: {delta: true}}, tokenTypes: %w[namespace type class enum interface struct typeParameter parameter variable property enumMember event function method macro keyword modifier comment string number regexp operator decorator], tokenModifiers: %w[declaration definition readonly static deprecated abstract async modification documentation defaultLibrary], formats: ["relative"], overlappingTokenSupport: false, multilineTokenSupport: false}
          },
          workspace: {applyEdit: true, configuration: true, workspaceFolders: true, workspaceEdit: {documentChanges: true, resourceOperations: %w[create rename delete], failureHandling: "abort"}}
        }
      }
    end

    def validate_capabilities
      mode = sync_mode
      raise Error, "invalid text document synchronization mode" unless mode.nil? || [0, 1, 2].include?(mode)

      @position_encoding = @capabilities.fetch("positionEncoding", "utf-16")
      unless @position_encoding == "utf-16"
        raise Error, "server selected unadvertised position encoding #{@position_encoding}"
      end
      semantic = @capabilities["semanticTokensProvider"]
      raise Error, "missing semantic token legend" if semantic && (!semantic.is_a?(Hash) || !semantic["legend"].is_a?(Hash))

      Protocol.semantic_tokens([], legend: semantic["legend"]) if semantic.is_a?(Hash)
    end

    def validate_document(document)
      raise Error, "expected a Document" unless document.is_a?(Document)
      valid_uri(document.uri)
      unless document.language_id.is_a?(String) && !document.language_id.empty?
        raise Error, "language id must be a nonempty String"
      end
      raise Error, "document version must be an unsigned integer" unless Protocol.uint?(document.version)
      unless document.text.is_a?(String) && document.text.valid_encoding?
        raise Error, "document text must be valid UTF-8"
      end
    end

    def validate_change(change)
      raise Error, "expected a ContentChange" unless change.is_a?(ContentChange)
      raise Error, "change text must be valid UTF-8" unless change.text.is_a?(String) && change.text.valid_encoding?

      Protocol.range_value(change.range) if change.range
    end

    def valid_uri(uri)
      valid = uri.is_a?(String) && !uri.empty? && !uri.include?("\0") && uri.valid_encoding?
      parsed = URI::DEFAULT_PARSER.parse(uri) if valid
      raise Error, "invalid URI" unless valid && parsed&.scheme && !parsed.scheme.empty?

      uri
    rescue URI::InvalidURIError
      raise Error, "invalid URI"
    end

    def request_at(method, uri, position, params = {})
      core = {textDocument: {uri: valid_uri(uri)}, position: Protocol.position_hash(position)}
      checked_request("textDocument/#{method}", params.merge(core), RESPONSE_KINDS.fetch(method))
    end

    def request_document(method, uri, **params)
      checked_request("textDocument/#{method}", params.merge(textDocument: {uri: valid_uri(uri)}), RESPONSE_KINDS.fetch(method))
    end

    def resolve(method, value, kind)
      raise Error, "resolve value must be an object" unless value.is_a?(Hash)

      checked_request(method, value, kind)
    end

    def notify_open(document)
      notify("textDocument/didOpen", {textDocument: {uri: document.uri, languageId: document.language_id, version: document.version, text: document.text}})
    end

    def sync_mode
      sync = @capabilities["textDocumentSync"]
      sync.is_a?(Hash) ? sync.fetch("change", 0) : sync
    end

    def open_close?
      sync = @capabilities["textDocumentSync"]
      sync.is_a?(Hash) ? sync["openClose"] : sync.is_a?(Integer) && sync.positive?
    end

    def cancel(id)
      @lock.synchronize { @pending.delete(id) }
      notify("$/cancelRequest", {id: id})
    rescue Error
      nil
    end

    def fail_pending(error)
      pending = @lock.synchronize do
        values = @pending.values
        @pending.clear
        values
      end
      pending.each { |future, _| future.fulfill(error: error) }
    end

    def report_error(error)
      bounded = Error.new("#{error.class}: #{error.message}".scrub.byteslice(0, 2048).scrub(""))
      @lock.synchronize do
        @errors << bounded
        @errors.shift if @errors.length > 200
      end
      @dispatch.call do
        begin
          @handlers["error"]&.call(bounded)
        rescue StandardError
          nil
        end
      end
    rescue StandardError
      nil
    end

    def receive(message, error, epoch = @epoch)
      return unless @lock.synchronize { epoch == @epoch }

      if error
        receive_error(error)
      elsif message.key?("id") && !message.key?("method")
        entry = @lock.synchronize { @pending.delete(message["id"]) }
        fulfill_response(entry, message)
      elsif message["method"]
        receive_call(message, epoch)
      end
    rescue StandardError => failure
      report_error(failure)
      if message&.key?("id") && message.key?("method")
        reply(message["id"], epoch, error: {code: -32603, message: "client dispatch failed"})
      end
    end

    def receive_error(error)
      running = @lock.synchronize do
        running = @state == :running
        @state = :failed
        running
      end
      fail_pending(Error.new(error.message))
      report_error(error)
      restart_server if running && @restart && !@closing && @restarts < 3
    end

    def receive_call(message, epoch)
      method = message["method"]
      params = message.fetch("params", {})
      @dispatch.call do
        next unless epoch == @epoch && !@closing

        begin
          receive_diagnostics(params) if method == "textDocument/publishDiagnostics"
          known = @handlers.key?(method)
          result = @handlers[method]&.call(params)
          next unless message.key?("id")

          unless known
            known, result = built_in_request(method, params)
          end
          respond_to_server(message["id"], epoch, known, result, method)
        rescue StandardError => failure
          report_error(failure)
          reply(message["id"], epoch, error: {code: -32603, message: "client request handler failed"}) if message.key?("id")
        end
      end
    end

    def receive_diagnostics(params)
      valid = params.is_a?(Hash) && params["uri"].is_a?(String) && params["diagnostics"].is_a?(Array)
      raise Error, "invalid diagnostics notification" unless valid

      version = params["version"]
      raise Error, "invalid diagnostic version" if !version.nil? && !version.is_a?(Integer)
      diagnostics = Protocol.diagnostics(params["diagnostics"])
      @lock.synchronize do
        document = @documents[params["uri"]]
        return if document && version && version < document.version

        @diagnostics[params["uri"]] = diagnostics
      end
    end

    def built_in_request(method, params)
      case method
      when "workspace/configuration"
        items = params.fetch("items")
        raise Error, "invalid configuration request" unless items.is_a?(Array)

        [true, items.map do |item|
          section = item["section"]
          section ? @configuration.dig(*section.split(".")) : @configuration
        end]
      when "workspace/workspaceFolders"
        [true, [{uri: Protocol.uri(@root), name: File.basename(@root)}]]
      when "window/workDoneProgress/create", "workspace/semanticTokens/refresh", "workspace/inlayHint/refresh", "workspace/codeLens/refresh", "workspace/diagnostic/refresh"
        @lock.synchronize { @semantic.clear } if method == "workspace/semanticTokens/refresh"
        [true, nil]
      else
        [false, nil]
      end
    end

    def respond_to_server(id, epoch, known, result, method)
      unless known
        reply(id, epoch, error: {code: -32601, message: "unsupported client request #{method}"})
        return
      end
      if result.is_a?(Future)
        result.then do |value, failure|
          if failure
            reply(id, epoch, error: {code: -32603, message: failure.message.byteslice(0, 2048).scrub})
          else
            reply(id, epoch, value: value)
          end
        end
      else
        reply(id, epoch, value: result)
      end
    end

    def reply(id, epoch, value: nil, error: nil)
      return unless epoch == @epoch && !@closing

      response = {jsonrpc: "2.0", id: id}
      error ? response[:error] = error : response[:result] = value
      @transport.write(response)
    rescue StandardError => failure
      report_error(failure)
    end

    def restart_server
      return if @restart_thread&.alive?

      previous = @transport
      @restart_thread = Thread.new do
        previous.close
        until @closing || @restarts >= 3
          @restarts += 1
          sleep(0.2 * @restarts)
          break if @closing

          begin
            connect(timeout: 10, state: :restarting)
            @lock.synchronize do
              raise Error, "language server restart was cancelled" if @closing || @state != :restarting

              @documents.values.each { |document| notify_open(document) if open_close? }
              @state = :running
            end
            break
          rescue StandardError => failure
            report_error(failure)
          end
        end
      end
    end
  end
end
