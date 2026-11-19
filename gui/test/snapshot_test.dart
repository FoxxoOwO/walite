import 'dart:convert';

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

  test('decodes a poll with its tallies and own vote', () {
    final snapshot = Snapshot.fromJson({
      'messages': [
        {
          'id': 'P1',
          'text': '',
          'poll': {
            'question': 'Kam na oběd?',
            'options': ['Sushi', 'Kebab'],
            'selectable': 1,
            'voters': 3,
            'mine': ['Kebab'],
            'tallies': [
              {'option': 'Sushi', 'votes': 1},
              {'option': 'Kebab', 'votes': 2},
            ],
          },
        },
      ],
    });

    final poll = snapshot.messages.single.poll!;
    expect(poll.question, 'Kam na oběd?');
    expect(poll.options, ['Sushi', 'Kebab']);
    expect(poll.selectable, 1);
    expect(poll.voters, 3);
    expect(poll.mine, ['Kebab']);
    expect(poll.tallies, {'Sushi': 1, 'Kebab': 2});
    expect(Snapshot.fromJson({}).messages, isEmpty);
  });

  test('missing fields fall back instead of throwing', () {
    final snapshot = Snapshot.fromJson({});
    expect(snapshot.connection, 'disconnected');
    expect(snapshot.chats, isEmpty);
  });

  test('decodes presence and settings, keeping defaults for absent ones', () {
    final snapshot = Snapshot.fromJson({
      'presence': [
        {'jid': '2@s.whatsapp.net', 'online': true},
        {
          'jid': '3@s.whatsapp.net',
          'online': false,
          'last_seen': '2026-01-02T03:04:05+00:00',
        },
      ],
      'prefs': {'show_previews': false, 'font_size': 16.0},
    });

    expect(snapshot.presence['2@s.whatsapp.net']!.online, isTrue);
    expect(snapshot.presence['2@s.whatsapp.net']!.lastSeen, isNull);
    expect(
      snapshot.presence['3@s.whatsapp.net']!.lastSeen,
      DateTime.utc(2026, 1, 2, 3, 4, 5).toLocal(),
    );

    expect(snapshot.prefs.showPreviews, isFalse);
    expect(snapshot.prefs.fontSize, 16.0);
    // An older backend sends no prefs at all; switches must not read null.
    expect(snapshot.prefs.enterIsSend, isTrue);
    expect(snapshot.prefs.autoDownloadVideos, isFalse);
    expect(Snapshot.fromJson({}).presence, isEmpty);
  });

  test('decodes call, audio, pinned_message, stickers, update, and rich contact/message metadata', () {
    final snapshot = Snapshot.fromJson({
      'self_name': 'Teresa',
      'self_avatar': '/tmp/me.jpg',
      'pinned_message': {'id': 'PIN1', 'until': 1700000900000},
      'ephemeral': 86400,
      'chats': [
        {
          'jid': '1@s.whatsapp.net',
          'name': 'Alice',
          'avatar': '/tmp/alice.jpg',
          'draft': 'rozpsana zprava',
          'participants_count': 0,
        }
      ],
      'contacts': [
        {
          'jid': '2@s.whatsapp.net',
          'name': 'Bob',
          'blocked': true,
          'business': true,
          'verified_name': 'Bob Corp',
          'avatar': '/tmp/bob.jpg',
        }
      ],
      'call': {
        'id': 'CALL1',
        'peer_jid': '2@s.whatsapp.net',
        'peer_name': 'Bob',
        'is_video': true,
        'is_group': false,
        'status': 'connected',
        'muted': true,
        'video_enabled': false,
        'started_at': 1700000000000,
        'connected_at': 1700000005000,
      },
      'audio': {
        'playing_id': 'M1',
        'paused': false,
        'pos_ms': 1200,
        'dur_ms': 5000,
      },
      'stickers': ['/tmp/s1.webp'],
      'update': {
        'current': '0.3.5',
        'status': 'Dostupná verze 0.4.0.',
        'busy': false,
        'available': {
          'version': '0.4.0',
          'tag': 'v0.4.0',
          'page_url': 'https://example.com',
          'notes': 'New UI',
          'has_asset': true,
        },
      },
      'prefs': {
        'language': 'en',
        'dark_theme_preset': 2,
        'auto_scroll_to_bottom': false,
        'start_with_windows': true,
      },
      'messages': [
        {
          'id': 'M1',
          'text': 'hello',
          'ts': 1700000000000,
          'from_me': true,
          'status': 'read',
          'media': 'voice',
          'media_path': '/tmp/v.ogg',
          'file_size': 4096,
          'reactions': [
            {'emoji': '❤️', 'sender': '2@s.whatsapp.net'},
            {'emoji': '❤️', 'sender': '3@s.whatsapp.net'},
          ],
        }
      ],
    });

    expect(snapshot.selfName, 'Teresa');
    expect(snapshot.selfAvatar, '/tmp/me.jpg');
    expect(snapshot.pinnedMessage?.id, 'PIN1');
    expect(snapshot.ephemeral, 86400);
    expect(snapshot.chats.single.draft, 'rozpsana zprava');
    expect(snapshot.chats.single.avatar, '/tmp/alice.jpg');

    final bob = snapshot.contactDetails['2@s.whatsapp.net']!;
    expect(bob.blocked, isTrue);
    expect(bob.business, isTrue);
    expect(bob.verifiedName, 'Bob Corp');

    expect(snapshot.call?.id, 'CALL1');
    expect(snapshot.call?.isVideo, isTrue);
    expect(snapshot.call?.muted, isTrue);
    expect(snapshot.audio?.playingId, 'M1');
    expect(snapshot.audio?.posMs, 1200);
    expect(snapshot.stickers, ['/tmp/s1.webp']);
    expect(snapshot.update.available?.version, '0.4.0');
    expect(snapshot.prefs.language, 'en');
    expect(snapshot.prefs.darkThemePreset, 2);
    expect(snapshot.prefs.autoScrollToBottom, isFalse);
    expect(snapshot.prefs.startWithWindows, isTrue);
    expect(snapshot.messages.single.reactionDetails, hasLength(2));
    expect(snapshot.messages.single.mediaPath, '/tmp/v.ogg');
    expect(snapshot.messages.single.fileSize, 4096);
  });

  test('decodes ChatGallery and full-history sync metadata', () {
    final snapshot = Snapshot.fromJson({
      'selected_total_messages': 1420,
      'history_syncing': ['1@s.whatsapp.net'],
      'history_exhausted': ['2@s.whatsapp.net'],
    });
    expect(snapshot.selectedTotalMessages, 1420);
    expect(snapshot.isHistorySyncing('1@s.whatsapp.net'), isTrue);
    expect(snapshot.isHistoryExhausted('2@s.whatsapp.net'), isTrue);

    final gallery = ChatGallery.fromJson({
      'chat': '1@s.whatsapp.net',
      'total_messages': 1420,
      'syncing': true,
      'exhausted': false,
      'media': [
        {'id': 'IMG1', 'chat': '1@s.whatsapp.net', 'media': 'image', 'ts': 100},
      ],
      'docs': [
        {
          'id': 'DOC1',
          'chat': '1@s.whatsapp.net',
          'media': 'document',
          'text': 'smlouva.pdf',
          'ts': 200,
        },
      ],
      'links': [
        {
          'id': 'L1',
          'chat': '1@s.whatsapp.net',
          'url': 'https://example.com',
          'text': 'Odkaz https://example.com',
          'ts': 300,
        },
      ],
    });
    expect(gallery.totalMessages, 1420);
    expect(gallery.syncing, isTrue);
    expect(gallery.media.single.id, 'IMG1');
    expect(gallery.docs.single.text, 'smlouva.pdf');
    expect(gallery.links.single.url, 'https://example.com');
  });

  test('decodes selfStatus, avatarRev and ProfileResult', () {
    final snapshot = Snapshot.fromJson({
      'self_name': 'Michael Scott',
      'self_status': 'World\'s Best Boss',
      'avatar_rev': 7,
    });
    expect(snapshot.selfName, 'Michael Scott');
    expect(snapshot.selfStatus, 'World\'s Best Boss');
    expect(snapshot.avatarRev, 7);

    final ok = ProfileResult.fromJson({'kind': 'picture', 'ok': true});
    expect(ok.kind, 'picture');
    expect(ok.ok, isTrue);
    expect(ok.error, isNull);

    final err = ProfileResult.fromJson({
      'kind': 'picture',
      'ok': false,
      'error': 'bad image',
    });
    expect(err.ok, isFalse);
    expect(err.error, 'bad image');
  });

  test('decodes starred, gifPlayback, contactCards and wallpaper prefs', () {
    final snapshot = Snapshot.fromJson({
      'prefs': {
        'chat_wallpaper_color': '#0B221D',
        'chat_wallpaper_path': '/tmp/bg.jpg',
        'chat_wallpaper_doodles': false,
        'notification_sound': 'bell',
        'custom_sound_path': '/tmp/ding.wav',
      },
      'messages': [
        {
          'id': 'STAR1',
          'chat': '1@s.whatsapp.net',
          'sender': '1@s.whatsapp.net',
          'text': '👤 Petr',
          'ts': 1000,
          'from_me': false,
          'starred': true,
          'gif_playback': true,
          'media': 'video',
          'contacts': [
            {
              'name': 'Petr Novák',
              'phone': '+420602123456',
              'waid': '420602123456',
            },
          ],
        },
      ],
    });
    expect(snapshot.prefs.chatWallpaperColor, '#0B221D');
    expect(snapshot.prefs.chatWallpaperPath, '/tmp/bg.jpg');
    expect(snapshot.prefs.chatWallpaperDoodles, isFalse);
    expect(snapshot.prefs.notificationSound, 'bell');
    expect(snapshot.prefs.customSoundPath, '/tmp/ding.wav');

    final m = snapshot.messages.single;
    expect(m.starred, isTrue);
    expect(m.gifPlayback, isTrue);
    expect(m.contactCards, hasLength(1));
    expect(m.contactCards.single.name, 'Petr Novák');
    expect(m.contactCards.single.waid, '420602123456');
  });

  test('sameJidUser and GroupInfo.isAdmin ignore :device suffix', () {
    expect(sameJidUser('420123@s.whatsapp.net', '420123@s.whatsapp.net'), isTrue);
    expect(sameJidUser('420123@s.whatsapp.net', '420123:12@s.whatsapp.net'), isTrue);
    expect(sameJidUser('420123:1@s.whatsapp.net', '420123:2@s.whatsapp.net'), isTrue);
    expect(sameJidUser('420123@s.whatsapp.net', '420999@s.whatsapp.net'), isFalse);
    expect(sameJidUser('420123@s.whatsapp.net', '420123@lid'), isFalse);
    expect(sameJidUser(null, '420123@s.whatsapp.net'), isFalse);
    expect(sameJidUser('', '420123@s.whatsapp.net'), isFalse);

    final group = GroupInfo.fromJson({
      'subject': 'Team',
      'admins': ['420111@s.whatsapp.net'],
    });
    expect(group.isAdmin('420111:7@s.whatsapp.net'), isTrue);
    expect(group.isAdmin('420111@s.whatsapp.net'), isTrue);
    expect(group.isAdmin('420222@s.whatsapp.net'), isFalse);
  });

  test('Msg.thumbBytes decodes lazily, caches bytes, and handles invalid base64', () {
    final valid = base64Encode([1, 2, 3, 4]);
    final msg = Msg.fromJson({
      'id': 'M1',
      'text': '',
      'ts': 1,
      'from_me': false,
      'sender': '1@s.whatsapp.net',
      'thumb': valid,
    });
    final decoded = msg.thumbBytes;
    expect(decoded, [1, 2, 3, 4]);
    expect(identical(msg.thumbBytes, decoded), isTrue);

    final invalid = Msg.fromJson({
      'id': 'M2',
      'text': '',
      'ts': 1,
      'from_me': false,
      'sender': '1@s.whatsapp.net',
      'thumb': '!!!not-base64!!!',
    });
    expect(invalid.thumbBytes, isNull);

    final empty = Msg.fromJson({
      'id': 'M3',
      'text': '',
      'ts': 1,
      'from_me': false,
      'sender': '1@s.whatsapp.net',
    });
    expect(empty.thumbBytes, isNull);
  });

  test('Snapshot.chat and Snapshot.message lookups prefer active chat', () {
    final snap = Snapshot.fromJson({
      'chats': [
        {'jid': '1@s.whatsapp.net', 'name': 'Active'},
      ],
      'archived': [
        {'jid': '1@s.whatsapp.net', 'name': 'Archived'},
        {'jid': '2@s.whatsapp.net', 'name': 'Old'},
      ],
      'messages': [
        {
          'id': 'MSG1',
          'text': 'first',
          'ts': 100,
          'from_me': false,
          'sender': '1@s.whatsapp.net',
        },
        {
          'id': 'MSG1',
          'text': 'duplicate',
          'ts': 200,
          'from_me': false,
          'sender': '1@s.whatsapp.net',
        },
      ],
    });
    expect(snap.chat('1@s.whatsapp.net')?.name, 'Active');
    expect(snap.chat('2@s.whatsapp.net')?.name, 'Old');
    expect(snap.chat('missing@s.whatsapp.net'), isNull);
    expect(snap.chat(null), isNull);

    expect(snap.message('MSG1')?.text, 'first');
    expect(snap.message('MISSING'), isNull);
    expect(snap.message(null), isNull);
  });

  test('Bridge.dispose is idempotent and suppresses post-dispose calls', () {
    final b = Bridge(18799);
    b.dispose();
    b.dispose();
    b.connect();
    b.select('1@s.whatsapp.net');
  });
}
