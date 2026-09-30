# frozen_string_literal: true

module SolidRespRactor
  module ArgumentEncoders
    module Default
      module_function

      def call(value)
        case value
        when String then value
        when Symbol, Integer, Float then value.to_s
        when true then "1"
        when false then "0"
        when nil then ""
        else value.to_s
        end
      end
    end
  end

  class Encoder
    CRLF = "\r\n"
    BULK_HEADERS = Ractor.make_shareable(
      Array.new(1_025) { |length| "$#{length}#{CRLF}".freeze },
    )
    ARRAY_HEADERS = Ractor.make_shareable(
      Array.new(129) { |length| "*#{length}#{CRLF}".freeze },
    )

    attr_reader :argument_encoder

    def initialize(argument_encoder: ArgumentEncoders::Default, expand_arrays: true)
      @argument_encoder = argument_encoder
      @expand_arrays = expand_arrays
      freeze
    end

    def encode(command)
      unless @expand_arrays && command.any? { |argument| argument.is_a?(Array) }
        return encode_flat(command)
      end

      length = command.sum { |argument| expanded?(argument) ? argument.length : 1 }
      raise ArgumentError, "RESP command cannot be empty" if length.zero?

      command.each_with_object(+"*#{length}#{CRLF}") do |argument, buffer|
        if expanded?(argument)
          argument.each { |value| append_argument(buffer, value) }
        else
          append_argument(buffer, argument)
        end
      end
    end

    private

    def encode_flat(command)
      length = command.length
      raise ArgumentError, "RESP command cannot be empty" if length.zero?

      command.each_with_object(+array_header(length)) do |argument, buffer|
        append_argument(buffer, argument)
      end
    end

    def array_header(length)
      ARRAY_HEADERS[length] || "*#{length}#{CRLF}"
    end

    def expanded?(argument)
      @expand_arrays && argument.is_a?(Array)
    end

    def append_argument(buffer, argument)
      value = @argument_encoder.call(argument)
      unless value.is_a?(String)
        raise TypeError, "argument encoder must return a String, got #{value.class}"
      end

      buffer << bulk_header(value.bytesize) << value << CRLF
    end

    def bulk_header(length)
      BULK_HEADERS[length] || "$#{length}#{CRLF}"
    end
  end

  DEFAULT_ENCODER = Encoder.new
  Ractor.make_shareable(DEFAULT_ENCODER) if defined?(Ractor)
end
