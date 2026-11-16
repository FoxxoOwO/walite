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

  test('decodes contacts and the rich message fields', () {
    final snapshot = Snapshot.fromJson({
      'type': 'snapshot',
      'selected': '1@s.whatsapp.net',
      'chats': [
        {
          'jid': '1@s.whatsapp.net',
          'name': 'Alice',
          'muted': true,
          'typing': true,
        }
      ],
      'archived': [
        {'jid': '9@s.whatsapp.net', 'name': 'Old', 'archived': true},
      ],
      'contacts': [
        {'jid': '2@s.whatsapp.net', 'name': 'Bob'},
        {'jid': '3@s.whatsapp.net', 'name': null},
      ],
      'messages': [
        {
          'id': 'M1',
          'chat': '1@s.whatsapp.net',
          'sender': '2@s.whatsapp.net',
          'text': 'new',
          'ts': 1700000000000,
          'from_me': false,
          'media': 'image',
          'caption': 'look',
          'downloaded': true,
          'reply_to': 'M0',
          'edited': true,
          'view_once': true,
          'reactions': [
            {'emoji': '👍', 'sender': '2@s.whatsapp.net'},
            {'emoji': '👍', 'sender': '3@s.whatsapp.net'},
          ],
        }
      ],
    });

    final chat = snapshot.chats.single;
    expect(chat.muted, isTrue);
    expect(chat.typing, isTrue);
    expect(snapshot.contacts['2@s.whatsapp.net'], 'Bob');
    expect(snapshot.contacts['3@s.whatsapp.net'], ''); // nameless entry decodes to '', Rust filters these out

    final msg = snapshot.messages.single;
    expect(msg.media, 'image');
    expect(msg.caption, 'look');
    expect(msg.downloaded, isTrue);
    expect(msg.replyTo, 'M0');
    expect(msg.edited, isTrue);
    expect(msg.reactions, ['👍']); // same emoji from two people appears once
    expect(msg.viewOnce, isTrue);

    final archived = snapshot.archived.single;
    expect(archived.name, 'Old');
    expect(archived.archived, isTrue);
  });

  test('decodes the selected group, including admin flags', () {
    final snapshot = Snapshot.fromJson({
      'self': '1@s.whatsapp.net',
      'group': {
        'subject': 'Trip',
        'description': 'Bikes',
        'admins': ['2@s.whatsapp.net'],
        'locked': true,
        'announcement': false,
        'invite_link': 'https://chat.whatsapp.com/x',
        'ephemeral': 86400,
        'participants': ['1@s.whatsapp.net', '2@s.whatsapp.net'],
      },
    });

    final group = snapshot.group!;
    expect(group.subject, 'Trip');
    expect(group.description, 'Bikes');
    expect(group.isAdmin(snapshot.self), isFalse);
    expect(group.isAdmin('2@s.whatsapp.net'), isTrue);
    expect(group.locked, isTrue);
    expect(group.announcement, isFalse);
    expect(group.inviteLink, 'https://chat.whatsapp.com/x');
    expect(group.ephemeral, 86400);
    expect(group.participants, hasLength(2));
    expect(Snapshot.fromJson({}).group, isNull);
  });

  test('decodes queued scheduled messages', () {
    final snapshot = Snapshot.fromJson({
      'scheduled': [
        {
          'id': 'abc',
          'chat': '1@s.whatsapp.net',
          'text': 'later',
          'at': '2026-01-02T03:04:05+00:00',
          'status': 'failed',
        },
      ],
    });

    final queued = snapshot.scheduled.single;
    expect(queued.id, 'abc');
    expect(queued.text, 'later');
    expect(queued.at, DateTime.utc(2026, 1, 2, 3, 4, 5));
    expect(queued.status, 'failed');
    expect(Snapshot.fromJson({}).scheduled, isEmpty);
  });

  test('missing fields fall back instead of throwing', () {
    final snapshot = Snapshot.fromJson({});
    expect(snapshot.connection, 'disconnected');
    expect(snapshot.chats, isEmpty);
  });
}
