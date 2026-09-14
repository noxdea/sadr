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
