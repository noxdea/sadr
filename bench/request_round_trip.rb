# frozen_string_literal: true

require_relative "../lib/sadr/testing"

server = Sadr::Testing::FakeServer.new
client = Sadr::Testing::FakeClient.new(server: server)
client.start(timeout: 1)
100.times { client.request("echo").await(timeout: 1) }

rounds = 7
iterations = 1_000
samples = Array.new(rounds) do
  started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
  iterations.times { client.request("echo").await(timeout: 1) }
  (Process.clock_gettime(Process::CLOCK_MONOTONIC) - started) / iterations
end
average = samples.sum / samples.length
median = samples.sort.fetch(samples.length / 2)
raise "request round trip exceeded 1ms: #{(median * 1000).round(3)}ms median" if ENV["BUDGET"] == "1" && median > 0.001

puts "request round trip (#{rounds}x#{iterations}): #{(average * 1000).round(3)}ms average, #{(median * 1000).round(3)}ms median"
client.stop
