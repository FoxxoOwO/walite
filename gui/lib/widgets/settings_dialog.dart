import 'dart:async';

import 'package:file_selector/file_selector.dart';
import 'package:material_ui/material_ui.dart';

import '../bridge.dart';
import '../i18n.dart';
import '../theme.dart';
import 'avatar.dart';

enum SettingsTab {
  profile,
  chats,
  notifications,
  privacy,
  appearance,
  storage,
  system,
}

class SettingsDialog extends StatefulWidget {
  const SettingsDialog({
    super.key,
    required this.initialSnapshot,
    required this.bridge,
    this.initialTab = SettingsTab.profile,
    required this.onOpenUpdate,
    required this.onConfirm,
  });

  final Snapshot initialSnapshot;
  final Bridge bridge;
  final SettingsTab initialTab;
  final VoidCallback onOpenUpdate;
  final Future<bool> Function(String title, String body, String action)
      onConfirm;

  @override
  State<SettingsDialog> createState() => _SettingsDialogState();
}

class _SettingsDialogState extends State<SettingsDialog> {
  late SettingsTab _tab;
  late TextEditingController _nameCtrl;
  late TextEditingController _statusCtrl;
  final FocusNode _statusFocus = FocusNode();
  bool _statusEdited = false;
  bool _photoBusy = false;
  String? _profileFeedback;
  bool _profileFeedbackOk = true;
  MediaStats? _stats;
  StreamSubscription<MediaStats>? _statsSub;
  StreamSubscription<ProfileResult>? _profileSub;
  String? _cleanedBanner;

  @override
  void initState() {
    super.initState();
    _tab = widget.initialTab;
    _nameCtrl = TextEditingController(
      text: widget.initialSnapshot.selfName ?? '',
    );
    _statusCtrl = TextEditingController(
      text: widget.initialSnapshot.selfStatus ?? '',
    );
    _statsSub = widget.bridge.mediaStats.listen((stats) {
      if (!mounted) return;
      setState(() {
        _stats = stats;
        if (stats.cleanedFiles != null) {
          _cleanedBanner =
              '${stats.cleanedFiles} (${formatBytes(stats.cleanedBytes ?? 0)})';
        }
      });
    });
    _profileSub = widget.bridge.profileResults.listen((res) {
      if (!mounted) return;
      final isEn = widget.initialSnapshot.prefs.language == 'en';
      setState(() {
        _photoBusy = false;
        if (res.ok) {
          _profileFeedbackOk = true;
          _profileFeedback = res.kind == 'remove_picture'
              ? (isEn ? 'Profile photo removed' : 'Profilová fotka odstraněna')
              : (isEn ? 'Profile photo updated' : 'Profilová fotka aktualizována');
        } else {
          _profileFeedbackOk = false;
          _profileFeedback = res.error ??
              (isEn ? 'Could not update photo' : 'Fotku se nepodařilo nahrát');
        }
      });
    });
    widget.bridge.requestMediaStats();
  }

