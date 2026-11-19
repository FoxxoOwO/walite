import 'dart:async';
import 'dart:io';

import 'package:file_selector/file_selector.dart';
import 'package:material_ui/material_ui.dart';
import 'package:flutter/services.dart';
import 'package:media_kit/media_kit.dart';
import 'package:media_kit_video/media_kit_video.dart';

import '../bridge.dart';
import '../i18n.dart';
import '../theme.dart';
import 'avatar.dart';

/// Start chat by phone number, join group by invite link, or open Contacts/New Group.
class NewChatDialog extends StatefulWidget {
  const NewChatDialog({
    super.key,
    required this.bridge,
    required this.palette,
    required this.tr,
    required this.onOpenNewGroup,
    required this.onOpenContacts,
  });

  final Bridge bridge;
  final WaPalette palette;
  final Tr tr;
  final VoidCallback onOpenNewGroup;
  final VoidCallback onOpenContacts;

  @override
  State<NewChatDialog> createState() => _NewChatDialogState();
}

class _NewChatDialogState extends State<NewChatDialog> {
  final _phoneCtrl = TextEditingController();
  final _linkCtrl = TextEditingController();

  @override
  void dispose() {
    _phoneCtrl.dispose();
    _linkCtrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final p = widget.palette;
    final tr = widget.tr;
    return AlertDialog(
      backgroundColor: p.surface,
      title: Text(tr.t('Nová konverzace', 'New conversation')),
      content: SizedBox(
        width: 400,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Expanded(
                  child: OutlinedButton.icon(
                    onPressed: () {
                      Navigator.pop(context);
                      widget.onOpenNewGroup();
                    },
                    icon: const Icon(Icons.group_add_outlined, size: 18),
                    label: Text(tr.t('Nová skupina', 'New group')),
                  ),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: OutlinedButton.icon(
                    onPressed: () {
                      Navigator.pop(context);
                      widget.onOpenContacts();
                    },
                    icon: const Icon(Icons.contacts_outlined, size: 18),
                    label: Text(tr.t('Kontakty', 'Contacts')),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 14),
            Divider(color: p.divider),
            const SizedBox(height: 10),
            Text(
              tr.t('Začít chat podle telefonního čísla:',
                  'Start chat with phone number:'),
              style: const TextStyle(fontSize: 13),
            ),
            const SizedBox(height: 6),
            Row(
              children: [
                Expanded(
                  child: TextField(
                    controller: _phoneCtrl,
                    autofocus: true,
                    onSubmitted: (_) => _startChat(),
                    decoration: InputDecoration(
                      isDense: true,
                      filled: true,
                      fillColor: p.bg,
                      hintText: '+420 123 456 789',
                      border: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(8),
                        borderSide: BorderSide.none,
                      ),
                    ),
                  ),
                ),
                const SizedBox(width: 8),
                FilledButton(
                  onPressed: _startChat,
                  style: FilledButton.styleFrom(
                      backgroundColor: WaPalette.accentDark),
                  child: const Text('Chat'),
                ),
              ],
            ),
            const SizedBox(height: 14),
            Divider(color: p.divider),
            const SizedBox(height: 10),
            Text(
              tr.t('Připojit se do skupiny odkazem:',
                  'Join group via invite link:'),
              style: const TextStyle(fontSize: 13),
            ),
            const SizedBox(height: 6),
            Row(
              children: [
                Expanded(
                  child: TextField(
                    controller: _linkCtrl,
                    onSubmitted: (_) => _joinGroup(),
                    decoration: InputDecoration(
                      isDense: true,
                      filled: true,
                      fillColor: p.bg,
                      hintText: 'https://chat.whatsapp.com/…',
                      border: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(8),
                        borderSide: BorderSide.none,
                      ),
                    ),
                  ),
                ),
                const SizedBox(width: 8),
                FilledButton(
                  onPressed: _joinGroup,
                  style: FilledButton.styleFrom(
                      backgroundColor: WaPalette.accentDark),
                  child: Text(tr.t('Připojit', 'Join')),
                ),
              ],
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: Text(tr.t('Zavřít', 'Close')),
        ),
      ],
    );
  }

  void _startChat() {
    final raw = _phoneCtrl.text.trim();
    if (raw.isEmpty) return;
    widget.bridge.startChat(raw);
    Navigator.pop(context);
  }

  void _joinGroup() {
    final code = _linkCtrl.text.trim();
    if (code.isEmpty) return;
    widget.bridge.joinGroup(code);
    Navigator.pop(context);
  }
}

/// Multi-select contact picker for creating a group or adding members.
class GroupMemberPickerDialog extends StatefulWidget {
  const GroupMemberPickerDialog({
    super.key,
    required this.snapshot,
    required this.bridge,
    required this.palette,
    required this.tr,
    this.existingGroupChatJid,
    this.excludeJids = const {},
  });

  final Snapshot snapshot;
  final Bridge bridge;
  final WaPalette palette;
  final Tr tr;
  final String? existingGroupChatJid;
  final Set<String> excludeJids;

  @override
  State<GroupMemberPickerDialog> createState() =>
      _GroupMemberPickerDialogState();
}

class _GroupMemberPickerDialogState extends State<GroupMemberPickerDialog> {
  final _subjectCtrl = TextEditingController();
  final _searchCtrl = TextEditingController();
  final _selected = <String>{};

  bool get _isCreate => widget.existingGroupChatJid == null;

