import 'dart:async';

import 'package:shelf/shelf.dart';
import 'package:shelf/shelf_io.dart' as shelf_io;
import 'package:shelf_sse/shelf_sse.dart';
import 'package:sse_channel/sse_channel.dart';

// Demonstrates wiring shelf_sse into a Shelf server and chatting with a
// client created via sse_channel.
Future<void> main() async {
  final activeChannels = <SseChannel>{};
  final firstConnection = Completer<void>();

  final handler = Cascade()
      .add(
        sseHandler((channel, _) {
          activeChannels.add(channel);
          print(
            'server: client connected (${activeChannels.length} connected)',
          );

          channel.stream.listen(
            (event) {
              print('server: received from client -> ${event.data}');
            },
            onDone: () {
              print('server: client disconnected');
              activeChannels.remove(channel);
            },
            onError: (Object error, StackTrace stackTrace) {
              print('server: stream error $error');
              activeChannels.remove(channel);
            },
          );

          channel.sink.add('server: welcome!');
          firstConnection.complete();
        }),
      )
      .add((_) => Response.ok('SSE server running. Connect at /sse'))
      .handler;

  final server = await shelf_io.serve(handler, 'localhost', 8080);
  print('server: listening on http://localhost:${server.port}');

  final client = SseChannel.connect(
    Uri.parse('http://localhost:${server.port}/sse'),
  );

  client.stream.listen(
    (event) => print('client: received -> ${event.data}'),
    onDone: () => print('client: connection closed'),
    onError: (Object error, StackTrace stackTrace) {
      print('client: error $error');
    },
  );

  await firstConnection.future;

  for (var tick = 1; tick <= 3; tick++) {
    await Future<void>.delayed(const Duration(seconds: 1));
    for (final channel in activeChannels) {
      channel.sink.add('server: tick $tick');
    }
  }

  client.sink.add('client: thanks for the messages!');
  await Future<void>.delayed(const Duration(milliseconds: 500));

  await client.sink.close();
  await Future<void>.delayed(const Duration(milliseconds: 500));

  await server.close();
  print('server: shutdown complete');
}
