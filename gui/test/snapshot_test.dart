import 'package:flutter_test/flutter_test.dart';
import 'package:warust_gui/bridge.dart';

// The bridge protocol is the only contract between Rust and this app, so it is
// the one thing worth asserting without a live backend.
void main() {
  test('snapshot decodes chats, messages and connection', () {
    final snapshot = Snapshot.fromJson({
      'type': 'snapshot',
      'self': '420@c.us',
      'connection': {'kind': 'connected', 'detail': null},
      'selected': '1@s.whatsapp.net',
      'search': '',
      'chats': [
        {
          'jid': '1@s.whatsapp.net',
          'name': 'Alice',
          'unread': 2,
          'group': false,
          'pinned': true,
          'last': {'text': 'hi', 'ts': 1700000000000, 'from_me': false},
        }
      ],
      'messages': [
        {
          'id': 'ABC',
          'chat': '1@s.whatsapp.net',
          'sender': '1@s.whatsapp.net',
          'text': 'hi',
          'ts': 1700000000000,
          'from_me': true,
          'status': 'sent',
          'media': null,
        }
      ],
    });

    expect(snapshot.connection, 'connected');
    expect(snapshot.selected, '1@s.whatsapp.net');
    expect(snapshot.chats.single.name, 'Alice');
    expect(snapshot.chats.single.last?.text, 'hi');
    expect(snapshot.messages.single.fromMe, isTrue);
  });

  test('missing fields fall back instead of throwing', () {
    final snapshot = Snapshot.fromJson({});
    expect(snapshot.connection, 'disconnected');
    expect(snapshot.chats, isEmpty);
  });
}
