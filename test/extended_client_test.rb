# frozen_string_literal: true

require_relative "test_helper"

class ExtendedClientTest < Minitest::Test
  POSITION = Sadr::Position.new(line: 2, character: 3)
  RANGE = Sadr::Range_.new(start: POSITION, end: Sadr::Position.new(line: 2, character: 5))
  WIRE_RANGE = {"start" => {"line" => 2, "character" => 3}, "end" => {"line" => 2, "character" => 5}}.freeze
  URI = "file:///tmp/extended.rb"

  def test_new_request_wrappers_validate_and_send_protocol_parameters
    item = {"name" => "Example", "kind" => 5, "uri" => URI, "range" => WIRE_RANGE, "selectionRange" => WIRE_RANGE}
    responses = {
      "textDocument/prepareRename" => {"range" => WIRE_RANGE, "placeholder" => "old"},
      "textDocument/documentHighlight" => [{"range" => WIRE_RANGE, "kind" => 2}],
      "textDocument/prepareCallHierarchy" => [item],
      "textDocument/prepareTypeHierarchy" => [item.merge("tags" => [1])],
      "textDocument/linkedEditingRange" => {"ranges" => [WIRE_RANGE], "wordPattern" => "[a-z]+"},
      "textDocument/foldingRange" => [{"startLine" => 2, "startCharacter" => 3, "endLine" => 4, "endCharacter" => 0, "kind" => "region"}],
      "textDocument/selectionRange" => [{"range" => WIRE_RANGE, "parent" => {"range" => WIRE_RANGE}}],
      "textDocument/documentLink" => [{"range" => WIRE_RANGE, "target" => "https://example.com", "tooltip" => "Open"}],
      "textDocument/rangeFormatting" => [{"range" => WIRE_RANGE, "newText" => "formatted"}]
    }
    server = Sadr::Testing::FakeServer.new(responses: responses)
    client = Sadr::Testing::FakeClient.new(server: server)
    client.start

    assert_equal "old", client.prepare_rename(URI, POSITION).await["placeholder"]
    assert_equal 2, client.document_highlight(URI, POSITION).await.first["kind"]
    assert_equal "Example", client.prepare_call_hierarchy(URI, POSITION).await.first["name"]
    assert_equal [1], client.prepare_type_hierarchy(URI, POSITION).await.first["tags"]
    assert_equal "[a-z]+", client.linked_editing_range(URI, POSITION).await["wordPattern"]
    assert_equal 4, client.folding_range(URI).await.first["endLine"]
    assert_equal WIRE_RANGE, client.selection_range(URI, [POSITION]).await.first["range"]
    assert_equal "https://example.com", client.document_link(URI).await.first["target"]
    assert_equal "formatted", client.range_formatting(URI, RANGE, tabSize: 2, insertSpaces: true).await.first["newText"]

    messages = server.messages
    positioned = messages.find { |message| message["method"] == "textDocument/documentHighlight" }
    assert_equal({"line" => 2, "character" => 3}, positioned.dig("params", "position"))
    selection = messages.find { |message| message["method"] == "textDocument/selectionRange" }
    assert_equal [{"line" => 2, "character" => 3}], selection.dig("params", "positions")
    formatting = messages.find { |message| message["method"] == "textDocument/rangeFormatting" }
    assert_equal 2, formatting.dig("params", "options", "tabSize")
  ensure
    client&.stop
  end

  def test_workspace_notifications_validate_and_normalize_values
    server = Sadr::Testing::FakeServer.new
    client = Sadr::Testing::FakeClient.new(server: server)
    client.start

    client.did_change_configuration("ruby" => {"lint" => true})
    client.did_change_watched_files([{uri: URI, type: 2}, {"uri" => URI, "type" => 3}])

    configuration = server.messages.find { |message| message["method"] == "workspace/didChangeConfiguration" }
    assert_equal true, configuration.dig("params", "settings", "ruby", "lint")
    watched = server.messages.find { |message| message["method"] == "workspace/didChangeWatchedFiles" }
    assert_equal [2, 3], watched.dig("params", "changes").map { |event| event["type"] }

    assert_raises(Sadr::Error) { client.did_change_configuration([]) }
    assert_raises(Sadr::Error) { client.did_change_watched_files([{"uri" => URI, "type" => 4}]) }
    assert_raises(Sadr::Error) { client.did_change_watched_files([{"uri" => "not a uri", "type" => 1}]) }
  ensure
    client&.stop
  end

  def test_new_wrappers_reject_malformed_server_results_without_stopping_client
    invalid = {
      "textDocument/prepareRename" => {"defaultBehavior" => false},
      "textDocument/documentHighlight" => [{"range" => WIRE_RANGE, "kind" => 4}],
      "textDocument/prepareCallHierarchy" => [{"name" => "missing fields", "kind" => 5}],
      "textDocument/prepareTypeHierarchy" => [{"name" => "bad kind", "kind" => 27, "uri" => URI, "range" => WIRE_RANGE, "selectionRange" => WIRE_RANGE}],
      "textDocument/linkedEditingRange" => {"ranges" => []},
      "textDocument/foldingRange" => [{"startLine" => 5, "endLine" => 2}],
      "textDocument/selectionRange" => [],
      "textDocument/documentLink" => [{"range" => WIRE_RANGE, "target" => "not a uri"}],
      "textDocument/rangeFormatting" => [{"range" => {}, "newText" => "x"}]
    }
    server = Sadr::Testing::FakeServer.new(responses: invalid)
    client = Sadr::Testing::FakeClient.new(server: server)
    client.start

    requests = [
      -> { client.prepare_rename(URI, POSITION) },
      -> { client.document_highlight(URI, POSITION) },
      -> { client.prepare_call_hierarchy(URI, POSITION) },
      -> { client.prepare_type_hierarchy(URI, POSITION) },
      -> { client.linked_editing_range(URI, POSITION) },
      -> { client.folding_range(URI) },
      -> { client.selection_range(URI, [POSITION]) },
      -> { client.document_link(URI) },
      -> { client.range_formatting(URI, RANGE, {}) }
    ]
    requests.each { |request| assert_raises(Sadr::Error) { request.call.await } }
    assert client.running?
    assert_equal({"ok" => true}, client.request("still-running", ok: true).await)
  ensure
    client&.stop
  end

  def test_initialization_advertises_new_client_capabilities
    server = Sadr::Testing::FakeServer.new
    client = Sadr::Testing::FakeClient.new(server: server)
    client.start

    initialize = server.messages.find { |message| message["method"] == "initialize" }
    text = initialize.dig("params", "capabilities", "textDocument")
    %w[documentHighlight foldingRange selectionRange rename callHierarchy typeHierarchy documentLink linkedEditingRange rangeFormatting].each do |name|
      assert text.key?(name), "missing #{name} capability"
    end
    assert_equal true, text.dig("rename", "prepareSupport")
    workspace = initialize.dig("params", "capabilities", "workspace")
    assert_equal false, workspace.dig("didChangeConfiguration", "dynamicRegistration")
    assert_equal false, workspace.dig("didChangeWatchedFiles", "dynamicRegistration")
  ensure
    client&.stop
  end
end
