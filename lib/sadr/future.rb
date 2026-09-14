# frozen_string_literal: true

module Sadr
  class Future
    class Subscription
      def initialize(&detach) = @detach = detach

      def detach
        callback, @detach = @detach, nil
        callback&.call
      end
    end

    attr_reader :id, :callback_errors

    def initialize(id, on_error: nil, &cancel)
      @id = id
      @cancel_callback = cancel
      @on_error = on_error
      @lock = Mutex.new
      @ready = ConditionVariable.new
      @callbacks = []
      @callback_errors = []
    end

    def fulfill(value = nil, error: nil)
      callbacks = @lock.synchronize do
        return if @done

        @value = value
        @error = error
        @done = true
        @ready.broadcast
        saved, @callbacks = @callbacks, []
        saved
      end
      callbacks.each { |callback| invoke(callback) }
      self
    end

    def then(&callback)
      raise ArgumentError, "callback required" unless callback

      on_complete { callback.call(@value, @error) }
      self
    end

    def done? = @lock.synchronize { !!@done }

    def on_complete(&callback)
      raise ArgumentError, "callback required" unless callback

      ready = @lock.synchronize do
        @callbacks << callback unless @done
        @done
      end
      invoke(callback) if ready
      Subscription.new { @lock.synchronize { @callbacks.delete(callback) } }
    end

    def await(timeout: 10)
      valid = timeout.nil? || (timeout.is_a?(Numeric) && timeout.finite? && timeout >= 0)
      raise ArgumentError, "timeout must be finite and nonnegative" unless valid

      if defined?(Zaniah::TaskExecutor) && Zaniah::TaskExecutor.current && !done?
        return Zaniah::TaskExecutor.current.await(self, timeout: timeout)
      end

      deadline = timeout && Process.clock_gettime(Process::CLOCK_MONOTONIC) + timeout
      @lock.synchronize do
        until @done
          remaining = deadline && deadline - Process.clock_gettime(Process::CLOCK_MONOTONIC)
          raise Timeout, "LSP request #{@id} timed out" if remaining && remaining <= 0

          @ready.wait(@lock, remaining)
        end
        raise @error if @error

        @value
      end
    rescue StandardError => error
      if error.is_a?(Timeout) || (defined?(Zaniah::Task::Timeout) && error.is_a?(Zaniah::Task::Timeout))
        cancel
        raise Timeout, "LSP request #{@id} timed out"
      end
      raise
    end

    def cancel
      callback = @lock.synchronize do
        return false if @done || @cancelling

        @cancelling = true
        @cancel_callback
      end
      invoke(-> { callback.call(@id) }) if callback
      fulfill(error: Error.new("request cancelled"))
      true
    end

    private

    def invoke(callback)
      callback.call
    rescue StandardError => error
      bounded = Error.new("#{error.class}: #{error.message}".scrub.byteslice(0, 2048).scrub(""))
      @lock.synchronize do
        @callback_errors << bounded
        @callback_errors.shift if @callback_errors.length > 32
      end
      begin
        @on_error&.call(bounded)
      rescue StandardError
        nil
      end
    end
  end
end
