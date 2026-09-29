# frozen_string_literal: true

module SolidRespRactor
  class Reader
    CRLF = "\r\n"
    COMPACT_THRESHOLD = 16 * 1024

    attr_reader :source

    def initialize(
      io = nil,
      source: nil,
      read_timeout: nil,
      handler: Handlers::Compatible,
      error_mapper: ErrorMappers::Default,
      limits: Limits::DEFAULT,
      chunk_size: 16_384,
      selector: Selectors::IOSelect,
      clock: Clocks::Monotonic
    )
      if io && source
        raise ArgumentError, "pass either io or source, not both"
      end
      raise ArgumentError, "io or source is required" unless io || source

      @source = source || Sources::IO.new(
        io,
        chunk_size: chunk_size,
        selector: selector,
        clock: clock,
      )
      @read_timeout = read_timeout
      @handler = handler
      @error_mapper = error_mapper
      @limits = limits
      @buffer = +""
      @offset = 0
      @read_depth = 0
      @captured_error = nil
    end

    def with_timeout(timeout)
      previous = @read_timeout
      @read_timeout = timeout
      yield
    ensure
      @read_timeout = previous
    end

    def wait_readable(timeout)
      return true if available_bytes.positive?
      return true unless @source.respond_to?(:wait_readable)

      @source.wait_readable(timeout)
    end

    def read(exception: true)
      top_level = @read_depth.zero?
      @captured_error = nil if top_level
      @read_depth += 1
      if @read_depth > @limits.max_nesting_depth
        raise ProtocolError, "RESP nesting exceeds #{@limits.max_nesting_depth}"
      end
      value = read_type(read_bytes(1))
      raise @captured_error if top_level && exception && @captured_error

      value
    rescue EOFError
      raise ConnectionError, "RESP stream closed"
    ensure
      @read_depth -= 1
    end

    private

    def read_type(type)
      case type
      when "+" then handle(:simple_string, read_line)
      when "-" then error_response(read_line, blob: false)
      when ":" then handle(:integer, parse_integer(read_line))
      when "$" then read_blob
      when "*" then read_array
      when "_" then read_null
      when "#" then read_boolean
      when "," then handle(:double, parse_float(read_line))
      when "(" then handle(:big_number, parse_integer(read_line))
      when "%" then read_map
      when "~" then read_collection(:set)
      when ">" then read_collection(:push)
      when "=" then read_verbatim
      when "!" then error_response(read_sized_string(streamed: true), blob: true)
      when "|" then read_attribute
      else raise ProtocolError, "Unknown RESP type byte: #{type.inspect}"
      end
    end

    def read_blob
      length = read_length(nullable: true, streamed: true)
      return handle(:blob_string, nil) unless length

      validate_blob_length(length) unless length == :streamed
      value = length == :streamed ? read_chunked_string : read_sized_value(length)
      handle(:blob_string, value)
    end

    def read_array
      length = read_length(nullable: true, streamed: true)
      return handle(:array, nil) unless length

      validate_collection_length(length) unless length == :streamed
      value = if length == :streamed
        read_streamed_collection
      else
        Array.new(length) { read(exception: false) }
      end
      handle(:array, value)
    end

    def read_collection(type)
      length = read_length(streamed: true)
      validate_collection_length(length) unless length == :streamed
      value = if length == :streamed
        read_streamed_collection
      else
        Array.new(length) { read(exception: false) }
      end
      handle(type, value)
    end

    def read_map
      length = read_length(streamed: true)
      validate_collection_length(length) unless length == :streamed
      value = if length == :streamed
        read_streamed_map
      else
        {}.tap do |result|
          length.times { result[read(exception: false)] = read(exception: false) }
        end
      end
      handle(:map, value)
    end

    def read_streamed_collection
      values = []
      loop do
        type = read_bytes(1)
        break if aggregate_end?(type)

        values << read_type(type)
        validate_collection_length(values.length)
      end
      values
    end

    def read_streamed_map
      {}.tap do |result|
        count = 0
        loop do
          type = read_bytes(1)
          break if aggregate_end?(type)

          key = read_type(type)
          result[key] = read(exception: false)
          count += 1
          validate_collection_length(count)
        end
      end
    end

    def aggregate_end?(type)
      return false unless type == "."

      value = read_line
      raise ProtocolError, "RESP aggregate terminator must not contain data" unless value.empty?

      true
    end

    def read_attribute
      attributes = read_map
      value = read(exception: false)
      handle(:attribute, [attributes, value])
    end

    def read_null
      value = read_line
      raise ProtocolError, "RESP null must not contain data" unless value.empty?

      handle(:null, nil)
    end

    def read_boolean
      case (value = read_line)
      when "t" then handle(:boolean, true)
      when "f" then handle(:boolean, false)
      else raise ProtocolError, "Invalid RESP boolean: #{value.inspect}"
      end
    end

    def read_verbatim
      value = read_sized_string(streamed: true)
      unless value.bytesize >= 4 && value.byteslice(3, 1) == ":"
        raise ProtocolError, "Invalid RESP verbatim string"
      end

      handle(:verbatim, [value.byteslice(0, 3).freeze, value.byteslice(4..)])
    end

    def read_sized_string(streamed: false)
      length = read_length(streamed: streamed)
      validate_blob_length(length) unless length == :streamed
      length == :streamed ? read_chunked_string : read_sized_value(length)
    end

    def read_chunked_string
      buffer = +""
      loop do
        type = read_bytes(1)
        raise ProtocolError, "Expected RESP chunk, got #{type.inspect}" unless type == ";"

        length = read_length
        break if length.zero?

        validate_blob_length(buffer.bytesize + length)
        buffer << read_sized_value(length)
      end
      buffer
    end

    def read_sized_value(length)
      value = read_bytes(length)
      actual = read_bytes(2)
      raise ProtocolError, "Expected CRLF, got #{actual.inspect}" unless actual == CRLF

      value
    end

    def read_length(nullable: false, streamed: false)
      value = read_line
      return :streamed if streamed && value == "?"

      length = parse_integer(value)
      return if nullable && length == -1
      raise ProtocolError, "Invalid RESP length: #{length}" if length.negative?

      length
    end

    def parse_integer(value)
      Integer(value)
    rescue ArgumentError
      raise ProtocolError, "Invalid RESP integer: #{value.inspect}"
    end

    def parse_float(value)
      return Float::INFINITY if value == "inf"
      return -Float::INFINITY if value == "-inf"
      return Float::NAN if value == "nan"

      Float(value)
    rescue ArgumentError
      raise ProtocolError, "Invalid RESP double: #{value.inspect}"
    end

    def read_line
      loop do
        if (index = @buffer.index(CRLF, @offset))
          line_length = index - @offset
          if line_length > @limits.max_line_size
            raise ProtocolError, "RESP line exceeds #{@limits.max_line_size} bytes"
          end
          value = @buffer.byteslice(@offset, line_length)
          @offset = index + 2
          clear_consumed_buffer
          return value
        end
        if available_bytes > @limits.max_line_size
          raise ProtocolError, "RESP line exceeds #{@limits.max_line_size} bytes"
        end
        fill_buffer
      end
    end

    def read_bytes(length)
      fill_buffer while available_bytes < length
      value = @buffer.byteslice(@offset, length)
      @offset += length
      clear_consumed_buffer
      value
    end

    def fill_buffer
      compact_buffer
      chunk = @source.read(timeout: @read_timeout)
      raise EOFError if chunk.nil?
      unless chunk.is_a?(String)
        raise ProtocolError, "RESP source must return a String or nil, got #{chunk.class}"
      end
      raise ProtocolError, "RESP source returned an empty chunk" if chunk.empty?

      @buffer << chunk
    end

    def available_bytes
      @buffer.bytesize - @offset
    end

    def clear_consumed_buffer
      return unless @offset == @buffer.bytesize

      @buffer.clear
      @offset = 0
    end

    def compact_buffer
      return if @offset < COMPACT_THRESHOLD
      return if @offset < @buffer.bytesize / 2

      @buffer = @buffer.byteslice(@offset..) || +""
      @offset = 0
    end

    def error_response(message, blob:)
      error = @error_mapper.call(message, blob: blob)
      unless error.is_a?(Exception)
        raise TypeError, "error mapper must return an Exception, got #{error.class}"
      end
      @captured_error ||= error
      error
    end

    def validate_blob_length(length)
      return if length <= @limits.max_blob_size

      raise ProtocolError, "RESP blob exceeds #{@limits.max_blob_size} bytes"
    end

    def validate_collection_length(length)
      return if length <= @limits.max_collection_size

      raise ProtocolError,
        "RESP collection exceeds #{@limits.max_collection_size} elements"
    end

    def handle(type, value)
      @handler.call(type, value)
    end
  end
end
