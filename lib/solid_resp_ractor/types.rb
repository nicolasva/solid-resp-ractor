# frozen_string_literal: true

module SolidRespRactor
  module Types
    class Collection
      attr_reader :value

      def initialize(value)
        @value = value
        freeze
      end

      def ==(other)
        other.instance_of?(self.class) && other.value == value
      end
    end

    class Set < Collection; end
    class Push < Collection; end

    class Verbatim
      attr_reader :format, :data

      def initialize(format, data)
        @format = format.freeze
        @data = data
        freeze
      end

      def ==(other)
        other.instance_of?(self.class) && other.format == format && other.data == data
      end
    end

    class Attribute
      attr_reader :attributes, :value

      def initialize(attributes, value)
        @attributes = attributes
        @value = value
        freeze
      end

      def ==(other)
        other.instance_of?(self.class) &&
          other.attributes == attributes &&
          other.value == value
      end
    end
  end

  module Handlers
    module Compatible
      module_function

      def call(type, value)
        case type
        when :verbatim then value.fetch(1)
        when :attribute then value.fetch(1)
        else value
        end
      end
    end

    module Typed
      module_function

      def call(type, value)
        case type
        when :set then Types::Set.new(value)
        when :push then Types::Push.new(value)
        when :verbatim then Types::Verbatim.new(*value)
        when :attribute then Types::Attribute.new(*value)
        else value
        end
      end
    end
  end
end
