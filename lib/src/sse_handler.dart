import 'dart:async';
import 'dart:convert';

import 'package:shelf/shelf.dart';
import 'package:sse_channel/sse_channel.dart';
import 'package:stream_channel/stream_channel.dart';

/// Used by `SseHandler` to report connections back to callers.
///
/// This takes an [SseChannel] as its first argument and an optional
/// [subprotocol] as its second argument.
typedef ConnectionCallback =
    void Function(SseChannel channel, String? subprotocol);

/// A class that exposes a handler for establishing Server-Sent Events (SSE)
/// connections that behave like [StreamChannel]s.
class SseHandler {
  SseHandler(this._onConnection, this._allowedOrigins);

  final ConnectionCallback _onConnection;
  final Set<String>? _allowedOrigins;

  final _connections = <String, _ServerSseConnection>{};

  /// Handles an incoming request.
  FutureOr<Response> handle(Request request) {
    if (request.method == 'OPTIONS') {
      return _optionsResponse(request);
    }

    final acceptHeader = request.headers['accept'];
    if (request.method == 'GET' &&
        acceptHeader != null &&
        acceptHeader.toLowerCase().contains('text/event-stream')) {
      return _handleUpgrade(request);
    }

    if (request.method == 'POST') {
      return _handleIncomingMessage(request);
    }

    return _notFound();
  }

  Response _handleUpgrade(Request request) {
    if (!request.canHijack) {
      throw StateError(
        'SseHandler may only be used with a server that supports request '
        'hijacking.',
      );
    }

    final origin = request.headers['origin'];
    if (!_originAllowed(origin)) {
      return _forbidden('invalid origin "$origin".');
    }

    final clientId = request.url.queryParameters['sseClientId'];
    if (clientId == null || clientId.isEmpty) {
      return _badRequest('missing sseClientId query parameter.');
    }

    final existing = _connections.remove(clientId);
    existing?.shutdown();

    late final _ServerSseConnection connection;
    connection = _ServerSseConnection(
      clientId: clientId,
      onClosed: () {
        if (_connections[clientId] == connection) {
          _connections.remove(clientId);
        }
      },
    );

    _connections[clientId] = connection;

    request.hijack((channel) {
      connection.bind(channel, request: request);
      _onConnection(connection.channel, null);
    });
  }

  Future<Response> _handleIncomingMessage(Request request) async {
    final clientId = request.url.queryParameters['sseClientId'];
    if (clientId == null || clientId.isEmpty) {
      return _badRequest('missing sseClientId query parameter.');
    }

    final connection = _connections[clientId];
    if (connection == null) {
      return Response.notFound('');
    }

    final messageIdParam = request.url.queryParameters['messageId'];
    final messageId = messageIdParam == null
        ? null
        : int.tryParse(messageIdParam, radix: 10);
    if (messageId == null) {
      return _badRequest('missing or invalid messageId query parameter.');
    }

    final body = await request.readAsString();
    String? payload;
    try {
      final decoded = json.decode(body);
      if (decoded == null || decoded is String) {
        payload = decoded;
      } else {
        payload = decoded.toString();
      }
    } on FormatException {
      return _badRequest('message body must be valid JSON.');
    }

    connection.addIncomingMessage(messageId, payload);

    return Response.ok('', headers: _corsHeaders(request));
  }

  Response _optionsResponse(Request request) {
    final headers = <String, String>{
      'access-control-allow-methods': 'GET,POST,OPTIONS',
      'access-control-allow-credentials': 'true',
    };

    final origin = request.headers['origin'];
    if (origin != null) {
      headers['access-control-allow-origin'] = origin;
    }

    final requestedHeaders = request.headers['access-control-request-headers'];
    if (requestedHeaders != null) {
      headers['access-control-allow-headers'] = requestedHeaders;
    }

    return Response.ok('', headers: headers);
  }

  Response _notFound() => _htmlResponse(
    404,
    '404 Not Found',
    'Only Server-Sent Events connections are supported.',
  );

  Response _badRequest(String message) => _htmlResponse(
    400,
    '400 Bad Request',
    'Invalid Server-Sent Events request: $message',
  );

  Response _forbidden(String message) =>
      _htmlResponse(403, '403 Forbidden', 'Sse connection refused: $message');

  Response _htmlResponse(int statusCode, String title, String message) {
    final escapedTitle = htmlEscape.convert(title);
    final escapedMessage = htmlEscape.convert(message);
    return Response(
      statusCode,
      body:
          '''
      <!doctype html>
      <html>
        <head><title>$escapedTitle</title></head>
        <body>
          <h1>$escapedTitle</h1>
          <p>$escapedMessage</p>
        </body>
      </html>
    ''',
      headers: {'content-type': 'text/html'},
    );
  }

  bool _originAllowed(String? origin) {
    if (origin == null) {
      return true;
    }

    final origins = _allowedOrigins;
    if (origins == null) {
      return true;
    }

    return origins.contains(origin.toLowerCase());
  }

