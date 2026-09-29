# frozen_string_literal: true

module SolidRespRactor
  class Error < StandardError; end
  class ConnectionError < Error; end
  class TimeoutError < ConnectionError; end
  class ProtocolError < Error; end
  class ResponseError < Error; end
  class AuthenticationError < ResponseError; end

  module ErrorMappers
    module Default
      module_function

      def call(message, blob:)
        error_class = if message.start_with?("NOAUTH", "WRONGPASS")
          AuthenticationError
        else
          ResponseError
        end
        error_class.new(message)
      end
    end
  end
end