  @override
  void dispose() {
    _subjectCtrl.dispose();
    _searchCtrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final p = widget.palette;
    final tr = widget.tr;
    final q = _searchCtrl.text.trim().toLowerCase();
    final rows = widget.snapshot.contactDetails.values
        .where((c) => !widget.excludeJids.contains(c.jid))
        .where((c) =>
            q.isEmpty ||
            c.name.toLowerCase().contains(q) ||
            formatJidPhone(c.jid).toLowerCase().contains(q))
        .toList()
      ..sort((a, b) => a.name.toLowerCase().compareTo(b.name.toLowerCase()));

    final ready = _isCreate
        ? _subjectCtrl.text.trim().isNotEmpty && _selected.isNotEmpty
        : _selected.isNotEmpty;

    return AlertDialog(
      backgroundColor: p.surface,
      title: Text(_isCreate
          ? tr.t('Nová skupina', 'New group')
          : tr.t('Přidat členy', 'Add members')),
      content: SizedBox(
        width: 400,
        height: 430,
        child: Column(
          children: [
            if (_isCreate) ...[
              TextField(
                controller: _subjectCtrl,
                autofocus: true,
                onChanged: (_) => setState(() {}),
                decoration: InputDecoration(
                  isDense: true,
                  filled: true,
                  fillColor: p.bg,
                  labelText: tr.t('Název skupiny', 'Group subject'),
                  hintText: tr.t('Např. Rodina', 'e.g. Family'),
                  border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(8),
                    borderSide: BorderSide.none,
                  ),
                ),
              ),
              const SizedBox(height: 10),
            ],
            Row(
              children: [
                Expanded(
                  child: TextField(
                    controller: _searchCtrl,
                    onChanged: (_) => setState(() {}),
                    decoration: InputDecoration(
                      isDense: true,
                      filled: true,
                      fillColor: p.bg,
                      prefixIcon: const Icon(Icons.search, size: 18),
                      hintText: tr.t('Hledat kontakty…', 'Search contacts…'),
                      border: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(8),
                        borderSide: BorderSide.none,
                      ),
                    ),
                  ),
                ),
                const SizedBox(width: 10),
                Text(
                  '${tr.t('Vybráno', 'Selected')}: ${_selected.length}',
                  style: const TextStyle(
                      fontSize: 12, color: WaPalette.textSecondary),
                ),
              ],
            ),
            const SizedBox(height: 8),
            Expanded(
              child: rows.isEmpty
                  ? Center(
                      child: Text(
                        tr.t('Žádné kontakty nenalezeny.', 'No contacts found.'),
                        style: const TextStyle(color: WaPalette.textSecondary),
                      ),
                    )
                  : ListView.builder(
                      itemCount: rows.length,
                      itemBuilder: (_, idx) {
                        final c = rows[idx];
                        final checked = _selected.contains(c.jid);
                        final label =
                            c.name.isNotEmpty ? c.name : formatJidPhone(c.jid);
                        return CheckboxListTile(
                          dense: true,
                          value: checked,
                          activeColor: WaPalette.accent,
                          onChanged: (v) => setState(() {
                            if (v ?? false) {
                              _selected.add(c.jid);
                            } else {
                              _selected.remove(c.jid);
                            }
                          }),
                          secondary: WaAvatar(
                            name: label,
                            avatarPath: c.avatar,
                            radius: 17,
                          ),
                          title: Text(label, maxLines: 1, overflow: TextOverflow.ellipsis),
                          subtitle: Text(
                            formatJidPhone(c.jid),
                            style: const TextStyle(
                                fontSize: 11, color: WaPalette.textSecondary),
                          ),
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
          child: Text(tr.t('Zrušit', 'Cancel')),
        ),
        FilledButton(
          onPressed: ready
              ? () {
                  if (_isCreate) {
                    widget.bridge.createGroup(
                      _subjectCtrl.text.trim(),
                      _selected.toList(),
                    );
                  } else {
                    widget.bridge.addParticipants(
                      widget.existingGroupChatJid!,
                      _selected.toList(),
                    );
                  }
                  Navigator.pop(context);
                }
              : null,
          style: FilledButton.styleFrom(backgroundColor: WaPalette.accentDark),
          child: Text(_isCreate
              ? tr.t('Vytvořit skupinu', 'Create group')
              : tr.t('Přidat', 'Add')),
        ),
      ],
    );
  }
}

/// Contacts browser: open chat or share contact as vCard into open chat.
class ContactsDialog extends StatefulWidget {
  const ContactsDialog({
    super.key,
    required this.snapshot,
    required this.bridge,
    required this.palette,
    required this.tr,
  });

  final Snapshot snapshot;
  final Bridge bridge;
  final WaPalette palette;
  final Tr tr;

  @override
  State<ContactsDialog> createState() => _ContactsDialogState();
}

class _ContactsDialogState extends State<ContactsDialog> {
  final _searchCtrl = TextEditingController();

  @override
  void dispose() {
    _searchCtrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final s = widget.snapshot;
    final p = widget.palette;
    final tr = widget.tr;
    final q = _searchCtrl.text.trim().toLowerCase();
    final rows = s.contactDetails.values
        .where((c) =>
            q.isEmpty ||
            c.name.toLowerCase().contains(q) ||
            formatJidPhone(c.jid).toLowerCase().contains(q))
        .toList()
      ..sort((a, b) => a.name.toLowerCase().compareTo(b.name.toLowerCase()));

    return AlertDialog(
      backgroundColor: p.surface,
      title: Text(tr.t('Kontakty', 'Contacts')),
      content: SizedBox(
        width: 400,
        height: 440,
        child: Column(
          children: [
            TextField(
              controller: _searchCtrl,
              autofocus: true,
              onChanged: (_) => setState(() {}),
              decoration: InputDecoration(
                isDense: true,
                filled: true,
                fillColor: p.bg,
                prefixIcon: const Icon(Icons.search, size: 18),
                hintText: tr.t('Hledat kontakt…', 'Search contact…'),
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(8),
                  borderSide: BorderSide.none,
                ),
              ),
            ),
            const SizedBox(height: 8),
            Expanded(
              child: rows.isEmpty
                  ? Center(
                      child: Text(
                        s.contactDetails.isEmpty
                            ? tr.t('Zatím žádné kontakty — synchronizujte je (🔄).',
                                'No contacts yet — sync them (🔄).')
                            : tr.t('Nic nenalezeno.', 'Nothing found.'),
                        textAlign: TextAlign.center,
                        style: const TextStyle(color: WaPalette.textSecondary),
                      ),
                    )
                  : ListView.separated(
                      itemCount: rows.length,
                      separatorBuilder: (_, _) =>
                          Divider(height: 1, color: p.divider),
                      itemBuilder: (_, idx) {
                        final c = rows[idx];
                        final label =
                            c.name.isNotEmpty ? c.name : formatJidPhone(c.jid);
                        return ListTile(
                          dense: true,
                          leading: WaAvatar(
                            name: label,
                            avatarPath: c.avatar,
                            radius: 18,
                          ),
                          title: Row(
                            children: [
                              Expanded(
                                child: Text(label,
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis),
                              ),
                              if (c.blocked)
                                const Icon(Icons.block,
                                    size: 14, color: WaPalette.danger),
                            ],
                          ),
                          subtitle: Text(
                            formatJidPhone(c.jid),
                            style: const TextStyle(
                                fontSize: 11.5, color: WaPalette.textSecondary),
                          ),
                          trailing: s.selected != null
                              ? IconButton(
                                  icon: const Icon(Icons.share_outlined, size: 18),
                                  tooltip: tr.t(
                                      'Sdílet kontakt do otevřeného chatu',
                                      'Share contact to open chat'),
                                  onPressed: () {
                                    widget.bridge
                                        .sendContact(s.selected!, c.jid);
                                    ScaffoldMessenger.of(context).showSnackBar(
                                      SnackBar(
                                        content: Text(
                                          '${tr.t('Kontakt sdílen', 'Contact shared')}: $label',
                                        ),
                                      ),
                                    );
                                  },
                                )
                              : null,
                          onTap: () {
                            widget.bridge.select(c.jid);
                            Navigator.pop(context);
                          },
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
          child: Text(tr.t('Zavřít', 'Close')),
        ),
      ],
    );
  }
}

/// Global message search modal (`Ctrl+F`), backed by Rust's `search_messages`.
class SearchMessagesDialog extends StatefulWidget {
  const SearchMessagesDialog({
    super.key,
    required this.snapshot,
    required this.bridge,
    required this.palette,
    required this.tr,
    required this.initialScope,
    required this.onJump,
  });

  final Snapshot snapshot;
  final Bridge bridge;
  final WaPalette palette;
  final Tr tr;
  final String initialScope; // 'current' | 'all'
  final void Function(String chatJid, String msgId, String? query) onJump;

  @override
  State<SearchMessagesDialog> createState() => _SearchMessagesDialogState();
}

class _SearchMessagesDialogState extends State<SearchMessagesDialog> {
  final _queryCtrl = TextEditingController();
  late String _scope;
  String _sender = 'all';
  String _contentType = 'all';
  String _dateRange = 'all';
  List<SearchHit> _hits = const [];
  int _totalHits = 0;
  int _scannedMessages = 0;
  late Snapshot _snap;
  StreamSubscription<SearchResultsBatch>? _sub;
  StreamSubscription<Snapshot>? _snapSub;
  Timer? _debounce;
  bool _autoSyncedCurrent = false;

  bool get _hasActiveCriteria =>
      _queryCtrl.text.trim().isNotEmpty ||
      _sender != 'all' ||
      _contentType != 'all' ||
      _dateRange != 'all';

  @override
  void initState() {
    super.initState();
    _scope = widget.initialScope;
    _snap = widget.snapshot;
    _sub = widget.bridge.searchBatches.listen((batch) {
      if (mounted) {
        setState(() {
          _hits = batch.items;
          _totalHits = batch.totalHits;
          _scannedMessages = batch.scannedMessages;
        });
      }
    });
    _snapSub = widget.bridge.snapshots.listen((s) {
      if (!mounted) return;
      final changed = s.selectedTotalMessages != _snap.selectedTotalMessages ||
          s.historySyncing.length != _snap.historySyncing.length ||
          s.historyExhausted.length != _snap.historyExhausted.length;
      setState(() => _snap = s);
      if (changed && _hasActiveCriteria) {
        _runSearch();
      }
    });
    _maybeAutoSyncCurrent();
  }

  void _maybeAutoSyncCurrent() {
    final sel = _snap.selected;
    if (_scope == 'current' &&
        !_autoSyncedCurrent &&
        sel != null &&
        !_snap.isHistoryExhausted(sel) &&
        !_snap.isHistorySyncing(sel)) {
      _autoSyncedCurrent = true;
      widget.bridge.syncFullHistory(chat: sel);
    }
  }

  @override
  void dispose() {
    _debounce?.cancel();
    _sub?.cancel();
    _snapSub?.cancel();
    _queryCtrl.dispose();
    super.dispose();
  }

  void _runSearch() {
    _debounce?.cancel();
    _debounce = Timer(const Duration(milliseconds: 120), () {
      widget.bridge.searchMessages(
        query: _queryCtrl.text,
        scope: _scope,
        sender: _sender,
        contentType: _contentType,
        dateRange: _dateRange,
      );
    });
  }

  @override
  Widget build(BuildContext context) {
    final p = widget.palette;
    final tr = widget.tr;
    return Dialog(
      backgroundColor: p.bg,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(14),
        side: BorderSide(color: p.divider),
      ),
      child: SizedBox(
        width: 620,
        height: 540,
        child: Padding(
          padding: const EdgeInsets.all(18),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  const Icon(Icons.search, color: WaPalette.accent),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      tr.t('Hledat ve zprávách', 'Search in messages'),
                      style: const TextStyle(
                          fontSize: 17, fontWeight: FontWeight.w600),
                    ),
                  ),
                  IconButton(
                    onPressed: () => Navigator.pop(context),
                    icon: const Icon(Icons.close),
                  ),
                ],
              ),
              const SizedBox(height: 10),
              TextField(
                controller: _queryCtrl,
                autofocus: true,
                onChanged: (_) {
                  setState(() {});
                  _runSearch();
                },
                decoration: InputDecoration(
                  isDense: true,
                  filled: true,
                  fillColor: p.surface,
                  prefixIcon: const Icon(Icons.search, size: 19),
                  suffixIcon: _queryCtrl.text.isNotEmpty
                      ? IconButton(
                          icon: const Icon(Icons.close, size: 16),
                          onPressed: () {
                            _queryCtrl.clear();
                            setState(() {});
                            _runSearch();
                          },
                        )
                      : null,
                  hintText: tr.t('Hledat text zprávy…', 'Search message text…'),
                  border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(10),
                    borderSide: BorderSide.none,
                  ),
                ),
              ),
              const SizedBox(height: 10),
              Wrap(
                spacing: 6,
                runSpacing: 6,
                children: [
                  _choice(tr.t('Tento chat', 'This chat'), 'current', _scope,
                      (v) {
                    setState(() => _scope = v);
                    _maybeAutoSyncCurrent();
                    _runSearch();
                  }),
                  _choice(tr.t('Všechny chaty', 'All chats'), 'all', _scope,
                      (v) {
                    setState(() => _scope = v);
                    _runSearch();
                  }),
                  const SizedBox(width: 8),
                  _choice(tr.t('Všichni', 'All'), 'all', _sender,
                      (v) => setState(() { _sender = v; _runSearch(); })),
                  _choice(tr.t('Odeslané mnou', 'Sent by me'), 'me', _sender,
                      (v) => setState(() { _sender = v; _runSearch(); })),
                  _choice(tr.t('Přijaté', 'Received'), 'received', _sender,
                      (v) => setState(() { _sender = v; _runSearch(); })),
                ],
              ),
              const SizedBox(height: 6),
              Wrap(
                spacing: 6,
                runSpacing: 6,
                children: [
                  _choice(tr.t('Vše', 'All'), 'all', _contentType,
                      (v) => setState(() { _contentType = v; _runSearch(); })),
                  _choice('Text', 'text', _contentType,
                      (v) => setState(() { _contentType = v; _runSearch(); })),
                  _choice(tr.t('Média', 'Media'), 'media', _contentType,
                      (v) => setState(() { _contentType = v; _runSearch(); })),
                  _choice(tr.t('Odkazy', 'Links'), 'links', _contentType,
                      (v) => setState(() { _contentType = v; _runSearch(); })),
                  _choice(tr.t('Ankety', 'Polls'), 'polls', _contentType,
                      (v) => setState(() { _contentType = v; _runSearch(); })),
                  _choice(tr.t('S reakcemi', 'Reacted'), 'reactions', _contentType,
                      (v) => setState(() { _contentType = v; _runSearch(); })),
                  _choice(tr.t('Hvězdičkou', 'Starred'), 'starred', _contentType,
                      (v) => setState(() { _contentType = v; _runSearch(); })),
                  const SizedBox(width: 8),
                  _choice(tr.t('Vždy', 'All time'), 'all', _dateRange,
                      (v) => setState(() { _dateRange = v; _runSearch(); })),
                  _choice(tr.t('Dnes', 'Today'), 'today', _dateRange,
                      (v) => setState(() { _dateRange = v; _runSearch(); })),
                  _choice(tr.t('7 dní', '7 days'), '7d', _dateRange,
                      (v) => setState(() { _dateRange = v; _runSearch(); })),
                  _choice(tr.t('30 dní', '30 days'), '30d', _dateRange,
                      (v) => setState(() { _dateRange = v; _runSearch(); })),
                ],
              ),
              const SizedBox(height: 8),
              Builder(builder: (_) {
                final sel = _snap.selected;
                final syncing = _scope == 'current'
                    ? (sel != null && _snap.isHistorySyncing(sel))
                    : _snap.historySyncing.isNotEmpty;
                final exhausted = _scope == 'current' &&
                    sel != null &&
                    _snap.isHistoryExhausted(sel);
                return Row(
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
                                'Stahuji starší zprávy z telefonu…',
                                'Fetching older messages from phone…',
                              )
                            : _scannedMessages > 0
                                ? tr.t(
                                    'Prohledáno $_scannedMessages zpráv • $_totalHits výsledků',
                                    'Scanned $_scannedMessages msgs • $_totalHits hits',
                                  )
                                : exhausted
                                    ? tr.t(
                                        'Načtena kompletní historie chatu',
                                        'Full chat history loaded',
                                      )
                                    : tr.t(
                                        'Prohledává všechny načtené zprávy',
                                        'Searches all loaded messages',
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
                        ),
                        child: Text(tr.t('Zastavit', 'Stop'),
                            style: const TextStyle(fontSize: 11.5)),
                      )
                    else
                      TextButton.icon(
                        onPressed: () => widget.bridge.syncFullHistory(
                          chat: _scope == 'current' ? sel : null,
                        ),
                        style: TextButton.styleFrom(
                          visualDensity: VisualDensity.compact,
                        ),
                        icon: const Icon(Icons.history, size: 14),
                        label: Text(
                          _scope == 'current'
                              ? (exhausted
                                  ? tr.t('Obnovit z telefonu', 'Refresh')
                                  : tr.t('Načíst vše z telefonu', 'Sync all'))
                              : tr.t('Načíst starší ze všech chatů',
                                  'Sync older across chats'),
                          style: const TextStyle(fontSize: 11.5),
                        ),
                      ),
                  ],
                );
              }),
              Divider(color: p.divider),
              Expanded(
                child: _hits.isEmpty
                    ? Center(
                        child: Text(
                          tr.t('Zadejte dotaz nebo zvolte filtr',
                              'Type a query or choose a filter'),
                          style: const TextStyle(color: WaPalette.textSecondary),
                        ),
                      )
                    : ListView.separated(
                        itemCount: _hits.length,
                        separatorBuilder: (_, _) => const SizedBox(height: 6),
                        itemBuilder: (_, idx) {
                          final h = _hits[idx];
                          final dt = DateTime.fromMillisecondsSinceEpoch(h.ts);
                          final timeStr =
                              '${dt.day}.${dt.month}.${dt.year} ${dt.hour.toString().padLeft(2, '0')}:${dt.minute.toString().padLeft(2, '0')}';
                          return InkWell(
                            onTap: () {
                              final q = _queryCtrl.text.trim();
                              widget.onJump(
                                h.chat,
                                h.id,
                                q.isEmpty ? null : q,
                              );
                              Navigator.pop(context);
                            },
                            borderRadius: BorderRadius.circular(8),
                            child: Container(
                              padding: const EdgeInsets.all(10),
                              decoration: BoxDecoration(
                                color: p.surface,
                                borderRadius: BorderRadius.circular(8),
                              ),
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Row(
                                    children: [
                                      Text(h.chatName,
                                          style: const TextStyle(
                                              fontWeight: FontWeight.w600,
                                              fontSize: 13)),
                                      const SizedBox(width: 6),
                                      Text('• ${h.senderName}',
                                          style: const TextStyle(
                                              fontSize: 12,
                                              color: WaPalette.linkBlue)),
                                      const Spacer(),
                                      Text(timeStr,
                                          style: const TextStyle(
                                              fontSize: 11,
                                              color: WaPalette.textSecondary)),
                                    ],
                                  ),
                                  const SizedBox(height: 4),
                                  Text(
                                    h.text.isEmpty && h.media != null
                                        ? '[${h.media}]'
                                        : h.text,
                                    maxLines: 2,
                                    overflow: TextOverflow.ellipsis,
                                    style: const TextStyle(fontSize: 13),
                                  ),
                                ],
                              ),
                            ),
                          );
                        },
                      ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _choice(
    String label,
    String val,
    String current,
    ValueChanged<String> onTap,
  ) {
    final active = current == val;
    return InkWell(
      onTap: () => onTap(val),
      borderRadius: BorderRadius.circular(14),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
        decoration: BoxDecoration(
          color: active ? widget.palette.outgoingBubble : widget.palette.surface,
          borderRadius: BorderRadius.circular(14),
        ),
        child: Text(
          label,
          style: TextStyle(
            fontSize: 12,
            color: active ? Colors.white : WaPalette.textSecondary,
          ),
        ),
      ),
    );
  }
}

/// Quick chat switcher (`Ctrl+K`) with keyboard navigation.
class CommandPaletteDialog extends StatefulWidget {
  const CommandPaletteDialog({
    super.key,
    required this.snapshot,
    required this.palette,
    required this.tr,
    required this.onSelect,
  });

