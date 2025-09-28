# shelf_sse

A lightweight helper for wiring [Shelf](https://pub.dev/packages/shelf) routes
to Server-Sent Events (SSE) channels backed by the
[`sse_channel`](https://pub.dev/packages/sse_channel) package. It mirrors the
ergonomics of `shelf_web_socket` so you can treat SSE connections as
`StreamChannel`s.

## Features

- Accepts browser SSE upgrades and exposes them as `SseChannel`s
- Optional origin filtering before hijacking the connection
- Bridges POST payloads from the client back into the server stream for
  bi-directional messaging
- Includes a runnable demo and unit tests

## Getting started

Add the dependency to your `pubspec.yaml`:

```yaml
dependencies:
  shelf_sse: ^0.0.1
```

Then create a handler and plug it into your Shelf pipeline:

```dart
import 'package:shelf/shelf.dart';
import 'package:shelf_sse/shelf_sse.dart';

void main() {
  final handler = Cascade()
      .add(
        sseHandler(
          (channel, _) {
            channel.stream.listen((event) {
              // Handle data sent by the browser.
            });
            channel.sink.add('hello from the server!');
          },
          allowedOrigins: const ['https://example.com'],
        ),
      )
      .add((_) => Response.notFound('Try connecting with SSE.'))
      .handler;

  // Expose `handler` with your preferred Shelf adapter.
}
```

For a runnable demo that spins up both a server and client, see
`example/shelf_sse_example.dart`.

## Testing

Run the analyzer and tests to keep things healthy:

```bash
dart analyze
dart test
```

## License

This project is distributed under the MIT License. See [LICENSE](LICENSE) for
details.
