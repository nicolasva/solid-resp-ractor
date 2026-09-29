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

    attr_reader :argument_encoder

    def initialize(argument_encoder: ArgumentEncoders::Default, expand_arrays: true)
      @argument_encoder = argument_encoder
      @expand_arrays = expand_arrays
      freeze
    end

    def encode(command)
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

    def expanded?(argument)
      @expand_arrays && argument.is_a?(Array)
    end

    def append_argument(buffer, argument)
      value = @argument_encoder.call(argument)
      unless value.is_a?(String)
        raise TypeError, "argument encoder must return a String, got #{value.class}"
      end

      buffer << "$#{value.bytesize}#{CRLF}#{value}#{CRLF}"
    end
  end

  DEFAULT_ENCODER = Encoder.new
  Ractor.make_shareable(DEFAULT_ENCODER) if defined?(Ractor)
end