  final Snapshot snapshot;
  final WaPalette palette;
  final Tr tr;
  final ValueChanged<ChatItem> onSelect;

  @override
  State<CommandPaletteDialog> createState() => _CommandPaletteDialogState();
}

class _CommandPaletteDialogState extends State<CommandPaletteDialog> {
  final _ctrl = TextEditingController();
  int _index = 0;

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final p = widget.palette;
    final tr = widget.tr;
    final q = _ctrl.text.trim().toLowerCase();
    final all = [...widget.snapshot.chats, ...widget.snapshot.archived];
    final matches = all
        .where((c) =>
            q.isEmpty ||
            c.name.toLowerCase().contains(q) ||
            c.jid.toLowerCase().contains(q))
        .take(8)
        .toList();
    if (_index >= matches.length && matches.isNotEmpty) {
      _index = matches.length - 1;
    }

    return Dialog(
      backgroundColor: p.surface,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(12),
        side: BorderSide(color: p.divider),
      ),
      child: Focus(
        onKeyEvent: (_, evt) {
          if (evt is! KeyDownEvent) return KeyEventResult.ignored;
          if (evt.logicalKey == LogicalKeyboardKey.arrowDown &&
              matches.isNotEmpty) {
            setState(() => _index = (_index + 1) % matches.length);
            return KeyEventResult.handled;
          }
          if (evt.logicalKey == LogicalKeyboardKey.arrowUp &&
              matches.isNotEmpty) {
            setState(() => _index = (_index - 1 + matches.length) % matches.length);
            return KeyEventResult.handled;
          }
          if (evt.logicalKey == LogicalKeyboardKey.enter &&
              matches.isNotEmpty) {
            widget.onSelect(matches[_index]);
            Navigator.pop(context);
            return KeyEventResult.handled;
          }
          return KeyEventResult.ignored;
        },
        child: SizedBox(
          width: 440,
          child: Padding(
            padding: const EdgeInsets.all(14),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                TextField(
                  controller: _ctrl,
                  autofocus: true,
                  onChanged: (_) => setState(() => _index = 0),
                  decoration: InputDecoration(
                    isDense: true,
                    filled: true,
                    fillColor: p.bg,
                    prefixIcon: const Icon(Icons.bolt, size: 18, color: WaPalette.accent),
                    hintText: tr.t('Přepnout chat… (↑ ↓ výběr, Enter otevřít)',
                        'Switch chat… (↑ ↓ select, Enter open)'),
                    border: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(8),
                      borderSide: BorderSide.none,
                    ),
                  ),
                ),
                const SizedBox(height: 8),
                if (matches.isEmpty)
                  Padding(
                    padding: const EdgeInsets.all(12),
                    child: Text(
                      tr.t('Nic nenalezeno.', 'Nothing found.'),
                      style: const TextStyle(color: WaPalette.textSecondary),
                    ),
                  )
                else
                  for (var i = 0; i < matches.length; i++)
                    InkWell(
                      onTap: () {
                        widget.onSelect(matches[i]);
                        Navigator.pop(context);
                      },
                      borderRadius: BorderRadius.circular(8),
                      child: Container(
                        padding: const EdgeInsets.symmetric(
                            horizontal: 10, vertical: 8),
                        decoration: BoxDecoration(
                          color: i == _index
                              ? widget.palette.outgoingBubble
                              : Colors.transparent,
                          borderRadius: BorderRadius.circular(8),
                        ),
                        child: Row(
                          children: [
                            WaAvatar(
                              name: matches[i].name,
                              avatarPath: matches[i].avatar,
                              radius: 14,
                              isGroup: matches[i].group,
                            ),
                            const SizedBox(width: 10),
                            Expanded(
                              child: Text(
                                matches[i].name.isEmpty
                                    ? formatJidPhone(matches[i].jid)
                                    : matches[i].name,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                              ),
                            ),
                          ],
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

/// Floating Call Overlay for Incoming, Ringing, Active and Ended calls.
class CallOverlay extends StatefulWidget {
  const CallOverlay({
    super.key,
    required this.call,
    required this.bridge,
    required this.palette,
    required this.tr,
  });

  final CallInfo call;
  final Bridge bridge;
  final WaPalette palette;
  final Tr tr;

  @override
  State<CallOverlay> createState() => _CallOverlayState();
}

class _CallOverlayState extends State<CallOverlay> {
  Timer? _timer;

  @override
  void initState() {
    super.initState();
    _timer = Timer.periodic(const Duration(seconds: 1), (_) {
      if (mounted && widget.call.status != 'ended') setState(() {});
    });
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final c = widget.call;
    final p = widget.palette;
    final tr = widget.tr;

    final isIncoming = c.status == 'incoming';
    final isConnected = c.status == 'connected';
    final isEnded = c.status == 'ended';

    String statusLine() {
      if (isIncoming) {
        return c.isVideo
            ? tr.t('Příchozí videohovor WhatsApp', 'Incoming WhatsApp video call')
            : tr.t('Příchozí hlasový hovor WhatsApp', 'Incoming WhatsApp voice call');
      }
      if (c.status == 'ringing') return tr.t('Vyzvánění…', 'Ringing…');
      if (isEnded) return c.reason ?? tr.t('Hovor ukončen', 'Call ended');
      final start = c.connectedAt ?? c.startedAt;
      final secs = ((DateTime.now().millisecondsSinceEpoch - start) ~/ 1000)
          .clamp(0, 999999);
      return '${(secs ~/ 60).toString().padLeft(2, '0')}:${(secs % 60).toString().padLeft(2, '0')}';
    }

    return Positioned(
      top: 20,
      right: 24,
      child: Material(
        elevation: 14,
        borderRadius: BorderRadius.circular(16),
        color: p.surface,
        child: Container(
          width: 344,
          padding: const EdgeInsets.all(18),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(16),
            border: Border.all(
              color: isIncoming ? WaPalette.accentBright : p.divider,
              width: isIncoming ? 2 : 1,
            ),
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Icon(
                    c.isVideo ? Icons.videocam : Icons.call,
                    size: 16,
                    color: WaPalette.accentBright,
                  ),
                  const SizedBox(width: 6),
                  Flexible(
                    child: Text(
                      statusLine(),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontSize: 12.5,
                        fontWeight: FontWeight.w600,
                        color:
                            isEnded ? WaPalette.danger : WaPalette.accentBright,
                      ),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 12),
              WaAvatar(
                name: c.peerName,
                avatarPath: c.peerAvatar,
                radius: 32,
                isGroup: c.isGroup,
              ),
              const SizedBox(height: 10),
              Text(
                c.peerName,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(
                  fontSize: 17,
                  fontWeight: FontWeight.bold,
                  color: WaPalette.textPrimary,
                ),
              ),
              const SizedBox(height: 16),
              if (isIncoming)
                Wrap(
                  spacing: 10,
                  runSpacing: 8,
                  alignment: WrapAlignment.center,
                  children: [
                    FilledButton.icon(
                      onPressed: () => widget.bridge.rejectCall(c.id),
                      style: FilledButton.styleFrom(
                          backgroundColor: WaPalette.danger),
                      icon: const Icon(Icons.call_end, size: 17),
                      label: Text(tr.t('Odmítnout', 'Decline')),
                    ),
                    FilledButton.icon(
                      onPressed: () => widget.bridge.acceptCall(c.id),
                      style: FilledButton.styleFrom(
                          backgroundColor: WaPalette.accentBright,
                          foregroundColor: Colors.black),
                      icon: const Icon(Icons.call, size: 17),
                      label: Text(tr.t('Přijmout', 'Accept')),
                    ),
                  ],
                )
              else if (!isEnded)
                Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    IconButton.filled(
                      onPressed: widget.bridge.toggleCallMute,
                      style: IconButton.styleFrom(
                        backgroundColor:
                            c.muted ? Colors.white24 : p.surfaceElevated,
                      ),
                      icon: Icon(c.muted ? Icons.mic_off : Icons.mic),
                      tooltip: tr.t('Ztlumit mikrofon', 'Mute mic'),
                    ),
                    if (c.isVideo) ...[
                      const SizedBox(width: 14),
                      IconButton.filled(
                        onPressed: widget.bridge.toggleCallVideo,
                        style: IconButton.styleFrom(
                          backgroundColor: c.videoEnabled
                              ? p.surfaceElevated
                              : Colors.white24,
                        ),
                        icon: Icon(c.videoEnabled
                            ? Icons.videocam
                            : Icons.videocam_off),
                        tooltip: tr.t('Kamera', 'Camera'),
                      ),
                    ],
                    const SizedBox(width: 14),
                    IconButton.filled(
                      onPressed: () => widget.bridge.endCall(c.id),
                      style: IconButton.styleFrom(
                          backgroundColor: WaPalette.danger),
                      icon: const Icon(Icons.call_end),
                      tooltip: tr.t('Ukončit hovor', 'End call'),
                    ),
                  ],
                ),
              if (isConnected && c.isVideo)
                Padding(
                  padding: const EdgeInsets.only(top: 10),
                  child: Text(
                    c.videoEnabled
                        ? tr.t('Kamera aktivní', 'Camera active')
                        : tr.t('Kamera vypnuta', 'Camera paused'),
                    style: const TextStyle(
                        fontSize: 11.5, color: WaPalette.textSecondary),
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Schedule Message Dialog with quick delay presets (+5m .. +1d) & custom picker.
class ScheduleMessageDialog extends StatefulWidget {
  const ScheduleMessageDialog({
    super.key,
    required this.chatJid,
    required this.chatName,
    required this.initialText,
    required this.bridge,
    required this.palette,
    required this.tr,
  });

  final String chatJid;
  final String chatName;
  final String initialText;
  final Bridge bridge;
  final WaPalette palette;
  final Tr tr;

  @override
  State<ScheduleMessageDialog> createState() => _ScheduleMessageDialogState();
}

class _ScheduleMessageDialogState extends State<ScheduleMessageDialog> {
  late final TextEditingController _textCtrl;
  DateTime _target = DateTime.now().add(const Duration(minutes: 10));

  @override
  void initState() {
    super.initState();
    _textCtrl = TextEditingController(text: widget.initialText);
  }

  @override
  void dispose() {
    _textCtrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final p = widget.palette;
    final tr = widget.tr;
    String two(int n) => n.toString().padLeft(2, '0');
    final when =
        '${_target.day}. ${_target.month}. ${_target.year} ${two(_target.hour)}:${two(_target.minute)}';

    return AlertDialog(
      backgroundColor: p.surface,
      title: Text(tr.t('Naplánovat zprávu', 'Schedule message')),
      content: SizedBox(
        width: 420,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              '${tr.t('Příjemce', 'Recipient')}: ${widget.chatName}',
              style: const TextStyle(
                  fontSize: 13, color: WaPalette.textSecondary),
            ),
            const SizedBox(height: 8),
            TextField(
              controller: _textCtrl,
              autofocus: true,
              minLines: 2,
              maxLines: 5,
              onChanged: (_) => setState(() {}),
              decoration: InputDecoration(
                filled: true,
                fillColor: p.bg,
                hintText: tr.t('Text zprávy k odeslání později…',
                    'Message text to send later…'),
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(8),
                  borderSide: BorderSide.none,
                ),
              ),
            ),
            const SizedBox(height: 12),
            Wrap(
              spacing: 6,
              runSpacing: 6,
              children: [
                for (final (label, mins) in [
                  ('+5 min', 5),
                  ('+15 min', 15),
                  ('+30 min', 30),
                  ('+1 h', 60),
                  ('+3 h', 180),
                  ('+1 d', 1440),
                ])
                  ActionChip(
                    label: Text(label, style: const TextStyle(fontSize: 12)),
                    onPressed: () => setState(() {
                      _target = DateTime.now().add(Duration(minutes: mins));
                    }),
                  ),
                ActionChip(
                  avatar: const Icon(Icons.calendar_today, size: 14),
                  label: Text(tr.t('Vlastní čas…', 'Custom…'),
                      style: const TextStyle(fontSize: 12)),
                  onPressed: _pickCustom,
                ),
              ],
            ),
            const SizedBox(height: 12),
            Container(
              padding: const EdgeInsets.all(10),
              decoration: BoxDecoration(
                color: WaPalette.accent.withValues(alpha: 0.12),
                borderRadius: BorderRadius.circular(8),
              ),
              child: Row(
                children: [
                  const Icon(Icons.schedule,
                      size: 17, color: WaPalette.accentBright),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      '${tr.t('Odeslání', 'Dispatch')}: $when',
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(fontWeight: FontWeight.w500),
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context, false),
          child: Text(tr.t('Zrušit', 'Cancel')),
        ),
        FilledButton(
          onPressed: _textCtrl.text.trim().isNotEmpty
              ? () {
                  if (!_target.isAfter(DateTime.now())) {
                    ScaffoldMessenger.of(context).showSnackBar(
                      SnackBar(
                        content: Text(
                            tr.t('Čas musí být v budoucnosti.',
                                'Time must be in the future.')),
                      ),
                    );
                    return;
                  }
                  widget.bridge.schedule(
                      widget.chatJid, _textCtrl.text.trim(), _target);
                  Navigator.pop(context, true);
                }
              : null,
          style: FilledButton.styleFrom(backgroundColor: WaPalette.accentDark),
          child: Text(tr.t('Naplánovat', 'Schedule')),
        ),
      ],
    );
  }

  Future<void> _pickCustom() async {
    final now = DateTime.now();
    final day = await showDatePicker(
      context: context,
      initialDate: _target.isAfter(now) ? _target : now,
      firstDate: now,
      lastDate: now.add(const Duration(days: 365)),
    );
    if (day == null || !mounted) return;
    final time = await showTimePicker(
      context: context,
      initialTime: TimeOfDay.fromDateTime(_target),
    );
    if (time == null || !mounted) return;
    setState(() {
      _target = DateTime(day.year, day.month, day.day, time.hour, time.minute);
    });
  }
}

/// Export Chat Dialog with TXT / JSON / HTML cards & result file path.
class ExportChatDialog extends StatefulWidget {
  const ExportChatDialog({
    super.key,
    required this.chat,
    required this.bridge,
    required this.palette,
    required this.tr,
  });

  final ChatItem chat;
  final Bridge bridge;
  final WaPalette palette;
  final Tr tr;

  @override
  State<ExportChatDialog> createState() => _ExportChatDialogState();
}

class _ExportChatDialogState extends State<ExportChatDialog> {
  String _format = 'txt';
  ExportResult? _result;
  StreamSubscription<ExportResult>? _sub;

  @override
  void initState() {
    super.initState();
    _sub = widget.bridge.exportResults.listen((res) {
      if (mounted) setState(() => _result = res);
    });
  }

  @override
  void dispose() {
    _sub?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final p = widget.palette;
    final tr = widget.tr;
    return AlertDialog(
      backgroundColor: p.surface,
      title: Text(tr.t('Exportovat konverzaci', 'Export conversation')),
      content: SizedBox(
        width: 410,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              widget.chat.name.isEmpty
                  ? formatJidPhone(widget.chat.jid)
                  : widget.chat.name,
              style: const TextStyle(fontWeight: FontWeight.w600, fontSize: 15),
            ),
            const SizedBox(height: 12),
            RadioGroup<String>(
              groupValue: _format,
              onChanged: (v) {
                if (v != null) setState(() => _format = v);
              },
              child: Column(
                children: [
                  RadioListTile<String>(
                    dense: true,
                    contentPadding: EdgeInsets.zero,
                    value: 'txt',
                    title: const Text('Text (.txt)'),
                    subtitle: Text(tr.t(
                        'Čitelný textový soubor s časy a odesílateli',
                        'Readable text file with timestamps and senders')),
                  ),
                  RadioListTile<String>(
                    dense: true,
                    contentPadding: EdgeInsets.zero,
                    value: 'json',
                    title: const Text('JSON (.json)'),
                    subtitle: Text(tr.t(
                        'Úplný strukturovaný export metadat a zpráv',
                        'Full structured data export with metadata')),
                  ),
                  RadioListTile<String>(
                    dense: true,
                    contentPadding: EdgeInsets.zero,
                    value: 'html',
                    title: const Text('HTML (.html)'),
                    subtitle: Text(tr.t(
                        'Offline webová stránka ve stylu tmavých bublin WhatsApp',
                        'Offline webpage styled like WhatsApp dark bubbles')),
                  ),
                ],
              ),
            ),
            if (_result != null) ...[
              const SizedBox(height: 10),
              Container(
                padding: const EdgeInsets.all(10),
                decoration: BoxDecoration(
                  color: (_result!.ok ? WaPalette.accent : WaPalette.danger)
                      .withValues(alpha: 0.14),
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      _result!.ok
                          ? tr.t('Exportováno:', 'Exported:')
                          : '${tr.t('Chyba', 'Error')}: ${_result!.error}',
                      style: TextStyle(
                        fontSize: 12.5,
                        color: _result!.ok
                            ? WaPalette.accentBright
                            : WaPalette.danger,
                      ),
                    ),
                    if (_result!.path != null)
                      Text(
                        _result!.path!,
                        style: const TextStyle(fontSize: 11.5),
                      ),
                  ],
                ),
              ),
            ],
          ],
        ),
      ),
      actions: [
        if (_result?.ok == true && _result?.path != null)
          TextButton.icon(
            onPressed: () => widget.bridge.showInFolder(_result!.path!),
            icon: const Icon(Icons.folder_open, size: 17),
            label: Text(tr.t('Otevřít ve složce', 'Show in folder')),
          ),
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: Text(tr.t('Zavřít', 'Close')),
        ),
        FilledButton(
          onPressed: () async {
            final dir = await getDirectoryPath(
              confirmButtonText: tr.t('Exportovat sem', 'Export here'),
            );
            if (dir == null || !mounted) return;
            widget.bridge.exportChat(widget.chat.jid, _format, dir: dir);
          },
          style: FilledButton.styleFrom(backgroundColor: WaPalette.accentDark),
          child: Text(tr.t('Exportovat…', 'Export…')),
        ),
      ],
    );
  }
}

/// Modal showing everyone who reacted to a message, allowing removal of own reaction.
class ReactionDetailDialog extends StatelessWidget {
  const ReactionDetailDialog({
    super.key,
    required this.msg,
    required this.snapshot,
    required this.chatJid,
    required this.bridge,
    required this.palette,
    required this.tr,
  });

  final Msg msg;
  final Snapshot snapshot;
  final String chatJid;
  final Bridge bridge;
  final WaPalette palette;
  final Tr tr;

  @override
  Widget build(BuildContext context) {
    final meUser = snapshot.self?.split('@').first.split(':').first;
    return AlertDialog(
      backgroundColor: palette.surface,
      title: Text('${tr.t('Reakce na zprávu', 'Message reactions')} (${msg.reactionDetails.length})'),
      content: SizedBox(
        width: 340,
        child: msg.reactionDetails.isEmpty
            ? Text(tr.t('Žádné reakce.', 'No reactions.'))
            : ListView.builder(
                shrinkWrap: true,
                itemCount: msg.reactionDetails.length,
                itemBuilder: (_, idx) {
                  final r = msg.reactionDetails[idx];
                  final senderUser = r.sender.split('@').first.split(':').first;
                  final isMine = meUser != null && senderUser == meUser;
                  final name = isMine
                      ? tr.t('Vy', 'You')
                      : (snapshot.contacts[r.sender]?.isNotEmpty == true
                          ? snapshot.contacts[r.sender]!
                          : formatJidPhone(r.sender));
                  return ListTile(
                    dense: true,
                    contentPadding: EdgeInsets.zero,
                    leading: Text(r.emoji, style: const TextStyle(fontSize: 22)),
                    title: Text(name),
                    trailing: isMine
                        ? TextButton(
                            onPressed: () {
                              bridge.react(chatJid, msg.id, '');
                              Navigator.pop(context);
                            },
                            child: Text(
                              tr.t('Odebrat', 'Remove'),
                              style: const TextStyle(color: WaPalette.danger),
                            ),
                          )
                        : null,
                  );
                },
              ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: Text(tr.t('Zavřít', 'Close')),
        ),
      ],
    );
  }
}

/// View-Once Modal: triggers download on open and deletes/consumes on close.
class ViewOnceModal extends StatefulWidget {
  const ViewOnceModal({
    super.key,
    required this.chatJid,
    required this.messageId,
    required this.bridge,
    required this.initialSnapshot,
    required this.palette,
    required this.tr,
  });

  final String chatJid;
  final String messageId;
  final Bridge bridge;
  final Snapshot initialSnapshot;
  final WaPalette palette;
  final Tr tr;

  @override
  State<ViewOnceModal> createState() => _ViewOnceModalState();
}

class _ViewOnceModalState extends State<ViewOnceModal> {
  @override
  void initState() {
    super.initState();
    widget.bridge.openViewOnce(widget.chatJid, widget.messageId);
  }

  @override
  void dispose() {
    widget.bridge.consumeViewOnce(widget.chatJid, widget.messageId);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final tr = widget.tr;
    return StreamBuilder<Snapshot>(
      stream: widget.bridge.snapshots,
      initialData: widget.initialSnapshot,
      builder: (context, snap) {
        final s = snap.data ?? widget.initialSnapshot;
        final msg = s.message(widget.messageId);
        final path = msg?.mediaPath;
        final file = path != null ? File(path) : null;
        final ready = file != null && file.existsSync();

        return AlertDialog(
          backgroundColor: widget.palette.surface,
          title: Row(
            children: [
              const Icon(Icons.looks_one_outlined, color: WaPalette.accent),
              const SizedBox(width: 8),
              Text(tr.t('Zobrazit jednou', 'View once')),
            ],
          ),
          content: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 520, maxHeight: 460),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                if (!ready)
                  Padding(
                    padding: const EdgeInsets.all(24),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        const CircularProgressIndicator(color: WaPalette.accent),
                        const SizedBox(width: 14),
                        Text(tr.t('Stahuji médium…', 'Downloading media…')),
                      ],
                    ),
                  )
                else if (msg?.media == 'image' || msg?.media == 'sticker')
                  Flexible(
                    child: ClipRRect(
                      borderRadius: BorderRadius.circular(10),
                      child: Image.file(file, fit: BoxFit.contain),
                    ),
                  )
                else
                  FilledButton.icon(
                    onPressed: () => widget.bridge.openFile(file.path),
                    icon: const Icon(Icons.play_arrow),
                    label: Text(tr.t('Přehrát / Otevřít', 'Play / Open')),
                  ),
                const SizedBox(height: 12),
                Text(
                  tr.t(
                    'Zavřením se médium smaže a už ho nezobrazíte.',
                    'Closing deletes this media permanently.',
                  ),
                  style: const TextStyle(
                      fontSize: 11.5, color: WaPalette.textSecondary),
                ),
              ],
            ),
          ),
          actions: [
            FilledButton(
              onPressed: () => Navigator.pop(context),
              child: Text(tr.t('Zavřít', 'Close')),
            ),
          ],
        );
      },
    );
  }
}