  Map<String, String> _corsHeaders(Request request) {
    final origin = request.headers['origin'];
    final headers = <String, String>{
      'access-control-allow-credentials': 'true',
    };

    if (origin != null) {
      headers['access-control-allow-origin'] = origin;
    }

    return headers;
  }
}

/// Internal helper that adapts the hijacked socket into an SSE-aware channel.
///
/// It keeps track of queued outbound frames until the handshake completes and
/// replays client POST payloads as ordered [Event]s.
class _ServerSseConnection {
  _ServerSseConnection({required this.clientId, required this.onClosed}) {
    _outgoingSubscription = _outgoingController.stream.listen(
      _handleOutgoingMessage,
      onError: (_) => shutdown(),
      onDone: shutdown,
    );
    _outgoingController.onCancel = shutdown;
  }

  final String clientId;
  final void Function() onClosed;

  final _incomingController = StreamController<Event>();
  final _outgoingController = StreamController<String?>();

  StreamSubscription<String?>? _outgoingSubscription;
  StreamSubscription<List<int>>? _socketSubscription;

  StringConversionSink? _sink;
  StreamSink<List<int>>? _rawSink;

  final _pendingOutgoingFrames = <String>[];
  final _pendingIncoming = <int, String?>{};
  int _nextExpectedMessageId = 0;
  bool _closed = false;

  late final SseChannel channel = _ServerSideSseChannel(
    _incomingController.stream,
    _outgoingController.sink,
  );

  Future<void> bind(
    StreamChannel<List<int>> channel, {
    required Request request,
  }) async {
    if (_closed) {
      return;
    }

    _rawSink = channel.sink;
    final stringSink = utf8.encoder.startChunkedConversion(channel.sink);
    _sink = stringSink
      ..add(_sseHeaders(request.headers['origin']))
      ..add(':ok\n\n');

    if (_pendingOutgoingFrames.isNotEmpty) {
      for (final frame in _pendingOutgoingFrames) {
        stringSink.add(frame);
      }
      _pendingOutgoingFrames.clear();
    }

    _socketSubscription = channel.stream.listen(
      (_) {},
      onError: (_) => shutdown(),
      onDone: shutdown,
      cancelOnError: true,
    );
  }

  void addIncomingMessage(int messageId, String? payload) {
    if (_closed) {
      return;
    }

    if (messageId < _nextExpectedMessageId) {
      return;
    }

    _pendingIncoming[messageId] = payload;

    while (_pendingIncoming.containsKey(_nextExpectedMessageId)) {
      final data = _pendingIncoming.remove(_nextExpectedMessageId);
      _incomingController.add(
        Event.message(id: _nextExpectedMessageId.toString(), data: data),
      );
      _nextExpectedMessageId++;
    }
  }

  void _handleOutgoingMessage(String? data) {
    if (_closed) {
      return;
    }

    final frame = _encodeEvent(data);
    final sink = _sink;
    if (sink == null) {
      _pendingOutgoingFrames.add(frame);
      return;
    }

    try {
      sink.add(frame);
    } on Object {
      _pendingOutgoingFrames.add(frame);
      shutdown();
    }
  }

  void shutdown() {
    if (_closed) {
      return;
    }
    _closed = true;

    unawaited(_outgoingSubscription?.cancel());
    unawaited(_socketSubscription?.cancel());
    _outgoingSubscription = null;
    _socketSubscription = null;

    unawaited(_outgoingController.close());
    unawaited(_incomingController.close());

    try {
      _sink?.close();
    } catch (_) {}
    _sink = null;

    try {
      _rawSink?.close();
    } catch (_) {}
    _rawSink = null;

    _pendingOutgoingFrames.clear();
    _pendingIncoming.clear();

    onClosed();
  }

  String _encodeEvent(String? data) {
    final encoded = jsonEncode(data);
    return 'data: $encoded\n\n';
  }
}

class _ServerSideSseChannel extends StreamChannelMixin implements SseChannel {
  _ServerSideSseChannel(this._stream, this._sink);

  final Stream<Event> _stream;
  final StreamSink<String?> _sink;

  @override
  Stream<Event> get stream => _stream;

  @override
  StreamSink<String?> get sink => _sink;
}

/// Generates the HTTP response headers sent during the SSE handshake.
String _sseHeaders(String? origin) =>
    'HTTP/1.1 200 OK\r\n'
    'Content-Type: text/event-stream\r\n'
    'Cache-Control: no-cache\r\n'
    'Connection: keep-alive\r\n'
    'Access-Control-Allow-Credentials: true\r\n'
    "${origin != null ? 'Access-Control-Allow-Origin: $origin\r\n' : ''}"
    'X-Accel-Buffering: no\r\n'
    '\r\n\r\n';

void unawaited(Future<void>? _) {}
