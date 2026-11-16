import 'package:material_ui/material_ui.dart';

import '../bridge.dart';
import '../i18n.dart';
import '../theme.dart';
import 'avatar.dart';

enum RailSection { chats, archived }

/// Far-left WhatsApp Desktop navigation rail.
class WaNavRail extends StatelessWidget {
  const WaNavRail({
    super.key,
    required this.snapshot,
    required this.palette,
    required this.tr,
    required this.section,
    required this.onSelectSection,
    required this.onOpenContacts,
    required this.onOpenScheduled,
    required this.onOpenStarred,
    required this.onOpenSearch,
    required this.onOpenPalette,
    required this.onOpenUpdate,
    required this.onOpenSettings,
    required this.onOpenProfile,
  });

  final Snapshot snapshot;
  final WaPalette palette;
  final Tr tr;
  final RailSection section;
  final ValueChanged<RailSection> onSelectSection;
  final VoidCallback onOpenContacts;
  final VoidCallback onOpenScheduled;
  final VoidCallback onOpenStarred;
  final VoidCallback onOpenSearch;
  final VoidCallback onOpenPalette;
  final VoidCallback onOpenUpdate;
  final VoidCallback onOpenSettings;
  final VoidCallback onOpenProfile;

  @override
  Widget build(BuildContext context) {
    final unreadTotal =
        snapshot.chats.fold<int>(0, (sum, c) => sum + c.unread);
    final pendingScheduled =
        snapshot.scheduled.where((s) => s.status == 'pending').length;
    final archivedCount = snapshot.archived.length;

    return Container(
      width: 62,
      decoration: BoxDecoration(
        color: palette.surface,
        border: Border(right: BorderSide(color: palette.divider)),
      ),
      child: Column(
        children: [
          const SizedBox(height: 10),
          Tooltip(
            message: 'WaLite',
            child: ClipRRect(
              borderRadius: BorderRadius.circular(8),
              child: Image.asset(
                'assets/icon.png',
                width: 28,
                height: 28,
                filterQuality: FilterQuality.medium,
                errorBuilder: (_, _, _) => const Icon(
                  Icons.chat_bubble,
                  color: WaPalette.accentBright,
                  size: 24,
                ),
              ),
            ),
          ),
          const SizedBox(height: 12),
          _RailIcon(
            icon: section == RailSection.chats
                ? Icons.chat
                : Icons.chat_outlined,
            tooltip: tr.t('Chaty', 'Chats'),
            active: section == RailSection.chats,
            badge: unreadTotal,
            palette: palette,
            onTap: () => onSelectSection(RailSection.chats),
          ),
          const SizedBox(height: 6),
          _RailIcon(
            icon: section == RailSection.archived
                ? Icons.archive
                : Icons.archive_outlined,
            tooltip: tr.t('Archivované', 'Archived'),
            active: section == RailSection.archived,
            badge: archivedCount,
            badgeMuted: true,
            palette: palette,
            onTap: () => onSelectSection(RailSection.archived),
          ),
          const SizedBox(height: 6),
          _RailIcon(
            icon: Icons.people_outline,
            tooltip: tr.t('Kontakty', 'Contacts'),
            palette: palette,
            onTap: onOpenContacts,
          ),
          const SizedBox(height: 6),
          _RailIcon(
            icon: Icons.schedule,
            tooltip: tr.t('Naplánované zprávy', 'Scheduled messages'),
            badge: pendingScheduled,
            palette: palette,
            onTap: onOpenScheduled,
          ),
          const SizedBox(height: 6),
          _RailIcon(
            icon: Icons.star_outline_rounded,
            tooltip: tr.t('Hvězdičkované zprávy', 'Starred messages'),
            palette: palette,
            onTap: onOpenStarred,
          ),
          const SizedBox(height: 6),
          _RailIcon(
            icon: Icons.search,
            tooltip: tr.t('Hledat ve zprávách (Ctrl+F)', 'Search messages (Ctrl+F)'),
            palette: palette,
            onTap: onOpenSearch,
          ),
          const SizedBox(height: 6),
          _RailIcon(
            icon: Icons.bolt,
            tooltip: tr.t('Přepnout chat (Ctrl+K)', 'Switch chat (Ctrl+K)'),
            palette: palette,
            onTap: onOpenPalette,
          ),
          const Spacer(),
          if (snapshot.update.available != null) ...[
            _RailIcon(
              icon: Icons.system_update_alt,
              tooltip:
                  '${tr.t('Dostupná aktualizace', 'Update available')} v${snapshot.update.available!.version}',
              highlightColor: WaPalette.accentBright,
              palette: palette,
              onTap: onOpenUpdate,
            ),
            const SizedBox(height: 6),
          ],
          _ConnectionDot(status: snapshot.connection, tr: tr),
          const SizedBox(height: 8),
          _RailIcon(
            icon: Icons.settings_outlined,
            tooltip: tr.t('Nastavení', 'Settings'),
            palette: palette,
            onTap: onOpenSettings,
          ),
          const SizedBox(height: 10),
          Tooltip(
            message: snapshot.selfName ?? tr.t('Můj profil', 'My profile'),
            child: InkWell(
              onTap: onOpenProfile,
              borderRadius: BorderRadius.circular(20),
              child: Padding(
                padding: const EdgeInsets.all(4),
                child: WaAvatar(
                  name: snapshot.selfName ?? 'WA',
                  avatarPath: snapshot.selfAvatar,
                  radius: 17,
                  backgroundColor: WaPalette.accentDark,
                ),
              ),
            ),
          ),
          const SizedBox(height: 12),
        ],
      ),
    );
  }
}

