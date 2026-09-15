# frozen_string_literal: true

require_relative "test_helper"

class ExtendedClientTest < Minitest::Test
  POSITION = Sadr::Position.new(line: 2, character: 3)
  RANGE = Sadr::Range_.new(start: POSITION, end: Sadr::Position.new(line: 2, character: 5))
  WIRE_RANGE = {"start" => {"line" => 2, "character" => 3}, "end" => {"line" => 2, "character" => 5}}.freeze
  OUTER_RANGE = {"start" => {"line" => 2, "character" => 1}, "end" => {"line" => 2, "character" => 7}}.freeze
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

    settings = {ruby: {lint: true}}
    client.did_change_configuration(settings)
    settings[:ruby][:lint] = false
    client.did_change_watched_files([{uri: URI, type: 2}, {"uri" => URI, "type" => 3}])

    configuration = server.messages.find { |message| message["method"] == "workspace/didChangeConfiguration" }
    assert_equal true, configuration.dig("params", "settings", "ruby", "lint")
    watched = server.messages.find { |message| message["method"] == "workspace/didChangeWatchedFiles" }
    assert_equal [2, 3], watched.dig("params", "changes").map { |event| event["type"] }

    known, values = client.send(:built_in_request, "workspace/configuration",
      {"items" => [{"section" => "ruby.lint"}]})
    assert known
    assert_equal [true], values

    client.did_change_configuration([1, true, nil])
    known, values = client.send(:built_in_request, "workspace/configuration",
      {"items" => [{}, {"section" => "ruby.lint"}]})
    assert known
    assert_equal [[1, true, nil], nil], values

    [Object.new, 0x80000000, {"same" => 1, same: 2}].each do |invalid|
      assert_raises(Sadr::Error) { client.did_change_configuration(invalid) }
    end
    assert_raises(Sadr::Error) { client.did_change_watched_files([{"uri" => URI, "type" => 4}]) }
    assert_raises(Sadr::Error) { client.did_change_watched_files([{"uri" => "not a uri", "type" => 1}]) }
  ensure
    client&.stop
  end

  def test_new_wrappers_reject_malformed_server_results_without_stopping_client
    invalid = {
      "textDocument/prepareRename" => {"defaultBehavior" => "yes"},
      "textDocument/documentHighlight" => [{"range" => WIRE_RANGE, "kind" => 4}],
      "textDocument/prepareCallHierarchy" => [{"name" => "missing fields", "kind" => 5}],
      "textDocument/prepareTypeHierarchy" => [{"name" => "bad kind", "kind" => 27, "uri" => URI, "range" => WIRE_RANGE, "selectionRange" => WIRE_RANGE}],
      "textDocument/linkedEditingRange" => {"ranges" => [WIRE_RANGE, WIRE_RANGE]},
      "textDocument/foldingRange" => [{"startLine" => 5, "endLine" => 2}],
      "textDocument/selectionRange" => [],
      "textDocument/documentLink" => [{"range" => WIRE_RANGE, "target" => nil}],
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
      -> { client.range_formatting(URI, RANGE, tabSize: 2, insertSpaces: true) }
    ]
    requests.each { |request| assert_raises(Sadr::Error) { request.call.await } }
    assert client.running?
    assert_equal({"ok" => true}, client.request("still-running", ok: true).await)
  ensure
    client&.stop
  end

  def test_nullable_and_empty_results_allowed_by_the_protocol
    server = Sadr::Testing::FakeServer.new(responses: {
      "textDocument/prepareRename" => {"defaultBehavior" => false},
      "textDocument/selectionRange" => nil,
      "textDocument/linkedEditingRange" => {"ranges" => []}
    })
    client = Sadr::Testing::FakeClient.new(server: server)
    client.start

    assert_equal false, client.prepare_rename(URI, POSITION).await["defaultBehavior"]
    assert_nil client.selection_range(URI, [POSITION]).await
    assert_equal [], client.linked_editing_range(URI, POSITION).await["ranges"]
  ensure
    client&.stop
  end

  def test_new_response_validators_enforce_cross_field_constraints
    selection_results = [
      [{"range" => {"start" => {"line" => 2, "character" => 4}, "end" => {"line" => 2, "character" => 5}}}],
      [{"range" => WIRE_RANGE, "parent" => {"range" => {"start" => {"line" => 2, "character" => 4}, "end" => {"line" => 2, "character" => 6}}}}]
    ]
    invalid_item = {"name" => "Example", "kind" => 5, "uri" => URI,
      "range" => WIRE_RANGE, "selectionRange" => OUTER_RANGE}
    server = Sadr::Testing::FakeServer.new(responses: {
      "textDocument/prepareRename" => {"range" => WIRE_RANGE},
      "textDocument/prepareCallHierarchy" => [invalid_item],
      "textDocument/selectionRange" => ->(_params, _message) { selection_results.shift }
    })
    client = Sadr::Testing::FakeClient.new(server: server)
    client.start

    assert_raises(Sadr::Error) { client.prepare_rename(URI, POSITION).await }
    assert_raises(Sadr::Error) { client.prepare_call_hierarchy(URI, POSITION).await }
    2.times { assert_raises(Sadr::Error) { client.selection_range(URI, [POSITION]).await } }
    assert client.running?
  ensure
    client&.stop
  end

  def test_deep_selection_parents_are_rejected_without_recursion
    selection = {"range" => OUTER_RANGE}
    256.times { selection = {"range" => OUTER_RANGE, "parent" => selection} }

    refute Sadr::Client.allocate.send(:valid_selection_ranges?, [selection], [{line: 2, character: 3}])
  end

  def test_range_formatting_validates_and_snapshots_options
    server = Sadr::Testing::FakeServer.new(responses: {"textDocument/rangeFormatting" => []})
    client = Sadr::Testing::FakeClient.new(server: server)
    client.start

    options = {tabSize: 2, insertSpaces: true, trimTrailingWhitespace: false}
    assert_equal [], client.range_formatting(URI, RANGE, options).await
    options[:tabSize] = -1
    sent = server.messages.find { |message| message["method"] == "textDocument/rangeFormatting" }
    assert_equal 2, sent.dig("params", "options", "tabSize")

    [{}, {tabSize: -1, insertSpaces: true}, {tabSize: 2, insertSpaces: nil},
      {tabSize: 2, insertSpaces: true, extension: []}].each do |invalid|
      assert_raises(Sadr::Error) { client.range_formatting(URI, RANGE, invalid) }
    end
  ensure
    client&.stop
  end

  def test_configuration_updates_are_safe_under_concurrent_input_mutation
    server = Sadr::Testing::FakeServer.new
    initial = {sequence: 99}
    client = Sadr::Testing::FakeClient.new(server: server, configuration: initial)
    initial[:sequence] = -1
    client.start
    inputs = Array.new(12) { |index| {sequence: index} }

    known, values = client.send(:built_in_request, "workspace/configuration", {"items" => [{}]})
    assert known
    assert_equal 99, values.first["sequence"]

    threads = inputs.map do |settings|
      Thread.new do
        client.did_change_configuration(settings)
        settings[:sequence] = -1
      end
    end
    threads.each { |thread| assert thread.join(2), "configuration update remained blocked" }

    notifications = server.messages.select { |message| message["method"] == "workspace/didChangeConfiguration" }
    assert_equal (0...12).to_a, notifications.map { |message| message.dig("params", "settings", "sequence") }.sort
    known, values = client.send(:built_in_request, "workspace/configuration", {"items" => [{}]})
    assert known
    assert_includes 0...12, values.first["sequence"]
  ensure
    threads&.each { |thread| thread.kill unless thread.join(0.1) }
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
    assert_equal 1, text.dig("rename", "prepareSupportDefaultBehavior")
    workspace = initialize.dig("params", "capabilities", "workspace")
    assert_equal false, workspace.dig("didChangeConfiguration", "dynamicRegistration")
    assert_equal false, workspace.dig("didChangeWatchedFiles", "dynamicRegistration")
  ensure
    client&.stop
  end
end
