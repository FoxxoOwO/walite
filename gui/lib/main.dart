import 'dart:async';

import 'package:material_ui/material_ui.dart';
import 'package:flutter/services.dart';
import 'package:media_kit/media_kit.dart';

import 'bridge.dart';
import 'i18n.dart';
import 'theme.dart';
import 'widgets/chat_info_panel.dart';
import 'widgets/chat_list.dart';
import 'widgets/conversation_view.dart';
import 'widgets/dialogs.dart';
import 'widgets/nav_rail.dart';
import 'widgets/pairing_view.dart';
import 'widgets/settings_dialog.dart';

/// Port the Rust bridge listens on (`warust --ui ws`).
const _port = 8787;

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  try {
    MediaKit.ensureInitialized();
  } catch (_) {
    // Allow running in headless environments where native media libs are absent.
  }
  runApp(const WarustApp());
}

class WarustApp extends StatefulWidget {
  const WarustApp({super.key});

  @override
  State<WarustApp> createState() => _WarustAppState();
}

class _WarustAppState extends State<WarustApp> with WidgetsBindingObserver {
  static const _trayChannel = MethodChannel('warust/tray');
  final _bridge = Bridge(_port);
  Snapshot? _snapshot;
  bool _linked = false;
  StreamSubscription<bool>? _linkSub;
  StreamSubscription<Snapshot>? _snapSub;
  StreamSubscription<String?>? _actSub;
  final _droppedFiles = StreamController<List<String>>.broadcast();
  String? _lastTrayKey;
  Timer? _backendWatchdog;

  void _updateBackendWatchdog(bool linked) {
    _backendWatchdog?.cancel();
    _backendWatchdog = null;
    if (!linked) {
      _backendWatchdog = Timer.periodic(const Duration(seconds: 3), (_) async {
        if (_linked || !mounted) return;
        try {
          await _trayChannel.invokeMethod<void>('ensureBackend');
        } on MissingPluginException {
          // Non-Windows or test harness.
        }
      });
    }
  }

  bool _isFocused() {
    final s = WidgetsBinding.instance.lifecycleState;
    return s == null || s == AppLifecycleState.resumed;
  }

  Future<void> _syncTray(Snapshot snap) async {
    final unread = snap.chats.fold<int>(0, (sum, c) => sum + c.unread);
    final lang = snap.prefs.language;
    final tr = Tr(lang);
    final tooltip = unread > 0
        ? 'WaLite ($unread ${tr.t('nepřečtených', 'unread')})'
        : 'WaLite';
    final key =
        '${snap.prefs.runInTray}|${snap.prefs.closeToTray}|${snap.prefs.monochromeTrayIcon}|$lang|$tooltip|$unread';
    if (key == _lastTrayKey) return;
    _lastTrayKey = key;
    try {
      await _trayChannel.invokeMethod<void>('update', {
        'runInTray': snap.prefs.runInTray,
        'closeToTray': snap.prefs.closeToTray,
        'monochrome': snap.prefs.monochromeTrayIcon,
        'lang': lang,
        'tooltip': tooltip,
        'unread': unread,
      });
    } on MissingPluginException {
      // Tests and non-Windows platforms do not mount the runner tray channel.
    }
  }

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _trayChannel.setMethodCallHandler((call) async {
      if (call.method == 'onWindowFocus') {
        _bridge.setWindowFocused(call.arguments == true);
      } else if (call.method == 'onFilesDropped' && call.arguments is List) {
        final paths = (call.arguments as List).whereType<String>().toList();
        if (paths.isNotEmpty) {
          _droppedFiles.add(paths);
        }
      }
    });
    _linkSub = _bridge.link.listen((linked) {
      if (linked) {
        _bridge.setWindowFocused(_isFocused());
      }
      _updateBackendWatchdog(linked);
      if (mounted) setState(() => _linked = linked);
    });
    _snapSub = _bridge.snapshots.listen((snap) {
      unawaited(_syncTray(snap));
      if (mounted) setState(() => _snapshot = snap);
    });
    _actSub = _bridge.windowActivations.listen((_) async {
      try {
        await _trayChannel.invokeMethod<void>('show');
      } on MissingPluginException {
        // Non-Windows or test harness.
      }
    });
    _bridge.connect();
    _updateBackendWatchdog(false);
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    _bridge.setWindowFocused(state == AppLifecycleState.resumed);
  }

  @override
  void dispose() {
    _backendWatchdog?.cancel();
    _trayChannel.setMethodCallHandler(null);
    WidgetsBinding.instance.removeObserver(this);
    _linkSub?.cancel();
    _snapSub?.cancel();
    _actSub?.cancel();
    _droppedFiles.close();
    _bridge.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final preset = _snapshot?.prefs.darkThemePreset ?? 0;
    final palette = WaPalette.forPreset(preset);

    return MaterialApp(
      title: 'WaLite',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        brightness: Brightness.dark,
        colorScheme: ColorScheme.fromSeed(
          seedColor: WaPalette.accent,
          brightness: Brightness.dark,
          surface: palette.surface,
        ),
        scaffoldBackgroundColor: palette.bg,
        dialogTheme: DialogThemeData(backgroundColor: palette.surface),
        useMaterial3: true,
      ),
      home: HomePage(
        bridge: _bridge,
        snapshot: _snapshot,
        linked: _linked,
        palette: palette,
        droppedFiles: _droppedFiles.stream,
      ),
    );
  }
}

