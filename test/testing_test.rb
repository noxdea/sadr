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
    server.messages.clear
    refute_empty server.messages
  ensure
    client&.stop
  end

  def test_fake_transport_matches_the_transport_lifecycle
    received = []
    server = Sadr::Testing::FakeServer.new
    transport = server.transport { |message, error| received << [message, error] }

    assert transport.alive?
    assert transport.try_write(jsonrpc: "2.0", id: 1, method: "echo", params: {value: 1})
    wait_until { received.length == 1 }
    assert_equal({"value" => 1}, received.fetch(0).fetch(0)["result"])
    refute transport.try_write(jsonrpc: "2.0", method: "large", params: {value: "x" * 512})
    assert_empty transport.stderr_lines
    assert_equal Process.pid, transport.pid

    reader = transport.instance_variable_get(:@reader)
    transport.close
    refute transport.alive?
    refute reader.alive?
    refute transport.try_write(jsonrpc: "2.0", method: "exit", params: {})
    assert_raises(Sadr::Error) { transport.write(jsonrpc: "2.0", method: "exit", params: {}) }
  end

  def test_fake_transport_rejects_the_production_message_limit
    transport = Sadr::Testing::FakeServer.new.transport { |_message, _error| }

    error = assert_raises(Sadr::Error) do
      transport.write(jsonrpc: "2.0", method: "large", params: {value: "x" * (33 << 20)})
    end
    assert_match(/oversized LSP message/, error.message)
  ensure
    transport&.close
  end

  def test_fake_transport_uses_production_frame_errors
    transport = Sadr::Testing::FakeServer.new.transport { |_message, _error| }
    invalid = [
      {jsonrpc: "1.0", method: "bad", params: {}},
      {jsonrpc: "2.0", method: "bad", params: {value: "\xFF".b}}
    ]

    invalid.each do |message|
      production = assert_raises(Sadr::Error) { Sadr::Transport.allocate.send(:frame, message) }
      fake = assert_raises(Sadr::Error) { transport.write(message) }
      assert_equal production.message, fake.message
    end
  ensure
    transport&.close
  end

  def test_close_discards_a_response_from_an_inflight_dispatch
    entered = Queue.new
    release = Queue.new
    received = Queue.new
    server = Sadr::Testing::FakeServer.new(responses: {
      "slow" => ->(*) { entered << true; release.pop; true }
    })
    transport = server.transport { |message, _error| received << message }
    writer = Thread.new { transport.write(jsonrpc: "2.0", id: 1, method: "slow", params: {}) }
    entered.pop

    refute transport.try_write(jsonrpc: "2.0", method: "busy", params: {})
    transport.close
    release << true
    assert writer.join(1)
    assert received.empty?
  ensure
    release << true if release
    if writer && !writer.join(1)
      writer.kill
      writer.join
    end
    transport&.close
  end

  def test_close_waits_for_an_inflight_callback
    entered = Queue.new
    release = Queue.new
    transport = Sadr::Testing::FakeServer.new.transport do |_message, _error|
      entered << true
      release.pop
    end
    transport.write(jsonrpc: "2.0", id: 1, method: "echo", params: {})
    entered.pop
    closing = Thread.new { transport.close }
    wait_until { !transport.alive? }
    assert closing.alive?

    release << true
    assert closing.join(1)
    refute transport.alive?
  ensure
    release << true if release
    if closing && !closing.join(1)
      closing.kill
      closing.join
    end
    transport&.close
  end

  def test_reader_callback_can_reply_and_close_without_deadlock
    messages = Queue.new
    server = Object.new
    server.define_singleton_method(:dispatch) do |message|
      messages << message
      next [] unless message["method"] == "trigger"

      [{"jsonrpc" => "2.0", "id" => "server-request", "method" => "client/request", "params" => {}}]
    end
    transport = nil
    completed = Queue.new
    transport = Sadr::Testing::FakeTransport.new(server) do |message, _error|
      transport.write(jsonrpc: "2.0", id: message["id"], result: true)
      transport.close
      completed << true
    end
    transport.write(jsonrpc: "2.0", id: 1, method: "trigger", params: {})

    wait_until { !completed.empty? }
    assert_equal true, messages.pop["params"].empty?
    reply = messages.pop
    assert_equal "server-request", reply["id"]
    assert_equal true, reply["result"]
    refute transport.alive?
  ensure
    transport&.close
  end
end
