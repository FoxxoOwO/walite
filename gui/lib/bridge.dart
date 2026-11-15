import 'dart:async';
import 'dart:convert';

import 'package:web_socket_channel/web_socket_channel.dart';

/// One chat row from the Rust backend's snapshot.
class ChatItem {
  ChatItem({required this.jid, required this.name, this.last});

  final String jid;
  final String name;
  final LastMessage? last;

  factory ChatItem.fromJson(Map<String, dynamic> json) => ChatItem(
        jid: json['jid'] as String,
        name: json['name'] as String? ?? '',
        last: json['last'] == null
            ? null
            : LastMessage.fromJson(json['last'] as Map<String, dynamic>),
      );
}

class LastMessage {
  LastMessage(this.text, this.ts, this.fromMe);

  final String text;
  final int ts;
  final bool fromMe;

  factory LastMessage.fromJson(Map<String, dynamic> json) => LastMessage(
        json['text'] as String? ?? '',
        json['ts'] as int? ?? 0,
        json['from_me'] as bool? ?? false,
      );
}

class Msg {
  Msg({
    required this.id,
    required this.text,
    required this.ts,
    required this.fromMe,
    required this.sender,
  });

  final String id;
  final String text;
  final int ts;
  final bool fromMe;
  final String sender;

  factory Msg.fromJson(Map<String, dynamic> json) => Msg(
        id: json['id'] as String? ?? '',
        text: json['text'] as String? ?? '',
        ts: json['ts'] as int? ?? 0,
        fromMe: json['from_me'] as bool? ?? false,
        sender: json['sender'] as String? ?? '',
      );
}

/// Everything the backend pushes, already decoded.
class Snapshot {
  Snapshot({
    required this.connection,
    required this.detail,
    required this.selected,
    required this.chats,
    required this.messages,
  });

  final String connection;
  final String? detail;
  final String? selected;
  final List<ChatItem> chats;
  final List<Msg> messages;

  factory Snapshot.fromJson(Map<String, dynamic> json) {
    final conn = json['connection'] as Map<String, dynamic>? ?? const {};
    return Snapshot(
      connection: conn['kind'] as String? ?? 'disconnected',
      detail: conn['detail']?.toString(),
      selected: json['selected'] as String?,
      chats: (json['chats'] as List<dynamic>? ?? const [])
          .map((e) => ChatItem.fromJson(e as Map<String, dynamic>))
          .toList(),
      messages: (json['messages'] as List<dynamic>? ?? const [])
          .map((e) => Msg.fromJson(e as Map<String, dynamic>))
          .toList(),
    );
  }
}

/// Client for `warust --ui ws`: reconnects on its own, so the app can be
/// started before the backend.
class Bridge {
  Bridge(this.port);

  final int port;

  final _snapshots = StreamController<Snapshot>.broadcast();
  final _link = StreamController<bool>.broadcast();
  Timer? _retry;
  WebSocketChannel? _channel;
  bool _connecting = false;

  Stream<Snapshot> get snapshots => _snapshots.stream;

  /// Emits true while the socket is open.
  Stream<bool> get link => _link.stream;

  void connect() {
    if (_connecting) return;
    _connecting = true;
    try {
      final channel = WebSocketChannel.connect(Uri.parse('ws://127.0.0.1:$port'));
      _channel = channel;
      _link.add(true);
      channel.stream.listen(
        (frame) {
          final decoded = jsonDecode(frame as String);
          if (decoded is Map<String, dynamic> && decoded['type'] == 'snapshot') {
            _snapshots.add(Snapshot.fromJson(decoded));
          }
        },
        onDone: _lost,
        onError: (_) => _lost(),
      );
    } catch (_) {
      _lost();
    }
  }

  void _lost() {
    _connecting = false;
    _channel = null;
    _link.add(false);
    _retry?.cancel();
    _retry = Timer(const Duration(seconds: 1), connect);
  }

  void _send(Map<String, Object?> message) {
    _channel?.sink.add(jsonEncode(message));
  }

  void select(String jid) => _send({'type': 'select', 'chat': jid});

  void sendText(String jid, String text) =>
      _send({'type': 'send', 'chat': jid, 'text': text});

  void search(String query) => _send({'type': 'search', 'q': query});

  void dispose() {
    _retry?.cancel();
    _channel?.sink.close();
  }
}
