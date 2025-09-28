import 'package:shelf/shelf.dart';

import 'src/sse_handler.dart';

/// Creates a Shelf handler that wires SSE connections into [SseChannel]s.
///
/// Each accepted browser handshake is translated into an instance of
/// `package:sse_channel` for you to read from and write to. The
/// [onConnection] callback receives that channel once the upgrade succeeds.
/// Provide [allowedOrigins] to filter the browser `Origin` header before the
/// request is hijacked.
Handler sseHandler(
  ConnectionCallback onConnection, {
  Iterable<String>? allowedOrigins,
}) {
  return SseHandler(
    onConnection,
    allowedOrigins?.map((origin) => origin.toLowerCase()).toSet(),
  ).handle;
}
