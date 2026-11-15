import 'package:flutter/material.dart';
import 'package:qr_flutter/qr_flutter.dart';

import 'bridge.dart';

/// Port the Rust bridge listens on (`warust --ui ws`).
const _port = 8787;

void main() => runApp(const WarustApp());

class WarustApp extends StatelessWidget {
  const WarustApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Warust',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        brightness: Brightness.dark,
        colorScheme: ColorScheme.fromSeed(
          seedColor: const Color(0xFF00A884),
          brightness: Brightness.dark,
        ),
        scaffoldBackgroundColor: const Color(0xFF111B21),
        useMaterial3: true,
      ),
      home: const HomePage(),
    );
  }
}

class HomePage extends StatefulWidget {
  const HomePage({super.key});

  @override
  State<HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<HomePage> {
  final _bridge = Bridge(_port);
  final _search = TextEditingController();
  final _composer = TextEditingController();
  Snapshot? _snapshot;
  bool _linked = false;

  @override
  void initState() {
    super.initState();
    _bridge.link.listen((linked) => setState(() => _linked = linked));
    _bridge.snapshots.listen((snap) => setState(() => _snapshot = snap));
    _bridge.connect();
  }

  @override
  void dispose() {
    _bridge.dispose();
    _search.dispose();
    _composer.dispose();
    super.dispose();
  }

  void _open(String jid) {
    _bridge.select(jid);
    _composer.clear();
  }

  void _submit() {
    final chat = _snapshot?.selected;
    final text = _composer.text.trim();
    if (chat == null || text.isEmpty) return;
    _bridge.sendText(chat, text);
    _composer.clear();
  }

  @override
  Widget build(BuildContext context) {
    final snapshot = _snapshot;
    if (!_linked || snapshot == null) {
      return Scaffold(body: Center(child: _waiting(snapshot)));
    }
    if (snapshot.connection == 'qr' || snapshot.connection == 'pair') {
      return Scaffold(body: Center(child: _pairing(snapshot)));
    }
    return Scaffold(
      body: Row(
        children: [
          SizedBox(width: 320, child: _sidebar(snapshot)),
          const VerticalDivider(width: 1, color: Color(0xFF202C33)),
          Expanded(child: _conversation(snapshot)),
        ],
      ),
    );
  }

  Widget _waiting(Snapshot? snapshot) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        const CircularProgressIndicator(),
        const SizedBox(height: 16),
        Text(_linked
            ? 'Načítám stav… (${snapshot?.connection ?? 'start'})'
            : 'Čekám na backend na portu $_port…'),
        const SizedBox(height: 8),
        const Text(
          'Spusť: warust --ui ws',
          style: TextStyle(color: Colors.white54, fontSize: 12),
        ),
      ],
    );
  }

  Widget _pairing(Snapshot snapshot) {
    final isQr = snapshot.connection == 'qr';
    return Padding(
      padding: const EdgeInsets.all(32),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text('Přihlášení do WhatsApp',
              style: Theme.of(context).textTheme.headlineSmall),
          const SizedBox(height: 24),
          if (isQr && snapshot.detail != null)
            Container(
              padding: const EdgeInsets.all(12),
              color: Colors.white,
              child: QrImageView(data: snapshot.detail!, size: 240),
            )
          else
            SelectableText(
              snapshot.detail ?? '—',
              style: const TextStyle(fontSize: 28, letterSpacing: 4),
            ),
          const SizedBox(height: 16),
          Text(
            isQr
                ? 'Naskenuj kód v WhatsApp → Propojená zařízení'
                : 'Zadej kód v WhatsApp → Propojená zařízení',
            style: const TextStyle(color: Colors.white70),
          ),
        ],
      ),
    );
  }

  Widget _sidebar(Snapshot snapshot) {
    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(12, 12, 12, 4),
          child: TextField(
            controller: _search,
            onChanged: _bridge.search,
            decoration: const InputDecoration(
              isDense: true,
              prefixIcon: Icon(Icons.search),
              hintText: 'Hledat',
              border: OutlineInputBorder(),
            ),
          ),
        ),
        Expanded(
          child: ListView.builder(
            itemCount: snapshot.chats.length,
            itemBuilder: (context, index) {
              final chat = snapshot.chats[index];
              return ListTile(
                selected: chat.jid == snapshot.selected,
                selectedTileColor: const Color(0xFF2A3942),
                leading: CircleAvatar(
                  child: Text(chat.name.isEmpty
                      ? '?'
                      : chat.name.characters.first.toUpperCase()),
                ),
                title: Text(
                  chat.name.isEmpty ? chat.jid : chat.name,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
                subtitle: chat.last == null
                    ? null
                    : Text(chat.last!.text.isEmpty ? '📎' : chat.last!.text,
                        maxLines: 1, overflow: TextOverflow.ellipsis),
                trailing: chat.last == null
                    ? null
                    : Text(_clock(chat.last!.ts),
                        style: const TextStyle(fontSize: 11)),
                onTap: () => _open(chat.jid),
              );
            },
          ),
        ),
        const Divider(height: 1),
        Padding(
          padding: const EdgeInsets.all(8),
          child: Row(
            children: [
              const Icon(Icons.circle, size: 10, color: Colors.greenAccent),
              const SizedBox(width: 6),
              Expanded(
                child: Text(
                  snapshot.connection,
                  style: const TextStyle(fontSize: 12),
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }

  Widget _conversation(Snapshot snapshot) {
    final selected = snapshot.selected;
    if (selected == null) {
      return const Center(
        child: Text('Vyber chat', style: TextStyle(color: Colors.white54)),
      );
    }
    return Column(
      children: [
        Expanded(
          child: ListView.builder(
            reverse: true,
            padding: const EdgeInsets.all(16),
            itemCount: snapshot.messages.length,
            itemBuilder: (context, index) {
              final msg = snapshot.messages[snapshot.messages.length - 1 - index];
              return _bubble(msg);
            },
          ),
        ),
        Container(
          color: const Color(0xFF202C33),
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
          child: Row(
            children: [
              Expanded(
                child: TextField(
                  controller: _composer,
                  minLines: 1,
                  maxLines: 5,
                  onSubmitted: (_) => _submit(),
                  decoration: const InputDecoration(
                    isDense: true,
                    hintText: 'Napiš zprávu',
                    border: InputBorder.none,
                  ),
                ),
              ),
              IconButton(
                onPressed: _submit,
                icon: const Icon(Icons.send),
                tooltip: 'Odeslat',
              ),
            ],
          ),
        ),
      ],
    );
  }

  Widget _bubble(Msg msg) {
    return Align(
      alignment: msg.fromMe ? Alignment.centerRight : Alignment.centerLeft,
      child: Container(
        margin: const EdgeInsets.symmetric(vertical: 2),
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        constraints: const BoxConstraints(maxWidth: 520),
        decoration: BoxDecoration(
          color: msg.fromMe ? const Color(0xFF005C4B) : const Color(0xFF202C33),
          borderRadius: BorderRadius.circular(8),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.end,
          children: [
            if (!msg.fromMe)
              Padding(
                padding: const EdgeInsets.only(bottom: 2),
                child: Text(
                  msg.sender.split('@').first,
                  style: const TextStyle(
                      fontSize: 11, color: Colors.lightGreenAccent),
                ),
              ),
            Text(msg.text.isEmpty ? '📎' : msg.text),
            Padding(
              padding: const EdgeInsets.only(top: 2),
              child: Text(_clock(msg.ts),
                  style: const TextStyle(fontSize: 10, color: Colors.white54)),
            ),
          ],
        ),
      ),
    );
  }

  String _clock(int millis) {
    if (millis == 0) return '';
    final t = DateTime.fromMillisecondsSinceEpoch(millis);
    final hh = t.hour.toString().padLeft(2, '0');
    final mm = t.minute.toString().padLeft(2, '0');
    final now = DateTime.now();
    final sameDay =
        t.year == now.year && t.month == now.month && t.day == now.day;
    return sameDay ? '$hh:$mm' : '${t.day}.${t.month}. $hh:$mm';
  }
}
