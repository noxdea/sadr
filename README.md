<h1 align="center">Sadr</h1>

<p align="center">
  <strong>Pure Ruby Language Server Protocol client</strong>
</p>

<p align="center">
  <a href="https://rubygems.org/gems/sadr"><img src="https://img.shields.io/gem/v/sadr.svg?colorB=319e8c" alt="Gem Version"></a>
  <a href="https://rubygems.org/gems/sadr"><img src="https://img.shields.io/gem/dt/sadr.svg" alt="Downloads"></a>
  <img src="https://img.shields.io/badge/ruby-%3E%3D%203.1-ruby.svg" alt="Ruby Version">
  <a href="LICENSE.txt"><img src="https://img.shields.io/badge/license-MIT-blue.svg" alt="MIT License"></a>
</p>

<p align="center">
  <a href="#features">Features</a> ·
  <a href="#installation">Installation</a> ·
  <a href="#quick-start">Quick Start</a> ·
  <a href="#protocol-coverage">Protocol Coverage</a> ·
  <a href="#testing">Testing</a>
</p>

---

Sadr is a pure Ruby Language Server Protocol client. It owns JSON-RPC framing,
server lifecycle, document synchronization, diagnostics, and semantic tokens
without depending on an editor model or text-storage gem.

## Features

- JSON-RPC framing and Language Server Protocol lifecycle management
- Document synchronization, diagnostics, semantic tokens, and workspace edits
- Completion, navigation, hierarchy, formatting, rename, and link requests
- UTF-16 position conversion through caller-owned text indexes
- Cancellable, timeout-aware futures and automatic server recovery
- In-memory and child-process testing helpers

## Installation

```ruby
gem "sadr"
```

Sadr supports Ruby 3.1 and later.

## Quick Start

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

## Protocol coverage

Document highlights, folding and selection ranges, rename preparation,
hierarchy preparation, document links, linked editing ranges, and range
formatting use the same URI and UTF-16 position values:

```ruby
highlights = client.document_highlight(document.uri, position).await
folds = client.folding_range(document.uri).await
selection = client.selection_range(document.uri, [position]).await
rename_range = client.prepare_rename(document.uri, position).await
range = Sadr::Range_.new(start: position, end: position)
formatted = client.range_formatting(document.uri, range,
  tabSize: 2, insertSpaces: true).await
```

Prepared hierarchy items can be followed in either direction. Document links
can likewise be resolved after discovery. Sadr validates the supplied item and
every returned item, call range, URI, and opaque JSON `data` value before
crossing the client boundary:

```ruby
call_item = client.prepare_call_hierarchy(document.uri, position).await&.first
incoming = client.call_hierarchy_incoming_calls(call_item).await if call_item
outgoing = client.call_hierarchy_outgoing_calls(call_item).await if call_item

type_item = client.prepare_type_hierarchy(document.uri, position).await&.first
supertypes = client.type_hierarchy_supertypes(type_item).await if type_item
subtypes = client.type_hierarchy_subtypes(type_item).await if type_item

link = client.document_link(document.uri).await&.first
resolved_link = client.resolve_document_link(link).await if link
```

Workspace changes are notifications and return after the transport accepts the
message:

```ruby
client.did_change_configuration("ruby" => {"lint" => true})
client.did_change_watched_files([{uri: document.uri, type: 2}])
```

Watched-file types follow LSP: `1` created, `2` changed, and `3` deleted.
Configuration settings may be any JSON value, as required by LSP. Sadr snapshots
them before sending so later caller mutations do not alter configuration replies.

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

## Testing

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

## Contributing

Bug reports and pull requests are welcome at https://github.com/noxdea/sadr.

## License

Sadr is available under the [MIT License](LICENSE.txt).
