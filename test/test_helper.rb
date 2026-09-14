# frozen_string_literal: true

ENV["MT_NO_PLUGINS"] = "1"
gem "minitest", "~> 5.0"
require "minitest/autorun"
require "rbconfig"
require "stringio"
require "sadr"
require "sadr/testing"

require_relative "support/text_index"

module SadrTestHelpers
  def wait_until(timeout: 3)
    deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + timeout
    until yield
      raise "condition timed out" if Process.clock_gettime(Process::CLOCK_MONOTONIC) > deadline

      sleep(0.005)
    end
  end
end

class Minitest::Test
  include SadrTestHelpers
end
