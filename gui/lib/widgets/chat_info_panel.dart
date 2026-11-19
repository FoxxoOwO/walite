import 'dart:async';
import 'dart:io';

import 'package:material_ui/material_ui.dart';
import 'package:flutter/services.dart';

import '../bridge.dart';
import '../i18n.dart';
import '../theme.dart';
import 'avatar.dart';
import 'dialogs.dart';

const _ephemeralValues = [0, 86400, 604800, 7776000];

String _ephemeralLabel(int seconds, Tr tr) => switch (seconds) {
      0 => tr.t('Vypnuto', 'Off'),
      86400 => tr.t('24 hodin', '24 hours'),
      604800 => tr.t('7 dní', '7 days'),
      _ => tr.t('90 dní', '90 days'),
    };

final _linkRegex = RegExp(r'https?://[^\s<>"\)\]\},;]+');

List<String> extractLinks(String text) {
  final out = <String>[];
  for (final m in _linkRegex.allMatches(text)) {
    var url = m.group(0)!;
    while (url.isNotEmpty && '.!?:'.contains(url[url.length - 1])) {
      url = url.substring(0, url.length - 1);
    }
    if (url.isNotEmpty && !out.contains(url)) out.add(url);
  }
  return out;
}

class ChatInfoPanel extends StatefulWidget {
  const ChatInfoPanel({
    super.key,
    required this.snapshot,
    required this.chat,
    required this.bridge,
    required this.palette,
    required this.tr,
    required this.onClose,
    required this.onJumpToMessage,
    required this.onOpenAddMembers,
    required this.onEditContactName,
    required this.onOpenExport,
    required this.onConfirm,
  });

  final Snapshot snapshot;
  final ChatItem chat;
  final Bridge bridge;
  final WaPalette palette;
  final Tr tr;
  final VoidCallback onClose;
  final ValueChanged<String> onJumpToMessage;
  final ValueChanged<GroupInfo> onOpenAddMembers;
  final ValueChanged<ChatItem> onEditContactName;
  final ValueChanged<ChatItem> onOpenExport;
  final Future<bool> Function(String title, String body, String action)
      onConfirm;

  @override
  State<ChatInfoPanel> createState() => _ChatInfoPanelState();
}

class _ChatInfoPanelState extends State<ChatInfoPanel> {
  int _galleryTab = 0; // 0 = media, 1 = docs, 2 = links
  bool _editingSubject = false;
  bool _editingDesc = false;
  final _subjectCtrl = TextEditingController();
  final _descCtrl = TextEditingController();
  String? _requestedGroupJid;
  String? _requestedHistoryJid;
  ChatGallery? _gallery;
  StreamSubscription<ChatGallery>? _gallerySub;

  @override
  void initState() {
    super.initState();
    _gallerySub = widget.bridge.chatGalleries.listen((g) {
      if (mounted && g.chat == widget.chat.jid) {
        setState(() => _gallery = g);
      }
    });
    _ensureGroupInfo();
    _ensureFullGallery();
  }

  @override
  void didUpdateWidget(covariant ChatInfoPanel oldWidget) {
    super.didUpdateWidget(oldWidget);
    final chatChanged = oldWidget.chat.jid != widget.chat.jid;
    final countsChanged = oldWidget.snapshot.selectedTotalMessages !=
            widget.snapshot.selectedTotalMessages ||
        oldWidget.snapshot.historySyncing.length !=
            widget.snapshot.historySyncing.length ||
        oldWidget.snapshot.historyExhausted.length !=
            widget.snapshot.historyExhausted.length;
    if (chatChanged) {
      _editingSubject = false;
      _editingDesc = false;
      _gallery = null;
      _ensureGroupInfo();
      _ensureFullGallery();
    } else if (countsChanged) {
      widget.bridge.requestChatGallery(widget.chat.jid);
    }
  }

  void _ensureGroupInfo() {
    if (widget.chat.group && _requestedGroupJid != widget.chat.jid) {
      _requestedGroupJid = widget.chat.jid;
      widget.bridge.requestGroupInfo(widget.chat.jid);
    }
  }

  void _ensureFullGallery() {
    widget.bridge.requestChatGallery(widget.chat.jid);
    if (_requestedHistoryJid != widget.chat.jid &&
        !widget.snapshot.isHistoryExhausted(widget.chat.jid) &&
        !widget.snapshot.isHistorySyncing(widget.chat.jid)) {
      _requestedHistoryJid = widget.chat.jid;
      widget.bridge.syncFullHistory(chat: widget.chat.jid);
    }
  }

