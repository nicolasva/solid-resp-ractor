# frozen_string_literal: true

require "stringio"
require "test_helper"

class AdversarialTest < Minitest::Test
  VALID_FRAMES = {
    "+OK\r\n" => "OK",
    ":42\r\n" => 42,
    "$5\r\nhello\r\n" => "hello",
    "*3\r\n+one\r\n:2\r\n$5\r\nthree\r\n" => ["one", 2, "three"],
    "%2\r\n+a\r\n:1\r\n+b\r\n:2\r\n" => { "a" => 1, "b" => 2 },
    "$?\r\n;2\r\nhe\r\n;3\r\nllo\r\n;0\r\n" => "hello",
    "*?\r\n+one\r\n:2\r\n.\r\n" => ["one", 2],
    "%?\r\n+key\r\n+value\r\n.\r\n" => { "key" => "value" },
  }.freeze

  TRUNCATED_STREAMED_FRAMES = [
    "$?\r\n;5\r\nhello\r\n",
    "$?\r\n;5\r\nhell",
    "*?\r\n+one\r\n",
    "*?\r\n+one\r\n.",
    "%?\r\n+key\r\n",
    "%?\r\n+key\r\n+value\r\n",
  ].freeze

  def test_decodes_valid_frames_split_at_every_byte_boundary
    VALID_FRAMES.each do |frame, expected|
      1.upto(frame.bytesize - 1) do |split|
        source = ChunkSource.new([
          frame.byteslice(0, split),
          frame.byteslice(split..),
        ])

        assert_equal expected, reader_for(source).read,
          "failed split #{split} for #{frame.inspect}"
      end
    end
  end

  def test_decodes_valid_frames_with_every_byte_in_a_separate_chunk
    VALID_FRAMES.each do |frame, expected|
      source = ChunkSource.new(frame.bytes.map(&:chr))

      assert_equal expected, reader_for(source).read, frame.inspect
    end
  end

  def test_rejects_eof_at_every_incomplete_byte_position
    VALID_FRAMES.each_key do |frame|
      0.upto(frame.bytesize - 1) do |length|
        truncated = frame.byteslice(0, length)

        assert_raises(SolidRespRactor::ConnectionError, truncated.inspect) do
          SolidRespRactor::Reader.new(StringIO.new(truncated)).read
        end
      end
    end
  end

  def test_rejects_truncated_streamed_values
    TRUNCATED_STREAMED_FRAMES.each do |frame|
      assert_raises(SolidRespRactor::ConnectionError, frame.inspect) do
        SolidRespRactor::Reader.new(StringIO.new(frame)).read
      end
    end
  end

  def test_rejects_lengths_over_configured_limits_before_reading_payloads
    limits = SolidRespRactor::Limits.new(
      max_blob_size: 8,
      max_collection_size: 2,
    )

    [
      "$9\r\n",
      "!9\r\n",
      "*3\r\n",
      "%3\r\n",
      "~3\r\n",
      ">3\r\n",
      "$?\r\n;9\r\n",
    ].each do |frame|
      assert_raises(SolidRespRactor::ProtocolError, frame.inspect) do
        SolidRespRactor::Reader.new(StringIO.new(frame), limits: limits).read
      end
    end
  end

  def test_rejects_excessive_nesting
    limits = SolidRespRactor::Limits.new(max_nesting_depth: 8)
    frame = ("*1\r\n" * 9) + "+value\r\n"

    error = assert_raises(SolidRespRactor::ProtocolError) do
      SolidRespRactor::Reader.new(StringIO.new(frame), limits: limits).read
    end

    assert_match "nesting exceeds 8", error.message
  end

  def test_deterministic_generated_values_survive_random_fragmentation
    random = Random.new(42_424)

    1_000.times do |iteration|
      frame, expected = generated_value(random)
      source = ChunkSource.new(fragment(frame, random))

      assert_equal expected, reader_for(source).read,
        "generated frame #{iteration}: #{frame.inspect}"
    end
  end

  def test_compacts_only_after_threshold_and_when_prefix_is_half_the_buffer
    reader = SolidRespRactor::Reader.new(StringIO.new(""))
    buffer = ("a" * 40_000).dup
    reader.instance_variable_set(:@buffer, buffer)

    reader.instance_variable_set(:@offset, 16_383)
    reader.send(:compact_buffer)
    assert_same buffer, reader.instance_variable_get(:@buffer)

    reader.instance_variable_set(:@offset, 16_384)
    reader.send(:compact_buffer)
    assert_same buffer, reader.instance_variable_get(:@buffer)

    reader.instance_variable_set(:@offset, 20_000)
    reader.send(:compact_buffer)
    assert_equal 20_000, reader.instance_variable_get(:@buffer).bytesize
    assert_equal 0, reader.instance_variable_get(:@offset)
  end

  private

  def reader_for(source)
    SolidRespRactor::Reader.new(source: source)
  end

  def generated_value(random, depth = 0)
    type = random.rand(depth >= 4 ? 3 : 7)

    case type
    when 0
      value = random.rand(-1_000_000..1_000_000)
      [":#{value}\r\n", value]
    when 1
      value = "text-#{random.rand(1_000_000)}"
      ["+#{value}\r\n", value]
    when 2
      value = random.bytes(random.rand(0..40))
      ["$#{value.bytesize}\r\n#{value}\r\n", value]
    when 3
      generated_collection(random, depth, streamed: false)
    when 4
      generated_map(random, depth)
    when 5
      generated_collection(random, depth, streamed: true)
    when 6
      value = random.bytes(random.rand(0..40))
      chunks = value.bytes.each_slice(random.rand(1..8)).map { |bytes| bytes.pack("C*") }
      frame = +"$?\r\n"
      chunks.each { |chunk| frame << ";#{chunk.bytesize}\r\n#{chunk}\r\n" }
      frame << ";0\r\n"
      [frame, value]
    end
  end

  def generated_collection(random, depth, streamed:)
    values = Array.new(random.rand(0..4)) { generated_value(random, depth + 1) }
    frame = streamed ? +"*?\r\n" : +"*#{values.length}\r\n"
    values.each { |child_frame, _| frame << child_frame }
    frame << ".\r\n" if streamed
    [frame, values.map(&:last)]
  end

  def generated_map(random, depth)
    pairs = Array.new(random.rand(0..4)) do |index|
      key = "key-#{depth}-#{index}-#{random.rand(1_000_000)}"
      [key, generated_value(random, depth + 1)]
    end
    frame = +"%#{pairs.length}\r\n"
    pairs.each do |key, (child_frame, _)|
      frame << "+#{key}\r\n" << child_frame
    end
    [frame, pairs.to_h { |key, (_, value)| [key, value] }]
  end

  def fragment(frame, random)
    chunks = []
    offset = 0
    while offset < frame.bytesize
      length = random.rand(1..[17, frame.bytesize - offset].min)
      chunks << frame.byteslice(offset, length)
      offset += length
    end
    chunks
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
