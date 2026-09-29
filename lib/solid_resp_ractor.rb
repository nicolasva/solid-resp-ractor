# frozen_string_literal: true

require_relative "solid_resp_ractor/version"
require_relative "solid_resp_ractor/errors"
require_relative "solid_resp_ractor/types"
require_relative "solid_resp_ractor/limits"
require_relative "solid_resp_ractor/encoder"
require_relative "solid_resp_ractor/source"
require_relative "solid_resp_ractor/reader"
require_relative "solid_resp_ractor/codec"

module SolidRespRactor
  module_function

  def encode(command, encoder: DEFAULT_ENCODER)
    encoder.encode(command)
  end

  def reader(io = nil, source: nil, read_timeout: nil, codec: DEFAULT_CODEC)
    codec.reader(io, source: source, read_timeout: read_timeout)
  end
end
