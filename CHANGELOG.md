# Changelog

All notable changes to this project are documented in this file.

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

[0.1.0]: https://github.com/nicolasva/solid-resp-ractor/releases/tag/v0.1.0