  @override
  void dispose() {
    _statsSub?.cancel();
    _profileSub?.cancel();
    _statusFocus.dispose();
    _nameCtrl.dispose();
    _statusCtrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return StreamBuilder<Snapshot>(
      stream: widget.bridge.snapshots,
      initialData: widget.initialSnapshot,
      builder: (context, snap) {
        final s = snap.data ?? widget.initialSnapshot;
        final prefs = s.prefs;
        final p = WaPalette.forPreset(prefs.darkThemePreset);
        final tr = Tr(prefs.language);

        return Dialog(
          backgroundColor: p.bg,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(14),
            side: BorderSide(color: p.divider),
          ),
          child: SizedBox(
            width: 760,
            height: 600,
            child: Row(
              children: [
                _buildSidebar(p, tr),
                VerticalDivider(width: 1, color: p.divider),
                Expanded(
                  child: Column(
                    children: [
                      Container(
                        height: 52,
                        padding: const EdgeInsets.symmetric(horizontal: 20),
                        decoration: BoxDecoration(
                          border:
                              Border(bottom: BorderSide(color: p.divider)),
                        ),
                        child: Row(
                          children: [
                            Expanded(
                              child: Text(
                                _tabTitle(_tab, tr),
                                style: const TextStyle(
                                  fontSize: 17,
                                  fontWeight: FontWeight.w600,
                                  color: WaPalette.textPrimary,
                                ),
                              ),
                            ),
                            IconButton(
                              onPressed: () => Navigator.pop(context),
                              icon: const Icon(Icons.close, size: 20),
                            ),
                          ],
                        ),
                      ),
                      Expanded(
                        child: SingleChildScrollView(
                          padding: const EdgeInsets.all(20),
                          child: switch (_tab) {
                            SettingsTab.profile => _profileTab(s, p, tr),
                            SettingsTab.chats => _chatsTab(prefs, p, tr),
                            SettingsTab.notifications =>
                              _notificationsTab(prefs, p, tr),
                            SettingsTab.privacy => _privacyTab(p, tr),
                            SettingsTab.appearance =>
                              _appearanceTab(prefs, p, tr),
                            SettingsTab.storage => _storageTab(s, prefs, p, tr),
                            SettingsTab.system => _systemTab(prefs, p, tr),
                          },
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        );
      },
    );
  }

  Widget _buildSidebar(WaPalette p, Tr tr) {
    final tabs = [
      (SettingsTab.profile, Icons.person_outline, tr.t('Účet a profil', 'Account & profile')),
      (SettingsTab.chats, Icons.chat_bubble_outline, tr.t('Konverzace a média', 'Chats & media')),
      (SettingsTab.notifications, Icons.notifications_none, tr.t('Oznámení', 'Notifications')),
      (SettingsTab.privacy, Icons.lock_outline, tr.t('Soukromí', 'Privacy')),
      (SettingsTab.appearance, Icons.palette_outlined, tr.t('Vzhled', 'Appearance')),
      (SettingsTab.storage, Icons.info_outline, tr.t('O aplikaci a data', 'About & storage')),
      (SettingsTab.system, Icons.desktop_windows_outlined, tr.t('Systém a spuštění', 'System & startup')),
    ];

    return Container(
      width: 224,
      color: p.surface,
      padding: const EdgeInsets.symmetric(vertical: 14, horizontal: 10),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
            child: Text(
              tr.t('Nastavení', 'Settings'),
              style: const TextStyle(
                fontSize: 19,
                fontWeight: FontWeight.bold,
                color: WaPalette.textPrimary,
              ),
            ),
          ),
          const SizedBox(height: 8),
          for (final (tab, icon, label) in tabs)
            Padding(
              padding: const EdgeInsets.only(bottom: 3),
              child: InkWell(
                onTap: () => setState(() => _tab = tab),
                borderRadius: BorderRadius.circular(8),
                child: Container(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
                  decoration: BoxDecoration(
                    color: _tab == tab
                        ? p.outgoingBubble
                        : Colors.transparent,
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: Row(
                    children: [
                      Icon(
                        icon,
                        size: 18,
                        color: _tab == tab
                            ? Colors.white
                            : WaPalette.textSecondary,
                      ),
                      const SizedBox(width: 10),
                      Expanded(
                        child: Text(
                          label,
                          style: TextStyle(
                            fontSize: 13.5,
                            color: _tab == tab
                                ? Colors.white
                                : WaPalette.textPrimary,
                            fontWeight: _tab == tab
                                ? FontWeight.w600
                                : FontWeight.w400,
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }

  String _tabTitle(SettingsTab tab, Tr tr) => switch (tab) {
        SettingsTab.profile => tr.t('Účet a profil', 'Account & profile'),
        SettingsTab.chats => tr.t('Konverzace a média', 'Chats & media'),
        SettingsTab.notifications => tr.t('Oznámení', 'Notifications'),
        SettingsTab.privacy => tr.t('Soukromí a zabezpečení', 'Privacy & security'),
        SettingsTab.appearance => tr.t('Vzhled aplikace', 'Application appearance'),
        SettingsTab.storage => tr.t('O aplikaci a úložiště', 'About & storage'),
        SettingsTab.system => tr.t('Systém a spuštění', 'System & startup'),
      };

  Widget _card(WaPalette p, String title, Widget child) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            title,
            style: const TextStyle(
              fontSize: 13.5,
              fontWeight: FontWeight.bold,
              color: WaPalette.accent,
            ),
          ),
          const SizedBox(height: 6),
          Material(
            color: p.surface,
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(10),
              side: BorderSide(color: p.divider),
            ),
            child: SizedBox(
              width: double.infinity,
              child: Padding(
                padding: const EdgeInsets.all(14),
                child: child,
              ),
            ),
          ),
        ],
      ),
    );
  }

  Future<void> _pickProfilePhoto(Tr tr) async {
    const typeGroup = XTypeGroup(
      label: 'Obrázky',
      extensions: ['png', 'jpg', 'jpeg', 'webp', 'bmp', 'gif'],
    );
    final file = await openFile(acceptedTypeGroups: const [typeGroup]);
    if (file == null || !mounted) return;
    setState(() {
      _photoBusy = true;
      _profileFeedback = null;
    });
    widget.bridge.setProfilePicture(file.path);
  }

  Widget _profileTab(Snapshot s, WaPalette p, Tr tr) {
    final incomingStatus = s.selfStatus ?? '';
    if (!_statusEdited &&
        !_statusFocus.hasFocus &&
        _statusCtrl.text != incomingStatus) {
      _statusCtrl.text = incomingStatus;
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _card(
          p,
          tr.t('Profilové údaje', 'Profile details'),
          Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Column(
                    children: [
                      WaAvatar(
                        name: s.selfName ?? 'WA',
                        avatarPath: s.selfAvatar,
                        radius: 36,
                        backgroundColor: WaPalette.accentDark,
                      ),
                      const SizedBox(height: 8),
                      Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          OutlinedButton.icon(
                            onPressed:
                                _photoBusy ? null : () => _pickProfilePhoto(tr),
                            style: OutlinedButton.styleFrom(
                              padding: const EdgeInsets.symmetric(
                                  horizontal: 10, vertical: 6),
                              minimumSize: const Size(0, 30),
                              side: BorderSide(color: p.divider),
                            ),
                            icon: _photoBusy
                                ? const SizedBox(
                                    width: 12,
                                    height: 12,
                                    child: CircularProgressIndicator(
                                        strokeWidth: 2),
                                  )
                                : const Icon(Icons.photo_camera_outlined,
                                    size: 14),
                            label: Text(
                              tr.t('Změnit', 'Change'),
                              style: const TextStyle(fontSize: 12),
                            ),
                          ),
                          if (s.selfAvatar != null &&
                              s.selfAvatar!.isNotEmpty) ...[
                            const SizedBox(width: 4),
                            IconButton(
                              tooltip:
                                  tr.t('Odstranit fotku', 'Remove photo'),
                              onPressed: _photoBusy
                                  ? null
                                  : () {
                                      setState(() {
                                        _photoBusy = true;
                                        _profileFeedback = null;
                                      });
                                      widget.bridge.removeProfilePicture();
                                    },
                              icon: const Icon(Icons.delete_outline,
                                  size: 16, color: Colors.redAccent),
                              visualDensity: VisualDensity.compact,
                            ),
                          ],
                        ],
                      ),
                    ],
                  ),
                  const SizedBox(width: 16),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Row(
                          children: [
                            Expanded(
                              child: TextField(
                                controller: _nameCtrl,
                                decoration: InputDecoration(
                                  isDense: true,
                                  labelText:
                                      tr.t('Jméno (Push Name)', 'Display name'),
                                  filled: true,
                                  fillColor: p.bg,
                                  border: OutlineInputBorder(
                                    borderRadius: BorderRadius.circular(8),
                                    borderSide: BorderSide.none,
                                  ),
                                ),
                              ),
                            ),
                            const SizedBox(width: 8),
                            FilledButton(
                              onPressed: () {
                                widget.bridge
                                    .setPushName(_nameCtrl.text.trim());
                                setState(() {
                                  _profileFeedbackOk = true;
                                  _profileFeedback = tr.t(
                                      'Jméno uloženo', 'Display name saved');
                                });
                              },
                              style: FilledButton.styleFrom(
                                  backgroundColor: WaPalette.accentDark),
                              child: Text(tr.t('Uložit', 'Save')),
                            ),
                          ],
                        ),
                        const SizedBox(height: 10),
                        Row(
                          children: [
                            Expanded(
                              child: TextField(
                                controller: _statusCtrl,
                                focusNode: _statusFocus,
                                maxLength: 139,
                                onChanged: (_) => _statusEdited = true,
                                decoration: InputDecoration(
                                  isDense: true,
                                  counterText: '',
                                  labelText:
                                      tr.t('O mně (Stav)', 'About / Status'),
                                  hintText: tr.t(
                                    'Např. V práci, Používám WaLite…',
                                    'e.g. At work, Using WaLite…',
                                  ),
                                  filled: true,
                                  fillColor: p.bg,
                                  border: OutlineInputBorder(
                                    borderRadius: BorderRadius.circular(8),
                                    borderSide: BorderSide.none,
                                  ),
                                ),
                              ),
                            ),
                            const SizedBox(width: 8),
                            FilledButton(
                              onPressed: () {
                                final text = _statusCtrl.text.trim();
                                widget.bridge.setStatusText(text);
                                setState(() {
                                  _statusEdited = false;
                                  _profileFeedbackOk = true;
                                  _profileFeedback = tr.t(
                                      'Stav „O mně“ uložen', 'About updated');
                                });
                              },
                              style: FilledButton.styleFrom(
                                  backgroundColor: WaPalette.accentDark),
                              child: Text(tr.t('Uložit', 'Save')),
                            ),
                          ],
                        ),
                        const SizedBox(height: 8),
                        if (s.self != null) ...[
                          Text(
                            '${tr.t('ID účtu', 'Account ID')}: ${s.self}',
                            style: const TextStyle(
                                fontSize: 12, color: WaPalette.textSecondary),
                          ),
                          Text(
                            '${tr.t('Telefon', 'Phone')}: ${formatJidPhone(s.self!)}',
                            style: const TextStyle(
                                fontSize: 12.5, color: WaPalette.accent),
                          ),
                        ],
                      ],
                    ),
                  ),
                ],
              ),
              if (_profileFeedback != null) ...[
                const SizedBox(height: 10),
                Container(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                  decoration: BoxDecoration(
                    color: (_profileFeedbackOk
                            ? WaPalette.accentBright
                            : Colors.redAccent)
                        .withValues(alpha: 0.12),
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: Text(
                    _profileFeedback!,
                    style: TextStyle(
                      fontSize: 12,
                      color: _profileFeedbackOk
                          ? WaPalette.accentBright
                          : Colors.redAccent,
                    ),
                  ),
                ),
              ],
            ],
          ),
        ),
        _card(
          p,
          tr.t('Stav připojení', 'Connection status'),
          Row(
            children: [
              Icon(
                Icons.circle,
                size: 11,
                color: s.connection == 'connected'
                    ? WaPalette.accentBright
                    : Colors.amber,
              ),
              const SizedBox(width: 8),
              Text(
                switch (s.connection) {
                  'connected' => tr.t('Online — Připojeno k WhatsApp',
                      'Online — Connected to WhatsApp'),
                  'connecting' => tr.t('Připojování…', 'Connecting…'),
                  'syncing' => tr.t('Synchronizace…', 'Syncing…'),
                  'disconnected' => tr.t('Odpojeno', 'Disconnected'),
                  'error' =>
                    '${tr.t('Chyba připojení', 'Connection error')}${s.detail != null ? ': ${s.detail}' : ''}',
                  _ => s.connection,
                },
                style: const TextStyle(fontSize: 13.5),
              ),
            ],
          ),
        ),
      ],
    );
  }

  Widget _chatsTab(Prefs prefs, WaPalette p, Tr tr) {
    return Column(
      children: [
        _card(
          p,
          tr.t('Odesílání zpráv', 'Sending messages'),
          Column(
            children: [
              SwitchListTile(
                dense: true,
                contentPadding: EdgeInsets.zero,
                title: Text(tr.t('Klávesa Enter odešle zprávu',
                    'Enter key sends message')),
                subtitle: Text(
                  tr.t(
                    'Když je zapnuto, Enter odešle zprávu a Shift+Enter vloží nový řádek.',
                    'When enabled, Enter sends and Shift+Enter inserts a new line.',
                  ),
                  style: const TextStyle(
                      fontSize: 11.5, color: WaPalette.textSecondary),
                ),
                value: prefs.enterIsSend,
                onChanged: (v) => widget.bridge.setPref('enter_is_send', v),
              ),
              SwitchListTile(
                dense: true,
                contentPadding: EdgeInsets.zero,
                title: Text(tr.t(
                    'Automaticky posouvat konverzaci dolů při nových zprávách',
                    'Auto-scroll to bottom on new messages')),
                value: prefs.autoScrollToBottom,
                onChanged: (v) =>
                    widget.bridge.setPref('auto_scroll_to_bottom', v),
              ),
            ],
          ),
        ),
        _card(
          p,
          tr.t('Automatické stahování médií', 'Auto-download media'),
          Column(
            children: [
              SwitchListTile(
                dense: true,
                contentPadding: EdgeInsets.zero,
                title: Text(tr.t('Automaticky stahovat fotografie a obrázky',
                    'Auto-download photos')),
                value: prefs.autoDownloadPhotos,
                onChanged: (v) =>
                    widget.bridge.setPref('auto_download_photos', v),
              ),
              SwitchListTile(
                dense: true,
                contentPadding: EdgeInsets.zero,
                title: Text(tr.t('Automaticky stahovat videa',
                    'Auto-download videos')),
                value: prefs.autoDownloadVideos,
                onChanged: (v) =>
                    widget.bridge.setPref('auto_download_videos', v),
              ),
              SwitchListTile(
                dense: true,
                contentPadding: EdgeInsets.zero,
                title: Text(tr.t('Automaticky stahovat dokumenty',
                    'Auto-download documents')),
                value: prefs.autoDownloadDocs,
                onChanged: (v) =>
                    widget.bridge.setPref('auto_download_docs', v),
              ),
            ],
          ),
        ),
        _card(
          p,
          tr.t('Velikost textu zpráv', 'Message font size'),
          Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Text('${tr.t('Velikost písma', 'Font size')}: ${prefs.fontSize.round()} px'),
                  Expanded(
                    child: Slider(
                      value: prefs.fontSize.clamp(12.0, 20.0),
                      min: 12,
                      max: 20,
                      divisions: 8,
                      activeColor: WaPalette.accent,
                      onChanged: (v) => widget.bridge.setPref('font_size', v),
                    ),
                  ),
                ],
              ),
              Text(
                tr.t('Ukázka: Ahoj! Jak se dnes máš?',
                    'Preview: Hey! How are you doing today?'),
                style: TextStyle(
                  fontSize: prefs.fontSize,
                  color: WaPalette.accentBright,
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }

  Widget _notificationsTab(Prefs prefs, WaPalette p, Tr tr) {
    return _card(
      p,
      tr.t('Upozornění a zvuky', 'Alerts and sounds'),
      Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SwitchListTile(
            dense: true,
            contentPadding: EdgeInsets.zero,
            title: Text(tr.t('Přehrát zvuk při příchozí zprávě',
                'Play sound on incoming message')),
            value: prefs.soundNotifications,
            onChanged: (v) => widget.bridge.setPref('sound_notifications', v),
          ),
          SwitchListTile(
            dense: true,
            contentPadding: EdgeInsets.zero,
            title: Text(tr.t('Zobrazovat náhled textu v oznámení',
                'Show message previews in notifications')),
            value: prefs.showPreviews,
            onChanged: (v) => widget.bridge.setPref('show_previews', v),
          ),
          SwitchListTile(
            dense: true,
            contentPadding: EdgeInsets.zero,
            title: Text(tr.t('Systémová oznámení na ploše',
                'Desktop notifications')),
            value: prefs.desktopNotifications,
            onChanged: (v) => widget.bridge.setPref('desktop_notifications', v),
          ),
          const SizedBox(height: 10),
          OutlinedButton.icon(
            onPressed: widget.bridge.testNotification,
            icon: const Icon(Icons.notifications_active_outlined, size: 17),
            label: Text(tr.t('Vyzkoušet oznámení', 'Test notification')),
          ),
        ],
      ),
    );
  }

  Widget _privacyTab(WaPalette p, Tr tr) {
    return _card(
      p,
      tr.t('End-to-End Šifrování', 'End-to-End Encryption'),
      Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Icon(Icons.lock, size: 28, color: WaPalette.accentBright),
          const SizedBox(width: 14),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  tr.t('Koncové šifrování je aktivní',
                      'End-to-end encryption is active'),
                  style: const TextStyle(
                    fontWeight: FontWeight.bold,
                    color: WaPalette.accentBright,
                  ),
                ),
                const SizedBox(height: 6),
                Text(
                  tr.t(
                    'Všechny vaše zprávy, reakce a média jsou šifrovány pomocí protokolu Signal. Klíče jsou uloženy pouze v lokální SQLite databázi ve vašem počítači.',
                    'All messages, reactions and media are encrypted using the Signal protocol. Keys remain stored locally in SQLite on your computer.',
                  ),
                  style: const TextStyle(
                    fontSize: 12.5,
                    color: WaPalette.textSecondary,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _appearanceTab(Prefs prefs, WaPalette p, Tr tr) {
    return Column(
      children: [
        _card(
          p,
          tr.t('Jazyk rozhraní', 'Interface language'),
          Wrap(
            spacing: 10,
            children: [
              ChoiceChip(
                label: const Text('Čeština'),
                selected: prefs.language == 'cs',
                onSelected: (_) => widget.bridge.setPref('language', 'cs'),
              ),
              ChoiceChip(
                label: const Text('English'),
                selected: prefs.language == 'en',
                onSelected: (_) => widget.bridge.setPref('language', 'en'),
              ),
            ],
          ),
        ),
        _card(
          p,
          tr.t('Barevné schéma', 'Colour scheme'),
          RadioGroup<int>(
            groupValue: prefs.darkThemePreset,
            onChanged: (v) {
              if (v != null) widget.bridge.setPref('dark_theme_preset', v);
            },
            child: Column(
              children: [
                RadioListTile<int>(
                  dense: true,
                  contentPadding: EdgeInsets.zero,
                  value: 0,
                  title: Text(tr.t('Výchozí WhatsApp Dark (#111B21)',
                      'Default WhatsApp Dark (#111B21)')),
                ),
                RadioListTile<int>(
                  dense: true,
                  contentPadding: EdgeInsets.zero,
                  value: 1,
                  title: Text(tr.t('OLED Černá (#000000)',
                      'OLED Black (#000000)')),
                ),
                RadioListTile<int>(
                  dense: true,
                  contentPadding: EdgeInsets.zero,
                  value: 2,
                  title: Text(tr.t('Půlnoční modrá (#0A192F)',
                      'Midnight Blue (#0A192F)')),
                ),
              ],
            ),
          ),
        ),
        _card(
          p,
          tr.t('Pozadí konverzace', 'Chat wallpaper'),
          Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                tr.t('Barva pozadí', 'Background color'),
                style: const TextStyle(
                    fontSize: 12.5, color: WaPalette.textSecondary),
              ),
              const SizedBox(height: 8),
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: [
                  _swatch(
                    color: p.chatCanvas,
                    selected: prefs.chatWallpaperColor == null &&
                        (prefs.chatWallpaperPath == null ||
                            prefs.chatWallpaperPath!.isEmpty),
                    tooltip: tr.t('Výchozí motiv', 'Theme default'),
                    onTap: () {
                      widget.bridge.setPref('chat_wallpaper_color', null);
                      widget.bridge.setPref('chat_wallpaper_path', null);
                    },
                  ),
                  for (final (hex, color, label) in const [
                    ('#0B221D', Color(0xFF0B221D), 'Tmavě zelená'),
                    ('#15202B', Color(0xFF15202B), 'Břidlicová'),
                    ('#1F1624', Color(0xFF1F1624), 'Švestková'),
                    ('#24161A', Color(0xFF24161A), 'Vínová'),
                    ('#1E1A16', Color(0xFF1E1A16), 'Kávová'),
                    ('#0E1A2B', Color(0xFF0E1A2B), 'Hluboká modř'),
                  ])
                    _swatch(
                      color: color,
                      selected: prefs.chatWallpaperColor == hex &&
                          (prefs.chatWallpaperPath == null ||
                              prefs.chatWallpaperPath!.isEmpty),
                      tooltip: label,
                      onTap: () {
                        widget.bridge.setPref('chat_wallpaper_path', null);
                        widget.bridge.setPref('chat_wallpaper_color', hex);
                      },
                    ),
                ],
              ),
              const SizedBox(height: 12),
              Row(
                children: [
                  OutlinedButton.icon(
                    onPressed: () async {
                      const typeGroup = XTypeGroup(
                        label: 'Obrázky',
                        extensions: ['png', 'jpg', 'jpeg', 'webp', 'bmp'],
                      );
                      final file = await openFile(
                          acceptedTypeGroups: const [typeGroup]);
                      if (file != null) {
                        widget.bridge.setPref('chat_wallpaper_path', file.path);
                      }
                    },
                    icon: const Icon(Icons.wallpaper_outlined, size: 16),
                    label: Text(
                        tr.t('Vybrat vlastní obrázek…', 'Choose custom image…')),
                  ),
                  const SizedBox(width: 8),
                  if (prefs.chatWallpaperPath != null &&
                      prefs.chatWallpaperPath!.isNotEmpty)
                    TextButton.icon(
                      onPressed: () =>
                          widget.bridge.setPref('chat_wallpaper_path', null),
                      icon: const Icon(Icons.close, size: 16),
                      label: Text(tr.t('Odebrat obrázek', 'Remove image')),
                    ),
                ],
              ),
              if (prefs.chatWallpaperPath != null &&
                  prefs.chatWallpaperPath!.isNotEmpty) ...[
                const SizedBox(height: 4),
                Text(
                  prefs.chatWallpaperPath!,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                      fontSize: 11.5, color: WaPalette.textSecondary),
                ),
              ],
              const SizedBox(height: 6),
              SwitchListTile(
                dense: true,
                contentPadding: EdgeInsets.zero,
                title: Text(tr.t('Jemný WhatsApp vzorek na pozadí',
                    'Subtle WhatsApp doodle pattern')),
                value: prefs.chatWallpaperDoodles,
                onChanged: (v) =>
                    widget.bridge.setPref('chat_wallpaper_doodles', v),
              ),
            ],
          ),
        ),
      ],
    );
  }

