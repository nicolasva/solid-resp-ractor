# Changelog

All notable changes to this project are documented in this file.

## [Unreleased]

## [0.1.6] - 2026-10-05

### Changed

- Relicense the project from MIT to LGPL-3.0-or-later.

## [0.1.5] - 2026-10-04

### Changed

- Parse RESP integers and lengths in place from the read buffer, without
  allocating a temporary line String. Non-decimal forms still fall back to
  `Kernel#Integer` semantics.
- Read nested values through an internal depth-tracked path instead of the
  public `#read`, removing per-element `ensure` bookkeeping and subclass
  wrappers from aggregate parsing.
- Skip handler dispatch for scalars and plain aggregates when the built-in
  `Compatible` or `Typed` handlers are used.
- Clear the consumed read buffer once per reply instead of after every token.
- Encode flat commands in a single loop with inline String and small Integer
  fast paths for the default argument encoder.
- Cache non-blocking IO capabilities and take only one clock reading per
  readiness wait.
- Ruby 4.0.1 microbenchmarks: flat command encoding +72% to +85%, bulk reply
  parsing +51%, 10-element arrays +68% with 33 → 11 allocations, and
  50-reply pipelines +46% with 125 → 75 allocations.

### Fixed

- Locate CRLF terminators by byte offset (`String#byteindex`, Ruby 3.2+) so
  custom sources returning multibyte UTF-8 chunks are parsed correctly.

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