/// Full-size image preview lightbox.
class ImageLightboxDialog extends StatelessWidget {
  const ImageLightboxDialog({
    super.key,
    required this.path,
    this.caption,
    required this.bridge,
    required this.tr,
  });

  final String path;
  final String? caption;
  final Bridge bridge;
  final Tr tr;

  @override
  Widget build(BuildContext context) {
    return Dialog(
      backgroundColor: Colors.black87,
      insetPadding: const EdgeInsets.all(28),
      child: Stack(
        children: [
          Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Padding(
                padding:
                    const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.end,
                  children: [
                    IconButton(
                      onPressed: () => bridge.openFile(path),
                      icon: const Icon(Icons.open_in_new, color: Colors.white),
                      tooltip: tr.t('Otevřít externě', 'Open externally'),
                    ),
                    IconButton(
                      onPressed: () => bridge.showInFolder(path),
                      icon: const Icon(Icons.folder_open, color: Colors.white),
                      tooltip: tr.t('Zobrazit ve složce', 'Show in folder'),
                    ),
                    IconButton(
                      onPressed: () => Navigator.pop(context),
                      icon: const Icon(Icons.close, color: Colors.white),
                      tooltip: tr.t('Zavřít', 'Close'),
                    ),
                  ],
                ),
              ),
              Flexible(
                child: InteractiveViewer(
                  child: Image.file(File(path), fit: BoxFit.contain),
                ),
              ),
              if (caption != null && caption!.trim().isNotEmpty)
                Padding(
                  padding: const EdgeInsets.all(14),
                  child: Text(caption!,
                      style: const TextStyle(color: Colors.white, fontSize: 14)),
                ),
            ],
          ),
        ],
      ),
    );
  }
}

