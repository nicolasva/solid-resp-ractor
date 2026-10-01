# frozen_string_literal: true

require "socket"
require "test_helper"

class SourceTest < Minitest::Test
  def test_waits_for_readable_data
    reader, writer = Socket.pair(:UNIX, :STREAM)
    source = SolidRespRactor::Sources::IO.new(reader)

    refute source.wait_readable(0.001)
    writer.write("+OK\r\n")
    assert source.wait_readable(0.1)
    assert_equal "+OK\r\n", source.read(timeout: 0.1)
  ensure
    reader&.close
    writer&.close
  end

  def test_times_out_when_nonblocking_io_never_becomes_ready
    io = WaitingIO.new
    selector = ->(_readers, _writers, _timeout) { nil }
    source = SolidRespRactor::Sources::IO.new(io, selector: selector)

    error = assert_raises(SolidRespRactor::TimeoutError) do
      source.read(timeout: 0.01)
    end

    assert_match(/0.01s/, error.message)
  end

  def test_handles_wait_writable_for_tls_compatible_streams
    io = WaitingIO.new(:wait_writable, "+OK\r\n")
    selector = lambda do |readers, writers, _timeout|
      assert_nil readers
      assert_equal [io], writers
      true
    end
    source = SolidRespRactor::Sources::IO.new(io, selector: selector)

    assert_equal "+OK\r\n", source.read(timeout: 0.1)
  end

  def test_reuses_the_nonblocking_read_buffer
    io = WaitingIO.new("+first\r\n", "+second\r\n")
    source = SolidRespRactor::Sources::IO.new(io)

    first = source.read(timeout: 0.1)
    first_id = first.object_id
    assert_equal "+first\r\n", first

    second = source.read(timeout: 0.1)
    assert_equal "+second\r\n", second
    assert_equal first_id, second.object_id
  end

  class WaitingIO
    def initialize(*responses)
      @responses = responses.empty? ? [:wait_readable] : responses
    end

    def read_nonblock(_length, buffer, exception:)
      raise ArgumentError unless exception == false

      response = @responses.length == 1 ? @responses.first : @responses.shift
      return response if response == :wait_readable || response == :wait_writable

      buffer.replace(response)
    end
  end
end
