# frozen_string_literal: true

require_relative "test_helper"

class ClientTest < Minitest::Test
  class BlockingWriter
    attr_reader :closed, :entered

    def initialize(io)
      @io = io
      @entered = Queue.new
      @closed = Queue.new
      @release = Queue.new
      @first = true
    end

    def write(value)
      if @first
        @first = false
        @entered << true
        @release.pop
      end
      @io.write(value)
    end

    def flush = @io.flush
    def closed? = @io.closed?

    def close
      @closed << true
      @release << true
      @io.close unless @io.closed?
    end
  end

  POSITION = Sadr::Position.new(line: 0, character: 2)
  RANGE = Sadr::Range_.new(start: POSITION, end: Sadr::Position.new(line: 0, character: 3))

  def with_client(restart: false, command: Sadr::Testing::FakeServer.command, **options)
    instance = Sadr::Client.new(command: command, restart: restart, **options)
    capabilities = instance.start(timeout: 3)
    assert_same capabilities, instance.capabilities
    yield instance
  ensure
    instance&.stop
  end

  def document(version: 0, text: "🙂a")
    Sadr::Document.new(uri: Sadr::Protocol.uri(File.expand_path("test.rb")), language_id: "ruby", version: version, text: text)
  end

  def probe(instance)
    instance.request("probe").await
  end

  def test_initialize_document_sync_semantic_delta_and_stale_diagnostics
    with_client do |client|
      assert client.running?
      assert_equal "Sadr", probe(client).find { |message| message["method"] == "initialize" }.dig("params", "clientInfo", "name")

      uri = client.open(document)
      first = client.semantic_tokens(uri, version: 0)
      assert_equal 1, first.first.length

      updated = client.change(uri, 1, [Sadr::ContentChange.new(range: RANGE, text: "new")])
      assert_equal "🙂new", updated.text
      assert_equal 2, client.semantic_tokens(uri, version: 1).first.length
      client.save(uri)

      messages = probe(client)
      change = messages.find { |message| message["method"] == "textDocument/didChange" }
      assert_equal({"line" => 0, "character" => 2}, change.dig("params", "contentChanges", 0, "range", "start"))
      save = messages.find { |message| message["method"] == "textDocument/didSave" }
      assert_equal "🙂new", save.dig("params", "text")

      client.request("server_notification", method: "textDocument/publishDiagnostics", params: {uri: uri, version: 0, diagnostics: []}).await
      refute client.diagnostics.key?(uri)
      client.request("server_notification", method: "textDocument/publishDiagnostics", params: {uri: uri, version: 1, diagnostics: []}).await
      assert_equal [], client.diagnostics[uri]

      client.close(uri)
      refute client.diagnostics.key?(uri)
      assert_raises(Sadr::Error) { client.change(uri, 2, [Sadr::ContentChange.new(range: nil, text: "x")]) }
    end
  end

  def test_public_request_wrappers_use_uri_positions_and_protocol_names
    with_client do |client|
      uri = client.open(document)
      position_methods = {
        completion: "completion", hover: "hover", definition: "definition",
        type_definition: "typeDefinition", implementation: "implementation",
        signature_help: "signatureHelp"
      }
      position_methods.each do |ruby_name, lsp_name|
        client.public_send(ruby_name, uri, POSITION).await
        request = probe(client).reverse.find { |message| message["method"] == "textDocument/#{lsp_name}" }
        assert_equal uri, request.dig("params", "textDocument", "uri")
        assert_equal({"line" => 0, "character" => 2}, request.dig("params", "position"))
      end

      client.references(uri, POSITION).await
      client.rename(uri, POSITION, "renamed").await
      client.document_symbol(uri).await
      client.formatting(uri, tabSize: 2).await
      client.code_action(uri, RANGE, diagnostics: []).await
      client.code_lens(uri).await
      client.inlay_hint(uri, RANGE).await
      client.diagnostic(uri, previous_result_id: "previous").await
      client.workspace_symbols("q").await
      assert_equal "x", client.resolve_completion("label" => "x").await["label"]
      assert_equal "quickfix", client.resolve_code_action("title" => "Fix", "kind" => "quickfix").await["kind"]
      lens = {"range" => {"start" => {"line" => 0, "character" => 0}, "end" => {"line" => 0, "character" => 1}}, "command" => {"title" => "Lens", "command" => "lens"}}
      assert_equal "lens", client.resolve_code_lens(lens).await.dig("command", "command")
      assert_equal [1], client.execute_command("run", arguments: [1]).await["arguments"]

      messages = probe(client)
      assert_equal true, messages.reverse.find { |message| message["method"] == "textDocument/references" }.dig("params", "context", "includeDeclaration")
      assert_equal "renamed", messages.reverse.find { |message| message["method"] == "textDocument/rename" }.dig("params", "newName")
      assert_equal 2, messages.reverse.find { |message| message["method"] == "textDocument/formatting" }.dig("params", "options", "tabSize")
      assert_equal "previous", messages.reverse.find { |message| message["method"] == "textDocument/diagnostic" }.dig("params", "previousResultId")
      assert_equal "q", messages.reverse.find { |message| message["method"] == "workspace/symbol" }.dig("params", "query")
    end
  end

  def test_full_sync_sends_the_final_document_text
    script = Sadr::Testing::FakeServer::SCRIPT.sub("change: 2", "change: 1")
    with_client(command: [RbConfig.ruby, "-e", script]) do |client|
      uri = client.open(document)
      client.change(uri, 1, [
        Sadr::ContentChange.new(range: RANGE, text: "new"),
        Sadr::ContentChange.new(range: nil, text: "final")
      ])
      change = probe(client).find { |message| message["method"] == "textDocument/didChange" }
      assert_equal [{"text" => "final"}], change.dig("params", "contentChanges")
    end
  end

  def test_server_requests_failures_cancellation_and_stderr_are_contained
    with_client(configuration: {"ruby" => {"lint" => true}}) do |client|
      assert_raises(Sadr::Error) { client.start }
      assert client.running?
      client.on("explode") { raise "boom" }
      client.on("error") { raise "error handler also failed" }
      assert client.request("server_request", method: "explode").await
      wait_until do
        probe(client).any? { |message| message["id"] == "server-1" && message.dig("error", "code") == -32603 }
      end

      client.request("server_request", method: "unknown").await
      assert probe(client).any? { |message| message["id"] == "server-1" && message.dig("error", "code") == -32601 }
      client.request("server_request", method: "workspace/configuration", params: {items: [{section: "ruby.lint"}]}).await
      assert probe(client).any? { |message| message["id"] == "server-1" && message["result"] == [true] }

      deferred = Sadr::Future.new(nil)
      client.on("deferred") { deferred }
      client.request("server_request", method: "deferred").await
      deferred.fulfill(false)
      assert probe(client).any? { |message| message["id"] == "server-1" && message["result"] == false }

      client.request("probe").then { raise "callback failed" }.await
      wait_until { client.errors.any? { |error| error.message.include?("callback failed") } }
      assert probe(client).is_a?(Array)

      client.request("never").tap { |future| assert_raises(Sadr::Timeout) { future.await(timeout: 0.01) } }
      assert probe(client).any? { |message| message["method"] == "$/cancelRequest" }
      client.request("stderr").await
      wait_until { client.transport.stderr_lines.length == 200 }
      assert client.transport.stderr_lines.all? { |line| line.bytesize <= 8192 }
      assert_operator client.errors.length, :>=, 1
      assert client.running?
    end
  end

  def test_deferred_reply_never_moves_to_a_replacement_transport
    entered = Queue.new
    release = Queue.new
    client = Sadr::Client.new(command: Sadr::Testing::FakeServer.command, restart: true)
    client.start(timeout: 3)
    deferred = Sadr::Future.new(nil)
    client.on("deferred") { deferred }
    client.request("server_request", method: "deferred").await
    source, first_line = Sadr::Client.instance_method(:reply).source_location
    lines = File.readlines(source)
    target_line = ((first_line - 1)...lines.length).find { |index| lines[index].include?("response = {jsonrpc:") } + 1
    trace = TracePoint.new(:line) do |event|
      next unless event.path == source && event.lineno == target_line

      entered << true
      release.pop
    end
    trace.enable
    replying = Thread.new { deferred.fulfill("old") }
    wait_until { !entered.empty? }
    entered.pop
    old_pid = client.transport.pid

    assert_raises(Sadr::Error) { client.request("crash").await }
    wait_until { client.running? && client.transport.pid != old_pid }
    release << true
    assert replying.join(3), "deferred reply remained blocked"
    refute probe(client).any? { |message| message["id"] == "server-1" }
  ensure
    trace&.disable
    release << true if release
    if replying && !replying.join(1)
      replying.kill
      replying.join(1)
    end
    client&.stop
  end

  def test_crash_restarts_and_reopens_documents_once
    with_client(restart: true) do |client|
      uri = client.open(document)
      pid = client.transport.pid
      assert_raises(Sadr::Error) { client.request("crash").await }
      wait_until { client.running? && client.transport.pid != pid }
      messages = probe(client)
      assert_equal 1, messages.count { |message| message["method"] == "textDocument/didOpen" && message.dig("params", "textDocument", "uri") == uri }

      client.change(uri, 1, [Sadr::ContentChange.new(range: nil, text: "new")])
      assert_equal 1, probe(client).count { |message| message["method"] == "textDocument/didChange" }
    end
  end

  def test_public_messages_are_rejected_while_starting
    entered = Queue.new
    release = Queue.new
    klass = Class.new(Sadr::Client) do
      define_method(:build_transport) do |epoch|
        value = super(epoch)
        if state == :starting
          entered << true
          release.pop
        end
        value
      end
    end
    client = klass.new(command: Sadr::Testing::FakeServer.command, restart: false)
    starter = Thread.new { client.start(timeout: 3) }
    wait_until { !entered.empty? }
    entered.pop
    refute client.running?
    assert_raises(Sadr::Error) { client.request("during_start").await }
    assert_raises(Sadr::Error) { client.notify("during_start") }
    assert_raises(Sadr::Error) { client.hover(document.uri, POSITION).await }

    release << true
    assert starter.join(3), "start remained blocked"
    starter.value
    refute probe(client).any? { |message| message["method"] == "during_start" || message["method"] == "textDocument/hover" }
  ensure
    release << true if release
    if starter && !starter.join(1)
      starter.kill
      starter.join(1)
    end
    client&.stop
  end

  def test_running_stays_false_until_restart_reopens_every_document
    entered = Queue.new
    release = Queue.new
    klass = Class.new(Sadr::Client) do
      define_method(:notify_open) do |value|
        if state == :restarting
          entered << true
          release.pop
        end
        super(value)
      end
    end
    client = klass.new(command: Sadr::Testing::FakeServer.command, restart: true)
    client.start(timeout: 3)
    uri = client.open(document)

    2.times do
      assert_raises(Sadr::Error) { client.request("crash").await }
      wait_until { !entered.empty? }
      entered.pop
      assert_equal :restarting, client.state
      refute client.running?
      assert_raises(Sadr::Error) { client.request("during_restart").await }
      assert_raises(Sadr::Error) { client.notify("during_restart") }
      assert_raises(Sadr::Error) { client.hover(uri, POSITION).await }
      release << true
      wait_until { client.running? }
      messages = client.request("probe").await
      assert_equal 1, messages.count { |message| message["method"] == "textDocument/didOpen" }
      refute messages.any? { |message| message["method"] == "during_restart" || message["method"] == "textDocument/hover" }
    end
  ensure
    release << true if release
    client&.stop
  end

  def test_stop_cancels_a_restart_even_after_its_transport_is_created
    entered = Queue.new
    klass = Class.new(Sadr::Client) do
      define_method(:build_transport) do |epoch|
        value = super(epoch)
        if state == :restarting
          entered << value
          sleep(0.005) while value.alive?
        end
        value
      end
    end
    client = klass.new(command: Sadr::Testing::FakeServer.command, restart: true)
    client.start(timeout: 3)
    assert_raises(Sadr::Error) { client.request("crash").await }
    wait_until { !entered.empty? }
    restarted_transport = entered.pop
    restart = client.instance_variable_get(:@restart_thread)

    client.stop
    assert restart.join(3), "restart did not observe cancellation"
    assert_equal :stopped, client.state
    refute client.running?
    refute restarted_transport.alive?
  ensure
    client&.stop
  end

  def test_stop_prevents_a_queued_restart_from_creating_a_transport
    entered = Queue.new
    release = Queue.new
    built = Queue.new
    klass = Class.new(Sadr::Client) do
      define_method(:connect) do |**options|
        if options[:state] == :restarting
          entered << true
          release.pop
        end
        super(**options)
      end
      define_method(:build_transport) do |epoch|
        built << true if state == :restarting
        super(epoch)
      end
    end
    client = klass.new(command: Sadr::Testing::FakeServer.command, restart: true)
    client.start(timeout: 3)
    assert_raises(Sadr::Error) { client.request("crash").await }
    wait_until { !entered.empty? }
    entered.pop
    restart = client.instance_variable_get(:@restart_thread)

    client.stop
    release << true
    assert restart.join(3), "restart did not observe cancellation"
    assert built.empty?
    assert_equal :stopped, client.state
    refute client.running?
  ensure
    release << true if release
    client&.stop
  end

  def test_restart_is_not_lost_when_the_new_transport_fails_before_the_loop_exits
    client = Sadr::Client.new(command: Sadr::Testing::FakeServer.command, restart: true)
    client.start(timeout: 3)
    source, first_line = Sadr::Client.instance_method(:restart_loop).source_location
    lines = File.readlines(source)
    running_line = ((first_line - 1)...lines.length).find { |index| lines[index].include?("@state = :running") } + 1
    target_line = running_line + 3
    killed = Queue.new
    fired = false
    trace = TracePoint.new(:line) do |event|
      next unless !fired && event.path == source && event.lineno == target_line

      fired = true
      pid = client.transport.pid
      Process.kill("KILL", pid)
      deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + 3
      sleep(0.005) until client.state == :failed || Process.clock_gettime(Process::CLOCK_MONOTONIC) >= deadline
      killed << [pid, client.state]
    end
    trace.enable

    assert_raises(Sadr::Error) { client.request("crash").await }
    wait_until { !killed.empty? }
    pid, state = killed.pop
    assert_equal :failed, state
    wait_until { client.running? && client.transport.pid != pid }
  ensure
    trace&.disable
    client&.stop
  end

  def test_stale_semantic_response_cannot_repopulate_the_cache
    started = Queue.new
    with_client(env: {"SADR_SEMANTIC_DELAY" => "0.05"}) do |client|
      client.on("semantic_started") { started << true }
      uri = client.open(document)
      request = Thread.new { client.semantic_tokens(uri, version: 0) }
      wait_until { !started.empty? }
      started.pop
      client.change(uri, 1, [Sadr::ContentChange.new(range: nil, text: "new")])
      assert_equal [], request.value
      assert_equal 1, client.semantic_tokens(uri, version: 1).first.length

      messages = probe(client)
      assert_equal 2, messages.count { |message| message["method"] == "textDocument/semanticTokens/full" }
      assert_equal 0, messages.count { |message| message["method"] == "textDocument/semanticTokens/full/delta" }
    end
  end

  def test_semantic_refresh_rejects_an_inflight_result_from_the_old_generation
    with_client(env: {"SADR_SEMANTIC_REFRESH" => "1"}) do |client|
      uri = client.open(document)
      assert_equal [], client.semantic_tokens(uri, version: 0)
      assert_equal 1, client.semantic_tokens(uri, version: 0).first.length

      messages = probe(client)
      assert_equal 2, messages.count { |message| message["method"] == "textDocument/semanticTokens/full" }
      assert_equal 0, messages.count { |message| message["method"] == "textDocument/semanticTokens/full/delta" }
    end
  end

  def test_semantic_refresh_invalidates_before_asynchronous_dispatch
    dispatches = Queue.new
    dispatch = ->(&block) { dispatches << block }
    with_client(env: {"SADR_SEMANTIC_REFRESH" => "1"}, dispatch: dispatch) do |client|
      uri = client.open(document)
      assert_equal [], client.semantic_tokens(uri, version: 0)
      assert_equal 1, dispatches.length
      assert_equal 1, client.semantic_tokens(uri, version: 0).first.length
    end
  end

  def test_stopping_closes_the_transport_while_a_document_write_is_blocked
    with_client do |client|
      uri = client.open(document)
      transport = client.transport
      writer = BlockingWriter.new(transport.instance_variable_get(:@stdin))
      transport.instance_variable_set(:@stdin, writer)
      change = Thread.new do
        client.change(uri, 1, [Sadr::ContentChange.new(range: nil, text: "new")])
      rescue Sadr::Error
        nil
      end
      wait_until { !writer.entered.empty? }

      stopping = Thread.new { client.stop }
      assert stopping.join(3), "stop remained blocked behind a document write"
      assert change.join(3), "document write did not unblock after transport close"
      refute writer.closed.empty?
    end
  end

  def test_stopping_closes_the_transport_while_a_request_write_is_blocked
    with_client do |client|
      transport = client.transport
      writer = BlockingWriter.new(transport.instance_variable_get(:@stdin))
      transport.instance_variable_set(:@stdin, writer)
      existing_threads = Thread.list
      request = Thread.new do
        client.request("probe").await
      rescue Sadr::Error
        nil
      end
      wait_until { !writer.entered.empty? }

      stopping = Thread.new { client.stop }
      assert stopping.join(4), "stop remained blocked behind a request write"
      assert request.join(3), "request write did not unblock after transport close"
      refute writer.closed.empty?
      wait_until { (Thread.list - existing_threads).empty? }
    end
  end

  def test_invalid_wrapper_response_fails_only_its_future
    with_client(env: {"SADR_INVALID_METHOD" => "textDocument/hover"}) do |client|
      uri = client.open(document)
      assert_raises(Sadr::Error) { client.hover(uri, POSITION).await }
      assert probe(client).is_a?(Array)
      assert client.running?
    end
    with_client(env: {"SADR_INVALID_METHOD" => "textDocument/formatting"}) do |client|
      uri = client.open(document)
      assert_raises(Sadr::Error) { client.formatting(uri, tabSize: 2).await }
      assert client.running?
    end
  end

  def test_invalid_wrapper_elements_fail_only_their_futures
    with_client(env: {"SADR_INVALID_ELEMENTS" => "1"}) do |client|
      uri = client.open(document)
      requests = [
        -> { client.completion(uri, POSITION) },
        -> { client.definition(uri, POSITION) },
        -> { client.code_action(uri, RANGE, diagnostics: []) },
        -> { client.code_lens(uri) },
        -> { client.inlay_hint(uri, RANGE) },
        -> { client.diagnostic(uri) }
      ]
      requests.each { |request| assert_raises(Sadr::Error) { request.call.await } }
      assert probe(client).is_a?(Array)
      assert client.running?
    end
  end

  def test_invalid_nested_wrapper_structures_fail_only_their_futures
    with_client(env: {"SADR_INVALID_STRUCTURES" => "1"}) do |client|
      uri = client.open(document)
      requests = [
        -> { client.completion(uri, POSITION) },
        -> { client.hover(uri, POSITION) },
        -> { client.signature_help(uri, POSITION) },
        -> { client.document_symbol(uri) },
        -> { client.workspace_symbols("q") },
        -> { client.resolve_completion("label" => "x") },
        -> { client.code_lens(uri) }
      ]
      requests.each { |request| assert_raises(Sadr::Error) { request.call.await } }
      assert probe(client).is_a?(Array)
      assert client.running?
    end
  end

  def test_documents_and_changes_are_validated_at_the_boundary
    with_client do |client|
      assert_raises(Sadr::Error) { client.open(Object.new) }
      assert_raises(Sadr::Error) { client.open(Sadr::Document.new(uri: "", language_id: "ruby", version: 0, text: "x")) }
      uri = client.open(document)
      assert_raises(Sadr::Error) { client.change(uri, 0, [Sadr::ContentChange.new(range: nil, text: "x")]) }
      assert_raises(Sadr::Error) { client.change(uri, 1, []) }
      assert_raises(Sadr::Error) { client.change(uri, 1, [Object.new]) }
    end
  end
end