/// Starred messages browser dialog (all chats or current chat).
class StarredMessagesDialog extends StatefulWidget {
  const StarredMessagesDialog({
    super.key,
    required this.snapshot,
    required this.bridge,
    required this.palette,
    required this.tr,
    required this.onJump,
  });

  final Snapshot snapshot;
  final Bridge bridge;
  final WaPalette palette;
  final Tr tr;
  final void Function(String chatJid, String msgId) onJump;

  @override
  State<StarredMessagesDialog> createState() => _StarredMessagesDialogState();
}

class _StarredMessagesDialogState extends State<StarredMessagesDialog> {
  String _scope = 'all';
  List<SearchHit> _items = const [];
  bool _loading = true;
  StreamSubscription<List<SearchHit>>? _sub;

  @override
  void initState() {
    super.initState();
    _sub = widget.bridge.starredMessages.listen((items) {
      if (!mounted) return;
      setState(() {
        _items = items;
        _loading = false;
      });
    });
    _refresh();
  }

  void _refresh() {
    setState(() => _loading = true);
    widget.bridge.requestStarred(
      chat: _scope == 'current' ? widget.snapshot.selected : null,
    );
  }

  @override
  void dispose() {
    _sub?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final p = widget.palette;
    final tr = widget.tr;
    final hasSelected = widget.snapshot.selected != null;

    return Dialog(
      backgroundColor: p.bg,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(14),
        side: BorderSide(color: p.divider),
      ),
      child: SizedBox(
        width: 580,
        height: 500,
        child: Padding(
          padding: const EdgeInsets.all(18),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  const Icon(Icons.star_rounded, color: WaPalette.accentBright),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      tr.t('Hvězdičkované zprávy', 'Starred messages'),
                      style: const TextStyle(
                          fontSize: 17, fontWeight: FontWeight.w600),
                    ),
                  ),
                  IconButton(
                    onPressed: () => Navigator.pop(context),
                    icon: const Icon(Icons.close),
                  ),
                ],
              ),
              if (hasSelected) ...[
                const SizedBox(height: 8),
                Wrap(
                  spacing: 8,
                  children: [
                    ChoiceChip(
                      label: Text(tr.t('Všechny chaty', 'All chats')),
                      selected: _scope == 'all',
                      onSelected: (_) {
                        _scope = 'all';
                        _refresh();
                      },
                    ),
                    ChoiceChip(
                      label: Text(tr.t('Tento chat', 'This chat')),
                      selected: _scope == 'current',
                      onSelected: (_) {
                        _scope = 'current';
                        _refresh();
                      },
                    ),
                  ],
                ),
              ],
              const SizedBox(height: 8),
              Divider(color: p.divider),
              Expanded(
                child: _loading
                    ? const Center(
                        child: CircularProgressIndicator(color: WaPalette.accent),
                      )
                    : _items.isEmpty
                        ? Center(
                            child: Text(
                              tr.t(
                                'Zatím žádné hvězdičkované zprávy.',
                                'No starred messages yet.',
                              ),
                              style: const TextStyle(
                                  color: WaPalette.textSecondary),
                            ),
                          )
                        : ListView.separated(
                            itemCount: _items.length,
                            separatorBuilder: (_, _) =>
                                const SizedBox(height: 6),
                            itemBuilder: (_, idx) {
                              final h = _items[idx];
                              final dt =
                                  DateTime.fromMillisecondsSinceEpoch(h.ts);
                              final timeStr =
                                  '${dt.day}.${dt.month}.${dt.year} ${dt.hour.toString().padLeft(2, '0')}:${dt.minute.toString().padLeft(2, '0')}';
                              return InkWell(
                                onTap: () {
                                  widget.onJump(h.chat, h.id);
                                  Navigator.pop(context);
                                },
                                borderRadius: BorderRadius.circular(8),
                                child: Container(
                                  padding: const EdgeInsets.all(10),
                                  decoration: BoxDecoration(
                                    color: p.surface,
                                    borderRadius: BorderRadius.circular(8),
                                  ),
                                  child: Row(
                                    children: [
                                      Expanded(
                                        child: Column(
                                          crossAxisAlignment:
                                              CrossAxisAlignment.start,
                                          children: [
                                            Row(
                                              children: [
                                                Text(h.chatName,
                                                    style: const TextStyle(
                                                        fontWeight:
                                                            FontWeight.w600,
                                                        fontSize: 13)),
                                                const SizedBox(width: 6),
                                                Text('• ${h.senderName}',
                                                    style: const TextStyle(
                                                        fontSize: 12,
                                                        color:
                                                            WaPalette.linkBlue)),
                                                const Spacer(),
                                                Text(timeStr,
                                                    style: const TextStyle(
                                                        fontSize: 11,
                                                        color: WaPalette
                                                            .textSecondary)),
                                              ],
                                            ),
                                            const SizedBox(height: 4),
                                            Text(
                                              h.text.isNotEmpty
                                                  ? h.text
                                                  : (h.media ?? '📎'),
                                              maxLines: 2,
                                              overflow: TextOverflow.ellipsis,
                                              style: const TextStyle(
                                                  fontSize: 13),
                                            ),
                                          ],
                                        ),
                                      ),
                                      IconButton(
                                        tooltip: tr.t(
                                            'Odebrat hvězdičku', 'Unstar'),
                                        onPressed: () {
                                          widget.bridge
                                              .starMessage(h.chat, h.id, false);
                                          setState(() => _items = _items
                                              .where((e) => !(e.id == h.id &&
                                                  e.chat == h.chat))
                                              .toList());
                                        },
                                        icon: const Icon(
                                          Icons.star_rounded,
                                          size: 18,
                                          color: Colors.amber,
                                        ),
                                      ),
                                    ],
                                  ),
                                ),
                              );
                            },
                          ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Built-in video & MP4-GIF lightbox powered by media_kit (libmpv).
class VideoLightboxDialog extends StatefulWidget {
  const VideoLightboxDialog({
    super.key,
    required this.path,
    this.caption,
    this.loopMuted = false,
    required this.bridge,
    required this.tr,
  });

  final String path;
  final String? caption;
  final bool loopMuted;
  final Bridge bridge;
  final Tr tr;

  @override
  State<VideoLightboxDialog> createState() => _VideoLightboxDialogState();
}

class _VideoLightboxDialogState extends State<VideoLightboxDialog> {
  Player? _player;
  VideoController? _controller;
  bool _failed = false;

  @override
  void initState() {
    super.initState();
    try {
      final p = Player();
      _player = p;
      final c = VideoController(p);
      _controller = c;
      if (widget.loopMuted) {
        unawaited(p.setPlaylistMode(PlaylistMode.single).catchError((_) {}));
        unawaited(p.setVolume(0).catchError((_) {}));
      }
      unawaited(
        p.open(Media(Uri.file(widget.path).toString())).catchError((_) {
          if (mounted) setState(() => _failed = true);
        }),
      );
    } catch (_) {
      final player = _player;
      _player = null;
      _controller = null;
      _failed = true;
      if (player != null) {
        unawaited(player.dispose().catchError((_) {}));
      }
    }
  }

  @override
  void dispose() {
    _player?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final tr = widget.tr;
    return Dialog(
      backgroundColor: Colors.black87,
      insetPadding: const EdgeInsets.all(28),
      child: SizedBox(
        width: 820,
        height: 560,
        child: Column(
          children: [
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
              child: Row(
                children: [
                  if (widget.loopMuted)
                    Container(
                      padding: const EdgeInsets.symmetric(
                          horizontal: 8, vertical: 3),
                      decoration: BoxDecoration(
                        color: Colors.white12,
                        borderRadius: BorderRadius.circular(6),
                      ),
                      child: const Text('GIF',
                          style: TextStyle(
                              color: Colors.white,
                              fontSize: 11.5,
                              fontWeight: FontWeight.w600)),
                    ),
                  const Spacer(),
                  IconButton(
                    onPressed: () => widget.bridge.openFile(widget.path),
                    icon: const Icon(Icons.open_in_new, color: Colors.white),
                    tooltip: tr.t('Otevřít externě', 'Open externally'),
                  ),
                  IconButton(
                    onPressed: () => widget.bridge.showInFolder(widget.path),
                    icon: const Icon(Icons.folder_open, color: Colors.white),
                    tooltip: tr.t('Zobrazit ve složce', 'Show in folder'),
                  ),
                  IconButton(
                    onPressed: () => Navigator.pop(context),
                    icon: const Icon(Icons.close, color: Colors.white),
                    tooltip: tr.t('Zavřít', 'Close'),
                  ),
                ],
              ),
            ),
            Expanded(
              child: _failed || _controller == null
                  ? Center(
                      child: FilledButton.icon(
                        onPressed: () => widget.bridge.openFile(widget.path),
                        icon: const Icon(Icons.play_arrow),
                        label: Text(tr.t(
                            'Přehrát v externím přehrávači', 'Open externally')),
                      ),
                    )
                  : ClipRRect(
                      borderRadius: BorderRadius.circular(8),
                      child: Video(controller: _controller!),
                    ),
            ),
            if (widget.caption != null && widget.caption!.trim().isNotEmpty)
              Padding(
                padding: const EdgeInsets.all(14),
                child: Text(widget.caption!,
                    style: const TextStyle(color: Colors.white, fontSize: 14)),
              ),
          ],
        ),
      ),
    );
  }
}

/// Silent looping inline player for downloaded WhatsApp MP4-GIF messages.
class InlineGifVideo extends StatefulWidget {
  const InlineGifVideo({
    super.key,
    required this.path,
    this.fallback,
  });

  final String path;
  final Widget? fallback;

  @override
  State<InlineGifVideo> createState() => _InlineGifVideoState();
}

class _InlineGifVideoState extends State<InlineGifVideo> {
  Player? _player;
  VideoController? _controller;
  bool _failed = false;

  @override
  void initState() {
    super.initState();
    _initPlayer();
  }

  @override
  void didUpdateWidget(covariant InlineGifVideo oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.path != widget.path) {
      _player?.dispose();
      _player = null;
      _controller = null;
      _failed = false;
      _initPlayer();
    }
  }

  void _initPlayer() {
    try {
      final p = Player();
      _player = p;
      final c = VideoController(p);
      _controller = c;
      unawaited(p.setPlaylistMode(PlaylistMode.single).catchError((_) {}));
      unawaited(p.setVolume(0).catchError((_) {}));
      unawaited(
        p.open(Media(Uri.file(widget.path).toString())).catchError((_) {
          if (mounted) setState(() => _failed = true);
        }),
      );
    } catch (_) {
      final player = _player;
      _player = null;
      _controller = null;
      _failed = true;
      if (player != null) {
        unawaited(player.dispose().catchError((_) {}));
      }
    }
  }

  @override
  void dispose() {
    _player?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (_failed || _controller == null) {
      return widget.fallback ?? Container(color: Colors.black38);
    }
    return Video(
      controller: _controller!,
      controls: NoVideoControls,
      fit: BoxFit.cover,
    );
  }
}

