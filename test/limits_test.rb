# frozen_string_literal: true

require "stringio"
require "test_helper"

class LimitsTest < Minitest::Test
  def test_default_limits_are_immutable_and_shareable
    assert_predicate SolidRespRactor::Limits::DEFAULT, :frozen?
    assert Ractor.shareable?(SolidRespRactor::Limits::DEFAULT)
  end

  def test_rejects_invalid_limits
    %i[max_blob_size max_collection_size max_nesting_depth max_line_size].each do |name|
      assert_raises(ArgumentError) { SolidRespRactor::Limits.new(**{ name => 0 }) }
    end
  end

  def test_limits_declared_and_streamed_blobs
    limits = limits(max_blob_size: 4)

    assert_protocol_error("$5\r\nhello\r\n", limits)
    assert_protocol_error("$?\r\n;3\r\nabc\r\n;2\r\nde\r\n;0\r\n", limits)
  end

  def test_limits_declared_and_streamed_collections
    limits = limits(max_collection_size: 2)

    assert_protocol_error("*3\r\n:1\r\n:2\r\n:3\r\n", limits)
    assert_protocol_error("*?\r\n:1\r\n:2\r\n:3\r\n.\r\n", limits)
    assert_protocol_error(
      "%?\r\n+same\r\n:1\r\n+same\r\n:2\r\n+same\r\n:3\r\n.\r\n",
      limits,
    )
  end

  def test_limits_line_length
    assert_protocol_error("+12345\r\n", limits(max_line_size: 4))
  end

  def test_limits_nesting_depth
    payload = "*1\r\n*1\r\n*1\r\n+value\r\n"

    assert_protocol_error(payload, limits(max_nesting_depth: 3))
    assert_equal(
      [[["value"]]],
      reader_for(payload, limits(max_nesting_depth: 4)).read,
    )
  end

  private

  def limits(**overrides)
    SolidRespRactor::Limits.new(**{
      max_blob_size: 1024,
      max_collection_size: 100,
      max_nesting_depth: 16,
      max_line_size: 1024,
    }.merge(overrides))
  end

  def assert_protocol_error(payload, configured_limits)
    assert_raises(SolidRespRactor::ProtocolError) do
      reader_for(payload, configured_limits).read
    end
  end

  def reader_for(payload, configured_limits)
    SolidRespRactor::Reader.new(
      StringIO.new(payload),
      limits: configured_limits,
    )
  end
end
