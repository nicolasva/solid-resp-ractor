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

  class WaitingIO
    def initialize(*responses)
      @responses = responses.empty? ? [:wait_readable] : responses
    end

    def read_nonblock(_length, exception:)
      raise ArgumentError unless exception == false

      @responses.length == 1 ? @responses.first : @responses.shift
    end
  end
end
