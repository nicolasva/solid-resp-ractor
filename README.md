# Solid RESP Ractor

`solid-resp-ractor` is a dependency-free RESP2/RESP3 codec for Ruby. It keeps
protocol parsing independent from Redis client behavior and provides explicit
extension points for transports, event loops, error hierarchies, value
representation, and command argument conversion.

The gem has no global mutable state. Immutable encoder instances can be shared
between Ractors; readers remain local to the Ractor that owns their IO.

## Installation

Add to your Gemfile:

```ruby
gem "solid-resp-ractor"
```

Then run:

```sh
bundle install
```

## Encoding commands

```ruby
require "solid_resp_ractor"

SolidRespRactor.encode(["SET", "key", "value"])
# => "*3\r\n$3\r\nSET\r\n$3\r\nkey\r\n$5\r\nvalue\r\n"
```

Arrays are expanded by one level, which supports APIs that group command
arguments:

```ruby
SolidRespRactor.encode(["MSET", ["first", 1], ["second", 2]])
```

Use an immutable custom encoder for domain-specific values:

```ruby
argument_encoder = Object.new

def argument_encoder.call(value)
  value.respond_to?(:to_wire) ? value.to_wire : value.to_s
end

argument_encoder.freeze

encoder = SolidRespRactor::Encoder.new(argument_encoder: argument_encoder)
encoder.encode(["SET", "key", custom_value])
```

Set `expand_arrays: false` when arrays represent individual values rather than
argument groups.

## Reusable codec configurations

`Codec` groups all extension points into one immutable object:

```ruby
codec = SolidRespRactor::Codec.new(
  encoder: custom_encoder,
  handler: SolidRespRactor::Handlers::Typed,
  error_mapper: error_mapper,
  limits: SolidRespRactor::Limits.new(max_blob_size: 64 * 1024 * 1024),
  chunk_size: 32_768,
)

payload = codec.encode(["PING"])
reader = codec.reader(socket, read_timeout: 1.0)
```

`SolidRespRactor::DEFAULT_CODEC` is Ractor-shareable. A custom codec is also
shareable when all injected collaborators are shareable.

Decoded responses are not automatically Ractor-shareable. Typed wrappers are
frozen, but mutable strings, arrays, hashes, and nested values they contain are
not deeply frozen. Transform a response explicitly with
`Ractor.make_shareable` (copying it first when mutation must remain possible)
before sending it to another Ractor.

## Reading RESP streams

The default reader accepts blocking IO objects such as `StringIO`, as well as
non-blocking TCP, Unix, and TLS-compatible streams:

```ruby
socket = TCPSocket.new("127.0.0.1", 6379)
reader = SolidRespRactor.reader(socket, read_timeout: 1.0)

socket.write(SolidRespRactor.encode(["PING"]))
reader.read
# => "PONG"
```

Use `exception: false` for pipelines or proxies that need error values:

```ruby
result = reader.read(exception: false)

if result.is_a?(SolidRespRactor::ResponseError)
  warn result.message
end
```

Nested errors are raised only after the complete aggregate has been consumed,
so the next frame remains synchronized.

## RESP3 types

The compatible handler returns ordinary Ruby values and intentionally unwraps
RESP3 sets, pushes, verbatim strings, and attributes:

```ruby
reader = SolidRespRactor::Reader.new(io)
```

Use the typed handler when those distinctions matter:

```ruby
reader = SolidRespRactor::Reader.new(
  io,
  handler: SolidRespRactor::Handlers::Typed,
)

case (value = reader.read)
when SolidRespRactor::Types::Push
  process_push(value.value)
when SolidRespRactor::Types::Attribute
  process(value.value, metadata: value.attributes)
end
```

Typed values include:

- `SolidRespRactor::Types::Set`
- `SolidRespRactor::Types::Push`
- `SolidRespRactor::Types::Verbatim`
- `SolidRespRactor::Types::Attribute`

RESP3 streamed blob strings, arrays, maps, and sets are supported as well as
special double values (`inf`, `-inf`, and `nan`).

## Resource limits

The default immutable limits protect generic protocol consumers from
unbounded allocations and nesting:

| Limit | Default |
|---|---:|
| Blob or chunked string | 512 MiB |
| Collection cardinality | 1,000,000 |
| Nesting depth | 128 |
| Line length | 64 KiB |

Provide stricter limits for untrusted peers:

```ruby
limits = SolidRespRactor::Limits.new(
  max_blob_size: 8 * 1024 * 1024,
  max_collection_size: 10_000,
  max_nesting_depth: 32,
  max_line_size: 8 * 1024,
)

codec = SolidRespRactor::Codec.new(limits: limits)
```

## Extension points

### Custom error mapping

Map RESP error frames into an application's existing exception hierarchy:

```ruby
error_mapper = lambda do |message, blob:|
  MyProtocolError.new(message)
end

reader = SolidRespRactor::Reader.new(io, error_mapper: error_mapper)
```

The mapper must return an `Exception`.

### Custom value handling

Every decoded value can be transformed:

```ruby
handler = lambda do |type, value|
  Event.new(type:, value:)
end

reader = SolidRespRactor::Reader.new(io, handler: handler)
```

### Custom byte sources

A source only needs:

```ruby
class Source
  def read(timeout:)
    # Return a non-empty String, or nil at EOF.
  end

  def wait_readable(timeout)
    # Optional polling API.
  end
end

reader = SolidRespRactor::Reader.new(source: Source.new)
```

This allows integration with event loops, in-memory transports, framed
protocols, instrumentation, or test fixtures without changing the parser.

The built-in `Sources::IO` also accepts custom `selector` and `clock` objects.

## Timeouts and blocking commands

`read_timeout: nil` waits indefinitely. Temporarily override a timeout without
rebuilding the reader:

```ruby
reader.with_timeout(nil) do
  reader.read
end
```

`wait_readable(timeout)` polls without consuming bytes, which is useful for
subscriptions and event-driven clients.

## Ractor usage

The default encoder is shareable:

```ruby
encoder = SolidRespRactor::DEFAULT_ENCODER

ractor = Ractor.new(encoder) do |shared_encoder|
  socket = TCPSocket.new("127.0.0.1", 6379)
  reader = SolidRespRactor::Reader.new(socket, read_timeout: 1.0)

  socket.write(shared_encoder.encode(["PING"]))
  reader.read
ensure
  socket&.close
end

ractor.take
```

Create sockets and readers inside their owning Ractor. Custom handlers,
encoders, selectors, and clocks must themselves be Ractor-shareable if they
are passed between Ractors. Responses remain local to the reader's Ractor
unless the application explicitly transforms them into shareable values.

## Buffer management

The reader advances a virtual cursor through buffered bytes. It clears a fully
consumed buffer immediately and compacts a partially consumed buffer only
after at least 16 KiB have been consumed and that prefix occupies at least half
of the buffer. This avoids copying a large unread suffix after small fragmented
reads while still releasing consumed data during long-lived streams.

## Development

```sh
bundle install
bundle exec rake
```

The default task runs the tests and builds the gem.
