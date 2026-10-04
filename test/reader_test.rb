# frozen_string_literal: true

require "stringio"
require "test_helper"

class ReaderTest < Minitest::Test
  def test_decodes_resp2_and_resp3_scalars
    payload = [
      "+OK\r\n",
      ":42\r\n",
      "$3\r\nfoo\r\n",
      "_\r\n",
      "#t\r\n",
      "#f\r\n",
      ",1.5\r\n",
      "(12345678901234567890\r\n",
    ].join
    reader = reader_for(payload)

    assert_equal "OK", reader.read
    assert_equal 42, reader.read
    assert_equal "foo", reader.read
    assert_nil reader.read
    assert_equal true, reader.read
    assert_equal false, reader.read
    assert_equal 1.5, reader.read
    assert_equal 12_345_678_901_234_567_890, reader.read
  end

  def test_decodes_arrays_maps_sets_and_pushes
    payload = [
      "*2\r\n+one\r\n:2\r\n",
      "%1\r\n+key\r\n+value\r\n",
      "~2\r\n+a\r\n+b\r\n",
      ">2\r\n+message\r\n+body\r\n",
    ].join
    reader = reader_for(payload)

    assert_equal ["one", 2], reader.read
    assert_equal({ "key" => "value" }, reader.read)
    assert_equal ["a", "b"], reader.read
    assert_equal ["message", "body"], reader.read
  end

  def test_typed_handler_preserves_resp3_semantics
    payload = [
      "~2\r\n+a\r\n+b\r\n",
      ">2\r\n+message\r\n+body\r\n",
      "=9\r\ntxt:hello\r\n",
      "|1\r\n+ttl\r\n:10\r\n+value\r\n",
    ].join
    reader = reader_for(payload, handler: SolidRespRactor::Handlers::Typed)

    assert_equal SolidRespRactor::Types::Set.new(["a", "b"]), reader.read
    assert_equal SolidRespRactor::Types::Push.new(["message", "body"]), reader.read
    assert_equal SolidRespRactor::Types::Verbatim.new("txt", "hello"), reader.read
    assert_equal(
      SolidRespRactor::Types::Attribute.new({ "ttl" => 10 }, "value"),
      reader.read,
    )
  end

  def test_decodes_streamed_resp3_values
    payload = [
      "$?\r\n;5\r\nhello\r\n;1\r\n!\r\n;0\r\n",
      "*?\r\n+one\r\n:2\r\n.\r\n",
      "%?\r\n+key\r\n+value\r\n.\r\n",
      "~?\r\n+a\r\n+b\r\n.\r\n",
    ].join
    reader = reader_for(payload, handler: SolidRespRactor::Handlers::Typed)

    assert_equal "hello!", reader.read
    assert_equal ["one", 2], reader.read
    assert_equal({ "key" => "value" }, reader.read)
    assert_equal SolidRespRactor::Types::Set.new(["a", "b"]), reader.read
  end

  def test_decodes_special_resp3_doubles
    reader = reader_for(",inf\r\n,-inf\r\n,nan\r\n")

    assert_equal Float::INFINITY, reader.read
    assert_equal(-Float::INFINITY, reader.read)
    assert_predicate reader.read, :nan?
  end

  def test_returns_or_raises_mapped_errors
    reader = reader_for("-ERR broken\r\n-NOAUTH required\r\n")

    error = reader.read(exception: false)
    assert_instance_of SolidRespRactor::ResponseError, error
    assert_equal "ERR broken", error.message
    assert_raises(SolidRespRactor::AuthenticationError) { reader.read }
  end

  def test_supports_a_custom_error_mapper
    custom_error = Class.new(StandardError)
    mapper = ->(message, blob:) { custom_error.new("#{blob}:#{message}") }
    reader = reader_for("!11\r\nERR details\r\n", error_mapper: mapper)

    error = reader.read(exception: false)

    assert_instance_of custom_error, error
    assert_equal "true:ERR details", error.message
  end

  def test_consumes_a_complete_collection_before_raising_nested_error
    reader = reader_for("*3\r\n+before\r\n-ERR broken\r\n+after\r\n+next\r\n")

    assert_raises(SolidRespRactor::ResponseError) { reader.read }
    assert_equal "next", reader.read
  end

  def test_reads_fragmented_data_from_an_injectable_source
    source = ChunkSource.new(["+fi", "rst\r\n+sec", "ond\r\n"])
    reader = SolidRespRactor::Reader.new(source: source)

    assert_equal "first", reader.read
    assert_equal "second", reader.read
  end

  def test_supports_custom_value_handlers
    handler = ->(type, value) { [type, value] }
    reader = reader_for("+OK\r\n", handler: handler)

    assert_equal [:simple_string, "OK"], reader.read
  end

  def test_custom_handlers_cannot_hide_nested_errors
    handler = ->(type, value) { [type, value] }
    reader = reader_for(
      "*2\r\n*1\r\n-ERR nested\r\n+after\r\n+next\r\n",
      handler: handler,
    )

    assert_raises(SolidRespRactor::ResponseError) { reader.read }
    assert_equal [:simple_string, "next"], reader.read
  end

  def test_rejects_malformed_frames
    invalid_frames = [
      "#x\r\n",
      "_value\r\n",
      "$-2\r\n",
      "=3\r\nbad\r\n",
      "$3\r\nfooXX",
      "?unknown\r\n",
    ]

    invalid_frames.each do |frame|
      assert_raises(SolidRespRactor::ProtocolError, frame.inspect) do
        reader_for(frame).read
      end
    end
  end

  def test_parses_integers_and_lengths_split_across_chunks
    payload = ":-12345\r\n:99999999999999999999999\r\n*2\r\n$11\r\nhello world\r\n:0\r\n$-1\r\n*-1\r\n"
    expected = [-12_345, 99_999_999_999_999_999_999_999, ["hello world", 0], nil, nil]

    payload.bytesize.times do |split|
      source = ChunkSource.new([payload.byteslice(0, split), payload.byteslice(split..)].reject(&:empty?))
      reader = SolidRespRactor::Reader.new(source: source)

      assert_equal expected, Array.new(expected.length) { reader.read }, "split at #{split}"
    end
  end

  def test_non_plain_integers_keep_kernel_integer_semantics
    reader = reader_for(":+5\r\n:1_000\r\n$+3\r\nabc\r\n")

    assert_equal 5, reader.read
    assert_equal 1_000, reader.read
    assert_equal "abc", reader.read
    assert_raises(SolidRespRactor::ProtocolError) { reader_for(":-\r\n").read }
    assert_raises(SolidRespRactor::ProtocolError) { reader_for(":12a\r\n").read }
    assert_raises(SolidRespRactor::ProtocolError) { reader_for("$-2\r\n").read }
  end

  def test_integer_lines_respect_the_line_limit
    limits = SolidRespRactor::Limits.new(max_line_size: 3)

    assert_equal 123, reader_for(":123\r\n", limits: limits).read
    assert_raises(SolidRespRactor::ProtocolError) do
      reader_for(":1234\r\n", limits: limits).read
    end
  end

  def test_finds_line_ends_by_byte_offset_in_multibyte_chunks
    skip "String#byteindex requires Ruby 3.2" unless "".respond_to?(:byteindex)

    reader = SolidRespRactor::Reader.new(source: ChunkSource.new(["+\u00e9t\u00e9\r\n:7\r\n"]))

    assert_equal "\u00e9t\u00e9".b, reader.read.b
    assert_equal 7, reader.read
  end

  def test_reports_end_of_stream_as_connection_error
    assert_raises(SolidRespRactor::ConnectionError) { reader_for("").read }
  end

  private

  def reader_for(payload, **options)
    SolidRespRactor::Reader.new(StringIO.new(payload), **options)
  end

  class ChunkSource
    def initialize(chunks)
      @chunks = chunks
    end

    def read(timeout:)
      @chunks.shift
    end
  end
end
