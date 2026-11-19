import 'dart:async';

import 'package:material_ui/material_ui.dart';

import '../bridge.dart';
import '../i18n.dart';
import '../theme.dart';
import 'avatar.dart';
import 'nav_rail.dart';

enum ChatFilter { all, unread, groups }

class ChatListPanel extends StatefulWidget {
  const ChatListPanel({
    super.key,
    required this.snapshot,
    required this.bridge,
    required this.palette,
    required this.tr,
    required this.section,
    required this.onSelectSection,
    required this.searchController,
    required this.onOpenChat,
    required this.onJumpNextUnread,
    required this.onOpenNewChat,
    required this.onOpenNewGroup,
    required this.onOpenContacts,
    required this.onOpenExport,
    required this.onOpenSchedule,
    required this.onEditContactName,
    required this.onOpenChatInfo,
    required this.onOpenSearch,
    required this.onOpenPalette,
    required this.onOpenSettings,
    required this.onConfirm,
  });

  final Snapshot snapshot;
  final Bridge bridge;
  final WaPalette palette;
  final Tr tr;
  final RailSection section;
  final ValueChanged<RailSection> onSelectSection;
  final TextEditingController searchController;
  final ValueChanged<ChatItem> onOpenChat;
  final VoidCallback onJumpNextUnread;
  final VoidCallback onOpenNewChat;
  final VoidCallback onOpenNewGroup;
  final VoidCallback onOpenContacts;
  final ValueChanged<ChatItem> onOpenExport;
  final ValueChanged<ChatItem> onOpenSchedule;
  final ValueChanged<ChatItem> onEditContactName;
  final ValueChanged<ChatItem> onOpenChatInfo;
  final VoidCallback onOpenSearch;
  final VoidCallback onOpenPalette;
  final VoidCallback onOpenSettings;
  final Future<bool> Function(String title, String body, String action) onConfirm;

  @override
  State<ChatListPanel> createState() => _ChatListPanelState();
}

class _ChatListPanelState extends State<ChatListPanel> {
  ChatFilter _filter = ChatFilter.all;
  bool _archivedExpanded = false;
  Timer? _searchDebounce;

