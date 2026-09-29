# frozen_string_literal: true

require "stringio"
require "test_helper"

class CodecTest < Minitest::Test
  def test_default_codec_is_immutable_and_ractor_shareable
    assert_predicate SolidRespRactor::DEFAULT_CODEC, :frozen?
    assert Ractor.shareable?(SolidRespRactor::DEFAULT_CODEC)
  end

  def test_codec_groups_encoding_and_reader_configuration
    codec = SolidRespRactor::Codec.new(handler: SolidRespRactor::Handlers::Typed)
    reader = codec.reader(StringIO.new("~1\r\n+value\r\n"))

    assert_equal "*1\r\n$4\r\nPING\r\n", codec.encode(["PING"])
    assert_equal SolidRespRactor::Types::Set.new(["value"]), reader.read
  end

  def test_module_reader_uses_default_codec
    reader = SolidRespRactor.reader(StringIO.new("+OK\r\n"))

    assert_equal "OK", reader.read
  end

  def test_each_ractor_can_create_its_own_reader_from_shared_codec
    workers = 2.times.map do |index|
      Ractor.new(SolidRespRactor::DEFAULT_CODEC, index) do |codec, value|
        codec.reader(StringIO.new(":#{value}\r\n")).read
      end
    end

    assert_equal [0, 1], workers.map { |worker| ractor_value(worker) }
  end
end
