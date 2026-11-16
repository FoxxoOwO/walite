import 'dart:async';

import 'package:file_selector/file_selector.dart';
import 'package:material_ui/material_ui.dart';
import 'package:flutter/services.dart';
import 'package:qr_flutter/qr_flutter.dart';

import 'bridge.dart';

/// Port the Rust bridge listens on (`warust --ui ws`).
const _port = 8787;

/// Disappearing-message presets, the same ones WhatsApp offers.
const _ephemeralValues = [0, 86400, 604800, 7776000];

String _ephemeralLabel(int seconds) => switch (seconds) {
      0 => 'vypnuto',
      86400 => '24 hodin',
      604800 => '7 dní',
      _ => '90 dní',
    };

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
  Msg? _reply;

  /// The bridge owns the microphone; the GUI only runs the clock.
  bool _recording = false;
  int _recSecs = 0;
  Timer? _tick;

  static const _quickReactions = ['👍', '❤️', '😂', '😮', '😢', '🙏'];

  @override
  void initState() {
    super.initState();
    _bridge.link.listen((linked) => setState(() => _linked = linked));
    _bridge.snapshots.listen((snap) => setState(() => _snapshot = snap));
    _bridge.connect();
  }

  @override
  void dispose() {
    _tick?.cancel();
    _bridge.dispose();
    _search.dispose();
    _composer.dispose();
    _tick?.cancel();
    super.dispose();
  }

  void _open(ChatItem chat) {
    _bridge.select(chat.jid);
    if (chat.unread > 0) _bridge.markRead(chat.jid);
    _composer.clear();
    setState(() => _reply = null);
  }

  void _submit() {
    final chat = _snapshot?.selected;
    final text = _composer.text.trim();
    if (chat == null || text.isEmpty) return;
    _bridge.sendText(chat, text, reply: _reply?.id);
    _composer.clear();
    setState(() => _reply = null);
  }

  /// Picks a file and sends it to the open chat; composer text becomes the caption.
  /// Picks a day and a time, then queues whatever sits in the composer.
  Future<void> _schedule() async {
    final chat = _snapshot?.selected;
    final text = _composer.text.trim();
    if (chat == null || text.isEmpty) return;
    final now = DateTime.now();
    final soon = now.add(const Duration(minutes: 5));
    final day = await showDatePicker(
      context: context,
      initialDate: soon,
      firstDate: now,
      lastDate: now.add(const Duration(days: 365)),
    );
    if (day == null || !mounted) return;
    final time = await showTimePicker(
      context: context,
      initialTime: TimeOfDay.fromDateTime(soon),
    );
    if (time == null) return;
    final at = DateTime(day.year, day.month, day.day, time.hour, time.minute);
    if (!mounted) return;
    if (!at.isAfter(now)) {
      ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Čas už je v minulosti.')));
      return;
    }
    _bridge.schedule(chat, text, at);
    _composer.clear();
    setState(() => _reply = null);
  }

  /// The queue the backend keeps; it sends each message when its clock passes.
  void _scheduled(Snapshot first) {
    showDialog<void>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('Naplánované zprávy'),
        content: SizedBox(
          width: 420,
          child: StreamBuilder<Snapshot>(
            stream: _bridge.snapshots,
            initialData: first,
            builder: (context, snap) {
              final list = (snap.data ?? first).scheduled;
              if (list.isEmpty) return const Text('Nic nečeká.');
              return SingleChildScrollView(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    for (final s in list)
                      ListTile(
                        dense: true,
                        title: Text(s.text,
                            maxLines: 2, overflow: TextOverflow.ellipsis),
                        subtitle: Text([
                          _nameOf(s.chat),
                          _when(s.at),
                          if (s.status == 'failed') 'selhalo',
                        ].join(' · ')),
                        trailing: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            IconButton(
                              onPressed: () => _bridge.sendScheduledNow(s.id),
                              icon: const Icon(Icons.send, size: 18),
                              tooltip: 'Odeslat teď',
                            ),
                            IconButton(
                              onPressed: () => _bridge.cancelScheduled(s.id),
                              icon: const Icon(Icons.delete_outline, size: 18),
                              tooltip: 'Zrušit',
                            ),
                          ],
                        ),
                      ),
                  ],
                ),
              );
            },
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext),
            child: const Text('Zavřít'),
          ),
        ],
      ),
    );
  }

  String _when(DateTime at) => '${at.day}. ${at.month}. '
      '${at.hour.toString().padLeft(2, '0')}:'
      '${at.minute.toString().padLeft(2, '0')}';

  /// The microphone lives in the Rust bridge (`crate::recorder`); the GUI only
  /// runs the clock. Stopping hands the take to the backend, which sends it.
  void _recordToggle() {
    final chat = _snapshot?.selected;
    if (_recording) {
      _tick?.cancel();
      setState(() => _recording = false);
      if (chat != null) _bridge.recordStop(chat);
      return;
    }
    if (chat == null) return;
    _bridge.recordStart();
    _tick = Timer.periodic(
        const Duration(seconds: 1), (_) => setState(() => _recSecs++));
    setState(() {
      _recording = true;
      _recSecs = 0;
    });
  }

  void _recordCancel() {
    _tick?.cancel();
    _bridge.recordCancel();
    setState(() => _recording = false);
  }

  String get _elapsed =>
      '${_recSecs ~/ 60}:${(_recSecs % 60).toString().padLeft(2, '0')}';

  Future<void> _attach() async {
    final chat = _snapshot?.selected;
    if (chat == null) return;
    final XFile? file;
    try {
      file = await openFile();
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text('Výběr souboru selhal: $e')));
      }
      return;
    }
    if (file == null) return;
    final caption = _composer.text.trim();
    _bridge.sendMedia(chat, file.path,
        caption: caption.isEmpty ? null : caption, replyTo: _reply?.id);
    _composer.clear();
    setState(() => _reply = null);
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
          child: ListView(
            children: [
              if (snapshot.scheduled.isNotEmpty)
                ListTile(
                  dense: true,
                  leading: const Icon(Icons.schedule),
                  title: Text('Naplánované (${snapshot.scheduled.length})'),
                  onTap: () => _scheduled(snapshot),
                ),
              for (final chat in snapshot.chats) _chatTile(snapshot, chat),
              if (snapshot.archived.isNotEmpty)
                ExpansionTile(
                  leading: const Icon(Icons.archive_outlined),
                  title: Text('Archivované (${snapshot.archived.length})'),
                  children: [
                    for (final chat in snapshot.archived)
                      _chatTile(snapshot, chat),
                  ],
                ),
            ],
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
        if (snapshot.group != null)
          Container(
            color: const Color(0xFF202C33),
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
            child: Row(
              children: [
                Expanded(
                  child: Text(
                    snapshot.group!.subject,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(fontWeight: FontWeight.w600),
                  ),
                ),
                IconButton(
                  onPressed: () => _group(snapshot),
                  icon: const Icon(Icons.info_outline, size: 18),
                  tooltip: 'Informace o skupině',
                ),
              ],
            ),
          ),
        Expanded(
          child: ListView.builder(
            reverse: true,
            padding: const EdgeInsets.all(16),
            itemCount: snapshot.messages.length + 1,
            itemBuilder: (context, index) {
              if (index == snapshot.messages.length) return _older(selected);
              final msg = snapshot.messages[snapshot.messages.length - 1 - index];
              return _bubble(msg);
            },
          ),
        ),
        Container(
          color: const Color(0xFF202C33),
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (_reply != null)
                Row(
                  children: [
                    const Icon(Icons.reply,
                        size: 16, color: Colors.lightGreenAccent),
                    const SizedBox(width: 6),
                    Expanded(
                      child: Text(
                        _reply!.text.isEmpty ? '📎' : _reply!.text,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                            fontSize: 12, color: Colors.white70),
                      ),
                    ),
                    IconButton(
                      onPressed: () => setState(() => _reply = null),
                      icon: const Icon(Icons.close, size: 16),
                      visualDensity: VisualDensity.compact,
                      tooltip: 'Zrušit odpověď',
                    ),
                  ],
                ),
              Row(
                children: [
                  IconButton(
                    onPressed: _schedule,
                    icon: const Icon(Icons.schedule),
                    tooltip: 'Naplánovat zprávu',
                  ),
                  IconButton(
                    onPressed: _attach,
                    icon: const Icon(Icons.attach_file),
                    tooltip: 'Přiložit soubor',
                  ),
                  IconButton(
                    onPressed: _newPoll,
                    icon: const Icon(Icons.poll_outlined),
                    tooltip: 'Vytvořit anketu',
                  ),
                  if (_recording) ...[
                    const Icon(Icons.fiber_manual_record,
                        color: Colors.red, size: 14),
                    Text(_elapsed, style: const TextStyle(fontSize: 12)),
                    IconButton(
                      onPressed: _recordToggle,
                      icon: const Icon(Icons.stop),
                      tooltip: 'Odeslat hlasovou zprávu',
                    ),
                    IconButton(
                      onPressed: _recordCancel,
                      icon: const Icon(Icons.close),
                      tooltip: 'Zahodit nahrávku',
                    ),
                  ] else
                    IconButton(
                      onPressed: _recordToggle,
                      icon: const Icon(Icons.mic),
                      tooltip: 'Nahrát hlasovou zprávu',
                    ),
                  if (_recording) ...[
                    const Icon(Icons.fiber_manual_record,
                        color: Colors.red, size: 14),
                    Text(_elapsed, style: const TextStyle(fontSize: 12)),
                    IconButton(
                      onPressed: _recordToggle,
                      icon: const Icon(Icons.stop),
                      tooltip: 'Odeslat hlasovou zprávu',
                    ),
                    IconButton(
                      onPressed: _recordCancel,
                      icon: const Icon(Icons.close, size: 18),
                      tooltip: 'Zahodit nahrávku',
                    ),
                  ] else
                    IconButton(
                      onPressed: _recordToggle,
                      icon: const Icon(Icons.mic),
                      tooltip: 'Nahrát hlasovou zprávu',
                    ),
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
            ],
          ),
        ),
      ],
    );
  }

  Widget _older(String chat) {
    return Center(
      child: TextButton.icon(
        onPressed: () => _bridge.more(chat),
        icon: const Icon(Icons.history, size: 16),
        label: const Text('Načíst starší'),
      ),
    );
  }

  /// Group dialog. Details live in the snapshot, so it listens to the stream:
  /// the invite link only shows up after a round trip to the phone.
  Future<void> _group(Snapshot first) async {
    final chat = first.selected;
    final known = first.group;
    if (chat == null) return;
    _bridge.requestGroupInfo(chat); // the cached copy may be stale
    final subject = TextEditingController(text: known?.subject ?? '');
    final description =
        TextEditingController(text: known?.description ?? '');
    await showDialog<void>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('Skupina'),
        content: SizedBox(
          width: 360,
          child: StreamBuilder<Snapshot>(
            stream: _bridge.snapshots,
            initialData: first,
            builder: (context, snap) {
              final snapshot = snap.data ?? first;
              final group = snapshot.group ?? known;
              if (group == null) return const Text('Načítám…');
              final admin = group.isAdmin(snapshot.self);
              return SingleChildScrollView(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    TextField(
                      controller: subject,
                      enabled: admin,
                      decoration: const InputDecoration(labelText: 'Název'),
                    ),
                    TextField(
                      controller: description,
                      enabled: admin,
                      minLines: 1,
                      maxLines: 4,
                      decoration: const InputDecoration(labelText: 'Popis'),
                    ),
                    if (admin)
                      Align(
                        alignment: Alignment.centerRight,
                        child: TextButton(
                          onPressed: () {
                            _bridge.setSubject(chat, subject.text.trim());
                            _bridge
                                .setDescription(chat, description.text.trim());
                            Navigator.pop(dialogContext);
                          },
                          child: const Text('Uložit'),
                        ),
                      ),
                    SwitchListTile(
                      dense: true,
                      contentPadding: EdgeInsets.zero,
                      value: group.announcement,
                      onChanged:
                          admin ? (v) => _bridge.setAnnounce(chat, v) : null,
                      title: const Text('Jen správci mohou psát',
                          style: TextStyle(fontSize: 13)),
                    ),
                    SwitchListTile(
                      dense: true,
                      contentPadding: EdgeInsets.zero,
                      value: group.locked,
                      onChanged:
                          admin ? (v) => _bridge.setLocked(chat, v) : null,
                      title: const Text('Uzamčená úprava informací',
                          style: TextStyle(fontSize: 13)),
                    ),
                    Row(
                      children: [
                        const Expanded(
                          child: Text('Mizející zprávy',
                              style: TextStyle(fontSize: 13)),
                        ),
                        DropdownButton<int>(
                          value: _ephemeralValues.contains(group.ephemeral)
                              ? group.ephemeral ?? 0
                              : 0,
                          items: [
                            for (final s in _ephemeralValues)
                              DropdownMenuItem(
                                  value: s, child: Text(_ephemeralLabel(s))),
                          ],
                          onChanged: admin
                              ? (v) => _bridge.setEphemeral(chat, v ?? 0)
                              : null,
                        ),
                      ],
                    ),
                    const Divider(),
                    Text('Členové (${group.participants.length})',
                        style: const TextStyle(fontWeight: FontWeight.w600)),
                    for (final jid in group.participants)
                      ListTile(
                        dense: true,
                        contentPadding: EdgeInsets.zero,
                        title: Text(_nameOf(jid)),
                        subtitle:
                            group.isAdmin(jid) ? const Text('správce') : null,
                        trailing: admin && jid != snapshot.self
                            ? IconButton(
                                onPressed: () =>
                                    _bridge.removeParticipants(chat, [jid]),
                                icon: const Icon(Icons.person_remove, size: 18),
                                tooltip: 'Odebrat',
                              )
                            : null,
                      ),
                    if (admin)
                      TextButton.icon(
                        onPressed: () => _addMembers(snapshot, group),
                        icon: const Icon(Icons.person_add, size: 18),
                        label: const Text('Přidat člena'),
                      ),
                    const Divider(),
                    Row(
                      children: [
                        Expanded(
                          child: Text(
                            group.inviteLink ?? 'Odkaz na pozvánku',
                            style: const TextStyle(fontSize: 12),
                          ),
                        ),
                        if (group.inviteLink == null)
                          TextButton(
                            onPressed: () => _bridge.inviteLink(chat),
                            child: const Text('Načíst'),
                          )
                        else
                          IconButton(
                            onPressed: () => Clipboard.setData(
                                ClipboardData(text: group.inviteLink!)),
                            icon: const Icon(Icons.copy, size: 18),
                            tooltip: 'Kopírovat odkaz',
                          ),
                      ],
                    ),
                    const Divider(),
                    TextButton.icon(
                      onPressed: () async {
                        final leave = await _confirm(
                            'Opustit skupinu',
                            'Opravdu opustit „${group.subject}“?',
                            'Opustit');
                        if (!leave) return;
                        _bridge.leaveGroup(chat);
                        if (dialogContext.mounted) {
                          Navigator.pop(dialogContext);
                        }
                      },
                      icon: const Icon(Icons.logout, size: 18),
                      label: const Text('Opustit skupinu'),
                    ),
                  ],
                ),
              );
            },
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext),
            child: const Text('Zavřít'),
          ),
        ],
      ),
    );
    subject.dispose();
    description.dispose();
  }

  Future<void> _addMembers(Snapshot snapshot, GroupInfo group) async {
    final chat = snapshot.selected;
    if (chat == null) return;
    final candidates = snapshot.contacts.entries
        .where((e) => !group.participants.contains(e.key))
        .toList();
    if (candidates.isEmpty) return;
    final picked = await showDialog<List<String>>(
      context: context,
      builder: (context) => SimpleDialog(
        title: const Text('Přidat člena'),
        children: [
          for (final c in candidates)
            SimpleDialogOption(
              onPressed: () => Navigator.pop(context, [c.key]),
              child: Text(c.value),
            ),
        ],
      ),
    );
    if (picked != null) _bridge.addParticipants(chat, picked);
  }

  Widget _bubble(Msg msg) {
    final chat = _snapshot?.selected ?? '';
    final quoted = msg.replyTo == null ? null : _snapshot?.message(msg.replyTo);
    return Align(
      alignment: msg.fromMe ? Alignment.centerRight : Alignment.centerLeft,
      child: GestureDetector(
        onLongPress: () => _menu(msg),
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
                    _nameOf(msg.sender),
                    style: const TextStyle(
                        fontSize: 11, color: Colors.lightGreenAccent),
                  ),
                ),
              if (quoted != null)
                Container(
                  width: double.infinity,
                  margin: const EdgeInsets.only(bottom: 4),
                  padding: const EdgeInsets.all(6),
                  decoration: const BoxDecoration(
                    color: Colors.black26,
                    border: Border(
                        left: BorderSide(
                            color: Color(0xFF00A884), width: 3)),
                  ),
                  child: Text(
                    quoted.text.isEmpty ? '📎' : quoted.text,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style:
                        const TextStyle(fontSize: 12, color: Colors.white70),
                  ),
                ),
              if (msg.text.isNotEmpty) Text(msg.text),
              if (msg.poll != null) _poll(msg),
              if (msg.media != null) _mediaRow(chat, msg),
              if (msg.caption != null && msg.caption!.isNotEmpty)
                Text(msg.caption!),
              Padding(
                padding: const EdgeInsets.only(top: 2),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    if (msg.edited)
                      const Text('upraveno · ',
                          style: TextStyle(
                              fontSize: 10, color: Colors.white54)),
                    Text(_clock(msg.ts),
                        style: const TextStyle(
                            fontSize: 10, color: Colors.white54)),
                  ],
                ),
              ),
              if (msg.reactions.isNotEmpty)
                Wrap(
                  spacing: 4,
                  children: [
                    for (final emoji in msg.reactions)
                      Container(
                        margin: const EdgeInsets.only(top: 4),
                        padding: const EdgeInsets.symmetric(
                            horizontal: 6, vertical: 1),
                        decoration: BoxDecoration(
                          color: Colors.black26,
                          borderRadius: BorderRadius.circular(10),
                        ),
                        child: Text(emoji,
                            style: const TextStyle(fontSize: 12)),
                      ),
                  ],
                ),
            ],
          ),
        ),
      ),
    );
  }

  String _nameOf(String jid) {
    final name = _snapshot?.contacts[jid];
    return (name == null || name.isEmpty) ? jid.split('@').first : name;
  }

  Widget _mediaRow(String chat, Msg msg) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(_mediaIcon(msg.media!), size: 16, color: Colors.white70),
        const SizedBox(width: 6),
        Text(msg.media!,
            style: const TextStyle(fontSize: 12, color: Colors.white70)),
        if (msg.downloaded)
          const Padding(
            padding: EdgeInsets.only(left: 8),
            child:
                Icon(Icons.check, size: 14, color: Colors.lightGreenAccent),
          )
        else
          TextButton(
            onPressed: () => _bridge.download(chat, msg.id),
            style: TextButton.styleFrom(
              padding: const EdgeInsets.symmetric(horizontal: 6),
              minimumSize: const Size(0, 24),
              tapTargetSize: MaterialTapTargetSize.shrinkWrap,
            ),
            child: const Text('Stáhnout', style: TextStyle(fontSize: 12)),
          ),
      ],
    );
  }

  IconData _mediaIcon(String media) {
    switch (media) {
      case 'image':
        return Icons.image;
      case 'video':
        return Icons.videocam;
      case 'audio':
        return Icons.mic;
      case 'document':
        return Icons.insert_drive_file;
      case 'sticker':
        return Icons.emoji_emotions;
      default:
        return Icons.attach_file;
    }
  }

  Widget _chatTile(Snapshot snapshot, ChatItem chat) {
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
      subtitle: chat.typing
          ? const Text('píše…',
              maxLines: 1,
              style: TextStyle(fontSize: 12, color: Colors.lightGreenAccent))
          : chat.last == null
              ? null
              : Text(chat.last!.text.isEmpty ? '📎' : chat.last!.text,
                  maxLines: 1, overflow: TextOverflow.ellipsis),
      trailing: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        crossAxisAlignment: CrossAxisAlignment.end,
        children: [
          Text(
            _clock(chat.last?.ts ?? 0),
            style: TextStyle(
                fontSize: 11,
                color: chat.unread > 0 ? Colors.lightGreenAccent : null),
          ),
          const SizedBox(height: 4),
          Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (chat.pinned)
                const Icon(Icons.push_pin, size: 13, color: Colors.white38),
              if (chat.muted)
                const Icon(Icons.volume_off, size: 13, color: Colors.white38),
              if (chat.unread > 0)
                Container(
                  margin: const EdgeInsets.only(left: 4),
                  padding:
                      const EdgeInsets.symmetric(horizontal: 5, vertical: 1),
                  decoration: BoxDecoration(
                    color: const Color(0xFF00A884),
                    borderRadius: BorderRadius.circular(9),
                  ),
                  child: Text('${chat.unread}',
                      style: const TextStyle(
                          fontSize: 11,
                          color: Colors.black,
                          fontWeight: FontWeight.bold)),
                ),
            ],
          ),
        ],
      ),
      onTap: () => _open(chat),
      onLongPress: () => _chatMenu(chat),
    );
  }

  Future<bool> _confirm(String title, String body, String action) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (dialog) => AlertDialog(
        title: Text(title),
        content: Text(body),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(dialog, false),
              child: const Text('Zrušit')),
          FilledButton(
              onPressed: () => Navigator.pop(dialog, true), child: Text(action)),
        ],
      ),
    );
    return ok ?? false;
  }

  /// Blank option rows are ignored by the backend, so extra empty fields are
  /// harmless; fewer than two filled ones is refused here to avoid a silent
  /// no-op on the bridge.
  Future<void> _newPoll() async {
    final chat = _snapshot?.selected;
    if (chat == null) return;
    final question = TextEditingController();
    final options = [TextEditingController(), TextEditingController()];
    var multi = false;
    final ok = await showDialog<bool>(
      context: context,
      builder: (dialog) => StatefulBuilder(
        builder: (dialog, setState) => AlertDialog(
          title: const Text('Nová anketa'),
          content: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                TextField(
                  controller: question,
                  autofocus: true,
                  decoration: const InputDecoration(labelText: 'Otázka'),
                ),
                for (final option in options)
                  TextField(
                    controller: option,
                    decoration: const InputDecoration(labelText: 'Volba'),
                  ),
                TextButton.icon(
                  onPressed: () =>
                      setState(() => options.add(TextEditingController())),
                  icon: const Icon(Icons.add),
                  label: const Text('Přidat volbu'),
                ),
                CheckboxListTile(
                  value: multi,
                  onChanged: (v) => setState(() => multi = v ?? false),
                  title: const Text('Více odpovědí'),
                  controlAffinity: ListTileControlAffinity.leading,
                  contentPadding: EdgeInsets.zero,
                ),
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(dialog, false),
              child: const Text('Zrušit'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(dialog, true),
              child: const Text('Vytvořit'),
            ),
          ],
        ),
      ),
    );
    final text = question.text.trim();
    final choices = options
        .map((c) => c.text.trim())
        .where((t) => t.isNotEmpty)
        .toList();
    for (final c in options) {
      c.dispose();
    }
    question.dispose();
    if (ok != true) return;
    if (text.isEmpty || choices.length < 2) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
            content: Text('Anketa potřebuje otázku a aspoň dvě volby.')));
      }
      return;
    }
    _bridge.createPoll(chat, text, choices, selectable: multi ? 0 : 1);
  }

  Widget _poll(Msg msg) {
    final poll = msg.poll!;
    return Container(
      width: double.infinity,
      margin: const EdgeInsets.only(top: 4),
      padding: const EdgeInsets.all(8),
      decoration: BoxDecoration(
        color: Colors.black26,
        borderRadius: BorderRadius.circular(6),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(poll.question,
              style: const TextStyle(fontWeight: FontWeight.bold)),
          for (final option in poll.options)
            InkWell(
              onTap: () => _vote(msg),
              child: Padding(
                padding: const EdgeInsets.symmetric(vertical: 4),
                child: Row(
                  children: [
                    Icon(
                      poll.mine.contains(option)
                          ? Icons.radio_button_checked
                          : Icons.radio_button_off,
                      size: 14,
                    ),
                    const SizedBox(width: 6),
                    Expanded(child: Text(option)),
                    Text('${poll.tallies[option] ?? 0}'),
                  ],
                ),
              ),
            ),
          Padding(
            padding: const EdgeInsets.only(top: 2),
            child: Text('${poll.voters} hlasujících',
                style: const TextStyle(fontSize: 10, color: Colors.white54)),
          ),
        ],
      ),
    );
  }

  /// One dialog for both kinds: a single choice poll replaces the selection, a
  /// multi choice one toggles up to `selectable` options (0 = unlimited).
  Future<void> _vote(Msg msg) async {
    final chat = _snapshot?.selected;
    final poll = msg.poll;
    if (chat == null || poll == null) return;
    final picked = {...poll.mine};
    final ok = await showDialog<bool>(
      context: context,
      builder: (dialog) => StatefulBuilder(
        builder: (dialog, setState) => AlertDialog(
          title: Text(poll.question),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              for (final option in poll.options)
                CheckboxListTile(
                  value: picked.contains(option),
                  onChanged: (v) => setState(() {
                    if (poll.selectable == 1) {
                      picked
                        ..clear()
                        ..add(option);
                    } else if (v ?? false) {
                      if (poll.selectable == 0 ||
                          picked.length < poll.selectable) {
                        picked.add(option);
                      }
                    } else {
                      picked.remove(option);
                    }
                  }),
                  title: Text(option),
                  controlAffinity: ListTileControlAffinity.leading,
                  contentPadding: EdgeInsets.zero,
                ),
            ],
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(dialog, false),
              child: const Text('Zrušit'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(dialog, true),
              child: const Text('Hlasovat'),
            ),
          ],
        ),
      ),
    );
    if (ok == true) _bridge.votePoll(chat, msg.id, picked.toList());
  }

  /// The backend owns the filename (`<chat>_<timestamp>.<ext>`), so only a
  /// folder is picked and only the folder can be reported back.
  Future<void> _exportChat(ChatItem chat) async {
    final format = await showDialog<String>(
      context: context,
      builder: (dialog) => SimpleDialog(
        title: const Text('Formát exportu'),
        children: [
          for (final f in const ['txt', 'json', 'html'])
            SimpleDialogOption(
              onPressed: () => Navigator.pop(dialog, f),
              child: Text(f.toUpperCase()),
            ),
        ],
      ),
    );
    if (format == null) return;
    final dir = await getDirectoryPath(confirmButtonText: 'Exportovat sem');
    _bridge.exportChat(chat.jid, format, dir: dir);
    if (!mounted || dir == null) return;
    ScaffoldMessenger.of(context)
        .showSnackBar(SnackBar(content: Text('Exportuji do $dir')));
  }

  void _chatMenu(ChatItem chat) {
    showModalBottomSheet<void>(
      context: context,
      backgroundColor: const Color(0xFF202C33),
      builder: (sheet) {
        void act(void Function() run) {
          Navigator.pop(sheet);
          run();
        }

        return SafeArea(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              ListTile(
                leading: Icon(chat.pinned
                    ? Icons.push_pin_outlined
                    : Icons.push_pin),
                title: Text(chat.pinned ? 'Odepnout' : 'Připnout'),
                onTap: () => act(() {
                  if (chat.pinned) {
                    _bridge.unpinChat(chat.jid);
                  } else {
                    _bridge.pinChat(chat.jid);
                  }
                }),
              ),
              if (chat.muted)
                ListTile(
                  leading: const Icon(Icons.volume_up),
                  title: const Text('Zrušit ztišení'),
                  onTap: () => act(() => _bridge.unmuteChat(chat.jid)),
                )
              else ...[
                ListTile(
                  leading: const Icon(Icons.volume_off),
                  title: const Text('Ztišit na 8 hodin'),
                  onTap: () => act(() => _bridge.muteChat(chat.jid, hours: 8)),
                ),
                ListTile(
                  leading: const Icon(Icons.notifications_off),
                  title: const Text('Ztišit navždy'),
                  onTap: () => act(() => _bridge.muteChat(chat.jid)),
                ),
              ],
              ListTile(
                leading: const Icon(Icons.archive_outlined),
                title: Text(chat.archived ? 'Vyjmout z archivu' : 'Archivovat'),
                onTap: () => act(() {
                  if (chat.archived) {
                    _bridge.unarchiveChat(chat.jid);
                  } else {
                    _bridge.archiveChat(chat.jid);
                  }
                }),
              ),
              ListTile(
                leading: const Icon(Icons.file_download_outlined),
                title: const Text('Exportovat chat…'),
                onTap: () => act(() => _exportChat(chat)),
              ),
              ListTile(
                leading: const Icon(Icons.cleaning_services),
                title: const Text('Vyčistit zprávy'),
                onTap: () => act(() async {
                  if (await _confirm('Vyčistit chat',
                      'Zprávy zůstanou jen na serveru WhatsApp.', 'Vyčistit')) {
                    _bridge.clearChat(chat.jid);
                  }
                }),
              ),
              ListTile(
                leading: const Icon(Icons.delete_outline, color: Colors.redAccent),
                title: const Text('Smazat chat'),
                onTap: () => act(() async {
                  if (await _confirm('Smazat chat',
                      'Chat zmizí z tohoto zařízení.', 'Smazat')) {
                    _bridge.deleteChat(chat.jid);
                  }
                }),
              ),
            ],
          ),
        );
      },
    );
  }

  Future<void> _forward(Msg msg) async {
    final snapshot = _snapshot;
    final from = snapshot?.selected;
    if (snapshot == null || from == null) return;
    final to = await showDialog<ChatItem>(
      context: context,
      builder: (dialog) => SimpleDialog(
        title: const Text('Přeposlat do'),
        children: [
          for (final chat in [...snapshot.chats, ...snapshot.archived])
            SimpleDialogOption(
              onPressed: () => Navigator.pop(dialog, chat),
              child: Text(chat.name.isEmpty ? chat.jid : chat.name),
            ),
        ],
      ),
    );
    if (to != null) _bridge.forward(from, to.jid, [msg.id]);
  }

  void _menu(Msg msg) {
    final chat = _snapshot?.selected;
    if (chat == null) return;
    showModalBottomSheet<void>(
      context: context,
      backgroundColor: const Color(0xFF202C33),
      builder: (sheet) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Wrap(
              children: [
                for (final emoji in _quickReactions)
                  IconButton(
                    tooltip: emoji,
                    onPressed: () {
                      _bridge.react(chat, msg.id, emoji);
                      Navigator.pop(sheet);
                    },
                    icon: Text(emoji,
                        style: const TextStyle(fontSize: 20)),
                  ),
              ],
            ),
            ListTile(
              leading: const Icon(Icons.reply),
              title: const Text('Odpovědět'),
              onTap: () {
                Navigator.pop(sheet);
                setState(() => _reply = msg);
              },
            ),
            if (msg.fromMe)
              ListTile(
                leading: const Icon(Icons.edit),
                title: const Text('Upravit'),
                onTap: () {
                  Navigator.pop(sheet);
                  _edit(msg);
                },
              ),
            ListTile(
              leading: const Icon(Icons.delete_outline),
              title: const Text('Smazat'),
              onTap: () {
                _bridge.deleteMessage(chat, msg.id);
                Navigator.pop(sheet);
              },
            ),
            ListTile(
              leading: const Icon(Icons.forward),
              title: const Text('Přeposlat'),
              onTap: () {
                Navigator.pop(sheet);
                _forward(msg);
              },
            ),
            if (!msg.viewOnce)
              ListTile(
                leading: const Icon(Icons.push_pin_outlined),
                title: const Text('Připíchnout na 7 dní'),
                onTap: () {
                  _bridge.pinMessage(chat, msg.id, seconds: 604800);
                  Navigator.pop(sheet);
                },
              ),
            if (msg.viewOnce && !msg.fromMe)
              ListTile(
                leading: const Icon(Icons.visibility),
                title: const Text('Zobrazit zprávu jednou'),
                onTap: () {
                  _bridge.openViewOnce(chat, msg.id);
                  Navigator.pop(sheet);
                },
              ),
            if (msg.fromMe)
              ListTile(
                leading: const Icon(Icons.delete_forever, color: Colors.redAccent),
                title: const Text('Smazat pro všechny'),
                onTap: () {
                  _bridge.revoke(chat, msg.id);
                  Navigator.pop(sheet);
                },
              ),
          ],
        ),
      ),
    );
  }

  Future<void> _edit(Msg msg) async {
    final chat = _snapshot?.selected;
    if (chat == null) return;
    final ctl = TextEditingController(text: msg.text);
    final text = await showDialog<String>(
      context: context,
      builder: (dialog) => AlertDialog(
        title: const Text('Upravit zprávu'),
        content: TextField(
          controller: ctl,
          autofocus: true,
          minLines: 1,
          maxLines: 5,
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialog),
            child: const Text('Zrušit'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(dialog, ctl.text.trim()),
            child: const Text('Uložit'),
          ),
        ],
      ),
    );
    if (text == null || text.isEmpty) return;
    _bridge.edit(chat, msg.id, text);
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
