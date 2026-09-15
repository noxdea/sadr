# frozen_string_literal: true

require_relative "test_helper"

class HierarchyClientTest < Minitest::Test
  RANGE = {"start" => {"line" => 1, "character" => 2}, "end" => {"line" => 3, "character" => 4}}.freeze
  SELECTION_RANGE = {"start" => {"line" => 1, "character" => 2}, "end" => {"line" => 1, "character" => 8}}.freeze
  URI = "file:///tmp/hierarchy.rb"

  def item(**changes)
    {"name" => "Example", "kind" => 5, "uri" => URI, "range" => RANGE,
     "selectionRange" => SELECTION_RANGE, "detail" => "class", "tags" => [1],
     "data" => {"token" => [1, true, nil]}}.merge(changes.transform_keys(&:to_s))
  end

  def link(**changes)
    {"range" => SELECTION_RANGE, "tooltip" => "Open", "data" => {"id" => 1}}.merge(changes.transform_keys(&:to_s))
  end

  def client_for(responses = {})
    server = Sadr::Testing::FakeServer.new(responses: responses)
    client = Sadr::Testing::FakeClient.new(server: server)
    client.start
    [client, server]
  end

  def test_followup_wrappers_send_items_and_validate_results
    hierarchy_item = item
    resolved_link = link(target: "https://example.com/docs")
    responses = {
      "documentLink/resolve" => resolved_link,
      "callHierarchy/incomingCalls" => [{"from" => hierarchy_item, "fromRanges" => [SELECTION_RANGE]}],
      "callHierarchy/outgoingCalls" => [{"to" => hierarchy_item, "fromRanges" => [SELECTION_RANGE]}],
      "typeHierarchy/supertypes" => [hierarchy_item],
      "typeHierarchy/subtypes" => [hierarchy_item]
    }
    client, server = client_for(responses)

    assert_equal "https://example.com/docs", client.resolve_document_link(link).await["target"]
    assert_equal "Example", client.call_hierarchy_incoming_calls(hierarchy_item).await.first.dig("from", "name")
    assert_equal "Example", client.call_hierarchy_outgoing_calls(hierarchy_item).await.first.dig("to", "name")
    assert_equal [1], client.type_hierarchy_supertypes(hierarchy_item).await.first["tags"]
    assert_equal({"token" => [1, true, nil]}, client.type_hierarchy_subtypes(hierarchy_item).await.first["data"])

    resolve = server.messages.find { |message| message["method"] == "documentLink/resolve" }
    assert_equal link, resolve["params"]
    %w[callHierarchy/incomingCalls callHierarchy/outgoingCalls typeHierarchy/supertypes typeHierarchy/subtypes].each do |method|
      request = server.messages.find { |message| message["method"] == method }
      assert_equal hierarchy_item, request.dig("params", "item")
    end
  ensure
    client&.stop
  end

  def test_followup_requests_snapshot_nested_input_and_preserve_extensions
    hierarchy_item = item(extension: {"nested" => ["original"]})
    document_link = link(extension: {"nested" => ["original"]})
    client, server = client_for(
      "callHierarchy/incomingCalls" => [],
      "documentLink/resolve" => link(target: "https://example.com")
    )

    hierarchy_future = client.call_hierarchy_incoming_calls(hierarchy_item)
    link_future = client.resolve_document_link(document_link)
    hierarchy_item["extension"]["nested"] << "changed"
    document_link["extension"]["nested"] << "changed"
    hierarchy_future.await
    link_future.await

    hierarchy_request = server.messages.find { |message| message["method"] == "callHierarchy/incomingCalls" }
    link_request = server.messages.find { |message| message["method"] == "documentLink/resolve" }
    assert_equal ["original"], hierarchy_request.dig("params", "item", "extension", "nested")
    assert_equal ["original"], link_request.dig("params", "extension", "nested")
  ensure
    client&.stop
  end

  def test_nullable_hierarchy_results_and_document_link_nullability
    client, = client_for(
      "callHierarchy/incomingCalls" => nil,
      "callHierarchy/outgoingCalls" => nil,
      "typeHierarchy/supertypes" => nil,
      "typeHierarchy/subtypes" => nil,
      "documentLink/resolve" => nil
    )

    assert_nil client.call_hierarchy_incoming_calls(item).await
    assert_nil client.call_hierarchy_outgoing_calls(item).await
    assert_nil client.type_hierarchy_supertypes(item).await
    assert_nil client.type_hierarchy_subtypes(item).await
    assert_raises(Sadr::Error) { client.resolve_document_link(link).await }
    assert client.running?
  ensure
    client&.stop
  end

  def test_followup_responses_reject_malformed_items_ranges_and_data
    invalid_item = item(selectionRange: RANGE.merge("start" => {"line" => 0, "character" => 0}))
    outside = {"start" => {"line" => 0, "character" => 0}, "end" => {"line" => 0, "character" => 1}}
    after_caller = {"start" => {"line" => 4, "character" => 0}, "end" => {"line" => 4, "character" => 1}}
    responses = {
      "documentLink/resolve" => link(target: "not a URI"),
      "callHierarchy/incomingCalls" => [{"from" => item, "fromRanges" => [outside]}],
      "callHierarchy/outgoingCalls" => [{"to" => item, "fromRanges" => [after_caller]}],
      "typeHierarchy/supertypes" => [invalid_item],
      "typeHierarchy/subtypes" => [item(data: 0x80000000)]
    }
    client, = client_for(responses)

    requests = [
      -> { client.resolve_document_link(link) },
      -> { client.call_hierarchy_incoming_calls(item) },
      -> { client.call_hierarchy_outgoing_calls(item) },
      -> { client.type_hierarchy_supertypes(item) },
      -> { client.type_hierarchy_subtypes(item) }
    ]
    requests.each { |request| assert_raises(Sadr::Error) { request.call.await } }
    assert client.running?
  ensure
    client&.stop
  end

  def test_followup_inputs_validate_every_hierarchy_field_and_json_limits
    client, = client_for
    invalid_items = [
      item(name: nil), item(kind: 27), item(uri: "not a URI"), item(range: {}),
      item(selectionRange: RANGE.merge("start" => {"line" => 0, "character" => 0})),
      item(tags: [2]), item(data: Object.new), item(uri: "file:///tmp/\0bad")
    ]
    invalid_items.each do |invalid|
      assert_raises(Sadr::Error) { client.call_hierarchy_incoming_calls(invalid) }
    end
    assert_raises(Sadr::Error) { client.resolve_document_link(link(range: {})) }
    assert_raises(Sadr::Error) { client.resolve_document_link(link(target: "not a URI")) }

    nested = nil
    101.times { nested = {"child" => nested} }
    assert_raises(Sadr::Error) { client.type_hierarchy_subtypes(item(data: nested)) }

    too_many = Array.new(10_001, item)
    limited_client, = client_for("typeHierarchy/supertypes" => too_many)
    assert_raises(Sadr::Error) { limited_client.type_hierarchy_supertypes(item).await }

    oversized = client.type_hierarchy_supertypes(item(data: "x" * Sadr::Transport::MAX_MESSAGE))
    error = assert_raises(Sadr::Error) { oversized.await }
    assert_match(/oversized LSP message/, error.message)
    assert client.running?
  ensure
    limited_client&.stop
    client&.stop
  end

  def test_followup_requests_preserve_server_errors_and_cancellation
    server = Sadr::Testing::FakeServer.new
    server.define_singleton_method(:dispatch) do |message|
      @lock.synchronize { @messages << message }
      case message["method"]
      when "callHierarchy/incomingCalls"
        [{"jsonrpc" => "2.0", "id" => message["id"], "error" => {"code" => -32001, "message" => "failed"}}]
      when "typeHierarchy/subtypes"
        []
      when "initialize"
        [{"jsonrpc" => "2.0", "id" => message["id"], "result" => {"capabilities" => @capabilities}}]
      when "shutdown"
        [{"jsonrpc" => "2.0", "id" => message["id"], "result" => nil}]
      else
        []
      end
    end
    client = Sadr::Testing::FakeClient.new(server: server)
    client.start

    error = assert_raises(Sadr::ServerError) { client.call_hierarchy_incoming_calls(item).await }
    assert_equal(-32001, error.code)
    pending = client.type_hierarchy_subtypes(item)
    assert pending.cancel
    assert_raises(Sadr::Error) { pending.await }
    assert server.messages.any? { |message| message["method"] == "$/cancelRequest" }
    assert client.running?
  ensure
    client&.stop
  end
end
