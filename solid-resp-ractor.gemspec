# frozen_string_literal: true

require_relative "lib/solid_resp_ractor/version"

Gem::Specification.new do |spec|
  spec.name = "solid-resp-ractor"
  spec.version = SolidRespRactor::VERSION
  spec.authors = ["Nicolas Vandenbogaerde"]

  spec.summary = "A modular, Ractor-friendly RESP2/RESP3 codec"
  spec.description = "Dependency-free RESP command encoding and stream decoding with injectable sources, selectors, clocks, error mappers, and RESP3 type handlers."
  spec.homepage = "https://github.com/nicolasva/solid-resp-ractor"
  spec.license = "LGPL-3.0-or-later"
  spec.required_ruby_version = ">= 3.1"

  spec.files = Dir["lib/**/*.rb", "README.md", "CHANGELOG.md", "LICENSE.txt"]
  spec.require_paths = ["lib"]

  spec.metadata["rubygems_mfa_required"] = "true"
  spec.metadata["source_code_uri"] = spec.homepage
  spec.metadata["changelog_uri"] = "#{spec.homepage}/blob/main/CHANGELOG.md"

  spec.add_development_dependency "minitest", ">= 5", "< 7"
  spec.add_development_dependency "rake", "~> 13.0"
end
