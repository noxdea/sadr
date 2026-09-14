# frozen_string_literal: true

require_relative "test_helper"

class FutureTest < Minitest::Test
  def test_callbacks_are_bounded_detachable_and_cancellation_is_once
    cancelled = []
    completed = []
    future = Sadr::Future.new(9) { |id| cancelled << id }
    subscription = future.on_complete { completed << :detached }
    subscription.detach
    40.times { future.then { raise "失敗" * 1000 } }
    future.on_complete { completed << :finished }

    assert future.cancel
    refute future.cancel
    assert future.done?
    assert_equal [9], cancelled
    assert_equal [:finished], completed
    assert_equal 32, future.callback_errors.length
    assert future.callback_errors.all? { |error| error.message.bytesize <= 2048 }
    assert_raises(Sadr::Error) { future.await }

    fulfilled = Sadr::Future.new(1) { flunk "completed request cancelled" }
    fulfilled.fulfill(42)
    refute fulfilled.cancel
    assert_equal 42, fulfilled.await(timeout: 0)
    assert_raises(ArgumentError) { fulfilled.await(timeout: Float::NAN) }
  end

  def test_timeout_cancels_the_request
    cancellations = []
    future = Sadr::Future.new(2) { |id| cancellations << id }
    assert_raises(Sadr::Timeout) { future.await(timeout: 0.001) }
    assert_equal [2], cancellations
    assert future.done?
  end

  def test_zaniah_foreground_wait_yields_and_translates_timeout
    zaniah = Module.new
    task = Module.new
    task.const_set(:Timeout, Class.new(StandardError))
    zaniah.const_set(:Task, task)
    executor_class = Class.new do
      class << self
        attr_accessor :current
      end
      attr_accessor :timeout

      def await(future, timeout:)
        raise Zaniah::Task::Timeout if @timeout

        Fiber.yield([future, timeout])
      end
    end
    zaniah.const_set(:TaskExecutor, executor_class)
    Object.const_set(:Zaniah, zaniah)

    executor = executor_class.new
    executor_class.current = executor
    future = Sadr::Future.new(3)
    events = []
    fiber = Fiber.new { events << :waiting; events << future.await(timeout: 1) }
    assert_equal [future, 1], fiber.resume
    events << :responsive
    future.fulfill(:value)
    fiber.resume(:value)
    assert_equal %i[waiting responsive value], events

    cancelled = []
    executor.timeout = true
    pending = Sadr::Future.new(4) { |id| cancelled << id }
    assert_raises(Sadr::Timeout) { pending.await(timeout: 0.01) }
    assert_equal [4], cancelled
  ensure
    executor_class.current = nil if executor_class
    Object.send(:remove_const, :Zaniah) if defined?(Zaniah)
  end
end
