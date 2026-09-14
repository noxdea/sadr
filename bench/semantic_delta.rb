# frozen_string_literal: true

require_relative "../lib/sadr"

tokens = Array.new(100_000) { [0, 1, 1, 0, 0] }.flatten
edit = [{"start" => tokens.length, "deleteCount" => 0, "data" => [0, 1, 1, 0, 0]}]
started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
result = Sadr::Protocol.semantic_delta(tokens, edit)
elapsed = Process.clock_gettime(Process::CLOCK_MONOTONIC) - started
raise "semantic token delta result is invalid" unless result.length == tokens.length + 5
raise "semantic token delta exceeded 1 second: #{elapsed.round(3)}s" if ENV["BUDGET"] == "1" && elapsed > 1.0

puts "100k-token semantic delta: #{(elapsed * 1000).round(2)}ms"
