# frozen_string_literal: true

module SolidRespRactor
  module Clocks
    module Monotonic
      module_function

      def now
        Process.clock_gettime(Process::CLOCK_MONOTONIC)
      end
    end
  end

  module Selectors
    module IOSelect
      module_function

      def call(readers, writers, timeout)
        IO.select(readers, writers, nil, timeout)
      end
    end
  end

  module Sources
    class IO
      def initialize(
        io,
        chunk_size: 16_384,
        selector: Selectors::IOSelect,
        clock: Clocks::Monotonic
      )
        @io = io
        @chunk_size = Integer(chunk_size)
        raise ArgumentError, "chunk_size must be positive" unless @chunk_size.positive?

        @selector = selector
        @clock = clock
      end

      def read(timeout:)
        return blocking_read unless @io.respond_to?(:read_nonblock)

        deadline = nil
        loop do
          chunk = @io.read_nonblock(@chunk_size, exception: false)
          return chunk unless chunk == :wait_readable || chunk == :wait_writable

          deadline ||= @clock.now + timeout if timeout
          remaining = deadline && deadline - @clock.now
          raise_timeout(timeout) if remaining && remaining <= 0

          selectable = @io.respond_to?(:to_io) ? @io.to_io : @io
          readers = chunk == :wait_readable ? [selectable] : nil
          writers = chunk == :wait_writable ? [selectable] : nil
          raise_timeout(timeout) unless @selector.call(readers, writers, remaining)
        end
      rescue IOError, SystemCallError => error
        raise ConnectionError, error.message, cause: error
      end

      def wait_readable(timeout)
        return true unless @io.respond_to?(:to_io)

        !@selector.call([@io.to_io], nil, timeout).nil?
      rescue IOError, SystemCallError => error
        raise ConnectionError, error.message, cause: error
      end

      private

      def blocking_read
        @io.read(@chunk_size)
      end

      def raise_timeout(timeout)
        raise TimeoutError, "RESP read timed out after #{timeout}s"
      end
    end
  end
end
