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

      def wait(io, event, timeout)
        if event == :read && io.respond_to?(:wait_readable)
          io.wait_readable(timeout)
        elsif event == :write && io.respond_to?(:wait_writable)
          io.wait_writable(timeout)
        else
          readers = event == :read ? [io] : nil
          writers = event == :write ? [io] : nil
          call(readers, writers, timeout)
        end
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
        @read_buffer = +""
        @nonblocking = io.respond_to?(:read_nonblock)
        @selector_waits = selector.respond_to?(:wait)
        @selectable = nil
      end

      def read(timeout:)
        return blocking_read unless @nonblocking

        chunk = @io.read_nonblock(@chunk_size, @read_buffer, exception: false)
        return chunk unless chunk == :wait_readable || chunk == :wait_writable

        wait_for_chunk(chunk, timeout)
      rescue IOError, SystemCallError => error
        raise ConnectionError, error.message, cause: error
      end

      def wait_readable(timeout)
        return true unless @io.respond_to?(:to_io)

        !wait(@io.to_io, :read, timeout).nil?
      rescue IOError, SystemCallError => error
        raise ConnectionError, error.message, cause: error
      end

      private

      def wait_for_chunk(chunk, timeout)
        selectable = (@selectable ||= @io.respond_to?(:to_io) ? @io.to_io : @io)
        deadline = timeout && @clock.now + timeout
        remaining = timeout
        loop do
          raise_timeout(timeout) if remaining && remaining <= 0

          event = chunk == :wait_readable ? :read : :write
          raise_timeout(timeout) unless wait(selectable, event, remaining)

          chunk = @io.read_nonblock(@chunk_size, @read_buffer, exception: false)
          return chunk unless chunk == :wait_readable || chunk == :wait_writable

          remaining = deadline && deadline - @clock.now
        end
      end

      def blocking_read
        @io.read(@chunk_size)
      end

      def wait(io, event, timeout)
        return @selector.wait(io, event, timeout) if @selector_waits

        readers = event == :read ? [io] : nil
        writers = event == :write ? [io] : nil
        @selector.call(readers, writers, timeout)
      end

      def raise_timeout(timeout)
        raise TimeoutError, "RESP read timed out after #{timeout}s"
      end
    end
  end
end
