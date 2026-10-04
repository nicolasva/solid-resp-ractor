# frozen_string_literal: true

module SolidRespRactor
  class Reader
    CRLF = "\r\n"
    COMPACT_THRESHOLD = 16 * 1024
    PASSTHROUGH_HANDLERS = Ractor.make_shareable([Handlers::Compatible, Handlers::Typed])

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
      # Built-in handlers return scalars and plain aggregates unchanged, so
      # the hot path can skip the dispatch for those types.
      @passthrough = PASSTHROUGH_HANDLERS.include?(handler)
      @error_mapper = error_mapper
      @limits = limits
      @max_line_size = limits.max_line_size
      @max_nesting_depth = limits.max_nesting_depth
      @buffer = +""
      @offset = 0
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
      @captured_error = nil
      value = read_value(1)
      clear_consumed_buffer
      raise @captured_error if exception && @captured_error

      value
    rescue EOFError
      raise ConnectionError, "RESP stream closed"
    end

    private

    def read_value(depth)
      if depth > @max_nesting_depth
        raise ProtocolError, "RESP nesting exceeds #{@max_nesting_depth}"
      end

      fill_buffer if @offset >= @buffer.bytesize
      type = @buffer.getbyte(@offset)
      @offset += 1
      read_type(type, depth)
    end

    def read_type(type, depth)
      case type
      when 36 then read_blob
      when 43
        value = read_line
        @passthrough ? value : handle(:simple_string, value)
      when 58
        value = read_integer
        @passthrough ? value : handle(:integer, value)
      when 42 then read_array(depth)
      when 45 then error_response(read_line, blob: false)
      when 95 then read_null
      when 35 then read_boolean
      when 44 then handle(:double, parse_float(read_line))
      when 40 then handle(:big_number, read_integer)
      when 37 then read_map(depth)
      when 126 then read_collection(:set, depth)
      when 62 then read_collection(:push, depth)
      when 61 then read_verbatim
      when 33 then error_response(read_sized_string(true), blob: true)
      when 124 then read_attribute(depth)
      else raise ProtocolError, "Unknown RESP type byte: #{type.chr.inspect}"
      end
    end

    def read_blob
      length = read_length(true, true)
      if length.nil?
        value = nil
      elsif length == :streamed
        value = read_chunked_string
      else
        validate_blob_length(length)
        value = read_sized_value(length)
      end
      @passthrough ? value : handle(:blob_string, value)
    end

    def read_array(depth)
      length = read_length(true, true)
      if length.nil?
        value = nil
      elsif length == :streamed
        value = read_streamed_collection(depth)
      else
        validate_collection_length(length)
        value = read_elements(length, depth + 1)
      end
      @passthrough ? value : handle(:array, value)
    end

    def read_elements(length, depth)
      values = Array.new(length)
      index = 0
      while index < length
        values[index] = read_value(depth)
        index += 1
      end
      values
    end

    def read_collection(type, depth)
      length = read_length(false, true)
      value = if length == :streamed
        read_streamed_collection(depth)
      else
        validate_collection_length(length)
        read_elements(length, depth + 1)
      end
      handle(type, value)
    end

    def read_map(depth)
      length = read_length(false, true)
      value = if length == :streamed
        read_streamed_map(depth)
      else
        validate_collection_length(length)
        result = {}
        length.times { result[read_value(depth + 1)] = read_value(depth + 1) }
        result
      end
      handle(:map, value)
    end

    def read_streamed_collection(depth)
      values = []
      loop do
        type = read_byte
        break if aggregate_end?(type)

        values << read_type(type, depth)
        validate_collection_length(values.length)
      end
      values
    end

    def read_streamed_map(depth)
      result = {}
      count = 0
      loop do
        type = read_byte
        break if aggregate_end?(type)

        key = read_type(type, depth)
        result[key] = read_value(depth + 1)
        count += 1
        validate_collection_length(count)
      end
      result
    end

    def aggregate_end?(type)
      return false unless type == 46

      value = read_line
      raise ProtocolError, "RESP aggregate terminator must not contain data" unless value.empty?

      true
    end

    def read_attribute(depth)
      attributes = read_map(depth)
      value = read_value(depth + 1)
      handle(:attribute, [attributes, value])
    end

    def read_null
      value = read_line
      raise ProtocolError, "RESP null must not contain data" unless value.empty?

      @passthrough ? nil : handle(:null, nil)
    end

    def read_boolean
      case (value = read_line)
      when "t" then handle(:boolean, true)
      when "f" then handle(:boolean, false)
      else raise ProtocolError, "Invalid RESP boolean: #{value.inspect}"
      end
    end

    def read_verbatim
      value = read_sized_string(true)
      unless value.bytesize >= 4 && value.byteslice(3, 1) == ":"
        raise ProtocolError, "Invalid RESP verbatim string"
      end

      handle(:verbatim, [value.byteslice(0, 3).freeze, value.byteslice(4..)])
    end

    def read_sized_string(streamed = false)
      length = read_length(false, streamed)
      return read_chunked_string if length == :streamed

      validate_blob_length(length)
      read_sized_value(length)
    end

    def read_chunked_string
      buffer = +""
      loop do
        type = read_byte
        unless type == 59
          raise ProtocolError, "Expected RESP chunk, got #{type.chr.inspect}"
        end

        length = read_length
        break if length.zero?

        validate_blob_length(buffer.bytesize + length)
        buffer << read_sized_value(length)
      end
      buffer
    end

    def read_sized_value(length)
      offset = @offset
      buffer = @buffer
      if buffer.bytesize - offset >= length + 2 &&
          buffer.getbyte(offset + length) == 13 &&
          buffer.getbyte(offset + length + 1) == 10
        @offset = offset + length + 2
        return buffer.byteslice(offset, length)
      end

      value = read_bytes(length)
      read_crlf
      value
    end

    def read_length(nullable = false, streamed = false)
      length = scan_integer
      unless length
        value = read_line
        return :streamed if streamed && value == "?"

        length = parse_integer(value)
      end
      return if nullable && length == -1
      raise ProtocolError, "Invalid RESP length: #{length}" if length.negative?

      length
    end

    def read_integer
      scan_integer || parse_integer(read_line)
    end

    # Parses a plain decimal line in place, without allocating the line.
    # Returns nil whenever the line is incomplete or not a plain decimal so
    # the caller falls back to the exact Kernel#Integer semantics.
    def scan_integer
      buffer = @buffer
      offset = @offset
      index = find_crlf(buffer, offset)
      return unless index && index - offset <= @max_line_size

      position = offset
      negative = buffer.getbyte(position) == 45
      position += 1 if negative
      return if position >= index
      return if buffer.getbyte(position) == 48 && position + 1 < index

      value = 0
      while position < index
        byte = buffer.getbyte(position)
        return unless byte >= 48 && byte <= 57

        value = (value * 10) + (byte - 48)
        position += 1
      end
      @offset = index + 2
      negative ? -value : value
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
        offset = @offset
        if (index = find_crlf(@buffer, offset))
          line_length = index - offset
          if line_length > @max_line_size
            raise ProtocolError, "RESP line exceeds #{@max_line_size} bytes"
          end
          @offset = index + 2
          return @buffer.byteslice(offset, line_length)
        end
        if available_bytes > @max_line_size
          raise ProtocolError, "RESP line exceeds #{@max_line_size} bytes"
        end
        fill_buffer
      end
    end

    if "".respond_to?(:byteindex)
      def find_crlf(buffer, offset)
        buffer.byteindex(CRLF, offset)
      end
    else
      def find_crlf(buffer, offset)
        buffer.index(CRLF, offset)
      end
    end

    def read_bytes(length)
      fill_buffer while available_bytes < length
      value = @buffer.byteslice(@offset, length)
      @offset += length
      value
    end

    def read_byte
      fill_buffer if @offset >= @buffer.bytesize
      value = @buffer.getbyte(@offset)
      @offset += 1
      value
    end

    def read_crlf
      fill_buffer while available_bytes < 2
      unless @buffer.getbyte(@offset) == 13 &&
          @buffer.getbyte(@offset + 1) == 10
        actual = @buffer.byteslice(@offset, 2)
        raise ProtocolError, "Expected CRLF, got #{actual.inspect}"
      end

      @offset += 2
    end

    def fill_buffer
      if @offset == @buffer.bytesize
        clear_consumed_buffer
      else
        compact_buffer
      end
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
