# frozen_string_literal: true

module SolidRespRactor
  class Limits
    attr_reader :max_blob_size, :max_collection_size, :max_nesting_depth,
      :max_line_size

    def initialize(
      max_blob_size: 512 * 1024 * 1024,
      max_collection_size: 1_000_000,
      max_nesting_depth: 128,
      max_line_size: 64 * 1024
    )
      @max_blob_size = positive_integer(max_blob_size, :max_blob_size)
      @max_collection_size = positive_integer(max_collection_size, :max_collection_size)
      @max_nesting_depth = positive_integer(max_nesting_depth, :max_nesting_depth)
      @max_line_size = positive_integer(max_line_size, :max_line_size)
      freeze
    end

    private

    def positive_integer(value, name)
      value = Integer(value)
      raise ArgumentError, "#{name} must be positive" unless value.positive?

      value
    end

    DEFAULT = new
    Ractor.make_shareable(DEFAULT) if defined?(Ractor)
  end
end