/// Update release notes & install dialog.
class UpdateDialog extends StatelessWidget {
  const UpdateDialog({
    super.key,
    required this.initialSnapshot,
    required this.bridge,
    required this.palette,
    required this.tr,
  });

  final Snapshot initialSnapshot;
  final Bridge bridge;
  final WaPalette palette;
  final Tr tr;

  @override
  Widget build(BuildContext context) {
    return StreamBuilder<Snapshot>(
      stream: bridge.snapshots,
      initialData: initialSnapshot,
      builder: (context, snap) {
        final u = (snap.data ?? initialSnapshot).update;
        final info = u.available;
        return AlertDialog(
          backgroundColor: palette.surface,
          title: Text(tr.t('Aktualizace WaLite', 'WaLite Update')),
          content: SizedBox(
            width: 440,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('${tr.t('Nainstalováno', 'Installed')}: v${u.current}',
                    style: const TextStyle(color: WaPalette.textSecondary)),
                const SizedBox(height: 8),
                if (info != null) ...[
                  Text(
                    '${tr.t('K dispozici je', 'Available')}: v${info.version}',
                    style: const TextStyle(
                      fontSize: 16,
                      fontWeight: FontWeight.bold,
                      color: WaPalette.accent,
                    ),
                  ),
                  if (info.notes.trim().isNotEmpty) ...[
                    const SizedBox(height: 10),
                    ConstrainedBox(
                      constraints: const BoxConstraints(maxHeight: 220),
                      child: SingleChildScrollView(
                        child: Text(
                          info.notes.trim(),
                          style: const TextStyle(
                              fontFamily: 'monospace', fontSize: 12),
                        ),
                      ),
                    ),
                  ],
                ] else
                  Text(tr.t('Není k dispozici žádná novější verze.',
                      'No newer version is available.')),
                if (u.status.isNotEmpty) ...[
                  const SizedBox(height: 10),
                  Text(u.status,
                      style: const TextStyle(
                          fontSize: 12, color: WaPalette.textSecondary)),
                ],
              ],
            ),
          ),
          actions: [
            if (info != null)
              TextButton(
                onPressed: () => bridge.openFile(info.pageUrl),
                child: Text(tr.t('Stránka vydání', 'Release page')),
              ),
            TextButton(
              onPressed: () => Navigator.pop(context),
              child: Text(tr.t('Později', 'Later')),
            ),
            if (info != null && info.hasAsset)
              FilledButton(
                onPressed: u.busy ? null : bridge.installUpdate,
                style: FilledButton.styleFrom(
                    backgroundColor: WaPalette.accentDark),
                child: Text(tr.t('Stáhnout a nainstalovat',
                    'Download & install')),
              ),
          ],
        );
      },
    );
  }
}
