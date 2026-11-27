import 'dart:async';
import 'dart:io';

import 'package:file_selector/file_selector.dart';
import 'package:flutter/gestures.dart';
import 'package:material_ui/material_ui.dart';
import 'package:flutter/services.dart';

import '../bridge.dart';
import '../i18n.dart';
import '../theme.dart';
import 'avatar.dart';
import 'dialogs.dart';
import 'emoji_sticker_picker.dart';
import 'wallpaper.dart';

class ConversationView extends StatefulWidget {
  const ConversationView({
    super.key,
    required this.snapshot,
    required this.bridge,
    required this.palette,
    required this.tr,
    required this.showInfoPanel,
    required this.onToggleInfoPanel,
    required this.onOpenSearchInChat,
    required this.onOpenExport,
    required this.onOpenScheduledManager,
    required this.onEditContactName,
    required this.onConfirm,
    this.jumpMessageId,
    this.onJumpHandled,
    this.droppedFiles,
    this.highlightQuery,
    this.onClearHighlight,
  });

  final Snapshot snapshot;
  final Bridge bridge;
  final WaPalette palette;
  final Tr tr;
  final bool showInfoPanel;
  final VoidCallback onToggleInfoPanel;
  final VoidCallback onOpenSearchInChat;
  final ValueChanged<ChatItem> onOpenExport;
  final VoidCallback onOpenScheduledManager;
  final ValueChanged<ChatItem> onEditContactName;
  final Future<bool> Function(String title, String body, String action)
      onConfirm;
  final String? jumpMessageId;
  final VoidCallback? onJumpHandled;
  final Stream<List<String>>? droppedFiles;
  final String? highlightQuery;
  final VoidCallback? onClearHighlight;

  @override
  State<ConversationView> createState() => ConversationViewState();
}

class ConversationViewState extends State<ConversationView> {
  static final _alnumRegex = RegExp(r'[A-Za-z0-9]');
  static final _wsRegex = RegExp(r'\s');
  static final _nonDigitRegex = RegExp(r'\D');

  final _composerCtrl = TextEditingController();
  final _composerFocus = FocusNode();
  final _scrollCtrl = ScrollController();

  Msg? _reply;
  String? _editingMessageId;
  String? _pendingAttachmentPath;
  final List<String> _extraAttachments = [];
  bool _sendViewOnce = false;
  final Set<String> _selectedMsgIds = {};
  final Map<String, List<String>> _multiPollDrafts = {};
  final Map<String, GlobalKey> _msgKeys = {};

  bool _showEmojiPicker = false;
  bool _showStickerPicker = false;
  String? _reactionPickerTargetId;
  bool _showJumpToBottom = false;

  bool _recording = false;
  int _recSecs = 0;
  Timer? _recTimer;
  Timer? _typingTimer;
  Timer? _draftTimer;
  bool _typingActive = false;

  String? _flashMessageId;
  Timer? _flashTimer;
  String? _pendingScrollMsgId;
  String? _pendingScrollChat;
  String? _lastSelectedChat;
  StreamSubscription<ClipboardImageResult>? _clipSub;
  StreamSubscription<List<String>>? _dropSub;

