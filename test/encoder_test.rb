# frozen_string_literal: true

require "test_helper"

class EncoderTest < Minitest::Test
  def test_encodes_commands
    assert_equal(
      "*2\r\n$3\r\nGET\r\n$3\r\nkey\r\n",
      SolidRespRactor.encode(["GET", "key"]),
    )
  end

  def test_expands_one_level_of_array_arguments_without_mutating_command
    command = ["MSET", ["first", 1], ["second", 2]]

    assert_equal(
      "*5\r\n$4\r\nMSET\r\n$5\r\nfirst\r\n$1\r\n1\r\n$6\r\nsecond\r\n$1\r\n2\r\n",
      SolidRespRactor.encode(command),
    )
    assert_equal ["MSET", ["first", 1], ["second", 2]], command
  end

  def test_can_disable_array_expansion
    encoder = SolidRespRactor::Encoder.new(
      expand_arrays: false,
      argument_encoder: ->(value) { value.inspect },
    )

    assert_equal(
      "*2\r\n$5\r\n\"CMD\"\r\n$10\r\n[\"a\", \"b\"]\r\n",
      encoder.encode(["CMD", ["a", "b"]]),
    )
  end

  def test_accepts_a_custom_argument_encoder
    encoder = SolidRespRactor::Encoder.new(
      argument_encoder: ->(value) { value.to_s.upcase },
    )

    assert_equal "*2\r\n$3\r\nSET\r\n$3\r\nKEY\r\n", encoder.encode([:set, :key])
  end

  def test_rejects_empty_commands_and_non_string_encoder_results
    assert_raises(ArgumentError) { SolidRespRactor.encode([]) }

    encoder = SolidRespRactor::Encoder.new(argument_encoder: ->(_value) { 1 })
    assert_raises(TypeError) { encoder.encode(["PING"]) }
  end

  def test_encodes_cached_and_uncached_integer_arguments
    assert_equal(
      "*5\r\n$6\r\nEXPIRE\r\n$1\r\n0\r\n$4\r\n1023\r\n$4\r\n1024\r\n$2\r\n-1\r\n",
      SolidRespRactor.encode(["EXPIRE", 0, 1_023, 1_024, -1]),
    )
  end

  def test_expands_arrays_found_after_flat_arguments
    assert_equal(
      "*4\r\n$4\r\nMSET\r\n$1\r\na\r\n$1\r\n1\r\n$1\r\nb\r\n",
      SolidRespRactor.encode(["MSET", "a", [1, :b]]),
    )
    assert_raises(ArgumentError) { SolidRespRactor.encode([[]]) }
  end

  def test_custom_argument_encoder_also_receives_strings
    encoder = SolidRespRactor::Encoder.new(argument_encoder: ->(value) { "#{value}!" })

    assert_equal "*2\r\n$4\r\nGET!\r\n$2\r\n1!\r\n", encoder.encode(["GET", 1])
  end

  def test_returns_a_new_mutable_buffer_for_every_command
    first = SolidRespRactor.encode(["PING"])
    second = SolidRespRactor.encode(["PING"])

    refute_same first, second
    refute first.frozen?
  end

  def test_default_encoder_is_ractor_shareable
    assert Ractor.shareable?(SolidRespRactor::DEFAULT_ENCODER)

    worker = Ractor.new(SolidRespRactor::DEFAULT_ENCODER) do |encoder|
      encoder.encode(["PING"])
    end

    assert_equal "*1\r\n$4\r\nPING\r\n", ractor_value(worker)
  end
end
