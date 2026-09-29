# frozen_string_literal: true

require "stringio"
require "test_helper"

class StressTest < Minitest::Test
  PIPELINE_SIZE = 50_000
  FRAGMENTED_FRAMES = 2_000
  RACTORS = 8
  OPERATIONS_PER_RACTOR = 2_000

  def test_decodes_large_pipeline_without_losing_frames
    reader = SolidRespRactor::Reader.new(
      StringIO.new("+OK\r\n" * PIPELINE_SIZE),
    )

    PIPELINE_SIZE.times do
      raise "pipeline frame mismatch" unless reader.read == "OK"
    end

    assert_raises(SolidRespRactor::ConnectionError) { reader.read }
  end

  def test_decodes_one_byte_fragmentation
    payload = +""
    FRAGMENTED_FRAMES.times { |index| payload << ":#{index}\r\n" }
    reader = SolidRespRactor::Reader.new(source: OneByteSource.new(payload))

    sum = FRAGMENTED_FRAMES.times.sum { reader.read }

    assert_equal (0...FRAGMENTED_FRAMES).sum, sum
  end

  def test_decodes_large_fragmented_blob
    size = 4 * 1024 * 1024
    payload = "$#{size}\r\n#{"x" * size}\r\n"
    reader = SolidRespRactor::Reader.new(
      source: FragmentedSource.new(payload, 1021),
    )

    value = reader.read

    assert_equal size, value.bytesize
    assert_equal "x", value.byteslice(0, 1)
    assert_equal "x", value.byteslice(-1, 1)
  end

  def test_shared_codec_under_parallel_ractor_load
    workers = RACTORS.times.map do |worker_index|
      Ractor.new(
        SolidRespRactor::DEFAULT_CODEC,
        worker_index,
        OPERATIONS_PER_RACTOR,
      ) do |codec, index, operations|
        payload = operations.times.map { |value| ":#{index + value}\r\n" }.join
        reader = codec.reader(StringIO.new(payload))
        decoded = operations.times.sum { reader.read }
        encoded = operations.times.sum do |value|
          codec.encode(["SET", "key", value]).bytesize
        end
        [decoded, encoded]
      end
    end

    results = workers.map { |worker| ractor_value(worker) }

    assert_equal RACTORS, results.length
    results.each_with_index do |(decoded, encoded), index|
      expected = OPERATIONS_PER_RACTOR.times.sum { |value| index + value }
      assert_equal expected, decoded
      assert_operator encoded, :>, 0
    end
  end

  def test_deterministic_malformed_input_fuzz
    random = Random.new(12_345)
    alphabet = (" ".."~").to_a.join

    2_000.times do
      payload = String.new(capacity: 40)
      random.rand(1..40).times { payload << alphabet.getbyte(random.rand(alphabet.bytesize)) }
      payload << "\r\n" if random.rand(2).zero?

      begin
        SolidRespRactor::Reader.new(StringIO.new(payload)).read
      rescue SolidRespRactor::Error
        nil
      end
    rescue StandardError => error
      flunk "unexpected #{error.class} for #{payload.inspect}: #{error.message}"
    end

    assert true
  end

  def test_deep_nested_error_keeps_following_frame_synchronized
    depth = 100
    payload = ("*1\r\n" * depth) + "-ERR deeply nested\r\n+next\r\n"
    reader = SolidRespRactor::Reader.new(StringIO.new(payload))

    assert_raises(SolidRespRactor::ResponseError) { reader.read }
    assert_equal "next", reader.read
  end

  class OneByteSource
    def initialize(payload)
      @payload = payload
      @offset = 0
    end

    def read(timeout:)
      return if @offset == @payload.bytesize

      byte = @payload.byteslice(@offset, 1)
      @offset += 1
      byte
    end
  end

  class FragmentedSource
    def initialize(payload, chunk_size)
      @payload = payload
      @chunk_size = chunk_size
      @offset = 0
    end

    def read(timeout:)
      return if @offset == @payload.bytesize

      chunk = @payload.byteslice(@offset, @chunk_size)
      @offset += chunk.bytesize
      chunk
    end
  end
end