class _RailIcon extends StatelessWidget {
  const _RailIcon({
    required this.icon,
    required this.tooltip,
    required this.palette,
    required this.onTap,
    this.active = false,
    this.badge = 0,
    this.badgeMuted = false,
    this.highlightColor,
  });

  final IconData icon;
  final String tooltip;
  final WaPalette palette;
  final VoidCallback onTap;
  final bool active;
  final int badge;
  final bool badgeMuted;
  final Color? highlightColor;

  @override
  Widget build(BuildContext context) {
    return Tooltip(
      message: tooltip,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(12),
        child: Container(
          width: 44,
          height: 44,
          decoration: BoxDecoration(
            color: active ? palette.surfaceElevated : Colors.transparent,
            borderRadius: BorderRadius.circular(12),
          ),
          child: Stack(
            alignment: Alignment.center,
            children: [
              Icon(
                icon,
                size: 22,
                color: highlightColor ??
                    (active ? WaPalette.textPrimary : WaPalette.textSecondary),
              ),
              if (badge > 0)
                Positioned(
                  right: 5,
                  top: 6,
                  child: Container(
                    padding:
                        const EdgeInsets.symmetric(horizontal: 4, vertical: 1),
                    decoration: BoxDecoration(
                      color: badgeMuted
                          ? WaPalette.textSecondary
                          : WaPalette.accent,
                      borderRadius: BorderRadius.circular(9),
                    ),
                    child: Text(
                      badge > 99 ? '99+' : '$badge',
                      style: const TextStyle(
                        fontSize: 9.5,
                        fontWeight: FontWeight.bold,
                        color: Colors.black,
                      ),
                    ),
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }
}

class _ConnectionDot extends StatelessWidget {
  const _ConnectionDot({required this.status, required this.tr});

  final String status;
  final Tr tr;

  @override
  Widget build(BuildContext context) {
    final (color, label) = switch (status) {
      'connected' => (WaPalette.accentBright, tr.t('Připojeno', 'Connected')),
      'connecting' => (Colors.amber, tr.t('Připojování…', 'Connecting…')),
      'syncing' => (Colors.amber, tr.t('Synchronizace…', 'Syncing…')),
      'error' => (WaPalette.danger, tr.t('Chyba připojení', 'Connection error')),
      _ => (WaPalette.textSecondary, status),
    };
    return Tooltip(
      message: label,
      child: Container(
        width: 10,
        height: 10,
        decoration: BoxDecoration(color: color, shape: BoxShape.circle),
      ),
    );
  }
}
