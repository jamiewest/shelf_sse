import 'dart:async';
import 'dart:convert';

import 'package:shelf/shelf.dart';
import 'package:shelf_sse/shelf_sse.dart';
import 'package:sse_channel/sse_channel.dart';
import 'package:stream_channel/stream_channel.dart';
import 'package:test/test.dart';

void main() {
  group('SseHandler', () {
    test('delivers server messages to the SSE client', () async {
      final connectionReady = Completer<SseChannel>();
      final outbound = StreamChannelController<List<int>>();
      final buffer = StringBuffer();
      final subscription = outbound.foreign.stream.listen(
        (chunk) => buffer.write(utf8.decode(chunk)),
      );

      final handler = sseHandler((channel, _) {
        // Keep the input stream subscribed so messages from the client are read.
        channel.stream.listen((_) {});
        connectionReady.complete(channel);
      });

      final request = Request(
        'GET',
        Uri.parse('http://localhost/sse?sseClientId=test-client'),
        headers: const {'accept': 'text/event-stream'},
        onHijack: (callback) {
          callback(outbound.local);
        },
      );

      await _invokeHandler(handler, request);

      final serverChannel = await connectionReady.future.timeout(
        const Duration(seconds: 1),
      );
      serverChannel.sink.add('hello client');

      await Future<void>.delayed(const Duration(milliseconds: 20));

      expect(buffer.toString(), contains('data: "hello client"'));

      await serverChannel.sink.close();
      await subscription.cancel();
      await outbound.local.sink.close();
      await outbound.foreign.sink.close();
    });

    test('rejects POST requests without a client identifier', () async {
      final handler = sseHandler((_, __) {});

      final response = await _invokeHandler(
        handler,
        Request(
          'POST',
          Uri.parse('http://localhost/sse'),
          headers: const {'content-type': 'application/json'},
          body: jsonEncode('ping'),
        ),
      );

      expect(response?.statusCode, 400);
    });

    test('rejects connections from disallowed origins', () async {
      final handler = sseHandler(
        (_, __) {},
        allowedOrigins: const ['https://allowed.example'],
      );

      var hijackCalled = false;
      final response = await _invokeHandler(
        handler,
        Request(
          'GET',
          Uri.parse('http://localhost/sse?sseClientId=test-client'),
          headers: const {
            'accept': 'text/event-stream',
            'origin': 'https://not-allowed.example',
          },
          onHijack: (_) {
            hijackCalled = true;
          },
        ),
      );

      expect(response?.statusCode, 403);
      expect(hijackCalled, isFalse);
    });
  });
}

/// Helper that tolerates hijacked responses while awaiting a [Handler] result.
Future<Response?> _invokeHandler(Handler handler, Request request) async {
  try {
    final result = handler(request);
    return result is Future<Response?> ? await result : result;
  } on HijackException {
    return null;
  }
}
