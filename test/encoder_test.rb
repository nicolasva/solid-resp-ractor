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

  def test_default_encoder_is_ractor_shareable
    assert Ractor.shareable?(SolidRespRactor::DEFAULT_ENCODER)

    worker = Ractor.new(SolidRespRactor::DEFAULT_ENCODER) do |encoder|
      encoder.encode(["PING"])
    end

    assert_equal "*1\r\n$4\r\nPING\r\n", ractor_value(worker)
  end
end
