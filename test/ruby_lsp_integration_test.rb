# frozen_string_literal: true

require_relative "test_helper"
require "tmpdir"

class RubyLspIntegrationTest < Minitest::Test
  def test_initialize_open_and_hover
    skip "set SADR_INTEGRATION=1 to run ruby-lsp integration" unless ENV["SADR_INTEGRATION"] == "1"

    command = Gem.bin_path("ruby-lsp", "ruby-lsp")
    Dir.mktmpdir("sadr-ruby-lsp") do |root|
      path = File.join(root, "example.rb")
      text = "String.new\n"
      File.write(path, text)
      client = Sadr::Client.new(command: [command], root: root, restart: false)
      assert_kind_of Hash, client.start(timeout: 20)
      uri = client.open(Sadr::Document.new(uri: Sadr::Protocol.uri(path), language_id: "ruby", version: 0, text: text))
      result = client.hover(uri, Sadr::Position.new(line: 0, character: 1)).await(timeout: 20)
      assert result.nil? || result.is_a?(Hash)
      client.close(uri)
    ensure
      client&.stop
    end
  rescue Gem::Exception
    skip "SADR_INTEGRATION=1 requires the ruby-lsp gem"
  end
end
