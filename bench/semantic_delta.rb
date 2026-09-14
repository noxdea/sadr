# frozen_string_literal: true

require_relative "../lib/sadr"

tokens = Array.new(100_000) { [0, 1, 1, 0, 0] }.flatten
edits = [
  {"start" => 0, "deleteCount" => 0, "data" => [0, 1, 1, 0, 0]},
  {"start" => tokens.length, "deleteCount" => 0, "data" => [0, 1, 1, 0, 0]}
]
started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
result = Sadr::Protocol.semantic_delta(tokens, edits)
elapsed = Process.clock_gettime(Process::CLOCK_MONOTONIC) - started
raise "semantic token delta result is invalid" unless result.length == tokens.length + 10
# The implementation targets 20ms locally; shared CI runners get headroom to avoid noisy failures.
raise "semantic token delta exceeded 50ms: #{(elapsed * 1000).round(2)}ms" if ENV["BUDGET"] == "1" && elapsed > 0.05

puts "100k-token semantic delta: #{(elapsed * 1000).round(2)}ms"
