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

    INTEGER_STRINGS = Ractor.make_shareable(
      Array.new(1_024) { |integer| integer.to_s.freeze },
    )
    EMPTY_COMMAND = "RESP command cannot be empty"

    attr_reader :argument_encoder

    def initialize(argument_encoder: ArgumentEncoders::Default, expand_arrays: true)
      @argument_encoder = argument_encoder
      @expand_arrays = expand_arrays
      @default_arguments = argument_encoder.equal?(ArgumentEncoders::Default)
      freeze
    end

    def encode(command)
      length = command.length
      raise ArgumentError, EMPTY_COMMAND if length.zero?

      buffer = +(ARRAY_HEADERS[length] || "*#{length}#{CRLF}")
      index = 0
      while index < length
        argument = command[index]
        if @default_arguments && argument.is_a?(String)
          value = argument
        elsif @expand_arrays && argument.is_a?(Array)
          return encode_expanded(command)
        else
          value = encode_argument(argument)
        end
        bytesize = value.bytesize
        buffer << (BULK_HEADERS[bytesize] || "$#{bytesize}#{CRLF}") << value << CRLF
        index += 1
      end
      buffer
    end

    private

    def encode_expanded(command)
      length = command.sum { |argument| argument.is_a?(Array) ? argument.length : 1 }
      raise ArgumentError, EMPTY_COMMAND if length.zero?

      command.each_with_object(+"*#{length}#{CRLF}") do |argument, buffer|
        if argument.is_a?(Array)
          argument.each { |value| append_argument(buffer, value) }
        else
          append_argument(buffer, argument)
        end
      end
    end

    def append_argument(buffer, argument)
      value = encode_argument(argument)
      bytesize = value.bytesize
      buffer << (BULK_HEADERS[bytesize] || "$#{bytesize}#{CRLF}") << value << CRLF
    end

    def encode_argument(argument)
      if @default_arguments
        return argument if argument.is_a?(String)
        if argument.is_a?(Integer) && argument >= 0 && argument < 1_024
          return INTEGER_STRINGS[argument]
        end
      end

      value = @argument_encoder.call(argument)
      unless value.is_a?(String)
        raise TypeError, "argument encoder must return a String, got #{value.class}"
      end

      value
    end
  end

  DEFAULT_ENCODER = Encoder.new
  Ractor.make_shareable(DEFAULT_ENCODER) if defined?(Ractor)
end