class HomePage extends StatefulWidget {
  const HomePage({
    super.key,
    required this.bridge,
    required this.snapshot,
    required this.linked,
    required this.palette,
    this.droppedFiles,
  });

  final Bridge bridge;
  final Snapshot? snapshot;
  final bool linked;
  final WaPalette palette;
  final Stream<List<String>>? droppedFiles;

  @override
  State<HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<HomePage> {
  final _searchCtrl = TextEditingController();
  final _convKey = GlobalKey<ConversationViewState>();
  RailSection _section = RailSection.chats;
  bool _showInfoPanel = false;
  String? _pendingJumpMsgId;
  String? _highlightQuery;

  @override
  void dispose() {
    _searchCtrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final s = widget.snapshot;
    final p = widget.palette;
    final tr = Tr(s?.prefs.language ?? 'cs');

    if (!widget.linked || s == null) {
      return Scaffold(
        backgroundColor: p.bg,
        body: Center(child: _waiting(s, tr)),
      );
    }

    if (s.connection == 'qr' ||
        s.connection == 'pair' ||
        (s.self == null && s.chats.isEmpty)) {
      return Scaffold(
        backgroundColor: p.chatCanvas,
        body: PairingView(
          snapshot: s,
          bridge: widget.bridge,
          palette: p,
          tr: tr,
        ),
      );
    }

    final selectedChat = s.chat(s.selected);

    return CallbackShortcuts(
      bindings: {
        const SingleActivator(LogicalKeyboardKey.keyK, control: true): () =>
            _openPalette(s, p, tr),
        const SingleActivator(LogicalKeyboardKey.keyF, control: true): () =>
            _openSearch(
              s,
              p,
              tr,
              scope: s.selected != null ? 'current' : 'all',
            ),
        const SingleActivator(LogicalKeyboardKey.arrowDown, alt: true): () =>
            _jumpNextUnread(s),
        const SingleActivator(LogicalKeyboardKey.escape): () => _handleEscape(),
      },
      child: Focus(
        autofocus: true,
        child: Scaffold(
          backgroundColor: p.bg,
          body: Stack(
            children: [
              Row(
                children: [
                  WaNavRail(
                    snapshot: s,
                    palette: p,
                    tr: tr,
                    section: _section,
                    onSelectSection: (sec) => setState(() => _section = sec),
                    onOpenContacts: () => _openContacts(s, p, tr),
                    onOpenScheduled: () => _openScheduledManager(s, p, tr),
                    onOpenStarred: () => _openStarred(s, p, tr),
                    onOpenSearch: () => _openSearch(s, p, tr, scope: 'all'),
                    onOpenPalette: () => _openPalette(s, p, tr),
                    onOpenUpdate: () => _openUpdate(s, p, tr),
                    onOpenSettings: () =>
                        _openSettings(s, SettingsTab.profile),
                    onOpenProfile: () =>
                        _openSettings(s, SettingsTab.profile),
                  ),
                  ChatListPanel(
                    snapshot: s,
                    bridge: widget.bridge,
                    palette: p,
                    tr: tr,
                    section: _section,
                    onSelectSection: (sec) => setState(() => _section = sec),
                    searchController: _searchCtrl,
                    onOpenChat: (chat) => _openChat(chat),
                    onJumpNextUnread: () => _jumpNextUnread(s),
                    onOpenNewChat: () => _openNewChat(s, p, tr),
                    onOpenNewGroup: () => _openNewGroup(s, p, tr),
                    onOpenContacts: () => _openContacts(s, p, tr),
                    onOpenExport: (chat) => _openExport(chat, p, tr),
                    onOpenSchedule: (chat) => _openScheduleForChat(chat, p, tr),
                    onEditContactName: (chat) =>
                        _editContactName(chat, p, tr),
                    onOpenChatInfo: (chat) {
                      _openChat(chat);
                      setState(() => _showInfoPanel = true);
                    },
                    onOpenSearch: () => _openSearch(s, p, tr, scope: 'all'),
                    onOpenPalette: () => _openPalette(s, p, tr),
                    onOpenSettings: () =>
                        _openSettings(s, SettingsTab.profile),
                    onConfirm: _confirm,
                  ),
                  Expanded(
                    child: ConversationView(
                      key: _convKey,
                      snapshot: s,
                      bridge: widget.bridge,
                      palette: p,
                      tr: tr,
                      showInfoPanel: _showInfoPanel,
                      onToggleInfoPanel: () =>
                          setState(() => _showInfoPanel = !_showInfoPanel),
                      onOpenSearchInChat: () =>
                          _openSearch(s, p, tr, scope: 'current'),
                      onOpenExport: (chat) => _openExport(chat, p, tr),
                      onOpenScheduledManager: () =>
                          _openScheduledManager(s, p, tr),
                      onEditContactName: (chat) =>
                          _editContactName(chat, p, tr),
                      onConfirm: _confirm,
                      jumpMessageId: _pendingJumpMsgId,
                      onJumpHandled: () =>
                          setState(() => _pendingJumpMsgId = null),
                      droppedFiles: widget.droppedFiles,
                      highlightQuery: _highlightQuery,
                      onClearHighlight: () =>
                          setState(() => _highlightQuery = null),
                    ),
                  ),
                  if (_showInfoPanel && selectedChat != null)
                    ChatInfoPanel(
                      snapshot: s,
                      chat: selectedChat,
                      bridge: widget.bridge,
                      palette: p,
                      tr: tr,
                      onClose: () => setState(() => _showInfoPanel = false),
                      onJumpToMessage: (msgId) =>
                          _convKey.currentState?.jumpToMessage(msgId),
                      onOpenAddMembers: (group) =>
                          _openAddMembers(s, selectedChat.jid, group, p, tr),
                      onEditContactName: (chat) =>
                          _editContactName(chat, p, tr),
                      onOpenExport: (chat) => _openExport(chat, p, tr),
                      onConfirm: _confirm,
                    ),
                ],
              ),
              if (s.call != null)
                CallOverlay(
                  call: s.call!,
                  bridge: widget.bridge,
                  palette: p,
                  tr: tr,
                ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _waiting(Snapshot? snapshot, Tr tr) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        const CircularProgressIndicator(color: WaPalette.accent),
        const SizedBox(height: 16),
        Text(
          widget.linked
              ? '${tr.t('Načítám stav…', 'Loading state…')} (${snapshot?.connection ?? 'start'})'
              : tr.t('Čekám na backend na portu $_port…',
                  'Waiting for backend on port $_port…'),
        ),
        const SizedBox(height: 8),
        Text(
          tr.t('Spusť: warust --ui ws', 'Run: warust --ui ws'),
          style: const TextStyle(color: WaPalette.textSecondary, fontSize: 12),
        ),
      ],
    );
  }

  void _openChat(ChatItem chat) {
    widget.bridge.select(chat.jid);
    if (chat.unread > 0) widget.bridge.markRead(chat.jid);
  }

  void _jumpNextUnread(Snapshot s) {
    final list = s.chats.where((c) => c.unread > 0).toList();
    if (list.isEmpty) return;
    final currentIdx = list.indexWhere((c) => c.jid == s.selected);
    final next = list[(currentIdx + 1) % list.length];
    _openChat(next);
  }

  void _handleEscape() {
    if (_convKey.currentState?.closeTopmostOverlay() ?? false) return;
    if (_showInfoPanel) {
      setState(() => _showInfoPanel = false);
    }
  }

  void _openNewChat(Snapshot s, WaPalette p, Tr tr) {
    showDialog<void>(
      context: context,
      builder: (_) => NewChatDialog(
        bridge: widget.bridge,
        palette: p,
        tr: tr,
        onOpenNewGroup: () => _openNewGroup(s, p, tr),
        onOpenContacts: () => _openContacts(s, p, tr),
      ),
    );
  }

  void _openNewGroup(Snapshot s, WaPalette p, Tr tr) {
    showDialog<void>(
      context: context,
      builder: (_) => GroupMemberPickerDialog(
        snapshot: s,
        bridge: widget.bridge,
        palette: p,
        tr: tr,
      ),
    );
  }

  void _openAddMembers(
    Snapshot s,
    String chatJid,
    GroupInfo group,
    WaPalette p,
    Tr tr,
  ) {
    showDialog<void>(
      context: context,
      builder: (_) => GroupMemberPickerDialog(
        snapshot: s,
        bridge: widget.bridge,
        palette: p,
        tr: tr,
        existingGroupChatJid: chatJid,
        excludeJids: group.participants.toSet(),
      ),
    );
  }

  void _openContacts(Snapshot s, WaPalette p, Tr tr) {
    showDialog<void>(
      context: context,
      builder: (_) => ContactsDialog(
        snapshot: s,
        bridge: widget.bridge,
        palette: p,
        tr: tr,
      ),
    );
  }

  void _openSearch(
    Snapshot s,
    WaPalette p,
    Tr tr, {
    required String scope,
  }) {
    showDialog<void>(
      context: context,
      builder: (_) => SearchMessagesDialog(
        snapshot: s,
        bridge: widget.bridge,
        palette: p,
        tr: tr,
        initialScope: scope,
        onJump: (chatJid, msgId, query) {
          if (s.selected != chatJid || s.message(msgId) == null) {
            widget.bridge.jumpToMessage(chatJid, msgId);
          }
          setState(() {
            _pendingJumpMsgId = msgId;
            _highlightQuery = query;
          });
        },
      ),
    );
  }

  void _openStarred(Snapshot s, WaPalette p, Tr tr) {
    showDialog<void>(
      context: context,
      builder: (_) => StarredMessagesDialog(
        snapshot: s,
        bridge: widget.bridge,
        palette: p,
        tr: tr,
        onJump: (chatJid, msgId) {
          if (s.selected != chatJid || s.message(msgId) == null) {
            widget.bridge.jumpToMessage(chatJid, msgId);
          }
          setState(() {
            _pendingJumpMsgId = msgId;
            _highlightQuery = null;
          });
        },
      ),
    );
  }

  void _openPalette(Snapshot s, WaPalette p, Tr tr) {
    showDialog<void>(
      context: context,
      builder: (_) => CommandPaletteDialog(
        snapshot: s,
        palette: p,
        tr: tr,
        onSelect: _openChat,
      ),
    );
  }

  void _openExport(ChatItem chat, WaPalette p, Tr tr) {
    showDialog<void>(
      context: context,
      builder: (_) => ExportChatDialog(
        chat: chat,
        bridge: widget.bridge,
        palette: p,
        tr: tr,
      ),
    );
  }

  void _openScheduleForChat(ChatItem chat, WaPalette p, Tr tr) {
    showDialog<void>(
      context: context,
      builder: (_) => ScheduleMessageDialog(
        chatJid: chat.jid,
        chatName: chat.name.isEmpty ? formatJidPhone(chat.jid) : chat.name,
        initialText: '',
        bridge: widget.bridge,
        palette: p,
        tr: tr,
      ),
    );
  }

  void _openScheduledManager(Snapshot first, WaPalette p, Tr tr) {
    String nameOf(Snapshot snap, String jid) =>
        snap.chat(jid)?.name ?? snap.contacts[jid] ?? formatJidPhone(jid);
    String fmt(DateTime at) {
      final local = at.toLocal();
      return '${local.day}. ${local.month}. ${local.hour.toString().padLeft(2, '0')}:${local.minute.toString().padLeft(2, '0')}';
    }

    showDialog<void>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        backgroundColor: p.surface,
        title: Text(tr.t('Naplánované zprávy', 'Scheduled messages')),
        content: SizedBox(
          width: 440,
          child: StreamBuilder<Snapshot>(
            stream: widget.bridge.snapshots,
            initialData: first,
            builder: (context, snap) {
              final cur = snap.data ?? first;
              final list = cur.scheduled;
              if (list.isEmpty) {
                return Text(tr.t('Nic nečeká.', 'No scheduled messages.'));
              }
              return SingleChildScrollView(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    for (final item in list)
                      ListTile(
                        dense: true,
                        title: Text(item.text,
                            maxLines: 2, overflow: TextOverflow.ellipsis),
                        subtitle: Text([
                          nameOf(cur, item.chat),
                          fmt(item.at),
                          if (item.status == 'failed')
                            tr.t('selhalo', 'failed'),
                        ].join(' · ')),
                        trailing: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            IconButton(
                              onPressed: () =>
                                  widget.bridge.sendScheduledNow(item.id),
                              icon: const Icon(Icons.send, size: 18),
                              tooltip: tr.t('Odeslat teď', 'Send now'),
                            ),
                            IconButton(
                              onPressed: () =>
                                  widget.bridge.cancelScheduled(item.id),
                              icon:
                                  const Icon(Icons.delete_outline, size: 18),
                              tooltip: tr.t('Zrušit', 'Cancel'),
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
            child: Text(tr.t('Zavřít', 'Close')),
          ),
        ],
      ),
    );
  }

  Future<void> _editContactName(ChatItem chat, WaPalette p, Tr tr) async {
    final ctl = TextEditingController(text: chat.name);
    final saved = await showDialog<String>(
      context: context,
      builder: (dialog) => AlertDialog(
        backgroundColor: p.surface,
        title: Text(tr.t('Upravit jméno kontaktu', 'Edit contact name')),
        content: TextField(
          controller: ctl,
          autofocus: true,
          onSubmitted: (v) => Navigator.pop(dialog, v.trim()),
          decoration: InputDecoration(
            labelText: tr.t('Jméno', 'Name'),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialog),
            child: Text(tr.t('Zrušit', 'Cancel')),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(dialog, ctl.text.trim()),
            style:
                FilledButton.styleFrom(backgroundColor: WaPalette.accentDark),
            child: Text(tr.t('Uložit', 'Save')),
          ),
        ],
      ),
    );
    ctl.dispose();
    if (saved != null && saved.isNotEmpty) {
      widget.bridge.saveContact(chat.jid, saved);
    }
  }

  void _openUpdate(Snapshot s, WaPalette p, Tr tr) {
    showDialog<void>(
      context: context,
      builder: (_) => UpdateDialog(
        initialSnapshot: s,
        bridge: widget.bridge,
        palette: p,
        tr: tr,
      ),
    );
  }

  void _openSettings(Snapshot s, SettingsTab initialTab) {
    showDialog<void>(
      context: context,
      builder: (_) => SettingsDialog(
        initialSnapshot: s,
        bridge: widget.bridge,
        initialTab: initialTab,
        onOpenUpdate: () {
          Navigator.pop(context);
          final latest = widget.snapshot ?? s;
          _openUpdate(latest, widget.palette, Tr(latest.prefs.language));
        },
        onConfirm: _confirm,
      ),
    );
  }

  Future<bool> _confirm(String title, String body, String action) async {
    final tr = Tr(widget.snapshot?.prefs.language ?? 'cs');
    final ok = await showDialog<bool>(
      context: context,
      builder: (dialog) => AlertDialog(
        backgroundColor: widget.palette.surface,
        title: Text(title),
        content: Text(body),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialog, false),
            child: Text(tr.t('Zrušit', 'Cancel')),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(dialog, true),
            style: FilledButton.styleFrom(backgroundColor: WaPalette.danger),
            child: Text(action),
          ),
        ],
      ),
    );
    return ok ?? false;
  }
}