  @override
  void dispose() {
    _searchDebounce?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final s = widget.snapshot;
    final p = widget.palette;
    final tr = widget.tr;
    final now = DateTime.now();
    final inArchive = widget.section == RailSection.archived;
    final unreadTotal = s.chats.fold<int>(0, (sum, c) => sum + c.unread);

    final baseList = inArchive ? s.archived : s.chats;
    final filtered = baseList.where((c) {
      return switch (_filter) {
        ChatFilter.all => true,
        ChatFilter.unread => c.unread > 0,
        ChatFilter.groups => c.group,
      };
    }).toList();

    final showArchiveHeader =
        !inArchive && s.archived.isNotEmpty && _filter == ChatFilter.all;
    final showExpandedArchived = showArchiveHeader && _archivedExpanded;
    final archivedOffset = showArchiveHeader ? 1 : 0;
    final expandedCount = showExpandedArchived ? s.archived.length : 0;
    final bodyCount = filtered.isEmpty ? 1 : filtered.length;
    final itemCount = archivedOffset + expandedCount + bodyCount;

    return Container(
      width: 348,
      decoration: BoxDecoration(
        color: p.bg,
        border: Border(right: BorderSide(color: p.divider)),
      ),
      child: Column(
        children: [
          _buildHeader(p, tr, inArchive, unreadTotal),
          if (s.connection == 'error') _buildErrorBanner(s, tr),
          if (s.connection == 'syncing') _buildSyncingBanner(s, tr),
          _buildSearchBar(p, tr),
          if (!inArchive) _buildFilterChips(p, tr),
          const SizedBox(height: 4),
          Expanded(
            child: ListView.builder(
              itemCount: itemCount,
              itemBuilder: (_, index) {
                if (showArchiveHeader && index == 0) {
                  return _buildArchivedRow(s, p, tr);
                }
                final rem = index - archivedOffset;
                if (rem < expandedCount) {
                  return _chatTile(s, s.archived[rem], p, tr, now);
                }
                final bodyIdx = rem - expandedCount;
                if (filtered.isEmpty) {
                  return _buildEmpty(inArchive, tr);
                }
                return _chatTile(s, filtered[bodyIdx], p, tr, now);
              },
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildHeader(WaPalette p, Tr tr, bool inArchive, int unreadTotal) {
    return Container(
      height: 58,
      padding: const EdgeInsets.symmetric(horizontal: 16),
      child: Row(
        children: [
          if (inArchive) ...[
            IconButton(
              onPressed: () => widget.onSelectSection(RailSection.chats),
              icon: const Icon(Icons.arrow_back, size: 20),
              tooltip: tr.t('Zpět na chaty', 'Back to chats'),
            ),
            const SizedBox(width: 4),
          ],
          Expanded(
            child: Text(
              inArchive ? tr.t('Archivované', 'Archived') : tr.t('Chaty', 'Chats'),
              style: const TextStyle(
                fontSize: 21,
                fontWeight: FontWeight.bold,
                color: WaPalette.textPrimary,
              ),
            ),
          ),
          if (unreadTotal > 0)
            Padding(
              padding: const EdgeInsets.only(right: 4),
              child: ActionChip(
                avatar: const Icon(Icons.arrow_downward, size: 14, color: Colors.black),
                label: Text(
                  '$unreadTotal',
                  style: const TextStyle(
                    fontSize: 12,
                    fontWeight: FontWeight.bold,
                    color: Colors.black,
                  ),
                ),
                backgroundColor: WaPalette.accent,
                side: BorderSide.none,
                padding: EdgeInsets.zero,
                visualDensity: VisualDensity.compact,
                tooltip: tr.t('Skočit na další nepřečtenou zprávu (Alt+↓)',
                    'Jump to next unread message (Alt+↓)'),
                onPressed: widget.onJumpNextUnread,
              ),
            ),
          IconButton(
            onPressed: widget.bridge.refreshChats,
            icon: const Icon(Icons.sync, size: 20, color: WaPalette.textSecondary),
            tooltip: tr.t('Synchronizovat kontakty a názvy',
                'Sync contacts and names from WhatsApp'),
          ),
          IconButton(
            onPressed: widget.onOpenNewChat,
            icon: const Icon(Icons.add_comment_outlined,
                size: 21, color: WaPalette.textSecondary),
            tooltip: tr.t('Nový chat', 'New chat'),
          ),
          PopupMenuButton<String>(
            icon: const Icon(Icons.more_vert,
                size: 21, color: WaPalette.textSecondary),
            color: p.surfaceElevated,
            onSelected: (value) {
              switch (value) {
                case 'new_group':
                  widget.onOpenNewGroup();
                case 'contacts':
                  widget.onOpenContacts();
                case 'search':
                  widget.onOpenSearch();
                case 'palette':
                  widget.onOpenPalette();
                case 'settings':
                  widget.onOpenSettings();
              }
            },
            itemBuilder: (_) => [
              PopupMenuItem(
                value: 'new_group',
                child: Text(tr.t('Nová skupina', 'New group')),
              ),
              PopupMenuItem(
                value: 'contacts',
                child: Text(tr.t('Kontakty', 'Contacts')),
              ),
              PopupMenuItem(
                value: 'search',
                child: Text(tr.t('Hledat ve zprávách (Ctrl+F)',
                    'Search messages (Ctrl+F)')),
              ),
              PopupMenuItem(
                value: 'palette',
                child: Text(
                    tr.t('Přepnout chat (Ctrl+K)', 'Switch chat (Ctrl+K)')),
              ),
              const PopupMenuDivider(),
              PopupMenuItem(
                value: 'settings',
                child: Text(tr.t('Nastavení', 'Settings')),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _buildErrorBanner(Snapshot s, Tr tr) {
    return Container(
      color: WaPalette.danger.withValues(alpha: 0.14),
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
      child: Row(
        children: [
          const Icon(Icons.error_outline, size: 16, color: WaPalette.danger),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              s.detail ?? tr.t('Chyba připojení', 'Connection error'),
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(fontSize: 12, color: WaPalette.danger),
            ),
          ),
          TextButton(
            onPressed: widget.bridge.reconnectBackend,
            child: Text(tr.t('Zkusit znovu', 'Retry')),
          ),
        ],
      ),
    );
  }

  Widget _buildSyncingBanner(Snapshot s, Tr tr) {
    final pct = int.tryParse(s.detail ?? '') ?? 0;
    return Container(
      color: WaPalette.accent.withValues(alpha: 0.12),
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 6),
      child: Row(
        children: [
          const SizedBox(
            width: 14,
            height: 14,
            child: CircularProgressIndicator(
              strokeWidth: 2,
              color: WaPalette.accent,
            ),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              pct > 0
                  ? '${tr.t('Synchronizace historie', 'Syncing history')} ($pct%)'
                  : tr.t('Synchronizace historie…', 'Syncing history…'),
              style: const TextStyle(fontSize: 12, color: WaPalette.textPrimary),
            ),
          ),
          IconButton(
            onPressed: widget.bridge.dismissSyncing,
            icon: const Icon(Icons.close, size: 15),
            visualDensity: VisualDensity.compact,
          ),
        ],
      ),
    );
  }

  Widget _buildSearchBar(WaPalette p, Tr tr) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 2, 12, 8),
      child: TextField(
        controller: widget.searchController,
        onChanged: (q) {
          setState(() {});
          _searchDebounce?.cancel();
          _searchDebounce = Timer(const Duration(milliseconds: 120), () {
            if (mounted) widget.bridge.search(q);
          });
        },
        style: const TextStyle(fontSize: 14, color: WaPalette.textPrimary),
        decoration: InputDecoration(
          isDense: true,
          filled: true,
          fillColor: p.surface,
          prefixIcon: const Icon(Icons.search, size: 19, color: WaPalette.textSecondary),
          suffixIcon: widget.searchController.text.isNotEmpty
              ? IconButton(
                  icon: const Icon(Icons.close, size: 16),
                  onPressed: () {
                    _searchDebounce?.cancel();
                    widget.searchController.clear();
                    setState(() {});
                    widget.bridge.search('');
                  },
                )
              : null,
          hintText: tr.t('Hledat nebo začít nový chat', 'Search or start new chat'),
          hintStyle: const TextStyle(fontSize: 13.5, color: WaPalette.textSecondary),
          contentPadding: const EdgeInsets.symmetric(vertical: 9),
          border: OutlineInputBorder(
            borderRadius: BorderRadius.circular(20),
            borderSide: BorderSide.none,
          ),
        ),
      ),
    );
  }

  Widget _buildFilterChips(WaPalette p, Tr tr) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 2),
      child: Align(
        alignment: Alignment.centerLeft,
        child: Wrap(
          spacing: 6,
          runSpacing: 6,
          children: [
            _chip(tr.t('Vše', 'All'), ChatFilter.all, p),
            _chip(tr.t('Nepřečtené', 'Unread'), ChatFilter.unread, p),
            _chip(tr.t('Skupiny', 'Groups'), ChatFilter.groups, p),
          ],
        ),
      ),
    );
  }

  Widget _chip(String label, ChatFilter target, WaPalette p) {
    final active = _filter == target;
    return InkWell(
      onTap: () => setState(() => _filter = target),
      borderRadius: BorderRadius.circular(16),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 5),
        decoration: BoxDecoration(
          color: active ? const Color(0xFF0A332C) : p.surface,
          borderRadius: BorderRadius.circular(16),
        ),
        child: Text(
          label,
          style: TextStyle(
            fontSize: 12.5,
            fontWeight: FontWeight.w500,
            color: active ? WaPalette.accent : WaPalette.textSecondary,
          ),
        ),
      ),
    );
  }

  Widget _buildArchivedRow(Snapshot s, WaPalette p, Tr tr) {
    return InkWell(
      onTap: () => setState(() => _archivedExpanded = !_archivedExpanded),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 10),
        child: Row(
          children: [
            const Icon(Icons.archive_outlined,
                size: 20, color: WaPalette.accent),
            const SizedBox(width: 18),
            Expanded(
              child: Text(
                tr.t('Archivované', 'Archived'),
                style: const TextStyle(
                  fontSize: 15,
                  fontWeight: FontWeight.w500,
                  color: WaPalette.textPrimary,
                ),
              ),
            ),
            Text(
              '${s.archived.length}',
              style: const TextStyle(
                fontSize: 12.5,
                color: WaPalette.accent,
                fontWeight: FontWeight.w600,
              ),
            ),
            const SizedBox(width: 6),
            Icon(
              _archivedExpanded
                  ? Icons.keyboard_arrow_up
                  : Icons.keyboard_arrow_down,
              size: 18,
              color: WaPalette.textSecondary,
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildEmpty(bool inArchive, Tr tr) {
    return Padding(
      padding: const EdgeInsets.only(top: 56, left: 24, right: 24),
      child: Column(
        children: [
          Icon(
            inArchive ? Icons.archive_outlined : Icons.chat_bubble_outline,
            size: 42,
            color: WaPalette.textSecondary,
          ),
          const SizedBox(height: 12),
          Text(
            inArchive
                ? tr.t('Žádné archivované chaty', 'No archived chats')
                : tr.t('Žádné chaty', 'No chats yet'),
            style: const TextStyle(
              fontSize: 15,
              fontWeight: FontWeight.w500,
              color: WaPalette.textPrimary,
            ),
          ),
          if (!inArchive) ...[
            const SizedBox(height: 6),
            Text(
              tr.t('Klikni na + nahoře pro novou konverzaci',
                  'Click + above to start a conversation'),
              textAlign: TextAlign.center,
              style: const TextStyle(
                  fontSize: 12.5, color: WaPalette.textSecondary),
            ),
          ],
        ],
      ),
    );
  }

  Widget _chatTile(
    Snapshot snapshot,
    ChatItem chat,
    WaPalette p,
    Tr tr,
    DateTime now,
  ) {
    final selected = chat.jid == snapshot.selected;
    final online = snapshot.presence[chat.jid]?.online ?? false;
    final displayName = chat.name.isEmpty ? formatJidPhone(chat.jid) : chat.name;
    final hasDraft = chat.draft != null && chat.draft!.trim().isNotEmpty;

    return _HoverableChatTile(
      selected: selected,
      palette: p,
      onTap: () => widget.onOpenChat(chat),
      onContextMenu: (pos) => _showContextMenu(chat, pos, p, tr),
      child: Row(
        children: [
          WaAvatar(
            name: displayName,
            avatarPath: chat.avatar,
            radius: 24,
            isGroup: chat.group,
            online: online,
          ),
          const SizedBox(width: 13),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Row(
                  children: [
                    Expanded(
                      child: Text(
                        displayName,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          fontSize: 15.5,
                          fontWeight: chat.unread > 0
                              ? FontWeight.w600
                              : FontWeight.w400,
                          color: WaPalette.textPrimary,
                        ),
                      ),
                    ),
                    const SizedBox(width: 6),
                    Text(
                      _formatTime(chat.last?.ts ?? 0, tr, now),
                      style: TextStyle(
                        fontSize: 11.5,
                        color: chat.unread > 0
                            ? WaPalette.accent
                            : WaPalette.textSecondary,
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 3),
                Row(
                  children: [
                    Expanded(child: _subtitle(chat, hasDraft, tr)),
                    const SizedBox(width: 6),
                    if (chat.muted)
                      const Padding(
                        padding: EdgeInsets.only(right: 4),
                        child: Icon(Icons.volume_off,
                            size: 15, color: WaPalette.textSecondary),
                      ),
                    if (chat.pinned)
                      const Padding(
                        padding: EdgeInsets.only(right: 4),
                        child: Icon(Icons.push_pin,
                            size: 14, color: WaPalette.textSecondary),
                      ),
                    if (chat.unread > 0)
                      Container(
                        padding: const EdgeInsets.symmetric(
                            horizontal: 6, vertical: 1.5),
                        decoration: BoxDecoration(
                          color: WaPalette.accent,
                          borderRadius: BorderRadius.circular(10),
                        ),
                        child: Text(
                          chat.unread > 99 ? '99+' : '${chat.unread}',
                          style: const TextStyle(
                            fontSize: 11,
                            color: Colors.black,
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                      ),
                  ],
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _subtitle(ChatItem chat, bool hasDraft, Tr tr) {
    if (chat.typing) {
      return Row(
        children: [
          Text(
            tr.t('píše', 'typing'),
            style: const TextStyle(fontSize: 13, color: WaPalette.accentBright),
          ),
          const SizedBox(width: 4),
          const BouncingDots(size: 3.5),
        ],
      );
    }
    if (hasDraft) {
      return Text.rich(
        TextSpan(
          children: [
            TextSpan(
              text: '${tr.t('Koncept', 'Draft')}: ',
              style: const TextStyle(
                  fontSize: 13,
                  color: WaPalette.accentBright,
                  fontWeight: FontWeight.w500),
            ),
            TextSpan(
              text: chat.draft!.trim(),
              style: const TextStyle(
                  fontSize: 13, color: WaPalette.textSecondary),
            ),
          ],
        ),
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
      );
    }
    final last = chat.last;
    if (last == null) return const SizedBox.shrink();

    final preview = _previewText(last, tr);
    return Row(
      children: [
        if (last.fromMe) ...[
          StatusTicks(status: last.status, size: 15),
          const SizedBox(width: 4),
        ],
        Expanded(
          child: Text(
            preview,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
              fontSize: 13,
              color: chat.unread > 0
                  ? WaPalette.textPrimary
                  : WaPalette.textSecondary,
            ),
          ),
        ),
      ],
    );
  }

  String _previewText(LastMessage last, Tr tr) {
    final text = last.text.trim();
    if (text.startsWith('[Reaction]')) return tr.t('Reakce', 'Reaction');
    final icon = switch (last.media) {
      'image' => '📷',
      'video' => '📹',
      'audio' || 'voice' => '🎤',
      'document' => '📄',
      'sticker' => '🎨',
      _ => '',
    };
    if (text.isEmpty || text == '[Protocol Message]') {
      if (icon.isEmpty) return tr.t('Zpráva', 'Message');
      return '$icon ${tr.t('Médium', 'Media')}';
    }
    final already = ['📷', '📹', '🎤', '🎵', '📄', '🎨']
        .any((p) => text.startsWith(p));
    if (icon.isEmpty || already) return text;
    return '$icon $text';
  }

  String _formatTime(int millis, Tr tr, DateTime now) {
    if (millis == 0) return '';
    final t = DateTime.fromMillisecondsSinceEpoch(millis);
    final today = DateTime(now.year, now.month, now.day);
    final day = DateTime(t.year, t.month, t.day);
    final diff = today.difference(day).inDays;
    if (diff == 0) {
      return '${t.hour.toString().padLeft(2, '0')}:${t.minute.toString().padLeft(2, '0')}';
    }
    if (diff == 1) return tr.t('Včera', 'Yesterday');
    return '${t.day}.${t.month}.${t.year}';
  }

  Future<void> _showContextMenu(
    ChatItem chat,
    Offset globalPos,
    WaPalette p,
    Tr tr,
  ) async {
    final overlay = Overlay.of(context).context.findRenderObject() as RenderBox;
    final choice = await showMenu<String>(
      context: context,
      color: p.surfaceElevated,
      position: RelativeRect.fromRect(
        globalPos & const Size(1, 1),
        Offset.zero & overlay.size,
      ),
      items: [
        PopupMenuItem(
          value: 'info',
          child: _menuItem(
              Icons.info_outline,
              chat.group
                  ? tr.t('Info o skupině', 'Group info')
                  : tr.t('Info o kontaktu', 'Contact info')),
        ),
        if (chat.unread > 0)
          PopupMenuItem(
            value: 'read',
            child: _menuItem(
                Icons.mark_chat_read_outlined,
                tr.t('Označit jako přečtené', 'Mark as read')),
          ),
        PopupMenuItem(
          value: 'pin',
          child: _menuItem(
            chat.pinned ? Icons.push_pin_outlined : Icons.push_pin,
            chat.pinned
                ? tr.t('Odepnout chat', 'Unpin chat')
                : tr.t('Připnout chat', 'Pin chat'),
          ),
        ),
        PopupMenuItem(
          value: 'archive',
          child: _menuItem(
            chat.archived ? Icons.unarchive_outlined : Icons.archive_outlined,
            chat.archived
                ? tr.t('Vyjmout z archivu', 'Unarchive')
                : tr.t('Archivovat chat', 'Archive chat'),
          ),
        ),
        if (chat.muted)
          PopupMenuItem(
            value: 'unmute',
            child: _menuItem(
                Icons.volume_up_outlined, tr.t('Zrušit ztišení', 'Unmute')),
          )
        else ...[
          PopupMenuItem(
            value: 'mute_8h',
            child: _menuItem(
                Icons.volume_off_outlined, tr.t('Ztišit na 8 hodin', 'Mute 8 hours')),
          ),
          PopupMenuItem(
            value: 'mute_1w',
            child: _menuItem(
                Icons.volume_off_outlined, tr.t('Ztišit na 1 týden', 'Mute 1 week')),
          ),
          PopupMenuItem(
            value: 'mute_forever',
            child: _menuItem(
                Icons.notifications_off_outlined, tr.t('Ztišit navždy', 'Mute always')),
          ),
        ],
        const PopupMenuDivider(),
        if (!chat.group)
          PopupMenuItem(
            value: 'edit_contact',
            child: _menuItem(
                Icons.edit_outlined, tr.t('Upravit jméno kontaktu', 'Edit contact name')),
          ),
        PopupMenuItem(
          value: 'schedule',
          child: _menuItem(
              Icons.schedule, tr.t('Naplánovat zprávu', 'Schedule message')),
        ),
        PopupMenuItem(
          value: 'export',
          child: _menuItem(
              Icons.file_download_outlined, tr.t('Exportovat chat…', 'Export chat…')),
        ),
        const PopupMenuDivider(),
        PopupMenuItem(
          value: 'clear',
          child: _menuItem(Icons.cleaning_services_outlined,
              tr.t('Vyčistit zprávy', 'Clear messages')),
        ),
        PopupMenuItem(
          value: 'delete',
          child: _menuItem(
            Icons.delete_outline,
            tr.t('Smazat chat', 'Delete chat'),
            color: WaPalette.danger,
          ),
        ),
      ],
    );

    if (!mounted || choice == null) return;
    switch (choice) {
      case 'info':
        widget.onOpenChatInfo(chat);
      case 'read':
        widget.bridge.markRead(chat.jid);
      case 'pin':
        chat.pinned
            ? widget.bridge.unpinChat(chat.jid)
            : widget.bridge.pinChat(chat.jid);
      case 'archive':
        chat.archived
            ? widget.bridge.unarchiveChat(chat.jid)
            : widget.bridge.archiveChat(chat.jid);
      case 'unmute':
        widget.bridge.unmuteChat(chat.jid);
      case 'mute_8h':
        widget.bridge.muteChat(chat.jid, hours: 8);
      case 'mute_1w':
        widget.bridge.muteChat(chat.jid, hours: 24 * 7);
      case 'mute_forever':
        widget.bridge.muteChat(chat.jid);
      case 'edit_contact':
        widget.onEditContactName(chat);
      case 'schedule':
        widget.onOpenSchedule(chat);
      case 'export':
        widget.onOpenExport(chat);
      case 'clear':
        if (await widget.onConfirm(
          tr.t('Vyčistit chat', 'Clear chat'),
          tr.t('Historie zmizí jen u tebe, ostatní ji pořád uvidí.',
              'Messages will be cleared locally only.'),
          tr.t('Vyčistit', 'Clear'),
        )) {
          widget.bridge.clearChat(chat.jid);
        }
      case 'delete':
        if (await widget.onConfirm(
          tr.t('Smazat chat', 'Delete chat'),
          tr.t('Chat zmizí ze seznamu; zprávy zůstanou na serveru.',
              'Chat disappears from this device.'),
          tr.t('Smazat', 'Delete'),
        )) {
          widget.bridge.deleteChat(chat.jid);
        }
    }
  }

  Widget _menuItem(IconData icon, String text, {Color? color}) {
    return Row(
      children: [
        Icon(icon, size: 18, color: color ?? WaPalette.textPrimary),
        const SizedBox(width: 10),
        Text(text, style: TextStyle(fontSize: 13.5, color: color)),
      ],
    );
  }
}

class _HoverableChatTile extends StatefulWidget {
  const _HoverableChatTile({
    required this.selected,
    required this.palette,
    required this.onTap,
    required this.onContextMenu,
    required this.child,
  });

  final bool selected;
  final WaPalette palette;
  final VoidCallback onTap;
  final ValueChanged<Offset> onContextMenu;
  final Widget child;

  @override
  State<_HoverableChatTile> createState() => _HoverableChatTileState();
}

class _HoverableChatTileState extends State<_HoverableChatTile> {
  bool _hovered = false;
  Offset? _tapPos;

  @override
  Widget build(BuildContext context) {
    final bg = widget.selected
        ? widget.palette.surfaceElevated
        : _hovered
            ? widget.palette.hover
            : Colors.transparent;

    return MouseRegion(
      onEnter: (_) => setState(() => _hovered = true),
      onExit: (_) => setState(() => _hovered = false),
      child: GestureDetector(
        onSecondaryTapDown: (d) => widget.onContextMenu(d.globalPosition),
        onLongPressStart: (d) => _tapPos = d.globalPosition,
        onLongPress: () {
          if (_tapPos != null) widget.onContextMenu(_tapPos!);
        },
        child: InkWell(
          onTap: widget.onTap,
          child: Container(
            color: bg,
            padding: const EdgeInsets.symmetric(horizontal: 13, vertical: 11),
            child: Stack(
              children: [
                widget.child,
                if (_hovered)
                  Positioned(
                    right: 0,
                    bottom: 0,
                    child: Builder(
                      builder: (ctx) => InkWell(
                        onTap: () {
                          final box = ctx.findRenderObject() as RenderBox;
                          final pos = box.localToGlobal(Offset.zero);
                          widget.onContextMenu(pos + const Offset(10, 18));
                        },
                        borderRadius: BorderRadius.circular(10),
                        child: Container(
                          padding: const EdgeInsets.all(2),
                          color: bg,
                          child: const Icon(
                            Icons.keyboard_arrow_down,
                            size: 16,
                            color: WaPalette.textSecondary,
                          ),
                        ),
                      ),
                    ),
                  ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