  @override
  void initState() {
    super.initState();
    _scrollCtrl.addListener(_onScroll);
    _clipSub = widget.bridge.clipboardImages.listen((res) {
      if (!mounted) return;
      if (res.path != null && res.path!.isNotEmpty) {
        setState(() {
          _pendingAttachmentPath = res.path;
          _extraAttachments.clear();
          _sendViewOnce = false;
        });
      } else if (res.error != null) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(res.error!)),
        );
      }
    });
    _dropSub = widget.droppedFiles?.listen(_onFilesDropped);
    _syncSelectedChat(widget.snapshot);
  }

  void _onFilesDropped(List<String> paths) {
    final valid = paths.where((p) => File(p).existsSync()).toList();
    if (valid.isEmpty || !mounted || widget.snapshot.selected == null) return;
    setState(() {
      if (_pendingAttachmentPath == null) {
        _pendingAttachmentPath = valid.first;
        _extraAttachments.addAll(valid.skip(1));
      } else {
        _extraAttachments.addAll(valid);
      }
      _sendViewOnce = false;
    });
    _composerFocus.requestFocus();
  }

  @override
  void didUpdateWidget(covariant ConversationView oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.snapshot.selected != _lastSelectedChat) {
      _syncSelectedChat(widget.snapshot);
    }
    if (widget.jumpMessageId != null &&
        widget.jumpMessageId != oldWidget.jumpMessageId) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) jumpToMessage(widget.jumpMessageId!);
        widget.onJumpHandled?.call();
      });
    } else if (_pendingScrollMsgId != null &&
        widget.snapshot.selected == _pendingScrollChat &&
        widget.snapshot.message(_pendingScrollMsgId) != null) {
      final target = _pendingScrollMsgId!;
      _pendingScrollMsgId = null;
      _pendingScrollChat = null;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) jumpToMessage(target);
      });
    }
  }

  void _syncSelectedChat(Snapshot s) {
    final prev = _lastSelectedChat;
    if (prev != null && prev != s.selected && _typingActive) {
      widget.bridge.sendTyping(prev, false);
      _typingActive = false;
    }
    _draftTimer?.cancel();
    _typingTimer?.cancel();
    if (_recording) {
      _recTimer?.cancel();
      widget.bridge.recordCancel();
      _recording = false;
      _recSecs = 0;
    }
    _lastSelectedChat = s.selected;
    if (prev != s.selected) {
      _msgKeys.clear();
    }
    _selectedMsgIds.clear();
    _multiPollDrafts.clear();
    _reply = null;
    _editingMessageId = null;
    _pendingAttachmentPath = null;
    _extraAttachments.clear();
    _sendViewOnce = false;
    _showEmojiPicker = false;
    _showStickerPicker = false;
    _reactionPickerTargetId = null;
    _msgKeys.clear();
    if (s.selected != _pendingScrollChat) {
      _pendingScrollMsgId = null;
      _pendingScrollChat = null;
    }
    final draft = s.selected != null ? s.chat(s.selected)?.draft : null;
    _composerCtrl.text = draft ?? '';
    _composerCtrl.selection =
        TextSelection.collapsed(offset: _composerCtrl.text.length);
  }

  @override
  void dispose() {
    _recTimer?.cancel();
    _typingTimer?.cancel();
    _draftTimer?.cancel();
    _flashTimer?.cancel();
    _clipSub?.cancel();
    _dropSub?.cancel();
    _scrollCtrl.dispose();
    _composerCtrl.dispose();
    _composerFocus.dispose();
    super.dispose();
  }

  void _onScroll() {
    if (!_scrollCtrl.hasClients) return;
    final show = _scrollCtrl.offset > 90;
    if (show != _showJumpToBottom) {
      setState(() => _showJumpToBottom = show);
    }
  }

  void jumpToMessage(String id) {
    final chat = widget.snapshot.selected;
    if (chat == null) return;
    final idx = widget.snapshot.messages.indexWhere((m) => m.id == id);
    if (idx == -1) {
      _pendingScrollMsgId = id;
      _pendingScrollChat = chat;
      widget.bridge.jumpToMessage(chat, id);
      setState(() => _flashMessageId = id);
      return;
    }
    final key = _msgKeys[id];
    if (key?.currentContext != null) {
      Scrollable.ensureVisible(
        key!.currentContext!,
        duration: const Duration(milliseconds: 280),
        alignment: 0.45,
      );
    } else if (_scrollCtrl.hasClients) {
      // Approximate reverse index jump when row is off-screen
      final reverseIdx = widget.snapshot.messages.length - 1 - idx;
      final est = (reverseIdx * 68.0).clamp(
        0.0,
        _scrollCtrl.position.maxScrollExtent,
      );
      _scrollCtrl.animateTo(
        est,
        duration: const Duration(milliseconds: 260),
        curve: Curves.easeOut,
      );
      Future.delayed(const Duration(milliseconds: 280), () {
        if (!mounted) return;
        final ctx = _msgKeys[id]?.currentContext;
        if (ctx != null && ctx.mounted) {
          Scrollable.ensureVisible(ctx,
              duration: const Duration(milliseconds: 200), alignment: 0.45);
        }
      });
    }
    setState(() => _flashMessageId = id);
    _flashTimer?.cancel();
    _flashTimer = Timer(const Duration(milliseconds: 2500), () {
      if (mounted) setState(() => _flashMessageId = null);
    });
  }

  bool closeTopmostOverlay() {
    if (_showEmojiPicker || _showStickerPicker) {
      setState(() {
        _showEmojiPicker = false;
        _showStickerPicker = false;
        _reactionPickerTargetId = null;
      });
      return true;
    }
    if (_selectedMsgIds.isNotEmpty) {
      setState(() => _selectedMsgIds.clear());
      return true;
    }
    if (_editingMessageId != null) {
      setState(() {
        _editingMessageId = null;
        _composerCtrl.clear();
      });
      return true;
    }
    if (_reply != null) {
      setState(() => _reply = null);
      return true;
    }
    if (_pendingAttachmentPath != null) {
      setState(() {
        _pendingAttachmentPath = null;
        _extraAttachments.clear();
        _sendViewOnce = false;
      });
      return true;
    }
    return false;
  }

  @override
  Widget build(BuildContext context) {
    final s = widget.snapshot;
    final selected = s.selected;
    if (selected == null) {
      return _welcomeScreen(widget.palette, widget.tr);
    }
    final chat = s.chat(selected);

    return Stack(
      children: [
        Column(
          children: [
            if (_selectedMsgIds.isNotEmpty)
              _selectionBar(s, selected, widget.palette, widget.tr)
            else
              _header(s, selected, chat, widget.palette, widget.tr),
            if (s.pinnedMessage != null)
              _pinnedBanner(s, selected, s.pinnedMessage!, widget.palette, widget.tr),
            if (widget.highlightQuery != null &&
                widget.highlightQuery!.trim().isNotEmpty)
              Container(
                padding:
                    const EdgeInsets.symmetric(horizontal: 14, vertical: 6),
                decoration: BoxDecoration(
                  color: widget.palette.surface,
                  border: Border(
                    bottom: BorderSide(color: widget.palette.divider),
                  ),
                ),
                child: Row(
                  children: [
                    const Icon(Icons.search,
                        size: 15, color: WaPalette.accentBright),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        '${widget.tr.t('Zvýrazněno hledání', 'Highlighting')}: "${widget.highlightQuery!.trim()}"',
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                            fontSize: 12.5, color: WaPalette.textSecondary),
                      ),
                    ),
                    IconButton(
                      visualDensity: VisualDensity.compact,
                      tooltip: widget.tr.t('Zrušit zvýraznění', 'Clear highlight'),
                      onPressed: widget.onClearHighlight,
                      icon: const Icon(Icons.close, size: 15),
                    ),
                  ],
                ),
              ),
            Expanded(
              child: WaWallpaper(
                backgroundColor: widget.palette.chatCanvas,
                customColorHex: s.prefs.chatWallpaperColor,
                wallpaperPath: s.prefs.chatWallpaperPath,
                showDoodles: s.prefs.chatWallpaperDoodles,
                child: Stack(
                  children: [
                    ListView.builder(
                      controller: _scrollCtrl,
                      reverse: true,
                      padding: const EdgeInsets.symmetric(
                          horizontal: 24, vertical: 14),
                      itemCount: s.messages.length + 1,
                      itemBuilder: (context, index) {
                        if (index == s.messages.length) {
                          return _olderButton(selected, widget.tr);
                        }
                        final chronologicalIdx = s.messages.length - 1 - index;
                        final msg = s.messages[chronologicalIdx];
                        final prev = chronologicalIdx > 0
                            ? s.messages[chronologicalIdx - 1]
                            : null;
                        final showDate = prev == null ||
                            !_sameDay(prev.ts, msg.ts);
                        final isFirstInRun = prev == null ||
                            showDate ||
                            prev.fromMe != msg.fromMe ||
                            prev.sender != msg.sender;
                        return Column(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            if (showDate)
                              _datePill(msg.ts, widget.palette, widget.tr),
                            _bubble(
                              s,
                              selected,
                              chat,
                              msg,
                              isFirstInRun: isFirstInRun,
                            ),
                          ],
                        );
                      },
                    ),
                    if (_showJumpToBottom)
                      Positioned(
                        right: 18,
                        bottom: 16,
                        child: FloatingActionButton.small(
                          backgroundColor: widget.palette.surface,
                          foregroundColor: WaPalette.textPrimary,
                          tooltip: widget.tr.t('Skočit na nejnovější zprávy',
                              'Jump to newest messages'),
                          onPressed: () {
                            _scrollCtrl.animateTo(
                              0,
                              duration: const Duration(milliseconds: 260),
                              curve: Curves.easeOut,
                            );
                          },
                          child: const Icon(Icons.keyboard_arrow_down, size: 22),
                        ),
                      ),
                  ],
                ),
              ),
            ),
            if (_selectedMsgIds.isEmpty)
              _composerArea(s, selected, chat, widget.palette, widget.tr),
          ],
        ),
        if (_showEmojiPicker)
          Positioned(
            left: 16,
            bottom: 70,
            child: EmojiPickerPanel(
              palette: widget.palette,
              tr: widget.tr,
              title: _reactionPickerTargetId != null
                  ? widget.tr.t('Vybrat reakci', 'Pick reaction')
                  : widget.tr.t('Emoji', 'Emoji'),
              onClose: () => setState(() {
                _showEmojiPicker = false;
                _reactionPickerTargetId = null;
              }),
              onSelect: (emoji) {
                final targetId = _reactionPickerTargetId;
                if (targetId != null) {
                  widget.bridge.react(selected, targetId, emoji);
                  setState(() {
                    _showEmojiPicker = false;
                    _reactionPickerTargetId = null;
                  });
                } else {
                  final sel = _composerCtrl.selection;
                  final text = _composerCtrl.text;
                  final insertAt = sel.isValid ? sel.start : text.length;
                  final next = text.replaceRange(
                    insertAt,
                    sel.isValid ? sel.end : text.length,
                    emoji,
                  );
                  _composerCtrl.text = next;
                  _composerCtrl.selection =
                      TextSelection.collapsed(offset: insertAt + emoji.length);
                  _onComposerChanged(selected, next);
                }
              },
            ),
          ),
        if (_showStickerPicker)
          Positioned(
            left: 16,
            bottom: 70,
            child: StickerPickerPanel(
              stickers: s.stickers,
              palette: widget.palette,
              tr: widget.tr,
              onClose: () => setState(() => _showStickerPicker = false),
              onSendSticker: (path) {
                widget.bridge.sendMedia(selected, path);
                setState(() => _showStickerPicker = false);
              },
            ),
          ),
      ],
    );
  }

  Widget _welcomeScreen(WaPalette p, Tr tr) {
    return Container(
      color: p.bg,
      alignment: Alignment.center,
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 440),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Image.asset(
              'assets/icon.png',
              width: 80,
              height: 80,
              filterQuality: FilterQuality.medium,
              errorBuilder: (_, _, _) => Container(
                width: 84,
                height: 84,
                decoration: BoxDecoration(
                  color: WaPalette.accent.withValues(alpha: 0.14),
                  shape: BoxShape.circle,
                ),
                child: const Icon(
                  Icons.chat_rounded,
                  size: 42,
                  color: WaPalette.accent,
                ),
              ),
            ),
            const SizedBox(height: 22),
            const Text(
              'WaLite',
              style: TextStyle(
                fontSize: 28,
                fontWeight: FontWeight.w300,
                color: WaPalette.textPrimary,
              ),
            ),
            const SizedBox(height: 10),
            Text(
              tr.t(
                'Vyber chat ze seznamu vlevo nebo začni novou konverzaci tlačítkem +.',
                'Select a chat from the list or start a new conversation with +.',
              ),
              textAlign: TextAlign.center,
              style: const TextStyle(
                  fontSize: 14, color: WaPalette.textSecondary, height: 1.45),
            ),
            const SizedBox(height: 28),
            Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                const Icon(Icons.lock_outline,
                    size: 14, color: WaPalette.textSecondary),
                const SizedBox(width: 6),
                Text(
                  tr.t('Vaše osobní zprávy jsou šifrované end-to-end',
                      'Your personal messages are end-to-end encrypted'),
                  style: const TextStyle(
                      fontSize: 12, color: WaPalette.textSecondary),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Widget _selectionBar(Snapshot s, String selected, WaPalette p, Tr tr) {
    return Container(
      height: 58,
      color: p.surface,
      padding: const EdgeInsets.symmetric(horizontal: 14),
      child: Row(
        children: [
          IconButton(
            onPressed: () => setState(() => _selectedMsgIds.clear()),
            icon: const Icon(Icons.close),
          ),
          const SizedBox(width: 8),
          Text(
            '${tr.t('Vybráno', 'Selected')}: ${_selectedMsgIds.length}',
            style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w600),
          ),
          const Spacer(),
          TextButton.icon(
            onPressed: () => _forwardIds(s, selected, _selectedMsgIds.toList()),
            icon: const Icon(Icons.forward, size: 18),
            label: Text(tr.t('Přeposlat', 'Forward')),
          ),
          const SizedBox(width: 8),
          TextButton.icon(
            onPressed: () {
              for (final id in _selectedMsgIds) {
                widget.bridge.deleteMessage(selected, id);
              }
              setState(() => _selectedMsgIds.clear());
            },
            icon: const Icon(Icons.delete_outline,
                size: 18, color: WaPalette.danger),
            label: Text(tr.t('Smazat', 'Delete'),
                style: const TextStyle(color: WaPalette.danger)),
          ),
        ],
      ),
    );
  }

  Widget _header(
    Snapshot s,
    String selected,
    ChatItem? chat,
    WaPalette p,
    Tr tr,
  ) {
    final group = s.group;
    final name = group?.subject ?? _title(s, selected);
    final isTyping = chat?.typing ?? false;
    final subtitle = group != null
        ? '${group.participants.length} ${tr.t('účastníků', 'participants')}'
        : _presenceText(s, selected, tr);
    final online = s.presence[selected]?.online ?? false;

    return Container(
      height: 58,
      color: p.surface,
      padding: const EdgeInsets.symmetric(horizontal: 14),
      child: Row(
        children: [
          Expanded(
            child: InkWell(
              onTap: widget.onToggleInfoPanel,
              borderRadius: BorderRadius.circular(8),
              child: Row(
                children: [
                  WaAvatar(
                    name: name,
                    avatarPath: chat?.avatar,
                    radius: 19,
                    isGroup: group != null,
                    online: online,
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      mainAxisAlignment: MainAxisAlignment.center,
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          name,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(
                            fontSize: 15.5,
                            fontWeight: FontWeight.w600,
                            color: WaPalette.textPrimary,
                          ),
                        ),
                        if (isTyping)
                          Row(
                            children: [
                              Text(
                                tr.t('píše', 'typing'),
                                style: const TextStyle(
                                    fontSize: 12,
                                    color: WaPalette.accentBright),
                              ),
                              const SizedBox(width: 4),
                              const BouncingDots(size: 3.5),
                            ],
                          )
                        else
                          Text(
                            subtitle,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                              fontSize: 12,
                              color: online
                                  ? WaPalette.accentBright
                                  : WaPalette.textSecondary,
                            ),
                          ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          ),
          IconButton(
            onPressed: () => widget.bridge.startCall(selected, isVideo: false),
            icon: const Icon(Icons.call_outlined,
                size: 20, color: WaPalette.textSecondary),
            tooltip: '${tr.t('Hlasový hovor s', 'Voice call')} $name',
          ),
          IconButton(
            onPressed: () => widget.bridge.startCall(selected, isVideo: true),
            icon: const Icon(Icons.videocam_outlined,
                size: 21, color: WaPalette.textSecondary),
            tooltip: '${tr.t('Videohovor s', 'Video call')} $name',
          ),
          IconButton(
            onPressed: widget.onOpenSearchInChat,
            icon: const Icon(Icons.search,
                size: 20, color: WaPalette.textSecondary),
            tooltip: tr.t('Hledat v tomto chatu', 'Search in this chat'),
          ),
          IconButton(
            onPressed: widget.onToggleInfoPanel,
            icon: Icon(
              widget.showInfoPanel ? Icons.info : Icons.info_outline,
              size: 20,
              color: widget.showInfoPanel
                  ? WaPalette.accent
                  : WaPalette.textSecondary,
            ),
            tooltip: group != null
                ? tr.t('Informace o skupině', 'Group info')
                : tr.t('Informace o kontaktu', 'Contact info'),
          ),
          if (chat != null)
            PopupMenuButton<String>(
              icon: const Icon(Icons.more_vert,
                  size: 20, color: WaPalette.textSecondary),
              color: p.surfaceElevated,
              onSelected: (act) async {
                switch (act) {
                  case 'info':
                    widget.onToggleInfoPanel();
                  case 'search':
                    widget.onOpenSearchInChat();
                  case 'export':
                    widget.onOpenExport(chat);
                  case 'schedule':
                    _schedule(selected, name);
                  case 'edit_contact':
                    widget.onEditContactName(chat);
                  case 'pin':
                    chat.pinned
                        ? widget.bridge.unpinChat(chat.jid)
                        : widget.bridge.pinChat(chat.jid);
                  case 'clear':
                    if (await widget.onConfirm(
                      tr.t('Vyčistit zprávy', 'Clear messages'),
                      tr.t('Historie zmizí jen u tebe.',
                          'History is cleared locally only.'),
                      tr.t('Vyčistit', 'Clear'),
                    )) {
                      widget.bridge.clearChat(chat.jid);
                    }
                }
              },
              itemBuilder: (_) => [
                PopupMenuItem(
                  value: 'info',
                  child: Text(tr.t('Info o chatu', 'Chat info')),
                ),
                PopupMenuItem(
                  value: 'search',
                  child: Text(tr.t('Hledat v chatu', 'Search in chat')),
                ),
                PopupMenuItem(
                  value: 'schedule',
                  child: Text(tr.t('Naplánovat zprávu', 'Schedule message')),
                ),
                PopupMenuItem(
                  value: 'export',
                  child: Text(tr.t('Exportovat chat…', 'Export chat…')),
                ),
                if (!chat.group)
                  PopupMenuItem(
                    value: 'edit_contact',
                    child: Text(
                        tr.t('Upravit jméno kontaktu', 'Edit contact name')),
                  ),
                PopupMenuItem(
                  value: 'pin',
                  child: Text(chat.pinned
                      ? tr.t('Odepnout chat', 'Unpin chat')
                      : tr.t('Připnout chat', 'Pin chat')),
                ),
                const PopupMenuDivider(),
                PopupMenuItem(
                  value: 'clear',
                  child: Text(
                    tr.t('Vyčistit zprávy', 'Clear messages'),
                    style: const TextStyle(color: WaPalette.danger),
                  ),
                ),
              ],
            ),
        ],
      ),
    );
  }

  Widget _pinnedBanner(
    Snapshot s,
    String chatJid,
    PinnedMsg pin,
    WaPalette p,
    Tr tr,
  ) {
    final target = s.message(pin.id);
    final preview = target == null
        ? tr.t('Připnutá zpráva', 'Pinned message')
        : (target.text.trim().isNotEmpty
            ? target.text.trim()
            : '📎 ${target.media ?? tr.t('Zpráva', 'Message')}');
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 7),
      decoration: BoxDecoration(
        color: p.pillBg,
        border: Border(bottom: BorderSide(color: p.divider)),
      ),
      child: Row(
        children: [
          const Icon(Icons.push_pin, size: 16, color: WaPalette.accent),
          const SizedBox(width: 10),
          Expanded(
            child: InkWell(
              onTap: () => jumpToMessage(pin.id),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    tr.t('Připnutá zpráva', 'Pinned message'),
                    style: const TextStyle(
                      fontSize: 11,
                      fontWeight: FontWeight.w600,
                      color: WaPalette.accent,
                    ),
                  ),
                  Text(
                    preview,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                        fontSize: 12.5, color: WaPalette.textPrimary),
                  ),
                ],
              ),
            ),
          ),
          IconButton(
            onPressed: () => widget.bridge.pinMessage(chatJid, pin.id),
            icon: const Icon(Icons.close, size: 16),
            visualDensity: VisualDensity.compact,
            tooltip: tr.t('Odepnout', 'Unpin'),
          ),
        ],
      ),
    );
  }

  Widget _olderButton(String chatJid, Tr tr) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: Center(
        child: OutlinedButton.icon(
          onPressed: () => widget.bridge.more(chatJid),
          icon: const Icon(Icons.history, size: 16),
          label: Text(tr.t('Načíst starší zprávy z telefonu',
              'Load older messages from phone')),
        ),
      ),
    );
  }

  Widget _datePill(int millis, WaPalette p, Tr tr) {
    final t = DateTime.fromMillisecondsSinceEpoch(millis);
    final now = DateTime.now();
    final today = DateTime(now.year, now.month, now.day);
    final day = DateTime(t.year, t.month, t.day);
    final diff = today.difference(day).inDays;
    final label = diff == 0
        ? tr.t('Dnes', 'Today')
        : diff == 1
            ? tr.t('Včera', 'Yesterday')
            : '${t.day}. ${t.month}. ${t.year}';

    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 10),
      child: Center(
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 5),
          decoration: BoxDecoration(
            color: p.pillBg,
            borderRadius: BorderRadius.circular(8),
            boxShadow: const [
              BoxShadow(color: Colors.black26, blurRadius: 3),
            ],
          ),
          child: Text(
            label,
            style: const TextStyle(
              fontSize: 11.5,
              color: WaPalette.textSecondary,
              fontWeight: FontWeight.w500,
            ),
          ),
        ),
      ),
    );
  }

  Widget _bubble(
    Snapshot s,
    String chatJid,
    ChatItem? chat,
    Msg msg, {
    required bool isFirstInRun,
  }) {
    final p = widget.palette;
    final tr = widget.tr;
    final fontSize = s.prefs.fontSize;
    final isSelected = _selectedMsgIds.contains(msg.id);
    final isFlashing = _flashMessageId == msg.id;
    final quoted = msg.replyTo == null ? null : s.message(msg.replyTo);
    final key = _msgKeys.putIfAbsent(msg.id, () => GlobalKey());

    final emojiCount = msg.media == null &&
            msg.poll == null &&
            msg.replyTo == null
        ? _countEmojiOnly(msg.text)
        : null;
    final isSticker = msg.media == 'sticker' && !msg.viewOnce;
    final isTransparent = emojiCount != null || isSticker;
    final bubbleColor = isTransparent
        ? Colors.transparent
        : (msg.fromMe ? p.outgoingBubble : p.incomingBubble);

    final radius = BorderRadius.only(
      topLeft: Radius.circular(!msg.fromMe && isFirstInRun ? 2 : 10),
      topRight: Radius.circular(msg.fromMe && isFirstInRun ? 2 : 10),
      bottomLeft: const Radius.circular(10),
      bottomRight: const Radius.circular(10),
    );

    return Container(
      key: key,
      margin: EdgeInsets.only(
        top: isFirstInRun ? 6 : 2,
        bottom: msg.reactionDetails.isNotEmpty ? 14 : 2,
      ),
      padding: isSelected || isFlashing
          ? const EdgeInsets.symmetric(horizontal: 6, vertical: 2)
          : EdgeInsets.zero,
      decoration: BoxDecoration(
        color: isSelected
            ? WaPalette.accent.withValues(alpha: 0.16)
            : isFlashing
                ? WaPalette.accent.withValues(alpha: 0.22)
                : Colors.transparent,
        borderRadius: BorderRadius.circular(10),
      ),
      child: _HoverableBubble(
        fromMe: msg.fromMe,
        onReactTap: (pos) => _showQuickReactionBar(s, chatJid, msg, pos, p, tr),
        onMenuTap: (pos) => _showMsgContextMenu(s, chatJid, msg, pos, p, tr),
        onBubbleTap: _selectedMsgIds.isNotEmpty
            ? () => _toggleSelection(msg.id)
            : null,
        child: Stack(
          clipBehavior: Clip.none,
          children: [
              if (isFirstInRun && !isTransparent)
                Positioned(
                  top: 0,
                  left: msg.fromMe ? null : -7,
                  right: msg.fromMe ? -7 : null,
                  child: CustomPaint(
                    size: const Size(9, 12),
                    painter: _BubbleTailPainter(
                      color: bubbleColor,
                      fromMe: msg.fromMe,
                    ),
                  ),
                ),
              Container(
                constraints: const BoxConstraints(maxWidth: 500),
                padding: isTransparent
                    ? const EdgeInsets.all(4)
                    : const EdgeInsets.fromLTRB(10, 7, 10, 6),
                decoration: BoxDecoration(
                  color: bubbleColor,
                  borderRadius: radius,
                  border: isFlashing
                      ? Border.all(color: WaPalette.accent, width: 1.5)
                      : null,
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    if (!msg.fromMe && (chat?.group ?? false) && isFirstInRun)
                      Padding(
                        padding: const EdgeInsets.only(bottom: 3),
                        child: Text(
                          _nameOf(s, msg.sender),
                          style: TextStyle(
                            fontSize: 12,
                            fontWeight: FontWeight.w600,
                            color: senderColor(msg.sender),
                          ),
                        ),
                      ),
                    if (quoted != null)
                      _replyQuote(s, quoted, p, tr),
                    if (msg.media != null) _mediaContent(chatJid, msg, p, tr),
                    if (msg.contactCards.isNotEmpty)
                      _contactCardsView(msg.contactCards, p, tr),
                    if (msg.text.isNotEmpty &&
                        !_isRedundantMediaLabel(msg) &&
                        !(msg.contactCards.isNotEmpty &&
                            (msg.text.startsWith('👤') ||
                                msg.text == msg.contactCards.first.name)))
                      _messageText(
                        msg.text,
                        fontSize: switch (emojiCount) {
                          1 => 42,
                          2 => 30,
                          3 => 24,
                          _ => fontSize,
                        },
                      ),
                    if (msg.poll != null) _pollCard(chatJid, msg, p, tr),
                    if (msg.caption != null && msg.caption!.isNotEmpty)
                      Padding(
                        padding: const EdgeInsets.only(top: 4),
                        child: _messageText(msg.caption!, fontSize: fontSize),
                      ),
                    const SizedBox(height: 2),
                    Align(
                      alignment: Alignment.bottomRight,
                      widthFactor: 1,
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          if (msg.starred)
                            const Padding(
                              padding: EdgeInsets.only(right: 4),
                              child: Icon(Icons.star_rounded,
                                  size: 12, color: Colors.amber),
                            ),
                          if (s.pinnedMessage?.id == msg.id)
                            const Padding(
                              padding: EdgeInsets.only(right: 4),
                              child: Icon(Icons.push_pin,
                                  size: 11, color: WaPalette.textSecondary),
                            ),
                          if (msg.edited)
                            Text(
                              '${tr.t('upraveno', 'edited')} · ',
                              style: const TextStyle(
                                fontSize: 10.5,
                                color: Colors.white60,
                              ),
                            ),
                          Text(
                            _clock(msg.ts),
                            style: const TextStyle(
                              fontSize: 10.5,
                              color: Colors.white60,
                            ),
                          ),
                          if (msg.fromMe) ...[
                            const SizedBox(width: 4),
                            StatusTicks(status: msg.status, size: 14),
                          ],
                        ],
                      ),
                    ),
                  ],
                ),
              ),
              if (msg.reactionDetails.isNotEmpty)
                Positioned(
                  bottom: -14,
                  right: msg.fromMe ? 8 : null,
                  left: msg.fromMe ? null : 8,
                  child: InkWell(
                    onTap: () => showDialog<void>(
                      context: context,
                      builder: (_) => ReactionDetailDialog(
                        msg: msg,
                        snapshot: s,
                        chatJid: chatJid,
                        bridge: widget.bridge,
                        palette: p,
                        tr: tr,
                      ),
                    ),
                    borderRadius: BorderRadius.circular(12),
                    child: Container(
                      padding: const EdgeInsets.symmetric(
                          horizontal: 7, vertical: 2),
                      decoration: BoxDecoration(
                        color: p.surfaceElevated,
                        borderRadius: BorderRadius.circular(12),
                        border: Border.all(color: p.chatCanvas, width: 1.5),
                      ),
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Text(msg.reactions.take(3).join(),
                              style: const TextStyle(fontSize: 12.5)),
                          if (msg.reactionDetails.length > 1) ...[
                            const SizedBox(width: 4),
                            Text(
                              '${msg.reactionDetails.length}',
                              style: const TextStyle(
                                fontSize: 11,
                                color: WaPalette.textSecondary,
                              ),
                            ),
                          ],
                        ],
                      ),
                    ),
                  ),
                ),
            ],
          ),
        ),
    );
  }

  Widget _replyQuote(Snapshot s, Msg quoted, WaPalette p, Tr tr) {
    final sender = quoted.fromMe
        ? tr.t('Vy', 'You')
        : _nameOf(s, quoted.sender);
    final body = quoted.text.trim().isNotEmpty
        ? quoted.text.trim()
        : (quoted.caption?.trim().isNotEmpty == true
            ? quoted.caption!.trim()
            : '📎 ${quoted.media ?? tr.t('Zpráva', 'Message')}');
    return InkWell(
      onTap: () => jumpToMessage(quoted.id),
      borderRadius: BorderRadius.circular(6),
      child: Container(
        margin: const EdgeInsets.only(bottom: 5),
        padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 6),
        decoration: BoxDecoration(
          color: p.quoteBg,
          borderRadius: BorderRadius.circular(6),
          border: Border(
            left: BorderSide(color: senderColor(quoted.sender), width: 3.5),
          ),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              sender,
              style: TextStyle(
                fontSize: 11.5,
                fontWeight: FontWeight.w600,
                color: senderColor(quoted.sender),
              ),
            ),
            const SizedBox(height: 1),
            Text(
              body,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(
                fontSize: 12.5,
                color: WaPalette.textSecondary,
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _mediaContent(String chatJid, Msg msg, WaPalette p, Tr tr) {
    if (msg.viewOnce) {
      return InkWell(
        onTap: msg.viewOnceOpened
            ? null
            : () => showDialog<void>(
                  context: context,
                  builder: (_) => ViewOnceModal(
                    chatJid: chatJid,
                    messageId: msg.id,
                    bridge: widget.bridge,
                    initialSnapshot: widget.snapshot,
                    palette: p,
                    tr: tr,
                  ),
                ),
        borderRadius: BorderRadius.circular(8),
        child: Container(
          width: 230,
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 14),
          margin: const EdgeInsets.only(bottom: 4),
          decoration: BoxDecoration(
            color: Colors.black26,
            borderRadius: BorderRadius.circular(8),
          ),
          child: Row(
            children: [
              Icon(
                msg.viewOnceOpened
                    ? Icons.check_circle_outline
                    : Icons.looks_one_outlined,
                color: msg.viewOnceOpened
                    ? WaPalette.textSecondary
                    : WaPalette.accentBright,
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Text(
                  msg.viewOnceOpened
                      ? tr.t('Jednorázové médium zobrazeno', 'Opened')
                      : '${msg.media == 'video' ? tr.t('Video', 'Video') : tr.t('Fotka', 'Photo')} (${tr.t('zobrazit jednou', 'view once')})',
                  style: const TextStyle(fontSize: 13),
                ),
              ),
            ],
          ),
        ),
      );
    }

    final file = msg.mediaPath != null ? File(msg.mediaPath!) : null;
    final hasFile = msg.downloaded && file != null;

    switch (msg.media) {
      case 'sticker':
        if (hasFile) {
          return SizedBox(
            width: 140,
            height: 140,
            child: Image.file(
              file,
              fit: BoxFit.contain,
              cacheWidth: 280,
              errorBuilder: (_, _, _) => _downloadTile(
                chatJid,
                msg,
                Icons.sticky_note_2_outlined,
                tr.t('Samolepka', 'Sticker'),
                tr,
              ),
            ),
          );
        }
        return _downloadTile(chatJid, msg, Icons.sticky_note_2_outlined,
            tr.t('Samolepka', 'Sticker'), tr);

      case 'image':
        Widget? img;
        if (hasFile) {
          img = Image.file(
            file,
            fit: BoxFit.cover,
            cacheWidth: 560,
            errorBuilder: (_, _, _) => const Icon(
              Icons.broken_image_outlined,
              size: 38,
              color: WaPalette.textSecondary,
            ),
          );
        } else {
          final tb = msg.thumbBytes;
          if (tb != null) {
            img = Image.memory(tb, fit: BoxFit.cover);
          }
        }
        return Padding(
          padding: const EdgeInsets.only(bottom: 4),
          child: InkWell(
            onTap: () {
              if (hasFile) {
                showDialog<void>(
                  context: context,
                  builder: (_) => ImageLightboxDialog(
                    path: file.path,
                    caption: msg.caption,
                    bridge: widget.bridge,
                    tr: tr,
                  ),
                );
              } else {
                widget.bridge.download(chatJid, msg.id);
              }
            },
            borderRadius: BorderRadius.circular(8),
            child: ClipRRect(
              borderRadius: BorderRadius.circular(8),
              child: ConstrainedBox(
                constraints:
                    const BoxConstraints(maxWidth: 280, maxHeight: 280, minWidth: 180, minHeight: 120),
                child: Stack(
                  alignment: Alignment.center,
                  children: [
                    if (img != null)
                      Positioned.fill(child: img)
                    else
                      Container(
                        width: 240,
                        height: 140,
                        color: Colors.black26,
                        child: const Icon(Icons.image_outlined,
                            size: 38, color: WaPalette.textSecondary),
                      ),
                    if (!hasFile)
                      Container(
                        padding: const EdgeInsets.symmetric(
                            horizontal: 12, vertical: 8),
                        decoration: BoxDecoration(
                          color: Colors.black54,
                          borderRadius: BorderRadius.circular(20),
                        ),
                        child: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            const Icon(Icons.download,
                                size: 17, color: Colors.white),
                            const SizedBox(width: 6),
                            Text(
                              msg.fileSize != null
                                  ? formatBytes(msg.fileSize!)
                                  : tr.t('Stáhnout', 'Download'),
                              style: const TextStyle(
                                  fontSize: 12, color: Colors.white),
                            ),
                          ],
                        ),
                      ),
                  ],
                ),
              ),
            ),
          ),
        );

      case 'video':
        final tb = msg.thumbBytes;
        final Widget? thumb =
            tb != null ? Image.memory(tb, fit: BoxFit.cover) : null;
        final isGif = msg.gifPlayback;
        return Padding(
          padding: const EdgeInsets.only(bottom: 4),
          child: InkWell(
            onTap: () {
              if (hasFile) {
                showDialog<void>(
                  context: context,
                  builder: (_) => VideoLightboxDialog(
                    path: file.path,
                    caption: msg.caption,
                    loopMuted: isGif,
                    bridge: widget.bridge,
                    tr: tr,
                  ),
                );
              } else {
                widget.bridge.download(chatJid, msg.id);
              }
            },
            borderRadius: BorderRadius.circular(8),
            child: ClipRRect(
              borderRadius: BorderRadius.circular(8),
              child: SizedBox(
                width: 260,
                height: 165,
                child: Stack(
                  alignment: Alignment.center,
                  children: [
                    if (hasFile && isGif)
                      Positioned.fill(
                        child: InlineGifVideo(
                          path: file.path,
                          fallback: thumb ?? Container(color: Colors.black38),
                        ),
                      )
                    else if (thumb != null)
                      Positioned.fill(child: thumb)
                    else
                      Container(color: Colors.black38),
                    if (!(hasFile && isGif))
                      Container(
                        width: 48,
                        height: 48,
                        decoration: const BoxDecoration(
                          color: Colors.black54,
                          shape: BoxShape.circle,
                        ),
                        child: Icon(
                          hasFile ? Icons.play_arrow : Icons.download,
                          color: Colors.white,
                          size: 28,
                        ),
                      ),
                    if (isGif)
                      Positioned(
                        top: 8,
                        left: 8,
                        child: Container(
                          padding: const EdgeInsets.symmetric(
                              horizontal: 6, vertical: 2),
                          decoration: BoxDecoration(
                            color: Colors.black54,
                            borderRadius: BorderRadius.circular(5),
                          ),
                          child: const Text(
                            'GIF',
                            style: TextStyle(
                                fontSize: 10.5,
                                fontWeight: FontWeight.w700,
                                color: Colors.white),
                          ),
                        ),
                      ),
                    if (!hasFile && msg.fileSize != null)
                      Positioned(
                        bottom: 8,
                        left: 8,
                        child: Container(
                          padding: const EdgeInsets.symmetric(
                              horizontal: 7, vertical: 2),
                          decoration: BoxDecoration(
                            color: Colors.black54,
                            borderRadius: BorderRadius.circular(6),
                          ),
                          child: Text(
                            formatBytes(msg.fileSize!),
                            style: const TextStyle(
                                fontSize: 11, color: Colors.white),
                          ),
                        ),
                      ),
                  ],
                ),
              ),
            ),
          ),
        );

      case 'audio':
      case 'voice':
        return _voiceAudioPlayer(chatJid, msg, hasFile, p, tr);

      case 'document':
        final name = hasFile
            ? file.path.split(Platform.pathSeparator).last
            : (msg.caption?.isNotEmpty == true
                ? msg.caption!
                : (msg.text.isNotEmpty
                    ? msg.text
                    : tr.t('Dokument', 'Document')));
        return InkWell(
          onTap: () {
            if (hasFile) {
              widget.bridge.openFile(file.path);
            } else {
              widget.bridge.download(chatJid, msg.id);
            }
          },
          borderRadius: BorderRadius.circular(8),
          child: Container(
            width: 260,
            margin: const EdgeInsets.only(bottom: 4),
            padding: const EdgeInsets.all(10),
            decoration: BoxDecoration(
              color: Colors.black26,
              borderRadius: BorderRadius.circular(8),
            ),
            child: Row(
              children: [
                Container(
                  width: 36,
                  height: 36,
                  decoration: BoxDecoration(
                    color: const Color(0xFF7F66FF),
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: const Icon(Icons.insert_drive_file,
                      color: Colors.white, size: 20),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        name,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                            fontSize: 13.5, fontWeight: FontWeight.w500),
                      ),
                      Text(
                        [
                          if (msg.fileSize != null) formatBytes(msg.fileSize!),
                          hasFile
                              ? tr.t('Otevřít', 'Open')
                              : tr.t('Stáhnout', 'Download'),
                        ].join(' • '),
                        style: TextStyle(
                          fontSize: 11,
                          color: hasFile
                              ? WaPalette.accentBright
                              : WaPalette.textSecondary,
                        ),
                      ),
                    ],
                  ),
                ),
                Icon(
                  hasFile ? Icons.open_in_new : Icons.download,
                  size: 18,
                  color: WaPalette.textSecondary,
                ),
              ],
            ),
          ),
        );

      default:
        return _downloadTile(chatJid, msg, Icons.attach_file, msg.media!, tr);
    }
  }

  Widget _downloadTile(
      String chatJid, Msg msg, IconData icon, String label, Tr tr) {
    return Container(
      margin: const EdgeInsets.only(bottom: 4),
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
      decoration: BoxDecoration(
        color: Colors.black26,
        borderRadius: BorderRadius.circular(8),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 18, color: WaPalette.textSecondary),
          const SizedBox(width: 8),
          Text(label, style: const TextStyle(fontSize: 13)),
          const SizedBox(width: 8),
          TextButton(
            onPressed: () => widget.bridge.download(chatJid, msg.id),
            child: Text(tr.t('Stáhnout', 'Download')),
          ),
        ],
      ),
    );
  }

  Widget _voiceAudioPlayer(
      String chatJid, Msg msg, bool hasFile, WaPalette p, Tr tr) {
    final audio = widget.snapshot.audio;
    final isCurrent = audio != null && audio.playingId == msg.id;
    final isPlaying = isCurrent && !audio.paused;
    final frac = isCurrent && (audio.durMs ?? 0) > 0
        ? (audio.posMs / audio.durMs!).clamp(0.0, 1.0)
        : 0.0;

    String fmtMs(int ms) {
      final total = ms ~/ 1000;
      return '${total ~/ 60}:${(total % 60).toString().padLeft(2, '0')}';
    }

    final timeLabel = isCurrent
        ? (audio.durMs != null
            ? '${fmtMs(audio.posMs)} / ${fmtMs(audio.durMs!)}'
            : fmtMs(audio.posMs))
        : (msg.fileSize != null && !hasFile
            ? formatBytes(msg.fileSize!)
            : tr.t('Hlasová zpráva', 'Voice message'));

    return Container(
      width: 248,
      margin: const EdgeInsets.only(bottom: 4),
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 7),
      decoration: BoxDecoration(
        color: Colors.black26,
        borderRadius: BorderRadius.circular(10),
      ),
      child: Row(
        children: [
          InkWell(
            onTap: () {
              if (!hasFile) {
                widget.bridge.download(chatJid, msg.id);
              } else if (isCurrent) {
                isPlaying
                    ? widget.bridge.audioPause()
                    : widget.bridge.audioResume();
              } else {
                widget.bridge.audioToggle(msg.id, msg.mediaPath!);
              }
            },
            borderRadius: BorderRadius.circular(18),
            child: Container(
              width: 34,
              height: 34,
              decoration: const BoxDecoration(
                color: WaPalette.accent,
                shape: BoxShape.circle,
              ),
              child: Icon(
                !hasFile
                    ? Icons.download
                    : isPlaying
                        ? Icons.pause
                        : Icons.play_arrow,
                color: Colors.black,
                size: 20,
              ),
            ),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                SizedBox(
                  height: 20,
                  child: Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    crossAxisAlignment: CrossAxisAlignment.center,
                    children: List.generate(24, (i) {
                      final t = i / 23;
                      final seed =
                          ((i * 12.9898 + 78.233) % 1.0).abs();
                      final h = 4.0 + 13.0 * ((seed * 3.7) % 1.0);
                      final played = isCurrent && t <= frac;
                      return Container(
                        width: 2.5,
                        height: h,
                        decoration: BoxDecoration(
                          color: !hasFile
                              ? Colors.white24
                              : played
                                  ? WaPalette.accentBright
                                  : WaPalette.textSecondary,
                          borderRadius: BorderRadius.circular(2),
                        ),
                      );
                    }),
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  timeLabel,
                  style: const TextStyle(
                      fontSize: 10.5, color: WaPalette.textSecondary),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _pollCard(String chatJid, Msg msg, WaPalette p, Tr tr) {
    final poll = msg.poll!;
    final isMulti = poll.selectable != 1;
    final draft = _multiPollDrafts[msg.id] ?? poll.mine;
    final totalVotes = poll.tallies.values.fold<int>(0, (a, b) => a + b);

    return Container(
      width: 265,
      margin: const EdgeInsets.only(top: 4),
      padding: const EdgeInsets.all(8),
      decoration: BoxDecoration(
        color: Colors.black26,
        borderRadius: BorderRadius.circular(8),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Text(
                poll.quiz
                    ? '🧠 ${tr.t('Kvíz', 'Quiz')}'
                    : '📊 ${tr.t('Anketa', 'Poll')}',
                style: const TextStyle(
                    fontSize: 11,
                    color: WaPalette.accentBright,
                    fontWeight: FontWeight.w600),
              ),
              const Spacer(),
              Text(
                '${poll.voters} ${tr.t('hlasujících', 'voters')}',
                style: const TextStyle(
                    fontSize: 10.5, color: WaPalette.textSecondary),
              ),
            ],
          ),
          const SizedBox(height: 5),
          Text(poll.question,
              style:
                  const TextStyle(fontWeight: FontWeight.bold, fontSize: 14)),
          const SizedBox(height: 6),
          for (final opt in poll.options)
            Padding(
              padding: const EdgeInsets.only(bottom: 5),
              child: InkWell(
                onTap: () {
                  if (!isMulti) {
                    final next =
                        poll.mine.contains(opt) ? <String>[] : [opt];
                    widget.bridge.votePoll(chatJid, msg.id, next);
                  } else {
                    setState(() {
                      final list = [...draft];
                      if (list.contains(opt)) {
                        list.remove(opt);
                      } else if (poll.selectable == 0 ||
                          list.length < poll.selectable) {
                        list.add(opt);
                      }
                      _multiPollDrafts[msg.id] = list;
                    });
                  }
                },
                borderRadius: BorderRadius.circular(6),
                child: Container(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
                  decoration: BoxDecoration(
                    color: Colors.white.withValues(alpha: 0.05),
                    borderRadius: BorderRadius.circular(6),
                    border: draft.contains(opt)
                        ? Border.all(color: WaPalette.accent)
                        : null,
                  ),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        children: [
                          Icon(
                            draft.contains(opt)
                                ? (isMulti
                                    ? Icons.check_box
                                    : Icons.radio_button_checked)
                                : (isMulti
                                    ? Icons.check_box_outline_blank
                                    : Icons.radio_button_off),
                            size: 15,
                            color: draft.contains(opt)
                                ? WaPalette.accentBright
                                : WaPalette.textSecondary,
                          ),
                          const SizedBox(width: 7),
                          Expanded(
                              child: Text(opt,
                                  style: const TextStyle(fontSize: 13))),
                          Text('${poll.tallies[opt] ?? 0}',
                              style: const TextStyle(
                                  fontSize: 11.5,
                                  color: WaPalette.textSecondary)),
                        ],
                      ),
                      if (totalVotes > 0) ...[
                        const SizedBox(height: 4),
                        ClipRRect(
                          borderRadius: BorderRadius.circular(3),
                          child: LinearProgressIndicator(
                            value: (poll.tallies[opt] ?? 0) / totalVotes,
                            minHeight: 4,
                            backgroundColor: Colors.white12,
                            color: draft.contains(opt)
                                ? WaPalette.accent
                                : Colors.white38,
                          ),
                        ),
                      ],
                    ],
                  ),
                ),
              ),
            ),
          if (isMulti)
            SizedBox(
              width: double.infinity,
              child: FilledButton(
                onPressed: () {
                  widget.bridge.votePoll(chatJid, msg.id, draft);
                  setState(() => _multiPollDrafts.remove(msg.id));
                },
                style: FilledButton.styleFrom(
                  backgroundColor: WaPalette.accentDark,
                  visualDensity: VisualDensity.compact,
                ),
                child: Text(tr.t('Hlasovat', 'Vote')),
              ),
            ),
        ],
      ),
    );
  }

  /// Renders shared vCard contact cards inside a bubble with quick Chat/Copy actions.
  Widget _contactCardsView(
      List<ContactCard> cards, WaPalette p, Tr tr) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        for (final card in cards)
          Container(
            width: 260,
            margin: const EdgeInsets.only(bottom: 4),
            padding: const EdgeInsets.all(10),
            decoration: BoxDecoration(
              color: Colors.black26,
              borderRadius: BorderRadius.circular(8),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    WaAvatar(
                      name: card.name,
                      radius: 18,
                      backgroundColor: WaPalette.accentDark,
                    ),
                    const SizedBox(width: 10),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            card.name,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(
                                fontWeight: FontWeight.w600, fontSize: 13.5),
                          ),
                          if (card.phone.isNotEmpty)
                            Text(
                              card.phone,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: const TextStyle(
                                  fontSize: 12,
                                  color: WaPalette.textSecondary),
                            ),
                        ],
                      ),
                    ),
                  ],
                ),
                if (card.waid != null || card.phone.isNotEmpty) ...[
                  const SizedBox(height: 8),
                  Row(
                    children: [
                      Expanded(
                        child: OutlinedButton.icon(
                          onPressed: () {
                            final digits = (card.waid != null &&
                                    card.waid!.isNotEmpty)
                                ? card.waid!
                                : card.phone.replaceAll(_nonDigitRegex, '');
                            if (digits.isNotEmpty) {
                              widget.bridge.startChat(digits);
                            }
                          },
                          style: OutlinedButton.styleFrom(
                            padding: const EdgeInsets.symmetric(vertical: 4),
                            minimumSize: const Size(0, 28),
                            side: BorderSide(color: p.divider),
                          ),
                          icon: const Icon(Icons.chat_outlined, size: 14),
                          label: Text(
                            tr.t('Zahájit chat', 'Message'),
                            style: const TextStyle(fontSize: 12),
                          ),
                        ),
                      ),
                      if (card.phone.isNotEmpty) ...[
                        const SizedBox(width: 6),
                        IconButton(
                          tooltip: tr.t('Kopírovat číslo', 'Copy number'),
                          visualDensity: VisualDensity.compact,
                          onPressed: () {
                            Clipboard.setData(ClipboardData(text: card.phone));
                            ScaffoldMessenger.of(context).showSnackBar(
                              SnackBar(
                                content: Text(tr.t('Číslo zkopírováno',
                                    'Number copied')),
                                duration: const Duration(seconds: 2),
                              ),
                            );
                          },
                          icon: const Icon(Icons.copy, size: 15),
                        ),
                      ],
                    ],
                  ),
                ],
              ],
            ),
          ),
      ],
    );
  }

  /// Renders plain text with highlighted `@mentions`, clickable `http(s)` URLs
  /// and active search-match highlights.
  Widget _messageText(String text, {required double fontSize}) {
    return _MessageRichText(
      text: text,
      fontSize: fontSize,
      highlightQuery: widget.highlightQuery,
      onOpenUrl: widget.bridge.openFile,
    );
  }

  Widget _composerArea(
    Snapshot s,
    String chatJid,
    ChatItem? chat,
    WaPalette p,
    Tr tr,
  ) {
    final pendingSched = s.scheduled
        .where((m) => m.chat == chatJid && m.status == 'pending')
        .length;

    return Container(
      color: p.surface,
      padding: const EdgeInsets.fromLTRB(10, 6, 10, 8),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (pendingSched > 0)
            Container(
              margin: const EdgeInsets.only(bottom: 6),
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 5),
              decoration: BoxDecoration(
                color: WaPalette.accent.withValues(alpha: 0.14),
                borderRadius: BorderRadius.circular(8),
              ),
              child: Row(
                children: [
                  const Icon(Icons.schedule,
                      size: 15, color: WaPalette.accentBright),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      '$pendingSched ${tr.t('naplánovaných zpráv pro tento chat', 'scheduled message(s) for this chat')}',
                      style: const TextStyle(
                          fontSize: 12, color: WaPalette.accentBright),
                    ),
                  ),
                  TextButton(
                    onPressed: widget.onOpenScheduledManager,
                    style: TextButton.styleFrom(
                      visualDensity: VisualDensity.compact,
                    ),
                    child: Text(tr.t('Zobrazit', 'View')),
                  ),
                ],
              ),
            ),
          if (_editingMessageId != null)
            _banner(
              p,
              Icons.edit,
              tr.t('Upravit zprávu', 'Edit message'),
              '',
              () => setState(() {
                _editingMessageId = null;
                _composerCtrl.clear();
              }),
            ),
          if (_reply != null)
            _banner(
              p,
              Icons.reply,
              _reply!.fromMe ? tr.t('Vy', 'You') : _nameOf(s, _reply!.sender),
              _reply!.text.isEmpty ? '📎' : _reply!.text,
              () => setState(() => _reply = null),
            ),
          if (_pendingAttachmentPath != null)
            _attachmentBanner(p, tr),
          if (chat?.group ?? false)
            ValueListenableBuilder<TextEditingValue>(
              valueListenable: _composerCtrl,
              builder: (_, val, _) {
                final mentionQuery = _activeMentionQuery(val.text);
                if (mentionQuery == null) return const SizedBox.shrink();
                final lowerQuery = mentionQuery.toLowerCase();
                final mentionCandidates =
                    (s.group?.participants ?? const <String>[])
                        .where((j) => !sameJidUser(j, s.self))
                        .map((j) => (j, _nameOf(s, j)))
                        .where((pair) =>
                            lowerQuery.isEmpty ||
                            pair.$2.toLowerCase().contains(lowerQuery))
                        .take(6)
                        .toList();
                if (mentionCandidates.isEmpty) return const SizedBox.shrink();
                return Container(
                  margin: const EdgeInsets.only(bottom: 6),
                  padding:
                      const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                  decoration: BoxDecoration(
                    color: p.bg,
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: Row(
                    children: [
                      const Text('@',
                          style: TextStyle(
                              color: WaPalette.accent,
                              fontWeight: FontWeight.bold)),
                      const SizedBox(width: 8),
                      Expanded(
                        child: Wrap(
                          spacing: 6,
                          children: [
                            for (final (_, name) in mentionCandidates)
                              ActionChip(
                                label: Text(name,
                                    style: const TextStyle(fontSize: 12)),
                                visualDensity: VisualDensity.compact,
                                onPressed: () {
                                  final updated =
                                      _applyMention(_composerCtrl.text, name);
                                  _composerCtrl.text = updated;
                                  _composerCtrl.selection =
                                      TextSelection.collapsed(
                                          offset: updated.length);
                                  _onComposerChanged(chatJid, updated);
                                },
                              ),
                          ],
                        ),
                      ),
                    ],
                  ),
                );
              },
            ),
          if (_recording)
            _recordingBar(chatJid, tr)
          else
            _composerRow(s, chatJid, p, tr),
        ],
      ),
    );
  }

  Widget _banner(
    WaPalette p,
    IconData icon,
    String title,
    String body,
    VoidCallback onCancel,
  ) {
    return Container(
      margin: const EdgeInsets.only(bottom: 6),
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 7),
      decoration: BoxDecoration(
        color: p.bg,
        borderRadius: BorderRadius.circular(8),
        border: const Border(
          left: BorderSide(color: WaPalette.accent, width: 3.5),
        ),
      ),
      child: Row(
        children: [
          Icon(icon, size: 16, color: WaPalette.accent),
          const SizedBox(width: 8),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(title,
                    style: const TextStyle(
                        fontSize: 12,
                        fontWeight: FontWeight.w600,
                        color: WaPalette.accent)),
                if (body.isNotEmpty)
                  Text(body,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                          fontSize: 12, color: WaPalette.textSecondary)),
              ],
            ),
          ),
          IconButton(
            onPressed: onCancel,
            icon: const Icon(Icons.close, size: 16),
            visualDensity: VisualDensity.compact,
          ),
        ],
      ),
    );
  }

  Widget _attachmentBanner(WaPalette p, Tr tr) {
    final path = _pendingAttachmentPath!;
    final name = path.split(Platform.pathSeparator).last;
    final file = File(path);
    final ext = name.split('.').last.toLowerCase();
    final isImg = ['jpg', 'jpeg', 'png', 'gif', 'bmp', 'webp'].contains(ext);
    late final String size;
    try {
      size = formatBytes(file.lengthSync());
    } catch (_) {
      size = '';
    }

    return Container(
      margin: const EdgeInsets.only(bottom: 6),
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 7),
      decoration: BoxDecoration(
        color: p.bg,
        borderRadius: BorderRadius.circular(8),
      ),
      child: Row(
        children: [
          if (isImg)
            ClipRRect(
              borderRadius: BorderRadius.circular(6),
              child: Image.file(
                file,
                width: 42,
                height: 42,
                cacheWidth: 84,
                fit: BoxFit.cover,
                errorBuilder: (_, _, _) =>
                    const Icon(Icons.attach_file, color: WaPalette.accent),
              ),
            )
          else
            const Icon(Icons.attach_file, color: WaPalette.accent),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  _extraAttachments.isEmpty
                      ? name
                      : '$name (+${_extraAttachments.length} ${tr.t('dalších', 'more')})',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(fontSize: 13),
                ),
                if (size.isNotEmpty)
                  Text(size,
                      style: const TextStyle(
                          fontSize: 11, color: WaPalette.textSecondary)),
              ],
            ),
          ),
          Tooltip(
            message: _sendViewOnce
                ? tr.t('Zobrazit jednou: zapnuto', 'View once: enabled')
                : tr.t('Odeslat jako zobrazení jednou', 'Send as view once'),
            child: InkWell(
              onTap: () => setState(() => _sendViewOnce = !_sendViewOnce),
              borderRadius: BorderRadius.circular(16),
              child: Container(
                padding:
                    const EdgeInsets.symmetric(horizontal: 9, vertical: 5),
                decoration: BoxDecoration(
                  color: _sendViewOnce
                      ? WaPalette.accent
                      : Colors.white.withValues(alpha: 0.08),
                  borderRadius: BorderRadius.circular(16),
                ),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(
                      Icons.looks_one_outlined,
                      size: 16,
                      color:
                          _sendViewOnce ? Colors.black : WaPalette.textPrimary,
                    ),
                    const SizedBox(width: 4),
                    Text(
                      '1×',
                      style: TextStyle(
                        fontSize: 12,
                        fontWeight: FontWeight.bold,
                        color: _sendViewOnce
                            ? Colors.black
                            : WaPalette.textPrimary,
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
          const SizedBox(width: 4),
          IconButton(
            onPressed: () => setState(() {
              _pendingAttachmentPath = null;
              _extraAttachments.clear();
              _sendViewOnce = false;
            }),
            icon: const Icon(Icons.close, size: 16),
            visualDensity: VisualDensity.compact,
          ),
        ],
      ),
    );
  }

  Widget _recordingBar(String chatJid, Tr tr) {
    final elapsed =
        '${_recSecs ~/ 60}:${(_recSecs % 60).toString().padLeft(2, '0')}';
    return Row(
      children: [
        const Icon(Icons.fiber_manual_record, color: Colors.red, size: 16),
        const SizedBox(width: 8),
        Text(elapsed,
            style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w600)),
        const SizedBox(width: 10),
        Text(
          tr.t('Nahrávání hlasové zprávy…', 'Recording voice message…'),
          style: const TextStyle(color: WaPalette.textSecondary, fontSize: 13),
        ),
        const Spacer(),
        IconButton(
          onPressed: _recordCancel,
          icon: const Icon(Icons.delete_outline, color: WaPalette.danger),
          tooltip: tr.t('Zahodit nahrávku', 'Discard recording'),
        ),
        IconButton.filled(
          onPressed: () => _recordStopAndSend(chatJid),
          style: IconButton.styleFrom(
            backgroundColor: WaPalette.accent,
            foregroundColor: Colors.black,
          ),
          icon: const Icon(Icons.send),
          tooltip: tr.t('Odeslat hlasovou zprávu', 'Send voice note'),
        ),
      ],
    );
  }

  Widget _composerRow(Snapshot s, String chatJid, WaPalette p, Tr tr) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.end,
      children: [
        IconButton(
          onPressed: () => setState(() {
            _showStickerPicker = false;
            _reactionPickerTargetId = null;
            _showEmojiPicker = !_showEmojiPicker;
          }),
          icon: Icon(
            Icons.emoji_emotions_outlined,
            color: _showEmojiPicker && _reactionPickerTargetId == null
                ? WaPalette.accent
                : WaPalette.textSecondary,
          ),
          tooltip: tr.t('Vybrat emoji', 'Pick emoji'),
        ),
        IconButton(
          onPressed: () => setState(() {
            _showEmojiPicker = false;
            _showStickerPicker = !_showStickerPicker;
          }),
          icon: Icon(
            Icons.sticky_note_2_outlined,
            color: _showStickerPicker
                ? WaPalette.accent
                : WaPalette.textSecondary,
          ),
          tooltip: tr.t('Poslat samolepku', 'Send sticker'),
        ),
        IconButton(
          onPressed: _attach,
          icon: const Icon(Icons.attach_file, color: WaPalette.textSecondary),
          tooltip: tr.t('Přiložit soubor', 'Attach file'),
        ),
        IconButton(
          onPressed: () => _newPoll(chatJid, tr),
          icon: const Icon(Icons.poll_outlined, color: WaPalette.textSecondary),
          tooltip: tr.t('Vytvořit anketu', 'Create poll'),
        ),
        Expanded(
          child: Focus(
            onKeyEvent: (_, evt) {
              if (evt is KeyDownEvent) {
                if (evt.logicalKey == LogicalKeyboardKey.keyV &&
                    HardwareKeyboard.instance.isControlPressed &&
                    !HardwareKeyboard.instance.isAltPressed) {
                  widget.bridge.pasteClipboardImage();
                  // Let TextField handle text paste via the default Ctrl+V action.
                  return KeyEventResult.ignored;
                }
                if (evt.logicalKey == LogicalKeyboardKey.enter) {
                  final shift = HardwareKeyboard.instance.isShiftPressed;
                  final ctrl = HardwareKeyboard.instance.isControlPressed;
                  if (s.prefs.enterIsSend && !shift) {
                    _submit(s, chatJid);
                    return KeyEventResult.handled;
                  }
                  if (!s.prefs.enterIsSend && ctrl) {
                    _submit(s, chatJid);
                    return KeyEventResult.handled;
                  }
                }
              }
              return KeyEventResult.ignored;
            },
            child: TextField(
              controller: _composerCtrl,
              focusNode: _composerFocus,
              minLines: 1,
              maxLines: 5,
              onChanged: (txt) => _onComposerChanged(chatJid, txt),
              style: const TextStyle(fontSize: 14.5),
              decoration: InputDecoration(
                isDense: true,
                filled: true,
                fillColor: p.surfaceElevated,
                hintText: _editingMessageId != null
                    ? tr.t('Upravit zprávu…', 'Edit message…')
                    : _pendingAttachmentPath != null
                        ? tr.t('Přidat popisek…', 'Add caption…')
                        : tr.t('Napište zprávu', 'Type a message'),
                hintStyle: const TextStyle(color: WaPalette.textSecondary),
                contentPadding: const EdgeInsets.symmetric(
                    horizontal: 14, vertical: 10),
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(12),
                  borderSide: BorderSide.none,
                ),
              ),
            ),
          ),
        ),
        const SizedBox(width: 4),
        IconButton(
          onPressed: () => _schedule(chatJid, _title(s, chatJid)),
          icon: const Icon(Icons.schedule, color: WaPalette.textSecondary),
          tooltip: tr.t('Naplánovat zprávu', 'Schedule message'),
        ),
        ValueListenableBuilder<TextEditingValue>(
          valueListenable: _composerCtrl,
          builder: (_, val, _) {
            final canSend =
                _pendingAttachmentPath != null || val.text.trim().isNotEmpty;
            return canSend
                ? IconButton.filled(
                    onPressed: () => _submit(s, chatJid),
                    style: IconButton.styleFrom(
                      backgroundColor: WaPalette.accent,
                      foregroundColor: Colors.black,
                    ),
                    icon: const Icon(Icons.send, size: 20),
                    tooltip: tr.t('Odeslat', 'Send'),
                  )
                : IconButton(
                    onPressed: _recordStart,
                    icon:
                        const Icon(Icons.mic, color: WaPalette.textSecondary),
                    tooltip: tr.t(
                        'Nahrát hlasovou zprávu', 'Record voice message'),
                  );
          },
        ),
      ],
    );
  }

  void _onComposerChanged(String chatJid, String text) {
    _draftTimer?.cancel();
    _draftTimer = Timer(const Duration(milliseconds: 350), () {
      widget.bridge.saveDraft(chatJid, text);
    });
    if (text.trim().isNotEmpty && !_typingActive) {
      _typingActive = true;
      widget.bridge.sendTyping(chatJid, true);
    }
    _typingTimer?.cancel();
    _typingTimer = Timer(const Duration(seconds: 3), () {
      if (_typingActive) {
        _typingActive = false;
        widget.bridge.sendTyping(chatJid, false);
      }
    });
  }

  void _submit(Snapshot s, String chatJid) {
    final text = _composerCtrl.text.trim();
    if (_editingMessageId != null) {
      if (text.isNotEmpty) {
        widget.bridge.edit(chatJid, _editingMessageId!, text);
      }
      setState(() {
        _editingMessageId = null;
        _composerCtrl.clear();
      });
      return;
    }

    if (_pendingAttachmentPath != null) {
      widget.bridge.sendMedia(
        chatJid,
        _pendingAttachmentPath!,
        caption: text.isEmpty ? null : text,
        replyTo: _reply?.id,
        viewOnce: _sendViewOnce,
      );
      for (final extra in _extraAttachments) {
        widget.bridge.sendMedia(chatJid, extra, viewOnce: _sendViewOnce);
      }
      _draftTimer?.cancel();
      widget.bridge.saveDraft(chatJid, '');
      setState(() {
        _pendingAttachmentPath = null;
        _extraAttachments.clear();
        _sendViewOnce = false;
        _reply = null;
        _composerCtrl.clear();
      });
      return;
    }

    if (text.isEmpty) return;
    _draftTimer?.cancel();
    widget.bridge.saveDraft(chatJid, '');
    final mentions = _collectMentions(s, text);
    widget.bridge.sendText(
      chatJid,
      text,
      reply: _reply?.id,
      mentions: mentions,
    );
    if (_typingActive) {
      _typingActive = false;
      widget.bridge.sendTyping(chatJid, false);
    }
    _composerCtrl.clear();
    setState(() => _reply = null);
  }

  Future<void> _attach() async {
    final file = await openFile();
    if (file == null || !mounted) return;
    setState(() {
      _pendingAttachmentPath = file.path;
      _sendViewOnce = false;
    });
  }

  void _recordStart() {
    widget.bridge.recordStart();
    _recTimer?.cancel();
    _recTimer = Timer.periodic(const Duration(seconds: 1), (_) {
      if (mounted) setState(() => _recSecs++);
    });
    setState(() {
      _recording = true;
      _recSecs = 0;
    });
  }

  void _recordStopAndSend(String chatJid) {
    _recTimer?.cancel();
    setState(() => _recording = false);
    widget.bridge.recordStop(chatJid);
  }

  void _recordCancel() {
    _recTimer?.cancel();
    widget.bridge.recordCancel();
    setState(() => _recording = false);
  }

  Future<void> _schedule(String chatJid, String chatName) async {
    final scheduled = await showDialog<bool>(
      context: context,
      builder: (_) => ScheduleMessageDialog(
        chatJid: chatJid,
        chatName: chatName,
        initialText: _composerCtrl.text.trim(),
        bridge: widget.bridge,
        palette: widget.palette,
        tr: widget.tr,
      ),
    );
    if (mounted && scheduled == true) {
      _draftTimer?.cancel();
      widget.bridge.saveDraft(chatJid, '');
      if (_composerCtrl.text.trim().isNotEmpty) {
        _composerCtrl.clear();
        setState(() {});
      }
    }
  }

  Future<void> _newPoll(String chatJid, Tr tr) async {
    final question = TextEditingController();
    final options = [TextEditingController(), TextEditingController()];
    var multi = false;
    final ok = await showDialog<bool>(
      context: context,
      builder: (dialog) => StatefulBuilder(
        builder: (dialog, setLocal) => AlertDialog(
          backgroundColor: widget.palette.surface,
          title: Text(tr.t('Nová anketa', 'New poll')),
          content: SingleChildScrollView(
            child: SizedBox(
              width: 360,
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  TextField(
                    controller: question,
                    autofocus: true,
                    decoration:
                        InputDecoration(labelText: tr.t('Otázka', 'Question')),
                  ),
                  for (var i = 0; i < options.length; i++)
                    Row(
                      children: [
                        Expanded(
                          child: TextField(
                            controller: options[i],
                            decoration: InputDecoration(
                                labelText:
                                    '${tr.t('Volba', 'Option')} ${i + 1}'),
                          ),
                        ),
                        if (options.length > 2)
                          IconButton(
                            icon: const Icon(Icons.remove_circle_outline,
                                size: 18),
                            onPressed: () =>
                                setLocal(() => options.removeAt(i).dispose()),
                          ),
                      ],
                    ),
                  if (options.length < 12)
                    TextButton.icon(
                      onPressed: () => setLocal(
                          () => options.add(TextEditingController())),
                      icon: const Icon(Icons.add),
                      label: Text(tr.t('Přidat volbu', 'Add option')),
                    ),
                  CheckboxListTile(
                    value: multi,
                    onChanged: (v) => setLocal(() => multi = v ?? false),
                    title: Text(tr.t('Více odpovědí', 'Allow multiple answers')),
                    controlAffinity: ListTileControlAffinity.leading,
                    contentPadding: EdgeInsets.zero,
                  ),
                ],
              ),
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(dialog, false),
              child: Text(tr.t('Zrušit', 'Cancel')),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(dialog, true),
              style: FilledButton.styleFrom(
                  backgroundColor: WaPalette.accentDark),
              child: Text(tr.t('Vytvořit', 'Create')),
            ),
          ],
        ),
      ),
    );
    final q = question.text.trim();
    final choices =
        options.map((c) => c.text.trim()).where((t) => t.isNotEmpty).toList();
    for (final c in options) {
      c.dispose();
    }
    question.dispose();
    if (ok == true && q.isNotEmpty && choices.length >= 2) {
      widget.bridge
          .createPoll(chatJid, q, choices, selectable: multi ? 0 : 1);
    }
  }

  Future<void> _forwardIds(Snapshot s, String fromChat, List<String> ids) async {
    final target = await showDialog<ChatItem>(
      context: context,
      builder: (_) => _ForwardTargetDialog(
        snapshot: s,
        palette: widget.palette,
        tr: widget.tr,
      ),
    );
    if (target != null) {
      widget.bridge.forward(fromChat, target.jid, ids);
      setState(() => _selectedMsgIds.clear());
    }
  }

  void _toggleSelection(String id) {
    setState(() {
      if (_selectedMsgIds.contains(id)) {
        _selectedMsgIds.remove(id);
      } else {
        _selectedMsgIds.add(id);
      }
    });
  }

  String? _myReactionEmoji(Snapshot s, Msg msg) {
    final meUser = s.self?.split('@').first.split(':').first;
    if (meUser == null || meUser.isEmpty) return null;
    for (final r in msg.reactionDetails) {
      final senderUser = r.sender.split('@').first.split(':').first;
      if (senderUser == meUser) return r.emoji;
    }
    return null;
  }

  Widget _buildQuickReactionRow({
    required BuildContext menuContext,
    required Iterable<String> emojis,
    required String? myEmoji,
    required String chatJid,
    required String msgId,
    required WaPalette p,
    required Tr tr,
    double buttonSize = 34,
    double fontSize = 20,
  }) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        for (final emoji in emojis)
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 2),
            child: InkWell(
              onTap: () {
                Navigator.pop(menuContext);
                widget.bridge.react(
                  chatJid,
                  msgId,
                  myEmoji == emoji ? '' : emoji,
                );
              },
              borderRadius: BorderRadius.circular(buttonSize / 2),
              child: Container(
                width: buttonSize,
                height: buttonSize,
                alignment: Alignment.center,
                decoration: BoxDecoration(
                  color: myEmoji == emoji
                      ? WaPalette.accent.withValues(alpha: 0.25)
                      : Colors.transparent,
                  shape: BoxShape.circle,
                ),
                child: Text(
                  emoji,
                  style: TextStyle(fontSize: fontSize, color: Colors.white),
                ),
              ),
            ),
          ),
        const SizedBox(width: 2),
        Tooltip(
          message: tr.t('Další emoji…', 'More emojis…'),
          child: InkWell(
            onTap: () {
              Navigator.pop(menuContext);
              setState(() {
                _showStickerPicker = false;
                _reactionPickerTargetId = msgId;
                _showEmojiPicker = true;
              });
            },
            borderRadius: BorderRadius.circular(18),
            child: Container(
              width: buttonSize - 2,
              height: buttonSize - 2,
              decoration: BoxDecoration(
                color: p.surface,
                shape: BoxShape.circle,
              ),
              child: const Icon(
                Icons.add,
                size: 18,
                color: WaPalette.textPrimary,
              ),
            ),
          ),
        ),
      ],
    );
  }

  Future<void> _showQuickReactionBar(
    Snapshot s,
    String chatJid,
    Msg msg,
    Offset pos,
    WaPalette p,
    Tr tr,
  ) async {
    final myEmoji = _myReactionEmoji(s, msg);
    final screen = MediaQuery.sizeOf(context);
    const estWidth = 356.0;
    const barHeight = 48.0;
    final left = (pos.dx - estWidth / 2).clamp(12.0, (screen.width - estWidth - 12).clamp(12.0, double.infinity));
    final top = pos.dy > 80 ? pos.dy - barHeight - 8 : pos.dy + 28;

    await showGeneralDialog<void>(
      context: context,
      barrierDismissible: true,
      barrierLabel: tr.t('Zavřít', 'Dismiss'),
      barrierColor: Colors.transparent,
      transitionDuration: const Duration(milliseconds: 110),
      pageBuilder: (dialogCtx, _, _) {
        return Stack(
          children: [
            Positioned(
              left: left,
              top: top,
              child: Material(
                color: Colors.transparent,
                child: Container(
                  height: barHeight,
                  padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                  decoration: BoxDecoration(
                    color: p.surfaceElevated,
                    borderRadius: BorderRadius.circular(26),
                    border: Border.all(color: p.divider),
                    boxShadow: const [
                      BoxShadow(
                        color: Colors.black54,
                        blurRadius: 14,
                        offset: Offset(0, 4),
                      ),
                    ],
                  ),
                  child: _buildQuickReactionRow(
                    menuContext: dialogCtx,
                    emojis: quickReactions,
                    myEmoji: myEmoji,
                    chatJid: chatJid,
                    msgId: msg.id,
                    p: p,
                    tr: tr,
                  ),
                ),
              ),
            ),
          ],
        );
      },
    );
  }

  Future<void> _showMsgContextMenu(
    Snapshot s,
    String chatJid,
    Msg msg,
    Offset pos,
    WaPalette p,
    Tr tr,
  ) async {
    final overlay = Overlay.of(context).context.findRenderObject() as RenderBox;
    final isPinned = s.pinnedMessage?.id == msg.id;
    final hasFile = msg.downloaded && msg.mediaPath != null;
    final myEmoji = _myReactionEmoji(s, msg);

    final choice = await showMenu<String>(
      context: context,
      color: p.surfaceElevated,
      constraints: const BoxConstraints(minWidth: 250, maxWidth: 340),
      position: RelativeRect.fromRect(
          pos & const Size(1, 1), Offset.zero & overlay.size),
      items: [
        _ReactionMenuEntry(
          child: _buildQuickReactionRow(
            menuContext: context,
            emojis: quickReactions.take(6),
            myEmoji: myEmoji,
            chatJid: chatJid,
            msgId: msg.id,
            p: p,
            tr: tr,
            buttonSize: 32,
            fontSize: 19,
          ),
        ),
        const PopupMenuDivider(),
        if (hasFile) ...[
          PopupMenuItem(
              value: 'open_file',
              child: Text(tr.t('Otevřít soubor', 'Open file'))),
          PopupMenuItem(
              value: 'show_folder',
              child: Text(tr.t('Zobrazit ve složce', 'Show in folder'))),
        ] else if (msg.media != null)
          PopupMenuItem(
              value: 'download', child: Text(tr.t('Stáhnout', 'Download'))),
        PopupMenuItem(
            value: 'reply', child: Text(tr.t('Odpovědět', 'Reply'))),
        PopupMenuItem(
            value: 'select', child: Text(tr.t('Vybrat', 'Select'))),
        if (msg.fromMe && msg.media == null && msg.text.isNotEmpty)
          PopupMenuItem(
              value: 'edit', child: Text(tr.t('Upravit', 'Edit'))),
        PopupMenuItem(
            value: 'copy', child: Text(tr.t('Kopírovat', 'Copy'))),
        PopupMenuItem(
            value: 'forward', child: Text(tr.t('Přeposlat', 'Forward'))),
        PopupMenuItem(
          value: 'star',
          child: Text(msg.starred
              ? tr.t('Odebrat hvězdičku', 'Unstar')
              : tr.t('Označit hvězdičkou', 'Star message')),
        ),
        if (!msg.viewOnce) ...[
          const PopupMenuDivider(),
          if (isPinned)
            PopupMenuItem(
                value: 'unpin', child: Text(tr.t('Odepnout', 'Unpin')))
          else ...[
            PopupMenuItem(
                value: 'pin_24h',
                child: Text(tr.t('Připnout na 24 hodin', 'Pin for 24 hours'))),
            PopupMenuItem(
                value: 'pin_7d',
                child: Text(tr.t('Připnout na 7 dní', 'Pin for 7 days'))),
            PopupMenuItem(
                value: 'pin_30d',
                child: Text(tr.t('Připnout na 30 dní', 'Pin for 30 days'))),
          ],
        ],
        const PopupMenuDivider(),
        PopupMenuItem(
          value: 'delete_me',
          child: Text(tr.t('Smazat pro mě', 'Delete for me')),
        ),
        if (msg.fromMe)
          PopupMenuItem(
            value: 'revoke',
            child: Text(
              tr.t('Smazat pro všechny', 'Delete for everyone'),
              style: const TextStyle(color: WaPalette.danger),
            ),
          ),
      ],
    );

    if (!mounted || choice == null) return;
    switch (choice) {
      case 'open_file':
        widget.bridge.openFile(msg.mediaPath!);
      case 'show_folder':
        widget.bridge.showInFolder(msg.mediaPath!);
      case 'download':
        widget.bridge.download(chatJid, msg.id);
      case 'reply':
        setState(() => _reply = msg);
        _composerFocus.requestFocus();
      case 'select':
        _toggleSelection(msg.id);
      case 'edit':
        setState(() {
          _reply = null;
          _editingMessageId = msg.id;
          _composerCtrl.text = msg.text;
          _composerCtrl.selection =
              TextSelection.collapsed(offset: msg.text.length);
        });
        _composerFocus.requestFocus();
      case 'copy':
        final copyText = (msg.text.isNotEmpty && !_isRedundantMediaLabel(msg))
            ? msg.text
            : (msg.caption ?? msg.text);
        Clipboard.setData(ClipboardData(text: copyText));
      case 'forward':
        _forwardIds(s, chatJid, [msg.id]);
      case 'star':
        widget.bridge.starMessage(chatJid, msg.id, !msg.starred);
      case 'unpin':
        widget.bridge.pinMessage(chatJid, msg.id);
      case 'pin_24h':
        widget.bridge.pinMessage(chatJid, msg.id, seconds: 86400);
      case 'pin_7d':
        widget.bridge.pinMessage(chatJid, msg.id, seconds: 604800);
      case 'pin_30d':
        widget.bridge.pinMessage(chatJid, msg.id, seconds: 2592000);
      case 'delete_me':
        widget.bridge.deleteMessage(chatJid, msg.id);
      case 'revoke':
        if (await widget.onConfirm(
          tr.t('Smazat pro všechny?', 'Delete for everyone?'),
          tr.t('Zpráva zmizí všem účastníkům konverzace.',
              'This message will be deleted for all participants.'),
          tr.t('Smazat', 'Delete'),
        )) {
          widget.bridge.revoke(chatJid, msg.id);
        }
    }
  }

  String _title(Snapshot snapshot, String jid) {
    final chat = snapshot.chat(jid);
    final contact = snapshot.contacts[jid];
    if (contact != null && contact.isNotEmpty) return contact;
    if (chat != null && chat.name.isNotEmpty) return chat.name;
    return formatJidPhone(jid);
  }

  String _nameOf(Snapshot s, String jid) {
    final name = s.contacts[jid];
    return (name == null || name.isEmpty) ? formatJidPhone(jid) : name;
  }

  String _presenceText(Snapshot snapshot, String jid, Tr tr) {
    final presence = snapshot.presence[jid];
    if (presence == null) return formatJidPhone(jid);
    if (presence.online) return tr.t('online', 'online');
    final seen = presence.lastSeen;
    if (seen == null) return formatJidPhone(jid);
    String two(int n) => n.toString().padLeft(2, '0');
    return '${tr.t('naposledy', 'last seen')} ${two(seen.day)}.${two(seen.month)}. ${two(seen.hour)}:${two(seen.minute)}';
  }

  bool _sameDay(int aMs, int bMs) {
    final a = DateTime.fromMillisecondsSinceEpoch(aMs);
    final b = DateTime.fromMillisecondsSinceEpoch(bMs);
    return a.year == b.year && a.month == b.month && a.day == b.day;
  }

  String _clock(int millis) {
    if (millis == 0) return '';
    final t = DateTime.fromMillisecondsSinceEpoch(millis);
    return '${t.hour.toString().padLeft(2, '0')}:${t.minute.toString().padLeft(2, '0')}';
  }

  bool _isRedundantMediaLabel(Msg msg) {
    if (msg.media == null) return false;
    final t = msg.text.trim();
    return t.startsWith('📷') ||
        t.startsWith('📹') ||
        t.startsWith('📄') ||
        t.startsWith('🎤') ||
        t.startsWith('🎵') ||
        t.startsWith('🎨');
  }

  int? _countEmojiOnly(String text) {
    final trimmed = text.trim();
    if (trimmed.isEmpty || trimmed.contains(_alnumRegex)) {
      return null;
    }
    final clusters = trimmed.characters
        .where((c) => c.trim().isNotEmpty)
        .toList();
    if (clusters.isEmpty || clusters.length > 3) return null;
    final allEmoji = clusters.every((c) => c.runes.any((r) => r >= 0x2600));
    return allEmoji ? clusters.length : null;
  }

  String? _activeMentionQuery(String text) {
    final idx = text.lastIndexOf('@');
    if (idx == -1) return null;
    if (idx > 0 && text[idx - 1].trim().isNotEmpty) return null;
    final tail = text.substring(idx + 1);
    if (tail.contains(_wsRegex)) return null;
    return tail;
  }

  String _applyMention(String text, String name) {
    final idx = text.lastIndexOf('@');
    if (idx == -1) return '$text@$name ';
    return '${text.substring(0, idx)}@$name ';
  }

  List<String> _collectMentions(Snapshot s, String text) {
    final participants = s.group?.participants ?? const <String>[];
    final out = <String>[];
    for (final jid in participants) {
      final name = _nameOf(s, jid);
      if (text.contains('@$name')) out.add(jid);
    }
    return out;
  }
}

