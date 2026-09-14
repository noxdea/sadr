# frozen_string_literal: true

require_relative "../lib/sadr"

tokens = Array.new(100_000) { [0, 1, 1, 0, 0] }.flatten
edits = [
  {"start" => 0, "deleteCount" => 0, "data" => [0, 1, 1, 0, 0]},
  {"start" => tokens.length, "deleteCount" => 0, "data" => [0, 1, 1, 0, 0]}
]
2.times { Sadr::Protocol.semantic_delta(tokens, edits) }
samples = Array.new(7) do
  started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
  result = Sadr::Protocol.semantic_delta(tokens, edits)
  raise "semantic token delta result is invalid" unless result.length == tokens.length + 10
  Process.clock_gettime(Process::CLOCK_MONOTONIC) - started
end
average = samples.sum / samples.length
median = samples.sort.fetch(samples.length / 2)
best = samples.min
raise "semantic token delta exceeded 20ms: #{(median * 1000).round(2)}ms median" if ENV["BUDGET"] == "1" && median > 0.020

puts "100k-token semantic delta (7 runs): #{(average * 1000).round(2)}ms average, #{(median * 1000).round(2)}ms median, #{(best * 1000).round(2)}ms best"
