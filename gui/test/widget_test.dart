import 'dart:ui';

import 'package:material_ui/material_ui.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:warust_gui/bridge.dart';
import 'package:warust_gui/main.dart';
import 'package:warust_gui/theme.dart';

void main() {
  testWidgets('renders WhatsApp 3-column shell with chats, messages, poll and call overlay',
      (tester) async {
    tester.view.physicalSize = const Size(1400, 900);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(() {
      tester.view.resetPhysicalSize();
      tester.view.resetDevicePixelRatio();
    });

    final bridge = Bridge(18787);
    addTearDown(bridge.dispose);

    final snapshot = Snapshot.fromJson({
      'type': 'snapshot',
      'self': '420111222333@s.whatsapp.net',
      'self_name': 'Teresa',
      'connection': {'kind': 'connected'},
      'selected': '120363000@g.us',
      'chats': [
        {
          'jid': '120363000@g.us',
          'name': 'Rodina',
          'unread': 2,
          'group': true,
          'pinned': true,
          'muted': false,
          'typing': false,
          'participants_count': 3,
          'last': {
            'text': 'Kdo jde na oběd?',
            'ts': 1700000000000,
            'from_me': false,
            'status': 'delivered',
          },
        },
        {
          'jid': '420777888999@s.whatsapp.net',
          'name': 'Petr',
          'unread': 0,
          'group': false,
          'draft': 'rozpsaný koncept',
        },
      ],
      'archived': [
        {'jid': '420999000111@s.whatsapp.net', 'name': 'Archiv', 'archived': true},
      ],
      'group': {
        'subject': 'Rodina',
        'description': 'Rodinný chat',
        'admins': ['420111222333@s.whatsapp.net'],
        'locked': false,
        'announcement': false,
        'participants': [
          '420111222333@s.whatsapp.net',
          '420777888999@s.whatsapp.net',
        ],
      },
      'pinned_message': {'id': 'M1'},
      'messages': [
        {
          'id': 'M1',
          'chat': '120363000@g.us',
          'sender': '420777888999@s.whatsapp.net',
          'text': 'Ahoj @Teresa mrkni na https://example.com',
          'ts': 1700000000000,
          'from_me': false,
          'reactions': [
            {'emoji': '👍', 'sender': '420111222333@s.whatsapp.net'},
          ],
        },
        {
          'id': 'M2',
          'chat': '120363000@g.us',
          'sender': '420111222333@s.whatsapp.net',
          'text': '',
          'ts': 1700000060000,
          'from_me': true,
          'status': 'read',
          'poll': {
            'question': 'Kam na oběd?',
            'options': ['Sushi', 'Pizza'],
            'selectable': 1,
            'voters': 1,
            'mine': ['Sushi'],
            'tallies': [
              {'option': 'Sushi', 'votes': 1},
              {'option': 'Pizza', 'votes': 0},
            ],
          },
        },
      ],
      'contacts': [
        {'jid': '420777888999@s.whatsapp.net', 'name': 'Petr'},
      ],
      'call': {
        'id': 'C1',
        'peer_jid': '420777888999@s.whatsapp.net',
        'peer_name': 'Petr',
        'is_video': false,
        'is_group': false,
        'status': 'incoming',
        'muted': false,
        'video_enabled': false,
        'started_at': 1700000000000,
      },
    });

    await tester.pumpWidget(
      MaterialApp(
        theme: ThemeData.dark(useMaterial3: true),
        home: HomePage(
          bridge: bridge,
          snapshot: snapshot,
          linked: true,
          palette: WaPalette.whatsappDark,
        ),
      ),
    );
    await tester.pump();

    expect(find.text('Chaty'), findsOneWidget);
    expect(find.text('Rodina'), findsAtLeastNWidgets(1));
    expect(find.text('Petr'), findsAtLeastNWidgets(1));
    expect(find.text('Kam na oběd?'), findsOneWidget);
    expect(find.text('Připnutá zpráva'), findsOneWidget);
    expect(find.text('Příchozí hlasový hovor WhatsApp'), findsOneWidget);
  });

  testWidgets('renders QR pairing view with phone-link option', (tester) async {
    tester.view.physicalSize = const Size(1200, 800);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(() {
      tester.view.resetPhysicalSize();
      tester.view.resetDevicePixelRatio();
    });

    final bridge = Bridge(18788);
    addTearDown(bridge.dispose);

    final snapshot = Snapshot.fromJson({
      'connection': {'kind': 'qr', 'detail': '2@mock-qr-payload'},
    });

    await tester.pumpWidget(
      MaterialApp(
        theme: ThemeData.dark(useMaterial3: true),
        home: HomePage(
          bridge: bridge,
          snapshot: snapshot,
          linked: true,
          palette: WaPalette.whatsappDark,
        ),
      ),
    );
    await tester.pump();

    expect(find.text('Přihlášení do WaLite'), findsOneWidget);
    expect(find.text('Propojit pomocí telefonního čísla'), findsOneWidget);

    await tester.tap(find.text('Propojit pomocí telefonního čísla'));
    await tester.pump();

    expect(find.text('Získat kód'), findsOneWidget);
  });

  testWidgets('opens right-hand ChatInfoPanel and 7-tab SettingsDialog without overflows',
      (tester) async {
    tester.view.physicalSize = const Size(1400, 900);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(() {
      tester.view.resetPhysicalSize();
      tester.view.resetDevicePixelRatio();
    });

    final bridge = Bridge(18789);
    addTearDown(bridge.dispose);

    final snapshot = Snapshot.fromJson({
      'type': 'snapshot',
      'self': '420111222333@s.whatsapp.net',
      'self_name': 'Teresa',
      'connection': {'kind': 'connected'},
      'selected': '120363000@g.us',
      'chats': [
        {
          'jid': '120363000@g.us',
          'name': 'Rodina',
          'group': true,
          'participants_count': 2,
        },
      ],
      'group': {
        'subject': 'Rodina',
        'description': 'Rodinný chat',
        'admins': ['420111222333@s.whatsapp.net'],
        'participants': [
          '420111222333@s.whatsapp.net',
          '420777888999@s.whatsapp.net',
        ],
      },
      'messages': [
        {
          'id': 'M1',
          'chat': '120363000@g.us',
          'sender': '420777888999@s.whatsapp.net',
          'text': 'mrkni na https://example.com',
          'ts': 1700000000000,
          'from_me': false,
        },
      ],
      'contacts': [
        {'jid': '420777888999@s.whatsapp.net', 'name': 'Petr'},
      ],
    });

    await tester.pumpWidget(
      MaterialApp(
        theme: ThemeData.dark(useMaterial3: true),
        home: HomePage(
          bridge: bridge,
          snapshot: snapshot,
          linked: true,
          palette: WaPalette.whatsappDark,
        ),
      ),
    );
    await tester.pump();

    // Open ChatInfoPanel via header info button
    await tester.tap(find.byIcon(Icons.info_outline));
    await tester.pump();

    expect(find.text('Info o skupině'), findsOneWidget);
    expect(find.text('MÉDIA, ODKAZY A DOKUMENTY'), findsOneWidget);
    expect(find.text('Odkazy (1)'), findsOneWidget);

    // Switch gallery to Odkazy tab
    await tester.ensureVisible(find.text('Odkazy (1)'));
    await tester.pump();
    await tester.tap(find.text('Odkazy (1)'));
    await tester.pump();
    await tester.ensureVisible(find.text('https://example.com'));
    expect(find.text('https://example.com'), findsOneWidget);

    // Open Settings dialog and check tabs
    await tester.tap(find.byIcon(Icons.settings_outlined));
    await tester.pump();

    expect(find.text('Nastavení'), findsOneWidget);
    expect(find.text('Profilové údaje'), findsOneWidget);
    expect(find.text('O mně (Stav)'), findsOneWidget);
    expect(find.text('Změnit'), findsOneWidget);

    await tester.enterText(
      find.widgetWithText(TextField, 'O mně (Stav)'),
      'Dostupný v WaLite',
    );
    await tester.tap(find.text('Uložit').last);
    await tester.pump();
    expect(find.text('Stav „O mně“ uložen'), findsOneWidget);

    await tester.tap(find.text('Vzhled'));
    await tester.pump();
    expect(find.text('Barevné schéma'), findsOneWidget);
    expect(find.text('Pozadí konverzace'), findsOneWidget);

    await tester.tap(find.text('Oznámení'));
    await tester.pump();
    expect(find.text('Zvuk upozornění'), findsOneWidget);
    expect(find.text('Bublina (Pop)'), findsOneWidget);
    expect(find.text('Vybrat vlastní zvuk…'), findsOneWidget);

    await tester.tap(find.text('O aplikaci a data'));
    await tester.pump();
    expect(find.text('Klávesové zkratky'), findsOneWidget);
  });

  testWidgets('quick reaction pill displays all reactions inside pill bounds without overflow',
      (tester) async {
    tester.view.physicalSize = const Size(1400, 900);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(() {
      tester.view.resetPhysicalSize();
      tester.view.resetDevicePixelRatio();
    });

    final bridge = Bridge(18790);
    addTearDown(bridge.dispose);

    final snapshot = Snapshot.fromJson({
      'type': 'snapshot',
      'self': '420111222333@s.whatsapp.net',
      'self_name': 'Teresa',
      'connection': {'kind': 'connected'},
      'selected': '420777888999@s.whatsapp.net',
      'chats': [
        {
          'jid': '420777888999@s.whatsapp.net',
          'name': 'Petr',
          'group': false,
        },
      ],
      'messages': [
        {
          'id': 'MSG_REACT',
          'chat': '420777888999@s.whatsapp.net',
          'sender': '420111222333@s.whatsapp.net',
          'text': 'nice, já tadyty nové brýle ani do toho vrka nestrčím',
          'ts': 1700000000000,
          'from_me': true,
          'status': 'sent',
          'reactions': [
            {'emoji': '😂', 'sender': '420777888999@s.whatsapp.net'},
          ],
        },
      ],
    });

    await tester.pumpWidget(
      MaterialApp(
        theme: ThemeData.dark(useMaterial3: true),
        home: HomePage(
          bridge: bridge,
          snapshot: snapshot,
          linked: true,
          palette: WaPalette.whatsappDark,
        ),
      ),
    );
    await tester.pump();

    // Hover in the empty row space BESIDE the outgoing bubble so its hover buttons still appear
    final msgRect = tester.getRect(
      find.text('nice, já tadyty nové brýle ani do toho vrka nestrčím'),
    );
    final gesture = await tester.createGesture(kind: PointerDeviceKind.mouse);
    await gesture.addPointer(location: Offset.zero);
    addTearDown(gesture.removePointer);
    await gesture.moveTo(Offset(msgRect.left - 120, msgRect.center.dy));
    await tester.pump();

    expect(find.byIcon(Icons.emoji_emotions_outlined), findsNWidgets(2));
    expect(find.byIcon(Icons.keyboard_arrow_down), findsOneWidget);
    await tester.tap(find.byIcon(Icons.emoji_emotions_outlined).first);
    await tester.pumpAndSettle();

    // All 8 quick reactions including the rightmost 🎉 + '+' must be inside the pill
    expect(find.text('👍'), findsOneWidget);
    expect(find.text('🎉'), findsOneWidget);
    expect(find.byIcon(Icons.add), findsOneWidget);
    expect(
      tester.getRect(find.text('🎉')).right,
      lessThan(tester.getRect(find.byIcon(Icons.add)).left),
    );

    // Dismiss pill, open message context menu, verify quick reactions aren't greyed out
    await tester.tapAt(const Offset(5, 5));
    await tester.pumpAndSettle();
    await tester.tap(find.byIcon(Icons.keyboard_arrow_down).first);
    await tester.pumpAndSettle();

    final thumbText = tester.widget<Text>(find.text('👍'));
    expect(thumbText.style?.color, Colors.white);
    expect(find.text('Odpovědět'), findsOneWidget);
  });

  testWidgets('renders starred badge, contact card actions, and search highlight bar',
      (tester) async {
    tester.view.physicalSize = const Size(1400, 900);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(() {
      tester.view.resetPhysicalSize();
      tester.view.resetDevicePixelRatio();
    });

    final bridge = Bridge(18791);
    addTearDown(bridge.dispose);

    final snapshot = Snapshot.fromJson({
      'type': 'snapshot',
      'self': '420111222333@s.whatsapp.net',
      'connection': {'kind': 'connected'},
      'selected': '420777888999@s.whatsapp.net',
      'prefs': {'chat_wallpaper_color': '#0B221D', 'chat_wallpaper_doodles': false},
      'chats': [
        {'jid': '420777888999@s.whatsapp.net', 'name': 'Petr', 'group': false},
      ],
      'messages': [
        {
          'id': 'M_STAR',
          'chat': '420777888999@s.whatsapp.net',
          'sender': '420777888999@s.whatsapp.net',
          'text': 'Důležitý smluvní termín zítra',
          'ts': 1700000000000,
          'from_me': false,
          'starred': true,
        },
        {
          'id': 'M_VCARD',
          'chat': '420777888999@s.whatsapp.net',
          'sender': '420777888999@s.whatsapp.net',
          'text': '👤 Jana K.',
          'ts': 1700000001000,
          'from_me': false,
          'contacts': [
            {
              'name': 'Jana Novotná',
              'phone': '+420602999888',
              'waid': '420602999888',
            },
          ],
        },
      ],
    });

    await tester.pumpWidget(
      MaterialApp(
        theme: ThemeData.dark(useMaterial3: true),
        home: HomePage(
          bridge: bridge,
          snapshot: snapshot,
          linked: true,
          palette: WaPalette.whatsappDark,
        ),
      ),
    );
    await tester.pump();

    expect(find.byIcon(Icons.star_rounded), findsOneWidget);
    expect(find.text('Jana Novotná'), findsOneWidget);
    expect(find.text('+420602999888'), findsOneWidget);
    expect(find.text('Zahájit chat'), findsOneWidget);

    // Search dialog exposes Poll, Reacted & Starred chips and updates highlight banner
    await tester.tap(find.byIcon(Icons.search).first);
    await tester.pumpAndSettle();
    expect(find.text('Ankety'), findsOneWidget);
    expect(find.text('S reakcemi'), findsOneWidget);
    expect(find.text('Hvězdičkou'), findsOneWidget);
  });

  testWidgets('sending a message within 350ms does not leave a stale draft',
      (tester) async {
    tester.view.physicalSize = const Size(1400, 900);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(() {
      tester.view.resetPhysicalSize();
      tester.view.resetDevicePixelRatio();
    });

    final bridge = _RecordingBridge(18788);
    addTearDown(bridge.dispose);

    final snapshot = Snapshot.fromJson({
      'type': 'snapshot',
      'self': '420111222333@s.whatsapp.net',
      'self_name': 'Teresa',
      'connection': {'kind': 'connected'},
      'selected': '420777888999@s.whatsapp.net',
      'chats': [
        {
          'jid': '420777888999@s.whatsapp.net',
          'name': 'Petr',
          'unread': 0,
          'group': false,
        },
      ],
      'messages': [],
    });

    await tester.pumpWidget(
      MaterialApp(
        theme: ThemeData.dark(useMaterial3: true),
        home: HomePage(
          bridge: bridge,
          snapshot: snapshot,
          linked: true,
          palette: WaPalette.whatsappDark,
        ),
      ),
    );
    await tester.pump();

    await tester.enterText(find.byType(TextField).last, 'Ahoj světe');
    await tester.pump(const Duration(milliseconds: 100));

    await tester.tap(find.byIcon(Icons.send).last);
    await tester.pump(const Duration(milliseconds: 500));

    expect(
      bridge.sentTexts,
      [('420777888999@s.whatsapp.net', 'Ahoj světe')],
    );
    expect(
      bridge.savedDrafts.where((d) => d.$2.isNotEmpty),
      isEmpty,
    );
    expect(
      bridge.savedDrafts.lastOrNull,
      ('420777888999@s.whatsapp.net', ''),
    );
  });
}

class _RecordingBridge extends Bridge {
  _RecordingBridge(super.port);

  final List<(String, String)> savedDrafts = [];
  final List<(String, String)> sentTexts = [];

  @override
  void saveDraft(String chat, String text) {
    savedDrafts.add((chat, text));
  }

  @override
  void sendText(
    String jid,
    String text, {
    String? reply,
    List<String> mentions = const [],
  }) {
    sentTexts.add((jid, text));
  }

  @override
  void sendTyping(String chat, bool composing) {}
}
