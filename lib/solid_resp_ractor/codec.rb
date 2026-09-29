# frozen_string_literal: true

module SolidRespRactor
  class Codec
    attr_reader :encoder, :handler, :error_mapper, :limits, :chunk_size,
      :selector, :clock

    def initialize(
      encoder: DEFAULT_ENCODER,
      handler: Handlers::Compatible,
      error_mapper: ErrorMappers::Default,
      limits: Limits::DEFAULT,
      chunk_size: 16_384,
      selector: Selectors::IOSelect,
      clock: Clocks::Monotonic
    )
      @encoder = encoder
      @handler = handler
      @error_mapper = error_mapper
      @limits = limits
      @chunk_size = Integer(chunk_size)
      raise ArgumentError, "chunk_size must be positive" unless @chunk_size.positive?

      @selector = selector
      @clock = clock
      freeze
    end

    def encode(command)
      @encoder.encode(command)
    end

    def reader(io = nil, source: nil, read_timeout: nil)
      Reader.new(
        io,
        source: source,
        read_timeout: read_timeout,
        handler: @handler,
        error_mapper: @error_mapper,
        limits: @limits,
        chunk_size: @chunk_size,
        selector: @selector,
        clock: @clock,
      )
    end
  end

  DEFAULT_CODEC = Codec.new
  Ractor.make_shareable(DEFAULT_CODEC) if defined?(Ractor)
end
