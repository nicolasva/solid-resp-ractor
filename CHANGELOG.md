# Changelog

All notable changes to this project are documented in this file.

## [0.1.4] - 2026-10-01

### Changed

- Reuse a destination String for non-blocking IO reads instead of allocating a
  chunk-sized String for every socket response.
- Reduce loopback GET allocation from 16,609.8 to 120.8 bytes per operation
  and from 6.0 to 4.0 objects per operation in the Ruby 4.0.1 benchmark.
- Improve loopback GET throughput by 8.18% at eight Ractors while preserving
  Reader parser-buffer invariants.

## [0.1.3] - 2026-09-30

### Changed

- Use direct socket readiness waits by default while preserving custom selector
  compatibility.
- Cache common RESP array and bulk headers and add a fast path for flat Redis
  commands.
- Parse RESP type bytes and CRLF terminators without temporary strings.
- Reduce a representative flat-command encoding benchmark from seven to three
  allocations per operation while increasing throughput by approximately 40%.

## [0.1.2] - 2026-09-29

### Added

- Add CI, RubyGems version, download count, and RubyDoc badges to the README.

## [0.1.1] - 2026-09-29

### Changed

- Compact partially consumed buffers only after 16 KiB and when the consumed
  prefix occupies at least half of the buffer.
- Clarify that decoded response contents are not automatically deeply frozen
  or Ractor-shareable.

### Added

- Adversarial coverage for every frame split and EOF position, truncated
  streamed values, resource limits, excessive nesting, and deterministic
  generated RESP values under random fragmentation.

## [0.1.0] - 2026-09-29

### Added

- Dependency-free RESP2/RESP3 stream reader.
- Immutable command encoder with injectable argument conversion.
- Injectable byte sources, selectors, clocks, error mappers, and value
  handlers.
- Compatible and typed RESP3 handling modes.
- Configurable limits for blob size, collection cardinality, nesting depth,
  and line length.
- Bounded stress coverage for large pipelines, fragmented streams, malformed
  input, and parallel Ractors.
- Ractor-shareable default encoder with no global mutable state.

[0.1.4]: https://github.com/nicolasva/solid-resp-ractor/compare/v0.1.3...v0.1.4
[0.1.3]: https://github.com/nicolasva/solid-resp-ractor/compare/v0.1.2...v0.1.3
[0.1.2]: https://github.com/nicolasva/solid-resp-ractor/compare/v0.1.1...v0.1.2
[0.1.1]: https://github.com/nicolasva/solid-resp-ractor/compare/v0.1.0...v0.1.1
[0.1.0]: https://github.com/nicolasva/solid-resp-ractor/releases/tag/v0.1.0