  @override
  void dispose() {
    _gallerySub?.cancel();
    _subjectCtrl.dispose();
    _descCtrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final s = widget.snapshot;
    final chat = widget.chat;
    final p = widget.palette;
    final tr = widget.tr;
    final group = s.group;
    final displayName =
        group?.subject ?? (chat.name.isEmpty ? formatJidPhone(chat.jid) : chat.name);

    return Container(
      width: 336,
      decoration: BoxDecoration(
        border: Border(left: BorderSide(color: p.divider)),
      ),
      child: Column(
        children: [
          Material(
            color: p.surface,
            child: SizedBox(
              height: 58,
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 12),
                child: Row(
                  children: [
                    IconButton(
                      onPressed: widget.onClose,
                      icon: const Icon(Icons.close, size: 20),
                      tooltip: tr.t('Zavřít', 'Close'),
                    ),
                    const SizedBox(width: 8),
                    Text(
                      chat.group
                          ? tr.t('Info o skupině', 'Group info')
                          : tr.t('Info o kontaktu', 'Contact info'),
                      style: const TextStyle(
                        fontSize: 16,
                        fontWeight: FontWeight.w600,
                        color: WaPalette.textPrimary,
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
          Expanded(
            child: Material(
              color: p.bg,
              child: ListView(
              padding: const EdgeInsets.all(16),
              children: [
                Center(
                  child: WaAvatar(
                    name: displayName,
                    avatarPath: chat.avatar,
                    radius: 48,
                    isGroup: chat.group,
                  ),
                ),
                const SizedBox(height: 12),
                Center(
                  child: Text(
                    displayName,
                    textAlign: TextAlign.center,
                    style: const TextStyle(
                      fontSize: 19,
                      fontWeight: FontWeight.bold,
                      color: WaPalette.textPrimary,
                    ),
                  ),
                ),
                const SizedBox(height: 4),
                Center(
                  child: Text(
                    chat.group
                        ? '${group?.participants.length ?? chat.participantsCount} ${tr.t('členů', 'participants')}'
                        : formatJidPhone(chat.jid),
                    style: const TextStyle(
                      fontSize: 13,
                      color: WaPalette.textSecondary,
                    ),
                  ),
                ),
                const SizedBox(height: 16),
                Divider(color: p.divider),
                if (chat.group)
                  _buildGroupDetails(s, group, p, tr)
                else
                  _buildContactDetails(s, chat, p, tr),
                Divider(color: p.divider),
                _buildMediaGallery(s, p, tr),
                Divider(color: p.divider),
                _buildChatSettings(s, chat, group, p, tr),
              ],
            ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _sectionTitle(String text) {
    return Padding(
      padding: const EdgeInsets.only(top: 10, bottom: 6),
      child: Text(
        text,
        style: const TextStyle(
          fontSize: 12,
          fontWeight: FontWeight.w700,
          color: WaPalette.accent,
          letterSpacing: 0.4,
        ),
      ),
    );
  }

  Widget _infoRow(String label, String value) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(
        children: [
          Text(
            label,
            style: const TextStyle(fontSize: 13, color: WaPalette.textSecondary),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Text(
              value,
              textAlign: TextAlign.right,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(fontSize: 13, color: WaPalette.textPrimary),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildContactDetails(
      Snapshot s, ChatItem chat, WaPalette p, Tr tr) {
    final details = s.contactDetails[chat.jid];
    final presence = s.presence[chat.jid];
    final statusStr = presence == null
        ? tr.t('neznámé', 'unknown')
        : presence.online
            ? tr.t('online', 'online')
            : presence.lastSeen != null
                ? '${tr.t('naposledy', 'last seen')} ${_fmtSeen(presence.lastSeen!)}'
                : tr.t('neznámé', 'unknown');
    final blocked = details?.blocked ?? false;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _sectionTitle(tr.t('O KONTAKTU', 'ABOUT CONTACT')),
        _infoRow(tr.t('Telefon', 'Phone'), formatJidPhone(chat.jid)),
        if (details?.verifiedName != null && details!.verifiedName!.isNotEmpty)
          _infoRow(tr.t('Ověřený název', 'Verified name'), details.verifiedName!),
        if (details?.business ?? false)
          _infoRow(tr.t('Účet', 'Account'), tr.t('Firma', 'Business')),
        _infoRow(tr.t('Stav', 'Status'), statusStr),
        if (blocked)
          _infoRow(tr.t('Blokace', 'Blocked'), tr.t('Kontakt je blokován', 'Contact is blocked')),
        const SizedBox(height: 8),
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: [
            OutlinedButton.icon(
              onPressed: () => widget.onEditContactName(chat),
              icon: const Icon(Icons.edit_outlined, size: 16),
              label: Text(tr.t('Upravit jméno', 'Edit name')),
            ),
            OutlinedButton.icon(
              onPressed: () async {
                if (blocked) {
                  widget.bridge.unblockContact(chat.jid);
                } else {
                  final ok = await widget.onConfirm(
                    '${tr.t('Blokovat', 'Block')} ${chat.name}?',
                    tr.t(
                      'Nebudou ti chodit zprávy ani hovory a nebude vidět, že jsi online.',
                      'Blocked contacts cannot send you messages or call you.',
                    ),
                    tr.t('Blokovat', 'Block'),
                  );
                  if (ok) widget.bridge.blockContact(chat.jid);
                }
              },
              icon: Icon(
                blocked ? Icons.lock_open : Icons.block,
                size: 16,
                color: blocked ? WaPalette.accent : WaPalette.danger,
              ),
              label: Text(
                blocked
                    ? tr.t('Odblokovat kontakt', 'Unblock contact')
                    : tr.t('Blokovat kontakt', 'Block contact'),
                style: TextStyle(
                    color: blocked ? WaPalette.accent : WaPalette.danger),
              ),
            ),
          ],
        ),
        const SizedBox(height: 8),
      ],
    );
  }

  Widget _buildGroupDetails(
      Snapshot s, GroupInfo? group, WaPalette p, Tr tr) {
    if (group == null) {
      return Padding(
        padding: const EdgeInsets.symmetric(vertical: 16),
        child: Row(
          children: [
            const SizedBox(
              width: 16,
              height: 16,
              child: CircularProgressIndicator(strokeWidth: 2),
            ),
            const SizedBox(width: 10),
            Text(tr.t('Načítám informace o skupině…', 'Loading group info…')),
          ],
        ),
      );
    }

    final admin = group.isAdmin(s.self);
    final participants = [...group.participants]
      ..sort((a, b) =>
          _nameOf(s, a).toLowerCase().compareTo(_nameOf(s, b).toLowerCase()));

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _sectionTitle(tr.t('NÁZEV SKUPINY', 'GROUP SUBJECT')),
        if (_editingSubject)
          Column(
            children: [
              TextField(
                controller: _subjectCtrl,
                decoration: InputDecoration(
                  isDense: true,
                  filled: true,
                  fillColor: p.surface,
                ),
              ),
              Row(
                mainAxisAlignment: MainAxisAlignment.end,
                children: [
                  TextButton(
                    onPressed: () => setState(() => _editingSubject = false),
                    child: Text(tr.t('Zrušit', 'Cancel')),
                  ),
                  TextButton(
                    onPressed: () {
                      final txt = _subjectCtrl.text.trim();
                      if (txt.isNotEmpty) {
                        widget.bridge.setSubject(widget.chat.jid, txt);
                      }
                      setState(() => _editingSubject = false);
                    },
                    child: Text(tr.t('Uložit', 'Save')),
                  ),
                ],
              ),
            ],
          )
        else
          Row(
            children: [
              Expanded(
                child: Text(group.subject,
                    style: const TextStyle(color: WaPalette.textPrimary)),
              ),
              if (admin)
                IconButton(
                  onPressed: () {
                    _subjectCtrl.text = group.subject;
                    setState(() => _editingSubject = true);
                  },
                  icon: const Icon(Icons.edit_outlined, size: 17),
                  visualDensity: VisualDensity.compact,
                ),
            ],
          ),
        _sectionTitle(tr.t('POPIS SKUPINY', 'DESCRIPTION')),
        if (_editingDesc)
          Column(
            children: [
              TextField(
                controller: _descCtrl,
                minLines: 2,
                maxLines: 4,
                decoration: InputDecoration(
                  isDense: true,
                  filled: true,
                  fillColor: p.surface,
                ),
              ),
              Row(
                mainAxisAlignment: MainAxisAlignment.end,
                children: [
                  TextButton(
                    onPressed: () => setState(() => _editingDesc = false),
                    child: Text(tr.t('Zrušit', 'Cancel')),
                  ),
                  TextButton(
                    onPressed: () {
                      widget.bridge.setDescription(
                          widget.chat.jid, _descCtrl.text.trim());
                      setState(() => _editingDesc = false);
                    },
                    child: Text(tr.t('Uložit', 'Save')),
                  ),
                ],
              ),
            ],
          )
        else
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(
                child: Text(
                  (group.description ?? '').trim().isEmpty
                      ? tr.t('Skupina zatím nemá popis.', 'No description yet.')
                      : group.description!,
                  style: TextStyle(
                    fontSize: 13,
                    color: (group.description ?? '').trim().isEmpty
                        ? WaPalette.textSecondary
                        : WaPalette.textPrimary,
                  ),
                ),
              ),
              if (admin)
                IconButton(
                  onPressed: () {
                    _descCtrl.text = group.description ?? '';
                    setState(() => _editingDesc = true);
                  },
                  icon: const Icon(Icons.edit_outlined, size: 17),
                  visualDensity: VisualDensity.compact,
                ),
            ],
          ),
        const SizedBox(height: 6),
        if (admin) ...[
          SwitchListTile(
            dense: true,
            contentPadding: EdgeInsets.zero,
            value: group.announcement,
            onChanged: (v) => widget.bridge.setAnnounce(widget.chat.jid, v),
            title: Text(
              tr.t('Zprávy mohou psát jen admini', 'Only admins can send'),
              style: const TextStyle(fontSize: 13),
            ),
          ),
          SwitchListTile(
            dense: true,
            contentPadding: EdgeInsets.zero,
            value: group.locked,
            onChanged: (v) => widget.bridge.setLocked(widget.chat.jid, v),
            title: Text(
              tr.t('Info skupiny mohou měnit jen admini',
                  'Only admins can edit info'),
              style: const TextStyle(fontSize: 13),
            ),
          ),
        ] else ...[
          if (group.announcement)
            _infoRow(tr.t('Zprávy', 'Messages'), tr.t('jen správci', 'admins only')),
          if (group.locked)
            _infoRow(tr.t('Úpravy', 'Edits'), tr.t('jen správci', 'admins only')),
        ],
        _sectionTitle('${tr.t('ČLENOVÉ', 'MEMBERS')} (${participants.length})'),
        if (admin)
          Padding(
            padding: const EdgeInsets.only(bottom: 6),
            child: OutlinedButton.icon(
              onPressed: () => widget.onOpenAddMembers(group),
              icon: const Icon(Icons.person_add_outlined, size: 17),
              label: Text(tr.t('Přidat člena', 'Add member')),
            ),
          ),
        ConstrainedBox(
          constraints: const BoxConstraints(maxHeight: 230),
          child: ListView.builder(
            shrinkWrap: true,
            itemCount: participants.length,
            itemBuilder: (_, idx) {
              final jid = participants[idx];
              final isMe = sameJidUser(jid, s.self);
              final isMemberAdmin = group.isAdmin(jid);
              final name = isMe
                  ? tr.t('Vy', 'You')
                  : _nameOf(s, jid);
              return ListTile(
                dense: true,
                contentPadding: EdgeInsets.zero,
                leading: WaAvatar(
                  name: name,
                  avatarPath: s.contactDetails[jid]?.avatar,
                  radius: 16,
                ),
                title: Row(
                  children: [
                    Expanded(
                      child: Text(
                        name,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(fontSize: 13.5),
                      ),
                    ),
                    if (isMemberAdmin)
                      Container(
                        padding: const EdgeInsets.symmetric(
                            horizontal: 6, vertical: 1),
                        decoration: BoxDecoration(
                          color: WaPalette.accent.withValues(alpha: 0.18),
                          borderRadius: BorderRadius.circular(4),
                        ),
                        child: Text(
                          tr.t('správce', 'admin'),
                          style: const TextStyle(
                            fontSize: 10.5,
                            color: WaPalette.accent,
                          ),
                        ),
                      ),
                  ],
                ),
                trailing: admin && !isMe
                    ? PopupMenuButton<String>(
                        icon: const Icon(Icons.more_horiz, size: 18),
                        color: p.surfaceElevated,
                        onSelected: (act) async {
                          switch (act) {
                            case 'promote':
                              widget.bridge
                                  .promoteParticipants(widget.chat.jid, [jid]);
                            case 'demote':
                              widget.bridge
                                  .demoteParticipants(widget.chat.jid, [jid]);
                            case 'remove':
                              final ok = await widget.onConfirm(
                                '${tr.t('Odebrat', 'Remove')} $name?',
                                tr.t('Tato osoba přestane dostávat zprávy skupiny.',
                                    'This person will stop receiving group messages.'),
                                tr.t('Odebrat', 'Remove'),
                              );
                              if (ok) {
                                widget.bridge
                                    .removeParticipants(widget.chat.jid, [jid]);
                              }
                          }
                        },
                        itemBuilder: (_) => [
                          if (isMemberAdmin)
                            PopupMenuItem(
                              value: 'demote',
                              child: Text(tr.t('Odebrat admina', 'Dismiss as admin')),
                            )
                          else
                            PopupMenuItem(
                              value: 'promote',
                              child: Text(tr.t('Povýšit na admina', 'Make group admin')),
                            ),
                          PopupMenuItem(
                            value: 'remove',
                            child: Text(
                              tr.t('Odebrat ze skupiny', 'Remove from group'),
                              style: const TextStyle(color: WaPalette.danger),
                            ),
                          ),
                        ],
                      )
                    : null,
              );
            },
          ),
        ),
        _sectionTitle(tr.t('POZVÁNKOVÝ ODKAZ', 'INVITE LINK')),
        Row(
          children: [
            Expanded(
              child: Text(
                group.inviteLink ?? tr.t('Odkaz není načtený', 'Link not loaded'),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(
                    fontSize: 12, color: WaPalette.textSecondary),
              ),
            ),
            if (group.inviteLink == null)
              TextButton(
                onPressed: () => widget.bridge.inviteLink(widget.chat.jid),
                child: Text(tr.t('Získat odkaz', 'Get link')),
              )
            else
              IconButton(
                onPressed: () {
                  Clipboard.setData(ClipboardData(text: group.inviteLink!));
                  ScaffoldMessenger.of(context).showSnackBar(
                    SnackBar(
                      content: Text(tr.t('Odkaz zkopírován', 'Invite link copied')),
                    ),
                  );
                },
                icon: const Icon(Icons.copy, size: 17),
                tooltip: tr.t('Kopírovat odkaz', 'Copy link'),
              ),
          ],
        ),
        const SizedBox(height: 6),
        OutlinedButton.icon(
          onPressed: () async {
            final ok = await widget.onConfirm(
              '${tr.t('Opustit skupinu', 'Leave group')} ${group.subject}?',
              tr.t('Zprávy, které jsi poslal, zůstanou ostatním.',
                  'Messages you sent will remain visible to others.'),
              tr.t('Opustit', 'Leave'),
            );
            if (ok) {
              widget.bridge.leaveGroup(widget.chat.jid);
              widget.onClose();
            }
          },
          icon: const Icon(Icons.logout, size: 17, color: WaPalette.danger),
          label: Text(
            tr.t('Opustit skupinu', 'Leave group'),
            style: const TextStyle(color: WaPalette.danger),
          ),
        ),
        const SizedBox(height: 8),
      ],
    );
  }

  Widget _buildMediaGallery(Snapshot s, WaPalette p, Tr tr) {
    final g = _gallery;
    final mediaMsgs = g?.media ??
        s.messages
            .where((m) =>
                m.media == 'image' ||
                m.media == 'video' ||
                m.media == 'sticker')
            .toList()
            .reversed
            .toList();
    final docMsgs = g?.docs ??
        s.messages
            .where((m) => m.media == 'document')
            .toList()
            .reversed
            .toList();
    final linkRows = g != null
        ? g.links
            .map((l) => (
                  Msg(
                    id: l.id,
                    sender: '',
                    text: l.text,
                    ts: l.ts,
                    fromMe: l.fromMe,
                    status: 'read',
                  ),
                  l.url,
                ))
            .toList()
        : <(Msg, String)>[
            for (final m in s.messages.reversed)
              if (m.text.isNotEmpty)
                for (final url in extractLinks(m.text)) (m, url),
          ];

    final starredMsgs = s.messages.where((m) => m.starred).toList().reversed.toList();
    final totalMsgs = g?.totalMessages ??
        (s.selectedTotalMessages > 0
            ? s.selectedTotalMessages
            : s.messages.length);
    final syncing = (g?.syncing ?? false) || s.isHistorySyncing(widget.chat.jid);
    final exhausted =
        (g?.exhausted ?? false) || s.isHistoryExhausted(widget.chat.jid);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _sectionTitle(tr.t('MÉDIA, ODKAZY A DOKUMENTY', 'MEDIA, LINKS & DOCS')),
        Padding(
          padding: const EdgeInsets.only(bottom: 8),
          child: Row(
            children: [
              if (syncing)
                const Padding(
                  padding: EdgeInsets.only(right: 6),
                  child: SizedBox(
                    width: 12,
                    height: 12,
                    child: CircularProgressIndicator(
                      strokeWidth: 1.8,
                      color: WaPalette.accent,
                    ),
                  ),
                ),
              Expanded(
                child: Text(
                  syncing
                      ? tr.t(
                          'Stahuji historii z telefonu ($totalMsgs zpráv)…',
                          'Fetching phone history ($totalMsgs msgs)…',
                        )
                      : exhausted
                          ? tr.t(
                              'Celá historie ($totalMsgs zpráv)',
                              'Full history ($totalMsgs msgs)',
                            )
                          : tr.t(
                              'Načteno $totalMsgs zpráv',
                              '$totalMsgs loaded msgs',
                            ),
                  style: const TextStyle(
                      fontSize: 11.5, color: WaPalette.textSecondary),
                ),
              ),
              if (syncing)
                TextButton(
                  onPressed: widget.bridge.cancelHistorySync,
                  style: TextButton.styleFrom(
                    visualDensity: VisualDensity.compact,
                    padding: const EdgeInsets.symmetric(horizontal: 8),
                  ),
                  child: Text(tr.t('Zastavit', 'Stop'),
                      style: const TextStyle(fontSize: 11)),
                )
              else
                TextButton(
                  onPressed: () =>
                      widget.bridge.syncFullHistory(chat: widget.chat.jid),
                  style: TextButton.styleFrom(
                    visualDensity: VisualDensity.compact,
                    padding: const EdgeInsets.symmetric(horizontal: 8),
                  ),
                  child: Text(
                    exhausted
                        ? tr.t('Obnovit', 'Refresh')
                        : tr.t('Načíst vše', 'Sync all'),
                    style: const TextStyle(fontSize: 11),
                  ),
                ),
            ],
          ),
        ),
        Wrap(
          spacing: 6,
          children: [
            ChoiceChip(
              label: Text('${tr.t('Média', 'Media')} (${mediaMsgs.length})',
                  style: const TextStyle(fontSize: 11.5)),
              selected: _galleryTab == 0,
              onSelected: (_) => setState(() => _galleryTab = 0),
            ),
            ChoiceChip(
              label: Text('${tr.t('Dokumenty', 'Docs')} (${docMsgs.length})',
                  style: const TextStyle(fontSize: 11.5)),
              selected: _galleryTab == 1,
              onSelected: (_) => setState(() => _galleryTab = 1),
            ),
            ChoiceChip(
              label: Text('${tr.t('Odkazy', 'Links')} (${linkRows.length})',
                  style: const TextStyle(fontSize: 11.5)),
              selected: _galleryTab == 2,
              onSelected: (_) => setState(() => _galleryTab = 2),
            ),
            ChoiceChip(
              label: Text(
                  '★ ${tr.t('Hvězdičkou', 'Starred')} (${starredMsgs.length})',
                  style: const TextStyle(fontSize: 11.5)),
              selected: _galleryTab == 3,
              onSelected: (_) => setState(() => _galleryTab = 3),
            ),
          ],
        ),
        const SizedBox(height: 8),
        if (_galleryTab == 0)
          mediaMsgs.isEmpty
              ? Text(
                  tr.t('Zatím žádné fotky ani videa.', 'No photos or videos yet.'),
                  style: const TextStyle(
                      fontSize: 12, color: WaPalette.textSecondary),
                )
              : SizedBox(
                  height: 165,
                  child: GridView.builder(
                    gridDelegate:
                        const SliverGridDelegateWithFixedCrossAxisCount(
                      crossAxisCount: 4,
                      mainAxisSpacing: 4,
                      crossAxisSpacing: 4,
                    ),
                    itemCount: mediaMsgs.length,
                    itemBuilder: (_, idx) {
                      final m = mediaMsgs[idx];
                      return InkWell(
                        onTap: () {
                          if (m.media == 'video' &&
                              m.mediaPath != null &&
                              File(m.mediaPath!).existsSync()) {
                            showDialog<void>(
                              context: context,
                              builder: (_) => VideoLightboxDialog(
                                path: m.mediaPath!,
                                caption: m.caption,
                                loopMuted: m.gifPlayback,
                                bridge: widget.bridge,
                                tr: tr,
                              ),
                            );
                          } else {
                            widget.onJumpToMessage(m.id);
                          }
                        },
                        borderRadius: BorderRadius.circular(6),
                        child: ClipRRect(
                          borderRadius: BorderRadius.circular(6),
                          child: Container(
                            color: p.surface,
                            child: _galleryThumb(m),
                          ),
                        ),
                      );
                    },
                  ),
                ),
        if (_galleryTab == 1)
          docMsgs.isEmpty
              ? Text(
                  tr.t('Zatím žádné dokumenty.', 'No documents yet.'),
                  style: const TextStyle(
                      fontSize: 12, color: WaPalette.textSecondary),
                )
              : ConstrainedBox(
                  constraints: const BoxConstraints(maxHeight: 160),
                  child: ListView.builder(
                    shrinkWrap: true,
                    itemCount: docMsgs.length,
                    itemBuilder: (_, idx) {
                      final m = docMsgs[idx];
                      final label = m.mediaPath != null
                          ? m.mediaPath!.split(Platform.pathSeparator).last
                          : (m.caption?.isNotEmpty ?? false)
                              ? m.caption!
                              : (m.text.isNotEmpty
                                  ? m.text
                                  : tr.t('Dokument', 'Document'));
                      return ListTile(
                        dense: true,
                        contentPadding: EdgeInsets.zero,
                        leading: const Icon(Icons.insert_drive_file_outlined,
                            size: 18, color: WaPalette.accent),
                        title: Text(label,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(fontSize: 12.5)),
                        onTap: () => widget.onJumpToMessage(m.id),
                      );
                    },
                  ),
                ),
        if (_galleryTab == 2)
          linkRows.isEmpty
              ? Text(
                  tr.t('Zatím žádné odkazy.', 'No links yet.'),
                  style: const TextStyle(
                      fontSize: 12, color: WaPalette.textSecondary),
                )
              : ConstrainedBox(
                  constraints: const BoxConstraints(maxHeight: 160),
                  child: ListView.builder(
                    shrinkWrap: true,
                    itemCount: linkRows.length,
                    itemBuilder: (_, idx) {
                      final (m, url) = linkRows[idx];
                      return ListTile(
                        dense: true,
                        contentPadding: EdgeInsets.zero,
                        leading: const Icon(Icons.link,
                            size: 18, color: WaPalette.linkBlue),
                        title: Text(url,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(
                                fontSize: 12.5, color: WaPalette.linkBlue)),
                        trailing: IconButton(
                          icon: const Icon(Icons.open_in_new, size: 15),
                          onPressed: () => widget.bridge.openFile(url),
                        ),
                        onTap: () => widget.onJumpToMessage(m.id),
                      );
                    },
                  ),
                ),
        if (_galleryTab == 3)
          starredMsgs.isEmpty
              ? Text(
                  tr.t('V tomto chatu nemáte žádné hvězdičkované zprávy.',
                      'No starred messages in this chat.'),
                  style: const TextStyle(
                      fontSize: 12, color: WaPalette.textSecondary),
                )
              : ConstrainedBox(
                  constraints: const BoxConstraints(maxHeight: 160),
                  child: ListView.builder(
                    shrinkWrap: true,
                    itemCount: starredMsgs.length,
                    itemBuilder: (_, idx) {
                      final m = starredMsgs[idx];
                      return ListTile(
                        dense: true,
                        contentPadding: EdgeInsets.zero,
                        leading: const Icon(Icons.star_rounded,
                            size: 17, color: Colors.amber),
                        title: Text(
                          m.text.isNotEmpty ? m.text : (m.media ?? '📎'),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(fontSize: 12.5),
                        ),
                        onTap: () => widget.onJumpToMessage(m.id),
                      );
                    },
                  ),
                ),
        const SizedBox(height: 8),
      ],
    );
  }

  Widget _galleryThumb(Msg m) {
    if (m.downloaded && m.mediaPath != null && m.media != 'video') {
      return Image.file(
        File(m.mediaPath!),
        fit: BoxFit.cover,
        cacheWidth: 160,
        errorBuilder: (_, _, _) => _thumbOrIcon(m),
      );
    }
    return _thumbOrIcon(m);
  }

  Widget _thumbOrIcon(Msg m) {
    final bytes = m.thumbBytes;
    if (bytes != null) {
      return Stack(
        fit: StackFit.expand,
        children: [
          Image.memory(bytes, fit: BoxFit.cover),
          if (m.media == 'video')
            const Center(
              child: Icon(Icons.play_circle_filled,
                  color: Colors.white70, size: 22),
            ),
        ],
      );
    }
    return Icon(
      m.media == 'video' ? Icons.videocam_outlined : Icons.image_outlined,
      color: WaPalette.textSecondary,
    );
  }

  Widget _buildChatSettings(
      Snapshot s, ChatItem chat, GroupInfo? group, WaPalette p, Tr tr) {
    final admin = group == null || group.isAdmin(s.self);
    final eph = s.ephemeral ?? group?.ephemeral ?? 0;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _sectionTitle(tr.t('NASTAVENÍ CHATU', 'CHAT SETTINGS')),
        Row(
          children: [
            Expanded(
              child: Text(tr.t('Umlčení', 'Mute'),
                  style: const TextStyle(fontSize: 13.5)),
            ),
            DropdownButton<String>(
              value: chat.muted ? 'muted' : 'off',
              dropdownColor: p.surfaceElevated,
              items: [
                DropdownMenuItem(
                    value: 'off', child: Text(tr.t('Vypnuto', 'Off'))),
                if (chat.muted)
                  DropdownMenuItem(
                      value: 'muted', child: Text(tr.t('Umlčeno', 'Muted'))),
                DropdownMenuItem(
                    value: '8h', child: Text(tr.t('8 hodin', '8 hours'))),
                DropdownMenuItem(
                    value: '1w', child: Text(tr.t('1 týden', '1 week'))),
                DropdownMenuItem(
                    value: 'always', child: Text(tr.t('Vždy', 'Always'))),
              ],
              onChanged: (v) {
                switch (v) {
                  case 'off':
                    widget.bridge.unmuteChat(chat.jid);
                  case '8h':
                    widget.bridge.muteChat(chat.jid, hours: 8);
                  case '1w':
                    widget.bridge.muteChat(chat.jid, hours: 24 * 7);
                  case 'always':
                    widget.bridge.muteChat(chat.jid);
                }
              },
            ),
          ],
        ),
        Row(
          children: [
            Expanded(
              child: Text(tr.t('Mizející zprávy', 'Disappearing messages'),
                  style: const TextStyle(fontSize: 13.5)),
            ),
            DropdownButton<int>(
              value: _ephemeralValues.contains(eph) ? eph : 0,
              dropdownColor: p.surfaceElevated,
              items: [
                for (final v in _ephemeralValues)
                  DropdownMenuItem(
                    value: v,
                    child: Text(_ephemeralLabel(v, tr)),
                  ),
              ],
              onChanged: admin
                  ? (v) => widget.bridge.setEphemeral(chat.jid, v ?? 0)
                  : null,
            ),
          ],
        ),
        const SizedBox(height: 10),
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: [
            OutlinedButton.icon(
              onPressed: () => widget.onOpenExport(chat),
              icon: const Icon(Icons.file_download_outlined, size: 16),
              label: Text(tr.t('Exportovat chat…', 'Export chat…')),
            ),
            OutlinedButton.icon(
              onPressed: () async {
                final ok = await widget.onConfirm(
                  tr.t('Vyčistit zprávy', 'Clear messages'),
                  tr.t('Historie zmizí jen u tebe, ostatní ji pořád uvidí.',
                      'Messages will be cleared locally only.'),
                  tr.t('Vyčistit', 'Clear'),
                );
                if (ok) widget.bridge.clearChat(chat.jid);
              },
              icon: const Icon(Icons.cleaning_services_outlined,
                  size: 16, color: WaPalette.danger),
              label: Text(
                tr.t('Vymazat zprávy', 'Clear messages'),
                style: const TextStyle(color: WaPalette.danger),
              ),
            ),
          ],
        ),
      ],
    );
  }

  String _nameOf(Snapshot s, String jid) {
    final name = s.contacts[jid];
    if (name != null && name.isNotEmpty) return name;
    return formatJidPhone(jid);
  }

  String _fmtSeen(DateTime t) {
    String two(int n) => n.toString().padLeft(2, '0');
    return '${two(t.day)}.${two(t.month)}. ${two(t.hour)}:${two(t.minute)}';
  }
}