class _HoverableBubble extends StatefulWidget {
  const _HoverableBubble({
    required this.fromMe,
    required this.onReactTap,
    required this.onMenuTap,
    this.onBubbleTap,
    required this.child,
  });

  final bool fromMe;
  final ValueChanged<Offset> onReactTap;
  final ValueChanged<Offset> onMenuTap;
  final VoidCallback? onBubbleTap;
  final Widget child;

  @override
  State<_HoverableBubble> createState() => _HoverableBubbleState();
}

class _HoverableBubbleState extends State<_HoverableBubble> {
  bool _hovered = false;
  Offset? _longPressPos;

  @override
  Widget build(BuildContext context) {
    return MouseRegion(
      onEnter: (_) => setState(() => _hovered = true),
      onExit: (_) => setState(() => _hovered = false),
      child: GestureDetector(
        behavior: HitTestBehavior.translucent,
        onTap: widget.onBubbleTap,
        onSecondaryTapDown: (d) => widget.onMenuTap(d.globalPosition),
        onLongPressStart: (d) => _longPressPos = d.globalPosition,
        onLongPress: () {
          if (_longPressPos != null) widget.onMenuTap(_longPressPos!);
        },
        child: Container(
          color: Colors.transparent,
          child: Align(
            alignment:
                widget.fromMe ? Alignment.centerRight : Alignment.centerLeft,
            child: Row(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.center,
              children: [
                if (widget.fromMe && _hovered) _hoverActions(),
                widget.child,
                if (!widget.fromMe && _hovered) _hoverActions(),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _hoverActions() {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 4),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Builder(
            builder: (ctx) => InkWell(
              onTap: () {
                final box = ctx.findRenderObject() as RenderBox;
                widget.onReactTap(box.localToGlobal(Offset.zero));
              },
              borderRadius: BorderRadius.circular(12),
              child: Container(
                padding: const EdgeInsets.all(4),
                decoration: const BoxDecoration(
                  color: Colors.black38,
                  shape: BoxShape.circle,
                ),
                child: const Icon(Icons.emoji_emotions_outlined,
                    size: 16, color: WaPalette.textSecondary),
              ),
            ),
          ),
          const SizedBox(width: 2),
          Builder(
            builder: (ctx) => InkWell(
              onTap: () {
                final box = ctx.findRenderObject() as RenderBox;
                widget.onMenuTap(box.localToGlobal(Offset.zero));
              },
              borderRadius: BorderRadius.circular(12),
              child: Container(
                padding: const EdgeInsets.all(4),
                decoration: const BoxDecoration(
                  color: Colors.black38,
                  shape: BoxShape.circle,
                ),
                child: const Icon(Icons.keyboard_arrow_down,
                    size: 16, color: WaPalette.textSecondary),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _BubbleTailPainter extends CustomPainter {
  const _BubbleTailPainter({required this.color, required this.fromMe});

  final Color color;
  final bool fromMe;

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()..color = color;
    final path = Path();
    if (fromMe) {
      path
        ..moveTo(0, 0)
        ..lineTo(size.width, 0)
        ..lineTo(0, size.height)
        ..close();
    } else {
      path
        ..moveTo(0, 0)
        ..lineTo(size.width, 0)
        ..lineTo(size.width, size.height)
        ..close();
    }
    canvas.drawPath(path, paint);
  }

  @override
  bool shouldRepaint(covariant _BubbleTailPainter oldDelegate) =>
      oldDelegate.color != color || oldDelegate.fromMe != fromMe;
}

class _ForwardTargetDialog extends StatefulWidget {
  const _ForwardTargetDialog({
    required this.snapshot,
    required this.palette,
    required this.tr,
  });

  final Snapshot snapshot;
  final WaPalette palette;
  final Tr tr;

  @override
  State<_ForwardTargetDialog> createState() => _ForwardTargetDialogState();
}

class _ForwardTargetDialogState extends State<_ForwardTargetDialog> {
  final _searchCtrl = TextEditingController();

  @override
  void dispose() {
    _searchCtrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final q = _searchCtrl.text.trim().toLowerCase();
    final chats = [...widget.snapshot.chats, ...widget.snapshot.archived]
        .where((c) => q.isEmpty || c.name.toLowerCase().contains(q))
        .toList();

    return AlertDialog(
      backgroundColor: widget.palette.surface,
      title: Text(widget.tr.t('Přeposlat do', 'Forward to')),
      content: SizedBox(
        width: 360,
        height: 360,
        child: Column(
          children: [
            TextField(
              controller: _searchCtrl,
              autofocus: true,
              onChanged: (_) => setState(() {}),
              decoration: InputDecoration(
                isDense: true,
                filled: true,
                fillColor: widget.palette.bg,
                prefixIcon: const Icon(Icons.search, size: 18),
                hintText: widget.tr.t('Hledat chat…', 'Search chat…'),
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(8),
                  borderSide: BorderSide.none,
                ),
              ),
            ),
            const SizedBox(height: 8),
            Expanded(
              child: ListView.builder(
                itemCount: chats.length,
                itemBuilder: (_, idx) {
                  final chat = chats[idx];
                  final label =
                      chat.name.isEmpty ? formatJidPhone(chat.jid) : chat.name;
                  return ListTile(
                    dense: true,
                    leading: WaAvatar(
                      name: label,
                      avatarPath: chat.avatar,
                      radius: 16,
                      isGroup: chat.group,
                    ),
                    title: Text(label,
                        maxLines: 1, overflow: TextOverflow.ellipsis),
                    onTap: () => Navigator.pop(context, chat),
                  );
                },
              ),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: Text(widget.tr.t('Zrušit', 'Cancel')),
        ),
      ],
    );
  }
}

class _ReactionMenuEntry extends PopupMenuEntry<String> {
  const _ReactionMenuEntry({required this.child});

  final Widget child;

  @override
  double get height => 44;

  @override
  bool represents(String? value) => false;

  @override
  State<_ReactionMenuEntry> createState() => _ReactionMenuEntryState();
}

class _ReactionMenuEntryState extends State<_ReactionMenuEntry> {
  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
      child: widget.child,
    );
  }
}

class _MessageRichText extends StatefulWidget {
  const _MessageRichText({
    required this.text,
    required this.fontSize,
    required this.highlightQuery,
    required this.onOpenUrl,
  });

  final String text;
  final double fontSize;
  final String? highlightQuery;
  final ValueChanged<String> onOpenUrl;

  @override
  State<_MessageRichText> createState() => _MessageRichTextState();
}

class _MessageRichTextState extends State<_MessageRichText> {
  static final _tokenRegex = RegExp(r'(https?://[^\s<>"\)\]\},;]+|@\S+)');

  final List<TapGestureRecognizer> _recognizers = [];
  late TextSpan _rootSpan;

  @override
  void initState() {
    super.initState();
    _rebuildSpan();
  }

  @override
  void didUpdateWidget(covariant _MessageRichText oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.text != widget.text ||
        oldWidget.fontSize != widget.fontSize ||
        oldWidget.highlightQuery != widget.highlightQuery) {
      _rebuildSpan();
    }
  }

  @override
  void dispose() {
    _disposeRecognizers();
    super.dispose();
  }

  void _disposeRecognizers() {
    for (final r in _recognizers) {
      r.dispose();
    }
    _recognizers.clear();
  }

  void _appendPlainHighlighted(
    List<InlineSpan> spans,
    String segment,
    String queryLower,
  ) {
    if (queryLower.isEmpty || segment.isEmpty) {
      spans.add(TextSpan(text: segment));
      return;
    }
    final segLower = segment.toLowerCase();
    var pos = 0;
    while (pos < segment.length) {
      final hit = segLower.indexOf(queryLower, pos);
      if (hit < 0) {
        spans.add(TextSpan(text: segment.substring(pos)));
        break;
      }
      if (hit > pos) {
        spans.add(TextSpan(text: segment.substring(pos, hit)));
      }
      spans.add(
        TextSpan(
          text: segment.substring(hit, hit + queryLower.length),
          style: TextStyle(
            backgroundColor: WaPalette.accentBright.withValues(alpha: 0.35),
            color: WaPalette.textPrimary,
            fontWeight: FontWeight.w600,
          ),
        ),
      );
      pos = hit + queryLower.length;
    }
  }

  void _rebuildSpan() {
    _disposeRecognizers();
    final text = widget.text;
    final queryLower = (widget.highlightQuery ?? '').trim().toLowerCase();
    final spans = <InlineSpan>[];
    var cursor = 0;
    for (final m in _tokenRegex.allMatches(text)) {
      if (m.start > cursor) {
        _appendPlainHighlighted(
          spans,
          text.substring(cursor, m.start),
          queryLower,
        );
      }
      final token = m.group(0)!;
      final isUrl = token.startsWith('http://') || token.startsWith('https://');
      final isHit =
          queryLower.isNotEmpty && token.toLowerCase().contains(queryLower);
      TapGestureRecognizer? recognizer;
      if (isUrl) {
        recognizer = TapGestureRecognizer()..onTap = () => widget.onOpenUrl(token);
        _recognizers.add(recognizer);
      }
      spans.add(
        TextSpan(
          text: token,
          style: TextStyle(
            color: WaPalette.linkBlue,
            decoration: isUrl ? TextDecoration.underline : null,
            backgroundColor: isHit
                ? WaPalette.accentBright.withValues(alpha: 0.35)
                : null,
          ),
          recognizer: recognizer,
        ),
      );
      cursor = m.end;
    }
    if (cursor < text.length) {
      _appendPlainHighlighted(spans, text.substring(cursor), queryLower);
    }
    _rootSpan = TextSpan(
      style: TextStyle(
        fontSize: widget.fontSize,
        height: 1.32,
        color: WaPalette.textPrimary,
      ),
      children: spans,
    );
  }

  @override
  Widget build(BuildContext context) {
    return SelectableText.rich(_rootSpan);
  }
}
