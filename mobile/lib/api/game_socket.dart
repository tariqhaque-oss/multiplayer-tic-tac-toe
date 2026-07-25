import 'dart:async';
import 'dart:convert';

import 'package:web_socket_channel/io.dart';

import '../storage/session_store.dart';
import 'api_client.dart';

/// WebSocket client for all the online board games (Tic Tac Toe, Connect
/// Four, Ludo) - they all speak the same /ws?intent=... connection
/// handshake shape, differing only in the path and their move/action
/// message payloads, which each screen supplies via [send].
class GameSocket {
  IOWebSocketChannel? _channel;
  StreamController<Map<String, dynamic>>? _controller;
  final SessionStore _sessionStore = SessionStore();

  Stream<Map<String, dynamic>> get messages => _controller!.stream;

  Future<void> connect({
    required String wsPath,
    required String intent,
    String key = '',
    String difficulty = 'medium',
    bool includeDifficulty = true,
    int? seats,
    Map<String, String>? extraQuery,
  }) async {
    final cookie = await _sessionStore.getCookie();
    final uri = Uri.parse('$wsBaseUrl$wsPath').replace(queryParameters: {
      'intent': intent,
      if (key.isNotEmpty) 'key': key,
      if (intent == 'bot' && includeDifficulty) 'difficulty': difficulty,
      if (intent == 'bot' && seats != null) 'seats': '$seats',
      ...?extraQuery,
    });

    _controller = StreamController<Map<String, dynamic>>.broadcast();
    _channel = IOWebSocketChannel.connect(
      uri,
      headers: cookie != null ? {'Cookie': cookie} : null,
    );

    _channel!.stream.listen(
      (data) {
        _controller!.add(jsonDecode(data as String) as Map<String, dynamic>);
      },
      onDone: () {
        _controller!.add({
          'type': '_closed',
          'code': _channel!.closeCode,
        });
        _controller!.close();
      },
      onError: (_) {
        _controller!.add({'type': '_closed', 'code': null});
        _controller!.close();
      },
    );
  }

  /// Sends a move with an arbitrary payload field - Tic Tac Toe uses
  /// {"index": N}, Connect Four uses {"column": N}, Ludo uses {"token": N}.
  void sendMove(Map<String, dynamic> payload) {
    _channel?.sink.add(jsonEncode({'type': 'move', ...payload}));
  }

  void sendReset() {
    _channel?.sink.add(jsonEncode({'type': 'reset'}));
  }

  /// Sends any other message type verbatim - Ludo's "roll", "request_seat",
  /// and "respond_seat_request" don't fit the move/reset shape above.
  void send(Map<String, dynamic> message) {
    _channel?.sink.add(jsonEncode(message));
  }

  void close() {
    _channel?.sink.close();
  }
}
