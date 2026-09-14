# Sadr

Sadr is a pure Ruby Language Server Protocol client. It owns JSON-RPC framing,
server lifecycle, document synchronization, diagnostics, and semantic tokens
without depending on an editor model or text-storage gem.

## Installation

```ruby
gem "sadr"
```

## Usage

```ruby
require "sadr"

client = Sadr::Client.new(command: ["ruby-lsp"])
capabilities = client.start
document = Sadr::Document.new(
  uri: Sadr::Protocol.uri("example.rb"),
  language_id: "ruby",
  version: 0,
  text: "puts :hello\n"
)
client.open(document)

position = Sadr::Position.new(line: 0, character: 0)
completion = client.completion(document.uri, position).await
client.stop
```

`Future#await` waits without a deadline by default. Pass `timeout:` in seconds
when the caller needs a bounded wait; expiry cancels the request best-effort.

`Position#character` is measured in UTF-16 code units. Increment versions and
send immutable changes when a document changes:

```ruby
client.change(document.uri, 1, [
  Sadr::ContentChange.new(range: nil, text: "puts :world\n")
])
```

Protocol conversion accepts any text index that provides `utf16_point_at`,
`utf16_offset_at`, `offset_at_utf16`, `line_start`, and `line`. This keeps rope
and buffer ownership in the caller:

```ruby
position = Sadr::Protocol.position(my_text_index, byte_offset)
edits = Sadr::Protocol.text_edits(my_text_index, server_edits)
```

Tests can use the bundled child-process server or the in-memory transport:

```ruby
require "sadr/testing"

client = Sadr::Client.new(command: Sadr::Testing::FakeServer.command)
server = Sadr::Testing::FakeServer.new(responses: {"custom/request" => {"ok" => true}})
fast_client = Sadr::Testing::FakeClient.new(server: server)
```

The optional real-server test stays outside the normal bundle and CI. After
`bundle install`, run it with the same Ruby:

```sh
gem install ruby-lsp
SADR_INTEGRATION=1 ruby -Ilib:test test/ruby_lsp_integration_test.rb
```

## Development

```sh
bundle install
bundle exec rake test
bundle exec rbs -I sig -r stringio validate
BUDGET=1 bundle exec rake bench
gem build --strict sadr.gemspec
```

## License

Sadr is available under the MIT License.
