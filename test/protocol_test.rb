# frozen_string_literal: true

require_relative "test_helper"

class ProtocolTest < Minitest::Test
  def frame(message)
    json = JSON.generate(message)
    "Content-Length: #{json.bytesize}\r\n\r\n#{json}"
  end

  def test_framing_and_json_rpc_validation
    message = {"jsonrpc" => "2.0", "id" => 1, "result" => "日本🙂"}
    io = StringIO.new(frame(message) * 2)
    assert_equal message, Sadr::Transport.read_message(io)
    assert_equal message, Sadr::Transport.read_message(io)
    assert_nil Sadr::Transport.read_message(io)

    [nil, [], {"jsonrpc" => "1.0"}, {"jsonrpc" => "2.0", "method" => 4},
      {"jsonrpc" => "2.0", "method" => "test", "id" => []},
      {"jsonrpc" => "2.0", "method" => "test", "params" => "bad"},
      {"jsonrpc" => "2.0", "id" => 1},
      {"jsonrpc" => "2.0", "id" => 1, "result" => nil, "error" => {}},
      {"jsonrpc" => "2.0", "id" => 1, "error" => {"code" => "bad", "message" => 1}}].each do |value|
      assert_raises(Sadr::Error) { Sadr::Transport.validate_message(value) }
    end

    ["Content-Length: -1\r\n\r\n", "Content-Length: 999999999999\r\n\r\n", "Bad\r\n\r\n",
      "Content-Length: 10\r\n\r\n{}", "Content-Length: 2\r\nContent-Length: 2\r\n\r\n{}",
      "Content-Length: 2\r\nContent-Type: application/vscode-jsonrpc; charset=latin1\r\n\r\n{}",
      "Content-Length: 1\r\n\r\n\xff".b, "Content-Length: 1\r\n\r\n{"].each do |invalid|
      assert_raises(Sadr::Error) { Sadr::Transport.read_message(StringIO.new(invalid)) }
    end
    assert_raises(ArgumentError) { Sadr::Transport.new(["bad\0command"]) {} }
  end

  def test_uri_utf16_ranges_and_text_edits_use_a_duck_typed_index
    index = TextIndex.new("a🙂日\nnext")
    assert_equal Sadr::Position.new(line: 0, character: 3), Sadr::Protocol.position(index, 5)
    assert_equal 5, Sadr::Protocol.offset(index, {"line" => 0, "character" => 3})
    assert_equal 8, Sadr::Protocol.offset(index, Sadr::Position.new(line: 0, character: 1000))
    range = Sadr::Protocol.range(index, 1...8)
    assert_equal Sadr::Position.new(line: 0, character: 1), range.start
    assert_equal Sadr::Position.new(line: 0, character: 4), range.end

    edits = Sadr::Protocol.text_edits(index, [{"range" => {"start" => {"line" => 0, "character" => 1}, "end" => {"line" => 0, "character" => 3}}, "newText" => "x"}])
    assert_equal [[1...5, "x"]], edits
    assert_includes Sadr::Protocol.uri("/tmp/a b.rb"), "a%20b.rb"
    assert_equal File.expand_path("/tmp/a b.rb"), Sadr::Protocol.path(Sadr::Protocol.uri("/tmp/a b.rb"))
    assert_raises(Sadr::Error) { Sadr::Protocol.path("file:///tmp/x%00") }
    assert_raises(Sadr::Error) { Sadr::Protocol.path("file:///tmp/x?query") }
    assert_raises(Sadr::Error) { Sadr::Protocol.offset(index, {"line" => 0, "character" => -1}) }
    assert_raises(RangeError) { Sadr::Protocol.offset(index, {"line" => 0, "character" => 2}) }
  end

  def test_semantic_tokens_deltas_and_diagnostics_are_strict
    data = Sadr::Protocol.semantic_delta([0, 0, 3, 0, 0], [{"start" => 5, "deleteCount" => 0, "data" => [1, 2, 4, 1, 0]}])
    tokens = Sadr::Protocol.semantic_tokens(data)
    assert_equal [0, 1], tokens.map(&:line)
    assert tokens.all? { |token| token.is_a?(Sadr::Token) }

    [[0, 0, 0, 0, 0], [0, 0, 1, -1, 0], [0, 0, 1, 0, 1 << 31], [1]].each do |invalid|
      assert_raises(Sadr::Error) { Sadr::Protocol.semantic_tokens(invalid) }
    end
    assert_raises(Sadr::Error) { Sadr::Protocol.semantic_tokens([0, 0, 1, 2, 0], legend: {"tokenTypes" => ["type"], "tokenModifiers" => []}) }
    assert_raises(Sadr::Error) { Sadr::Protocol.semantic_delta(data, [{"start" => -1, "deleteCount" => 2}]) }
    assert_raises(Sadr::Error) { Sadr::Protocol.semantic_delta([], [{"start" => nil}]) }
    assert_raises(Sadr::Error) { Sadr::Protocol.diagnostics([{"message" => "bad", "range" => {}}]) }
    assert_raises(Sadr::Error) do
      Sadr::Protocol.diagnostics([{"message" => "bad", "severity" => nil, "range" => {"start" => {"line" => 0, "character" => 0}, "end" => {"line" => 0, "character" => 0}}}])
    end
    assert_raises(Sadr::Error) do
      Sadr::Protocol.diagnostics([{"message" => "bad", "range" => {"start" => {"line" => 1, "character" => 0}, "end" => {"line" => 0, "character" => 0}}}])
    end
  end
end
