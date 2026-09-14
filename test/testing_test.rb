# frozen_string_literal: true

require_relative "test_helper"

class TestingTest < Minitest::Test
  def test_fake_server_drives_a_client_without_a_process
    server = Sadr::Testing::FakeServer.new(responses: {"echo" => ->(params, _) { params.merge("ok" => true) }})
    client = Sadr::Testing::FakeClient.new(server: server)

    assert_equal server.capabilities, client.start(timeout: 1)
    assert_equal({"value" => 1, "ok" => true}, client.request("echo", value: 1).await(timeout: 1))
    assert_instance_of Sadr::Testing::FakeTransport, client.transport
    assert server.messages.any? { |message| message["method"] == "initialize" }
  ensure
    client&.stop
  end

  def test_fake_transport_matches_the_transport_lifecycle
    received = []
    server = Sadr::Testing::FakeServer.new
    transport = server.transport { |message, error| received << [message, error] }

    assert transport.alive?
    assert transport.try_write(jsonrpc: "2.0", id: 1, method: "echo", params: {value: 1})
    assert_equal({"value" => 1}, received.fetch(0).fetch(0)["result"])
    refute transport.try_write(jsonrpc: "2.0", method: "large", params: {value: "x" * 512})
    assert_empty transport.stderr_lines
    assert_equal Process.pid, transport.pid

    transport.close
    refute transport.alive?
    refute transport.try_write(jsonrpc: "2.0", method: "exit", params: {})
    assert_raises(Sadr::Error) { transport.write(jsonrpc: "2.0", method: "exit", params: {}) }
  end
end
