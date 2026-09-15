# frozen_string_literal: true

module Sadr
  class Client
    POSITION_METHODS = {
      completion: "completion",
      hover: "hover",
      definition: "definition",
      type_definition: "typeDefinition",
      implementation: "implementation",
      signature_help: "signatureHelp",
      prepare_rename: "prepareRename",
      document_highlight: "documentHighlight",
      prepare_call_hierarchy: "prepareCallHierarchy",
      prepare_type_hierarchy: "prepareTypeHierarchy",
      linked_editing_range: "linkedEditingRange"
    }.freeze
    RESPONSE_KINDS = {
      "completion" => :completion,
      "hover" => :hover,
      "definition" => :locations,
      "typeDefinition" => :locations,
      "implementation" => :locations,
      "references" => :locations,
      "rename" => :workspace_edit,
      "prepareRename" => :prepare_rename,
      "documentHighlight" => :document_highlights,
      "prepareCallHierarchy" => :hierarchy_items,
      "prepareTypeHierarchy" => :hierarchy_items,
      "linkedEditingRange" => :linked_editing_ranges,
      "signatureHelp" => :signature_help,
      "documentSymbol" => :document_symbols,
      "formatting" => :text_edits,
      "rangeFormatting" => :text_edits,
      "codeAction" => :code_actions,
      "codeLens" => :code_lenses,
      "inlayHint" => :inlay_hints,
      "foldingRange" => :folding_ranges,
      "documentLink" => :document_links,
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
      @configuration = json_snapshot(configuration, "configuration must be JSON")
      @pending = {}
      @handlers = {}
      @documents = {}
      @diagnostics = {}
      @semantic = {}
      @semantic_requests = Hash.new(0)
      @sequence = 0
      @lock = Mutex.new
      @document_lock = Mutex.new
      @configuration_lock = Mutex.new
      @connecting_transport = nil
      @state = :stopped
      @restarts = 0
      @epoch = 0
      @semantic_generation = 0
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
      running, transport, stop_epoch, connecting, restart_thread = @lock.synchronize do
        @closing = true
        [@state == :running, @transport, @epoch, @connecting_transport, @restart_thread]
      end
      shutdown = nil
      begin
        shutdown = Thread.new do
          locked = false
          begin
            locked = @document_lock.try_lock
            next unless locked

            send_request("shutdown", {}, nil, state: :running, epoch: stop_epoch, transport: transport, allow_closing: true).await(timeout: 2)
            send_notification("exit", {}, state: :running, epoch: stop_epoch, transport: transport, allow_closing: true) if transport&.alive?
          rescue Error
            nil
          ensure
            @document_lock.unlock if locked
          end
        end if running
        shutdown&.join(2)
      ensure
        [transport, connecting].compact.uniq.each(&:close)
        [shutdown, restart_thread].compact.uniq.each { |thread| finish_thread(thread) }
        pending = @lock.synchronize do
          next unless @epoch == stop_epoch && @transport.equal?(transport)

          @epoch += 1
          @documents.clear
          @semantic.clear
          @semantic_requests.clear
          @semantic_generation += 1
          @diagnostics.clear
          @connecting_transport = nil
          @restart_thread = nil
          @state = :stopped
          values = @pending.values
          @pending.clear
          values
        end
        error = Error.new("language server stopped")
        pending&.each { |future, _| future.fulfill(error: error) }
      end
    end

    def running?
      transport = @lock.synchronize { @transport if @state == :running && !@closing }
      !!transport&.alive?
    end

    def request(method, params = {})
      send_request(method, params, nil)
    end

    def notify(method, params = {})
      send_notification(method, params)
    end

    def on(method, &handler)
      raise ArgumentError, "handler required" unless handler

      @handlers[method.to_s] = handler
    end

    def supports?(capability) = !!@capabilities[capability.to_s]

    def open(document)
      uri, language_id, text = validate_document(document)
      stored = Document.new(uri: uri.freeze, language_id: language_id.freeze,
        version: document.version, text: text.freeze)
      @document_lock.synchronize do
        send_open = @lock.synchronize do
          ensure_running!
          @documents[stored.uri] = stored
          @diagnostics.delete(stored.uri)
          @semantic.delete(stored.uri)
          open_close?
        end
        notify_open(stored) if send_open
      end
      stored.uri
    end

    def change(uri, version, changes)
      uri = valid_uri(uri)
      @document_lock.synchronize do
        updated, notification = @lock.synchronize do
          ensure_running!
          document = @documents.fetch(uri) { raise Error, "document is not open" }
          unless Protocol.uint?(version) && version > document.version
            raise Error, "document version must increase"
          end
          raise Error, "content changes must be a nonempty Array" unless changes.is_a?(Array) && !changes.empty?

          text = document.text
          wire_changes = changes.map do |change|
            change_text = validate_change(change)
            if change.range
              index = DocumentIndex.new(text)
              first = Protocol.offset(index, change.range.start)
              last = Protocol.offset(index, change.range.end)
              raise Error, "invalid content change range" if last < first

              text = text.byteslice(0, first) + change_text + text.byteslice(last, text.bytesize - last)
              {range: Protocol.range_hash(change.range), text: change_text}
            else
              text = change_text
              {text: change_text}
            end
          end
          updated = Document.new(uri: document.uri, language_id: document.language_id, version: version, text: text.freeze)
          @documents[uri] = updated

          mode = sync_mode
          notification = if [1, 2].include?(mode)
            content_changes = mode == 2 ? wire_changes : [{text: text}]
            {textDocument: {uri: uri, version: version}, contentChanges: content_changes}
          end
          [updated, notification]
        end
        notify("textDocument/didChange", notification) if notification
        updated
      end
    rescue KeyError
      raise Error, "document is not open"
    end

    def save(uri, text: nil)
      uri = valid_uri(uri)
      text = utf8_string(text, "saved text must be valid UTF-8") unless text.nil?
      @document_lock.synchronize do
        params = @lock.synchronize do
          ensure_running!
          document = @documents.fetch(uri) { raise Error, "document is not open" }
          sync = @capabilities["textDocumentSync"]
          save = sync.is_a?(Hash) ? sync["save"] : sync.is_a?(Integer) && sync.positive?
          next unless save

          value = {textDocument: {uri: uri}}
          value[:text] = text || document.text if save.is_a?(Hash) && save["includeText"]
          value
        end
        notify("textDocument/didSave", params) if params
      end
    rescue KeyError
      raise Error, "document is not open"
    end

    def close(uri)
      uri = valid_uri(uri)
      @document_lock.synchronize do
        send_close = @lock.synchronize do
          ensure_running!
          raise Error, "document is not open" unless @documents.delete(uri)

          @diagnostics.delete(uri)
          @semantic.delete(uri)
          open_close?
        end
        notify("textDocument/didClose", {textDocument: {uri: uri}}) if send_close
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
      new_name = utf8_string(new_name, "new name must be a valid UTF-8 String")

      request_at("rename", uri, position, newName: new_name)
    end

    def document_symbol(uri) = request_document("documentSymbol", uri)

    def formatting(uri, options)
      raise Error, "formatting options must be an object" unless options.is_a?(Hash)

      request_document("formatting", uri, options: options)
    end

    def range_formatting(uri, range, options)
      request_document("rangeFormatting", uri, range: Protocol.range_hash(range), options: formatting_options(options))
    end

    def code_action(uri, range, context)
      raise Error, "code action context must be an object" unless context.is_a?(Hash)

      request_document("codeAction", uri, range: Protocol.range_hash(range), context: context)
    end

    def code_lens(uri) = request_document("codeLens", uri)
    def inlay_hint(uri, range) = request_document("inlayHint", uri, range: Protocol.range_hash(range))
    def folding_range(uri) = request_document("foldingRange", uri)
    def document_link(uri) = request_document("documentLink", uri)

    def selection_range(uri, positions)
      raise Error, "positions must be an Array" unless positions.is_a?(Array)

      wire_positions = positions.map { |position| Protocol.position_hash(position) }
      params = {textDocument: {uri: valid_uri(uri)}, positions: wire_positions}
      send_request("textDocument/selectionRange", params, lambda do |value|
        raise Error, "invalid LSP response" unless valid_selection_ranges?(value, wire_positions)

        value
      end)
    end

    def did_change_configuration(settings)
      settings = json_snapshot(settings, "settings must be JSON")
      @configuration_lock.synchronize do
        @lock.synchronize do
          ensure_running!
          @configuration = settings
        end
        notify("workspace/didChangeConfiguration", settings: settings)
      end
    end

    def did_change_watched_files(events)
      raise Error, "file events must be an Array" unless events.is_a?(Array)

      values = events.map do |event|
        raise Error, "invalid file event" unless event.is_a?(Hash)

        uri = event.key?(:uri) ? event[:uri] : event["uri"]
        type = event.key?(:type) ? event[:type] : event["type"]
        raise Error, "invalid file event" unless type.is_a?(Integer) && type.between?(1, 3)

        {uri: valid_uri(uri), type: type}
      end
      notify("workspace/didChangeWatchedFiles", changes: values)
    end

    def diagnostic(uri, previous_result_id: nil)
      params = {}
      if previous_result_id
        previous_result_id = utf8_string(previous_result_id, "previous result id must be a valid UTF-8 String")

        params[:previousResultId] = previous_result_id
      end
      request_document("diagnostic", uri, **params)
    end

    def semantic_tokens(uri, version:)
      document, provider, previous, generation, request_sequence = @lock.synchronize do
        document = @documents[uri]
        provider = @capabilities["semanticTokensProvider"]
        request_sequence = @semantic_requests[uri] += 1 if document&.version == version && provider.is_a?(Hash) && provider["full"]
        [document, provider, @semantic[uri], @semantic_generation, request_sequence]
      end
      return [] unless request_sequence

      delta = previous && previous[0] && provider["full"].is_a?(Hash) && provider["full"]["delta"]
      method = delta ? "textDocument/semanticTokens/full/delta" : "textDocument/semanticTokens/full"
      params = {textDocument: {uri: uri}}
      params[:previousResultId] = previous[0] if delta
      result = checked_request(method, params, :semantic).await

      @lock.synchronize do
        current = @documents[uri]
        current_request = @semantic_requests[uri]
        return [] unless result && current.equal?(document) && current.version == version &&
          generation == @semantic_generation && request_sequence == current_request

        raise Error, "unexpected semantic token delta" if !delta && !result.key?("data")

        data = result["data"] || Protocol.semantic_delta(previous[1], result["edits"])
        tokens = Protocol.semantic_tokens(data, legend: provider["legend"])
        @semantic[uri] = [result["resultId"], data]
        tokens
      end
    end

    def workspace_symbols(query)
      query = utf8_string(query, "query must be a valid UTF-8 String")

      checked_request("workspace/symbol", {query: query}, :workspace_symbols)
    end

    def resolve_completion(item) = resolve("completionItem/resolve", item, :completion_item)
    def resolve_code_action(action) = resolve("codeAction/resolve", action, :code_action)
    def resolve_code_lens(lens) = resolve("codeLens/resolve", lens, :code_lens)

    def execute_command(command, arguments: [])
      command = utf8_string(command, "command must be a nonempty valid UTF-8 String")
      raise Error, "command must be a nonempty valid UTF-8 String" if command.empty?
      raise Error, "arguments must be an Array" unless arguments.is_a?(Array)

      request("workspace/executeCommand", {command: command, arguments: arguments})
    end

    private

    def finish_thread(thread)
      return if thread == Thread.current || thread.join(1)

      thread.kill
      thread.join(1)
    end

    def send_request(method, params, validator, state: :running, epoch: nil, transport: nil, allow_closing: false)
      target = request_epoch = future = id = nil
      @lock.synchronize do
        id = @sequence += 1
        target = connected_transport(state: state, epoch: epoch, transport: transport, allow_closing: allow_closing)
        request_epoch = @epoch
        future = Future.new(id, on_error: method(:report_error)) { |number| cancel(number, target, request_epoch) }
        @pending[id] = [future, validator] if target
      end
      raise Error, "language server is not connected" unless target&.alive?

      target.write(jsonrpc: "2.0", id: id, method: method.to_s, params: params)
      future
    rescue StandardError => error
      @lock.synchronize { @pending.delete(id) }
      future.fulfill(error: error)
      future
    end

    def checked_request(method, params, kind, **options)
      send_request(method, params, ->(value) { validate_response(kind, value) }, **options)
    end

    def send_notification(method, params, state: :running, epoch: nil, transport: nil, allow_closing: false)
      target = @lock.synchronize do
        connected_transport(state: state, epoch: epoch, transport: transport, allow_closing: allow_closing)
      end
      raise Error, "language server is not connected" unless target&.alive?

      target.write(jsonrpc: "2.0", method: method.to_s, params: params)
    end

    def connected_transport(state:, epoch:, transport:, allow_closing:)
      return if state && @state != state
      return if !allow_closing && @closing
      return if epoch && @epoch != epoch
      return if transport && !@transport.equal?(transport)

      @transport
    end

    def connect(timeout:, state:, expected_epoch: nil)
      transport = nil
      epoch = @lock.synchronize do
        if expected_epoch && (@epoch != expected_epoch || @closing || @state != :failed)
          raise Error, "language server restart was cancelled"
        end
        raise Error, "language server is already started" if %i[starting restarting running].include?(@state)

        @closing = false if state == :starting
        @state = state
        @epoch += 1
        @semantic.clear
        @semantic_requests.clear
        @semantic_generation += 1
        @epoch
      end
      transport = build_transport(epoch)
      installed = @lock.synchronize do
        next false unless @epoch == epoch && @state == state && !@closing

        @transport = transport
        @connecting_transport = nil if @connecting_transport.equal?(transport)
        true
      end
      raise Error, "language server connection was cancelled" unless installed

      result = checked_request("initialize", initialize_params, :initialize, state: state, epoch: epoch, transport: transport).await(timeout: timeout)
      @lock.synchronize do
        unless @epoch == epoch && @state == state && !@closing && @transport.equal?(transport)
          raise Error, "language server connection was cancelled"
        end
        @capabilities = result["capabilities"]
        @server_info = result["serverInfo"]
        validate_capabilities
      end
      send_notification("initialized", {}, state: state, epoch: epoch, transport: transport)
      @capabilities
    rescue StandardError => error
      transport&.close
      active = @lock.synchronize do
        next false unless epoch && @epoch == epoch

        @state = :failed unless @closing
        !@closing
      end
      fail_pending(error) if active
      raise
    ensure
      @lock.synchronize do
        @connecting_transport = nil if @connecting_transport.equal?(transport)
      end
    end

    def build_transport(epoch)
      Transport.new(@command, cwd: @root, env: @env, on_spawn: ->(transport) {
        tracked = @lock.synchronize do
          next false unless @epoch == epoch && !@closing && %i[starting restarting].include?(@state)

          @connecting_transport = transport
          true
        end
        unless tracked
          transport.close
          raise Error, "language server connection was cancelled"
        end
      }) do |message, error|
        receive(message, error, epoch)
      end
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
      when :hover
        valid = valid_hover?(value)
      when :signature_help
        valid = valid_signature_help?(value)
      when :document_symbols
        valid = valid_document_symbols?(value)
      when :workspace_symbols
        valid = valid_workspace_symbols?(value)
      when :locations
        valid = value.nil? || valid_locations?(value)
      when :prepare_rename
        valid = valid_prepare_rename?(value)
      when :document_highlights
        valid = value.nil? || (value.is_a?(Array) && value.all? { |highlight| valid_document_highlight?(highlight) })
      when :hierarchy_items
        valid = value.nil? || (value.is_a?(Array) && value.all? { |item| valid_hierarchy_item?(item) })
      when :linked_editing_ranges
        valid = valid_linked_editing_ranges?(value)
      when :completion
        valid = valid_completion?(value)
      when :completion_item
        valid = valid_completion_item?(value)
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
        value&.each do |action|
          raise Error, "invalid LSP response" unless valid_code_action?(action)

          Protocol.workspace_edit(action["edit"]) if action["edit"]
        end
      when :code_action
        valid = valid_code_action?(value)
        Protocol.workspace_edit(value["edit"]) if valid && value["edit"]
      when :code_lenses
        valid = value.nil? || value.is_a?(Array)
        value&.each { |lens| validate_code_lens(lens) }
      when :code_lens
        valid = value.is_a?(Hash)
        validate_code_lens(value) if valid
      when :inlay_hints
        valid = value.nil? || value.is_a?(Array)
        value&.each { |hint| validate_inlay_hint(hint) }
      when :folding_ranges
        valid = value.nil? || (value.is_a?(Array) && value.all? { |range| valid_folding_range?(range) })
      when :document_links
        valid = value.nil? || (value.is_a?(Array) && value.all? { |link| valid_document_link?(link) })
      when :diagnostic
        valid = value.nil? || valid_diagnostic_report?(value)
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

    def valid_completion?(value)
      return true if value.nil?

      items = if value.is_a?(Hash)
        return false unless boolean?(value["isIncomplete"])

        value["items"]
      else
        value
      end
      items.is_a?(Array) && items.all? { |item| valid_completion_item?(item) }
    end

    def valid_completion_item?(item)
      item.is_a?(Hash) && item["label"].is_a?(String)
    end

    def valid_hover?(hover)
      return true if hover.nil?
      return false unless hover.is_a?(Hash) && hover.key?("contents") && valid_hover_contents?(hover["contents"])

      Protocol.range_value(hover["range"]) if hover.key?("range")
      true
    end

    def valid_hover_contents?(contents)
      return true if contents.is_a?(String)
      return contents.all? { |item| valid_marked_string?(item) } if contents.is_a?(Array)
      return false unless contents.is_a?(Hash)

      if contents.key?("kind")
        %w[plaintext markdown].include?(contents["kind"]) && contents["value"].is_a?(String)
      else
        valid_marked_string?(contents)
      end
    end

    def valid_marked_string?(value)
      value.is_a?(String) || (value.is_a?(Hash) && value["language"].is_a?(String) && value["value"].is_a?(String))
    end

    def valid_signature_help?(help)
      return true if help.nil?
      return false unless help.is_a?(Hash) && help["signatures"].is_a?(Array)
      return false unless optional_uint?(help, "activeSignature") && optional_uint?(help, "activeParameter")

      help["signatures"].all? { |signature| valid_signature?(signature) }
    end

    def valid_signature?(signature)
      return false unless signature.is_a?(Hash) && signature["label"].is_a?(String)
      return false unless optional_uint?(signature, "activeParameter")
      return true unless signature.key?("parameters")

      signature["parameters"].is_a?(Array) && signature["parameters"].all? do |parameter|
        next false unless parameter.is_a?(Hash)

        label = parameter["label"]
        label.is_a?(String) || (label.is_a?(Array) && label.length == 2 && label.all? { |offset| Protocol.uint?(offset) } && label[0] <= label[1])
      end
    end

    def valid_document_symbols?(value)
      value.nil? || (value.is_a?(Array) && value.all? do |symbol|
        symbol.is_a?(Hash) && symbol.key?("location") ? valid_symbol_information?(symbol) : valid_document_symbol?(symbol)
      end)
    end

    def valid_document_symbol?(symbol)
      return false unless valid_symbol?(symbol)

      Protocol.range_value(symbol.fetch("range"))
      Protocol.range_value(symbol.fetch("selectionRange"))
      !symbol.key?("children") || (symbol["children"].is_a?(Array) && symbol["children"].all? { |child| valid_document_symbol?(child) })
    end

    def valid_workspace_symbols?(value)
      value.nil? || (value.is_a?(Array) && value.all? { |symbol| valid_workspace_symbol?(symbol) })
    end

    def valid_workspace_symbol?(symbol)
      return false unless valid_symbol?(symbol) && symbol["location"].is_a?(Hash)

      location = symbol["location"]
      valid_uri(location.fetch("uri"))
      Protocol.range_value(location["range"]) if location.key?("range")
      true
    end

    def valid_symbol_information?(symbol)
      valid_symbol?(symbol) && valid_location?(symbol["location"])
    end

    def valid_symbol?(symbol)
      symbol.is_a?(Hash) && symbol["name"].is_a?(String) && symbol["kind"].is_a?(Integer) && symbol["kind"].between?(1, 26)
    end

    def valid_locations?(value)
      locations = value.is_a?(Array) ? value : [value]
      locations.all? { |location| valid_location?(location) || valid_location_link?(location) }
    end

    def valid_prepare_rename?(value)
      return true if value.nil?

      if value.is_a?(Hash) && (value.key?("defaultBehavior") || value.key?(:defaultBehavior))
        default_behavior = value.key?("defaultBehavior") ? value["defaultBehavior"] : value[:defaultBehavior]
        return boolean?(default_behavior)
      end

      if value.is_a?(Hash) && (value.key?("range") || value.key?(:range))
        range = value["range"] || value[:range]
        placeholder = value.key?("placeholder") ? value["placeholder"] : value[:placeholder]
        return false unless placeholder.is_a?(String)

        Protocol.range_value(range)
      else
        Protocol.range_value(value)
      end
      true
    rescue Error, KeyError
      false
    end

    def valid_document_highlight?(highlight)
      return false unless highlight.is_a?(Hash)

      Protocol.range_value(highlight.fetch("range"))
      !highlight.key?("kind") || (highlight["kind"].is_a?(Integer) && highlight["kind"].between?(1, 3))
    rescue Error, KeyError
      false
    end

    def valid_hierarchy_item?(item)
      return false unless valid_symbol?(item) && item["uri"].is_a?(String)

      valid_uri(item["uri"])
      range = Protocol.range_value(item.fetch("range"))
      selection_range = Protocol.range_value(item.fetch("selectionRange"))
      return false unless range_contains_range?(range, selection_range)
      return false if item.key?("detail") && !item["detail"].is_a?(String)
      return false if item.key?("tags") && !(item["tags"].is_a?(Array) && item["tags"].all? { |tag| tag == 1 })

      true
    rescue Error, KeyError
      false
    end

    def valid_linked_editing_ranges?(value)
      return true if value.nil?
      return false unless value.is_a?(Hash) && value["ranges"].is_a?(Array)
      return false if value.key?("wordPattern") && !value["wordPattern"].is_a?(String)

      ranges = value["ranges"].map { |range| Protocol.range_value(range) }
      ranges.sort_by! { |range| position_tuple(range.start) }
      ranges.each_cons(2).all? { |first, last| position_before_or_equal?(first.end, last.start) }
    rescue Error
      false
    end

    def valid_folding_range?(range)
      return false unless range.is_a?(Hash)

      first = range["startLine"]
      last = range["endLine"]
      return false unless Protocol.uint?(first) && Protocol.uint?(last) && first <= last
      return false unless optional_uint?(range, "startCharacter") && optional_uint?(range, "endCharacter")
      return false if range.key?("kind") && !range["kind"].is_a?(String)
      return false if range.key?("collapsedText") && !range["collapsedText"].is_a?(String)

      first != last || !range.key?("startCharacter") || !range.key?("endCharacter") || range["startCharacter"] <= range["endCharacter"]
    end

    def valid_selection_ranges?(value, positions)
      return true if value.nil?
      return false unless value.is_a?(Array) && value.length == positions.length

      pending = value.each_index.map { |index| [value[index], positions[index], nil, 0] }
      until pending.empty?
        selection, position, child_range, depth = pending.pop
        return false unless selection.is_a?(Hash) && depth < 256

        range = Protocol.range_value(selection.fetch("range"))
        return false unless range_contains_position?(range, position)
        return false if child_range && !range_contains_range?(range, child_range)

        pending << [selection["parent"], position, range, depth + 1] if selection.key?("parent")
      end
      true
    rescue Error, KeyError
      false
    end

    def valid_document_link?(link)
      return false unless link.is_a?(Hash)

      Protocol.range_value(link.fetch("range"))
      valid_uri(link["target"]) if link.key?("target")
      return false if link.key?("tooltip") && !link["tooltip"].is_a?(String)

      true
    rescue Error, KeyError
      false
    end

    def range_contains_position?(range, position)
      range = Protocol.range_value(range)
      position_before_or_equal?(range.start, position) && position_before_or_equal?(position, range.end)
    end

    def range_contains_range?(outer, inner)
      outer = Protocol.range_value(outer)
      inner = Protocol.range_value(inner)
      position_before_or_equal?(outer.start, inner.start) && position_before_or_equal?(inner.end, outer.end)
    end

    def position_before_or_equal?(first, last)
      (position_tuple(first) <=> position_tuple(last)) <= 0
    end

    def position_tuple(value)
      value = Protocol.position_value(value)
      [value.line, value.character]
    end

    def valid_location?(location)
      return false unless location.is_a?(Hash) && location.key?("uri")

      valid_uri(location["uri"])
      Protocol.range_value(location.fetch("range"))
      true
    end

    def valid_location_link?(location)
      return false unless location.is_a?(Hash) && location.key?("targetUri")

      valid_uri(location["targetUri"])
      Protocol.range_value(location.fetch("targetRange"))
      Protocol.range_value(location.fetch("targetSelectionRange"))
      Protocol.range_value(location["originSelectionRange"]) if location.key?("originSelectionRange")
      true
    end

    def valid_code_action?(action)
      return false unless action.is_a?(Hash) && action["title"].is_a?(String)
      return valid_command?(action) if action["command"].is_a?(String)
      return false if action.key?("command") && !valid_command?(action["command"])

      Protocol.diagnostics(action["diagnostics"]) if action.key?("diagnostics")
      true
    end

    def valid_command?(command)
      command.is_a?(Hash) && command["title"].is_a?(String) && command["command"].is_a?(String) &&
        (!command.key?("arguments") || command["arguments"].is_a?(Array))
    end

    def validate_code_lens(lens)
      raise Error, "invalid LSP response" unless lens.is_a?(Hash)

      Protocol.range_value(lens.fetch("range"))
      raise Error, "invalid LSP response" if lens.key?("command") && !valid_command?(lens["command"])
    end

    def validate_inlay_hint(hint)
      label = hint["label"] if hint.is_a?(Hash)
      valid_label = label.is_a?(String) || (label.is_a?(Array) && label.all? { |part| part.is_a?(Hash) && part["value"].is_a?(String) })
      raise Error, "invalid LSP response" unless valid_label

      Protocol.position_value(hint.fetch("position"))
    end

    def valid_diagnostic_report?(report)
      return false unless report.is_a?(Hash)

      case report["kind"]
      when "full"
        Protocol.diagnostics(report.fetch("items"))
        true
      when "unchanged"
        report["resultId"].is_a?(String)
      else
        false
      end
    end

    def optional_uint?(value, key)
      !value.key?(key) || Protocol.uint?(value[key])
    end

    def boolean?(value) = value == true || value == false

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
            documentHighlight: {dynamicRegistration: false},
            foldingRange: {dynamicRegistration: false, lineFoldingOnly: false},
            selectionRange: {dynamicRegistration: false},
            rename: {dynamicRegistration: false, prepareSupport: true},
            callHierarchy: {dynamicRegistration: false},
            typeHierarchy: {dynamicRegistration: false},
            documentLink: {dynamicRegistration: false, tooltipSupport: true},
            linkedEditingRange: {dynamicRegistration: false},
            formatting: {dynamicRegistration: false},
            rangeFormatting: {dynamicRegistration: false},
            codeAction: {codeActionLiteralSupport: {codeActionKind: {valueSet: %w[quickfix refactor refactor.extract refactor.inline refactor.rewrite source source.organizeImports]}}, resolveSupport: {properties: ["edit"]}},
            publishDiagnostics: {relatedInformation: true, versionSupport: true},
            diagnostic: {dynamicRegistration: false, relatedDocumentSupport: false},
            inlayHint: {dynamicRegistration: false},
            codeLens: {dynamicRegistration: false},
            semanticTokens: {requests: {full: {delta: true}}, tokenTypes: %w[namespace type class enum interface struct typeParameter parameter variable property enumMember event function method macro keyword modifier comment string number regexp operator decorator], tokenModifiers: %w[declaration definition readonly static deprecated abstract async modification documentation defaultLibrary], formats: ["relative"], overlappingTokenSupport: false, multilineTokenSupport: false}
          },
          workspace: {applyEdit: true, configuration: true, workspaceFolders: true,
            didChangeConfiguration: {dynamicRegistration: false}, didChangeWatchedFiles: {dynamicRegistration: false},
            workspaceEdit: {documentChanges: true, resourceOperations: %w[create rename delete], failureHandling: "abort"}}
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
      uri = valid_uri(document.uri)
      language_id = utf8_string(document.language_id, "language id must be a nonempty valid UTF-8 String")
      raise Error, "language id must be a nonempty valid UTF-8 String" if language_id.empty?
      raise Error, "document version must be an unsigned integer" unless Protocol.uint?(document.version)
      text = utf8_string(document.text, "document text must be valid UTF-8")
      [uri, language_id, text]
    end

    def ensure_running!
      raise Error, "language server is not running" unless @state == :running && !@closing
    end

    def validate_change(change)
      raise Error, "expected a ContentChange" unless change.is_a?(ContentChange)

      Protocol.range_value(change.range) if change.range
      utf8_string(change.text, "change text must be valid UTF-8")
    end

    def valid_uri(uri)
      uri = utf8_string(uri, "invalid URI")
      valid = !uri.empty? && !uri.include?("\0")
      parsed = URI::DEFAULT_PARSER.parse(uri) if valid
      raise Error, "invalid URI" unless valid && parsed&.scheme && !parsed.scheme.empty?

      uri
    rescue URI::InvalidURIError
      raise Error, "invalid URI"
    end

    def formatting_options(value)
      value = json_snapshot(value, "formatting options must be JSON")
      valid = value.is_a?(Hash) && Protocol.uint?(value["tabSize"]) && boolean?(value["insertSpaces"])
      valid &&= value.all? do |key, item|
        %w[tabSize insertSpaces].include?(key) || boolean?(item) || item.is_a?(String) ||
          (item.is_a?(Integer) && item.between?(-0x80000000, 0x7fffffff))
      end
      raise Error, "invalid formatting options" unless valid

      value
    end

    def json_snapshot(value, message)
      pending = [[value, 0]]
      until pending.empty?
        item, depth = pending.pop
        case item
        when NilClass, TrueClass, FalseClass
          next
        when Integer
          raise Error, message unless item.between?(-0x80000000, 0x7fffffff)
        when Float
          raise Error, message unless item.finite?
        when String
          raise Error, message unless item.dup.force_encoding(Encoding::UTF_8).valid_encoding?
        when Array
          raise Error, message if depth >= 100

          item.each { |child| pending << [child, depth + 1] }
        when Hash
          raise Error, message if depth >= 100
          raise Error, message unless item.keys.all? { |key| key.is_a?(String) || key.is_a?(Symbol) }
          raise Error, message unless item.keys.map(&:to_s).uniq.length == item.length

          item.each_key do |key|
            key = key.to_s
            raise Error, message unless key.dup.force_encoding(Encoding::UTF_8).valid_encoding?
          end
          item.each_value { |child| pending << [child, depth + 1] }
        else
          raise Error, message
        end
      end
      JSON.parse(JSON.generate(value))
    rescue JSON::JSONError, EncodingError, RuntimeError
      raise Error, message
    end

    def utf8_string(value, message)
      raise Error, message unless value.is_a?(String)

      value = value.dup.force_encoding(Encoding::UTF_8)
      raise Error, message unless value.valid_encoding?

      value
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
      state, epoch, transport = @lock.synchronize { [@state, @epoch, @transport] }
      send_notification("textDocument/didOpen", {textDocument: {uri: document.uri, languageId: document.language_id, version: document.version, text: document.text}}, state: state, epoch: epoch, transport: transport)
    end

    def sync_mode
      sync = @capabilities["textDocumentSync"]
      sync.is_a?(Hash) ? sync.fetch("change", 0) : sync
    end

    def open_close?
      sync = @capabilities["textDocumentSync"]
      sync.is_a?(Hash) ? sync["openClose"] : sync.is_a?(Integer) && sync.positive?
    end

    def cancel(id, transport, epoch)
      target = @lock.synchronize do
        @pending.delete(id)
        connected_transport(state: nil, epoch: epoch, transport: transport, allow_closing: false)
      end
      target&.try_write(jsonrpc: "2.0", method: "$/cancelRequest", params: {id: id})
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
        receive_error(error, epoch)
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

    def receive_error(error, epoch)
      pending, restart_epoch = @lock.synchronize do
        next unless epoch == @epoch

        running = @state == :running && !@closing
        @state = :failed unless @closing
        values = @pending.values
        @pending.clear
        [values, (@epoch if running && @restart && @restarts < 3)]
      end
      return unless pending

      pending.each { |future, _| future.fulfill(error: Error.new(error.message)) }
      report_error(error)
      restart_server(restart_epoch) if restart_epoch
    end

    def receive_call(message, epoch)
      method = message["method"]
      params = message.fetch("params", {})
      if method == "workspace/semanticTokens/refresh"
        active = @lock.synchronize do
          next false unless epoch == @epoch && !@closing

          @semantic.clear
          @semantic_generation += 1
          true
        end
        return unless active
      end
      @dispatch.call do
        next unless @lock.synchronize { epoch == @epoch && !@closing }

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
      valid = params.is_a?(Hash) && params["diagnostics"].is_a?(Array)
      raise Error, "invalid diagnostics notification" unless valid

      uri = valid_uri(params["uri"])
      version = params["version"]
      valid_version = version.nil? || (version.is_a?(Integer) && version.between?(-0x80000000, 0x7fffffff))
      raise Error, "invalid diagnostic version" unless valid_version
      diagnostics = Protocol.diagnostics(params["diagnostics"])
      @lock.synchronize do
        document = @documents[uri]
        return if document && version && version < document.version

        @diagnostics[uri] = diagnostics
      end
    end

    def built_in_request(method, params)
      case method
      when "workspace/configuration"
        items = params.fetch("items")
        raise Error, "invalid configuration request" unless items.is_a?(Array)
        configuration = @configuration_lock.synchronize { @configuration }

        [true, items.map do |item|
          section = item["section"]
          section && configuration.is_a?(Hash) ? configuration.dig(*section.split(".")) : (configuration unless section)
        end]
      when "workspace/workspaceFolders"
        [true, [{uri: Protocol.uri(@root), name: File.basename(@root)}]]
      when "window/workDoneProgress/create", "workspace/semanticTokens/refresh", "workspace/inlayHint/refresh", "workspace/codeLens/refresh", "workspace/diagnostic/refresh"
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
      transport = @lock.synchronize do
        connected_transport(state: nil, epoch: epoch, transport: nil, allow_closing: false)
      end
      return unless transport

      response = {jsonrpc: "2.0", id: id}
      error ? response[:error] = error : response[:result] = value
      transport.write(response)
    rescue StandardError => failure
      report_error(failure)
    end

    def restart_server(epoch)
      @lock.synchronize do
        return unless @epoch == epoch && @state == :failed && !@closing
        return if @restart_thread&.alive?

        previous = @transport
        @restart_thread = Thread.new { restart_loop(previous, epoch) }
      end
    end

    def restart_loop(previous, epoch)
      previous.close
      loop do
        attempt = @lock.synchronize do
          next if @closing || @state != :failed || @epoch != epoch || @restarts >= 3

          @restarts += 1
          [@restarts, epoch]
        end
        break unless attempt

        sleep(0.2 * attempt[0])
        begin
          connect(timeout: 10, state: :restarting, expected_epoch: attempt[1])
          @document_lock.synchronize do
            documents, send_open, connected_epoch = @lock.synchronize do
              raise Error, "language server restart was cancelled" if @closing || @state != :restarting

              [@documents.values.dup, open_close?, @epoch]
            end
            documents.each { |document| notify_open(document) } if send_open
            @lock.synchronize do
              if @closing || @state != :restarting || @epoch != connected_epoch
                raise Error, "language server restart was cancelled"
              end
              @state = :running
            end
          end
          retry_epoch = @lock.synchronize do
            if @state == :failed && !@closing
              @epoch
            else
              @restart_thread = nil if @restart_thread == Thread.current
              nil
            end
          end
          break unless retry_epoch

          epoch = retry_epoch
        rescue StandardError => failure
          report_error(failure)
          epoch = @lock.synchronize { @epoch if @state == :failed && !@closing }
          break unless epoch
        end
      end
    end
  end
end
