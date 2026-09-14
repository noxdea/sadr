# frozen_string_literal: true

require_relative "test_helper"

class ClientTest < Minitest::Test
  POSITION = Sadr::Position.new(line: 0, character: 2)
  RANGE = Sadr::Range_.new(start: POSITION, end: Sadr::Position.new(line: 0, character: 3))

  def with_client(restart: false, command: Sadr::Testing::FakeServer.command, **options)
    instance = Sadr::Client.new(command: command, restart: restart, **options).start(timeout: 3)
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
        result = client.public_send(ruby_name, uri, POSITION).await
        assert_equal uri, result.dig("textDocument", "uri")
        assert_equal({"line" => 0, "character" => 2}, result["position"])
        assert probe(client).any? { |message| message["method"] == "textDocument/#{lsp_name}" }
      end

      assert_equal true, client.references(uri, POSITION).await.dig("context", "includeDeclaration")
      assert_equal "renamed", client.rename(uri, POSITION, "renamed").await["newName"]
      assert_equal uri, client.document_symbol(uri).await.dig("textDocument", "uri")
      assert_equal 2, client.formatting(uri, tabSize: 2).await.dig("options", "tabSize")
      assert_equal [], client.code_action(uri, RANGE, diagnostics: []).await.dig("context", "diagnostics")
      assert_equal uri, client.code_lens(uri).await.dig("textDocument", "uri")
      assert_equal({"line" => 0, "character" => 2}, client.inlay_hint(uri, RANGE).await.dig("range", "start"))
      assert_equal "previous", client.diagnostic(uri, previous_result_id: "previous").await["previousResultId"]
      assert_equal "q", client.workspace_symbols("q").await["query"]
      assert_equal "x", client.resolve_completion("label" => "x").await["label"]
      assert_equal "quickfix", client.resolve_code_action("kind" => "quickfix").await["kind"]
      assert_equal "lens", client.resolve_code_lens("command" => "lens").await["command"]
      assert_equal [1], client.execute_command("run", arguments: [1]).await["arguments"]
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

      client.request("never").tap { |future| assert_raises(Sadr::Timeout) { future.await(timeout: 0.01) } }
      assert probe(client).any? { |message| message["method"] == "$/cancelRequest" }
      client.request("stderr").await
      wait_until { client.transport.stderr_lines.length == 200 }
      assert client.transport.stderr_lines.all? { |line| line.bytesize <= 8192 }
      assert_operator client.errors.length, :>=, 1
      assert client.running?
    end
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