  Widget _swatch({
    required Color color,
    required bool selected,
    required String tooltip,
    required VoidCallback onTap,
  }) {
    return Tooltip(
      message: tooltip,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(18),
        child: Container(
          width: 30,
          height: 30,
          decoration: BoxDecoration(
            color: color,
            shape: BoxShape.circle,
            border: Border.all(
              color: selected ? WaPalette.accentBright : Colors.white24,
              width: selected ? 2.5 : 1,
            ),
          ),
          child: selected
              ? const Icon(Icons.check, size: 15, color: WaPalette.accentBright)
              : null,
        ),
      ),
    );
  }

  Widget _storageTab(Snapshot s, Prefs prefs, WaPalette p, Tr tr) {
    final stats = _stats;
    final update = s.update;

    return Column(
      children: [
        _card(
          p,
          tr.t('Verze aplikace', 'Application version'),
          Row(
            children: [
              Image.asset(
                'assets/icon.png',
                width: 44,
                height: 44,
                filterQuality: FilterQuality.medium,
                errorBuilder: (_, _, _) => const Icon(
                  Icons.chat_bubble,
                  color: WaPalette.accentBright,
                  size: 36,
                ),
              ),
              const SizedBox(width: 14),
              Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text('WaLite: v${update.current}'),
                  const Text('whatsapp-rust: 0.7.0 (Rust native client)'),
                  const Text('GUI: Flutter Desktop'),
                ],
              ),
            ],
          ),
        ),
        _card(
          p,
          tr.t('Správa stažených médií', 'Downloaded media storage'),
          Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              if (stats != null) ...[
                Text(
                  stats.dir,
                  style: const TextStyle(
                      fontSize: 11.5, color: WaPalette.textSecondary),
                ),
                const SizedBox(height: 6),
                Text(
                  '${tr.t('Souborů', 'Files')}: ${stats.files} · ${formatBytes(stats.totalBytes)}',
                ),
                Text(
                  '${tr.t('Nepoužívané', 'Unused')}: ${stats.staleFiles} · ${formatBytes(stats.staleBytes)}',
                  style: const TextStyle(
                      fontSize: 12, color: WaPalette.textSecondary),
                ),
              ] else
                const Text('…'),
              const SizedBox(height: 10),
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: [
                  OutlinedButton.icon(
                    onPressed: widget.bridge.openMediaDir,
                    icon: const Icon(Icons.folder_open, size: 16),
                    label: Text(
                        tr.t('Otevřít složku médií', 'Open media folder')),
                  ),
                  OutlinedButton.icon(
                    onPressed: (stats?.staleFiles ?? 0) > 0
                        ? () => widget.bridge.cleanMedia('stale')
                        : null,
                    icon: const Icon(Icons.cleaning_services, size: 16),
                    label: Text(
                        tr.t('Smazat nepoužívané', 'Delete unused')),
                  ),
                  OutlinedButton.icon(
                    onPressed: (stats?.oldFiles ?? 0) > 0
                        ? () => widget.bridge.cleanMedia('old')
                        : null,
                    icon: const Icon(Icons.delete_sweep, size: 16),
                    label: Text(tr.t('Starší 30 dní', 'Older than 30 days')),
                  ),
                ],
              ),
              if (_cleanedBanner != null) ...[
                const SizedBox(height: 6),
                Text(
                  '${tr.t('Uvolněno', 'Freed')}: $_cleanedBanner',
                  style: const TextStyle(
                      fontSize: 12, color: WaPalette.accentBright),
                ),
              ],
            ],
          ),
        ),
        _card(
          p,
          tr.t('Aktualizace', 'Updates'),
          Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              if (update.status.isNotEmpty)
                Padding(
                  padding: const EdgeInsets.only(bottom: 8),
                  child: Text(update.status,
                      style: const TextStyle(
                          fontSize: 12, color: WaPalette.textSecondary)),
                ),
              Wrap(
                spacing: 8,
                children: [
                  OutlinedButton.icon(
                    onPressed: update.busy ? null : widget.bridge.checkUpdates,
                    icon: const Icon(Icons.refresh, size: 16),
                    label: Text(tr.t('Zkontrolovat aktualizace',
                        'Check for updates')),
                  ),
                  if (update.available != null)
                    FilledButton.icon(
                      onPressed: widget.onOpenUpdate,
                      style: FilledButton.styleFrom(
                          backgroundColor: WaPalette.accentDark),
                      icon: const Icon(Icons.download, size: 16),
                      label: Text('v${update.available!.version}'),
                    ),
                ],
              ),
              SwitchListTile(
                dense: true,
                contentPadding: EdgeInsets.zero,
                title: Text(tr.t('Kontrolovat aktualizace na pozadí',
                    'Check updates in background')),
                value: prefs.checkUpdates,
                onChanged: (v) => widget.bridge.setPref('check_updates', v),
              ),
              SwitchListTile(
                dense: true,
                contentPadding: EdgeInsets.zero,
                title: Text(tr.t('Instalovat aktualizace automaticky',
                    'Auto-install updates')),
                value: prefs.autoInstallUpdates,
                onChanged: (v) =>
                    widget.bridge.setPref('auto_install_updates', v),
              ),
            ],
          ),
        ),
        _card(
          p,
          tr.t('Klávesové zkratky', 'Keyboard shortcuts'),
          Column(
            children: [
              _shortcut('Ctrl+K', tr.t('Přepínač chatů', 'Switch chat')),
              _shortcut('Ctrl+F', tr.t('Hledání ve zprávách', 'Search messages')),
              _shortcut('Esc', tr.t('Zavřít okno nebo dialog', 'Close panel or dialog')),
              _shortcut('Alt+↓', tr.t('Další nepřečtený chat', 'Next unread chat')),
              _shortcut('Ctrl+V', tr.t('Vložit obrázek ze schránky', 'Paste image from clipboard')),
            ],
          ),
        ),
        _card(
          p,
          tr.t('Účet a odhlášení', 'Account & sign out'),
          OutlinedButton.icon(
            onPressed: () async {
              final ok = await widget.onConfirm(
                tr.t('Odhlásit se z WhatsApp?', 'Sign out from WhatsApp?'),
                tr.t(
                  'Relace bude ukončena a pro další použití bude nutné znovu naskenovat QR kód.',
                  'Your session will end and you will need to scan a QR code again.',
                ),
                tr.t('Odhlásit se', 'Sign out'),
              );
              if (ok && mounted) {
                widget.bridge.disconnect();
                Navigator.pop(context);
              }
            },
            icon: const Icon(Icons.logout, size: 17, color: WaPalette.danger),
            label: Text(
              tr.t('Odhlásit se z účtu WhatsApp', 'Log out of WhatsApp'),
              style: const TextStyle(color: WaPalette.danger),
            ),
          ),
        ),
      ],
    );
  }

  Widget _shortcut(String keys, String desc) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 2),
      child: Row(
        children: [
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
            decoration: BoxDecoration(
              color: Colors.white10,
              borderRadius: BorderRadius.circular(4),
            ),
            child: Text(keys,
                style: const TextStyle(
                    fontFamily: 'monospace',
                    fontSize: 11.5,
                    color: WaPalette.textPrimary)),
          ),
          const SizedBox(width: 10),
          Text(desc,
              style: const TextStyle(
                  fontSize: 12.5, color: WaPalette.textSecondary)),
        ],
      ),
    );
  }

  Widget _systemTab(Prefs prefs, WaPalette p, Tr tr) {
    return Column(
      children: [
        _card(
          p,
          tr.t('Spuštění se systémem Windows', 'Start with Windows'),
          SwitchListTile(
            dense: true,
            contentPadding: EdgeInsets.zero,
            title: Text(tr.t('Spouštět WaLite při přihlášení do Windows',
                'Launch WaLite at Windows sign-in')),
            value: prefs.startWithWindows,
            onChanged: (v) => widget.bridge.setPref('start_with_windows', v),
          ),
        ),
        _card(
          p,
          tr.t('Oznamovací oblast (Tray)', 'System Tray'),
          Column(
            children: [
              SwitchListTile(
                dense: true,
                contentPadding: EdgeInsets.zero,
                title: Text(tr.t('Zavřením okna minimalizovat do systémové lišty',
                    'Minimize to tray on close')),
                value: prefs.closeToTray,
                onChanged: (v) => widget.bridge.setPref('close_to_tray', v),
              ),
              SwitchListTile(
                dense: true,
                contentPadding: EdgeInsets.zero,
                title: Text(tr.t('Zobrazovat ikonu v oznamovací oblasti',
                    'Show system tray icon')),
                value: prefs.runInTray,
                onChanged: (v) => widget.bridge.setPref('run_in_tray', v),
              ),
            ],
          ),
        ),
      ],
    );
  }
}
