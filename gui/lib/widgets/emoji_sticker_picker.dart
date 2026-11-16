import 'dart:io';

import 'package:file_selector/file_selector.dart';
import 'package:material_ui/material_ui.dart';

import '../i18n.dart';
import '../theme.dart';

class EmojiCategoryData {
  const EmojiCategoryData({
    required this.nameCs,
    required this.nameEn,
    required this.icon,
    required this.emojis,
  });

  final String nameCs;
  final String nameEn;
  final String icon;
  final List<String> emojis;
}

const quickReactions = ['👍', '❤️', '😂', '😮', '😢', '🙏', '🔥', '🎉'];

const _popularEmojis = [
  '👍', '❤️', '😂', '🔥', '🙏', '🎉', '💀', '✨',
  '👏', '🥰', '😍', '🥺', '🤣', '😭', '💯', '👌',
];

const _emojiCategories = [
  EmojiCategoryData(
    nameCs: 'Smajlíci a emoce',
    nameEn: 'Smileys & Emotion',
    icon: '😃',
    emojis: [
      '😀', '😃', '😄', '😁', '😆', '😅', '🤣', '😂', '🙂', '🙃', '😉', '😊',
      '😇', '🥰', '😍', '🤩', '😘', '😗', '😚', '😙', '😋', '😛', '😜', '🤪',
      '😝', '🤑', '🤗', '🤭', '🤫', '🤔', '🤐', '🤨', '😐', '😑', '😶', '😏',
      '😒', '🙄', '😬', '🤥', '😌', '😔', '😪', '🤤', '😴', '😷', '🤒', '🤕',
      '🤢', '🤮', '🤧', '🥵', '🥶', '🥴', '😵', '🤯', '🤠', '🥳', '😎', '🤓',
      '🧐', '😕', '😟', '🙁', '😮', '😯', '😲', '😳', '🥺', '😦', '😧', '💀',
      '☠️', '👻', '💩', '🤡', '🤖', '🎃',
    ],
  ),
  EmojiCategoryData(
    nameCs: 'Gesta a tělo',
    nameEn: 'Gestures & Body',
    icon: '👋',
    emojis: [
      '👋', '🤚', '🖐️', '✋', '🖖', '👌', '🤌', '🤏', '✌️', '🤞', '🫰', '🤟',
      '🤘', '🤙', '👈', '👉', '👆', '🖕', '👇', '☝️', '👍', '👎', '✊', '👊',
      '🤛', '🤜', '👏', '🙌', '🫶', '👐', '🤲', '🤝', '🙏', '✍️', '💅', '🤳',
      '💪', '🦵', '🦶', '👂', '👀', '👁️', '👅', '👄',
    ],
  ),
  EmojiCategoryData(
    nameCs: 'Srdce a emoce',
    nameEn: 'Hearts & Love',
    icon: '❤️',
    emojis: [
      '❤️', '🧡', '💛', '💚', '💙', '💜', '🖤', '🤍', '🤎', '💔', '❣️', '💕',
      '💞', '💓', '💗', '💖', '💘', '💝', '💟', '💌', '💋', '💯', '💢', '💥',
      '💫', '✨', '🌟', '🔥',
    ],
  ),
  EmojiCategoryData(
    nameCs: 'Zvířata a příroda',
    nameEn: 'Animals & Nature',
    icon: '🐶',
    emojis: [
      '🐶', '🐱', '🐭', '🐹', '🐰', '🦊', '🐻', '🐼', '🐨', '🐯', '🦁', '🐮',
      '🐷', '🐸', '🐵', '🐔', '🐧', '🐦', '🐤', '🦆', '🦅', '🦉', '🐺', '🐴',
      '🦄', '🐝', '🐛', '🦋', '🐌', '🐞', '🐜', '🦀', '🐙', '🐠', '🐬', '🐳',
      '🐊', '🐢', '🐍', '🌲', '🌳', '🌴', '🌵', '🌿', '🍀', '🍁', '🍂', '🍄',
    ],
  ),
  EmojiCategoryData(
    nameCs: 'Jídlo a nápoje',
    nameEn: 'Food & Drink',
    icon: '🍕',
    emojis: [
      '🍏', '🍎', '🍐', '🍊', '🍋', '🍌', '🍉', '🍇', '🍓', '🍒', '🍑', '🍍',
      '🥥', '🥝', '🍅', '🥑', '🥦', '🌽', '🥕', '🍞', '🥐', '🥖', '🥨', '🧀',
      '🍗', '🥩', '🍔', '🍟', '🍕', '🌭', '🥪', '🌮', '🌯', '🍝', '🍜', '🍲',
      '🍣', '🍱', '🥟', '🍦', '🍧', '🍨', '🍩', '🍪', '🎂', '🍰', '🧁', '🍫',
      '🍬', '🍭', '🍿', '☕', '🍵', '🧃', '🥤', '🧋', '🍺', '🍻', '🥂', '🍷',
      '🥃', '🍸',
    ],
  ),
  EmojiCategoryData(
    nameCs: 'Aktivity a sport',
    nameEn: 'Activities & Sport',
    icon: '⚽',
    emojis: [
      '⚽', '🏀', '🏈', '⚾', '🎾', '🏐', '🎱', '🏓', '🏸', '🏒', '🥊', '🥋',
      '🛹', '🛼', '⛸️', '🎿', '🏂', '🏋️', '🤼', '🤸', '🎯', '🎳', '🎮', '🎲',
      '♟️', '🏆', '🥇', '🥈', '🥉', '🏅', '🎖️', '🎫', '🎟️', '🎪', '🎨', '🎬',
      '🎤', '🎧', '🎼', '🎹', '🥁', '🎷', '🎺', '🎸', '🎻', '🎭',
    ],
  ),
  EmojiCategoryData(
    nameCs: 'Cestování a místa',
    nameEn: 'Travel & Places',
    icon: '🚗',
    emojis: [
      '🚗', '🚕', '🚙', '🚌', '🏎️', '🚓', '🚑', '🚒', '🚐', '🚚', '🚜', '🚲',
      '🛴', '🛵', '🏍️', '🚨', '🚔', '✈️', '🛫', '🛬', '🚀', '🛸', '🚁', '⛵',
      '🚤', '🛳️', '⚓', '🚧', '🚥', '🚦', '🛑', '🗺️', '🗿', '🗽', '🗼', '🏰',
      '🏟️', '🏖️', '🏝️', '🌋', '⛰️', '🏔️', '🏕️', '🏠', '🏢', '🏦', '🏥',
    ],
  ),
  EmojiCategoryData(
    nameCs: 'Předměty a symboly',
    nameEn: 'Objects & Symbols',
    icon: '💡',
    emojis: [
      '⌚', '📱', '📲', '💻', '⌨️', '🖥️', '🖨️', '💾', '📷', '📸', '📹', '🎥',
      '📞', '☎️', '📺', '📻', '🎙️', '⏱️', '⏰', '🕰️', '⏳', '💡', '🔦', '🕯️',
      '💸', '💵', '💰', '💳', '💎', '🔧', '🔨', '🛠️', '🔑', '🗝️', '🚪', '🎁',
      '🎈', '🎉', '🎊', '✉️', '📩', '📦', '🏷️', '📌', '📍', '✂️', '🖊️', '📝',
      '✏️', '🔍', '🔎', '🔒', '🔓', '🔔', '🔕', '📢', '📣',
    ],
  ),
];

List<String> searchEmojis(String query) {
  final q = query.toLowerCase().trim();
  if (q.isEmpty) return const [];
  final out = <String>{};
  void addIf(bool cond, List<String> items) {
    if (cond) out.addAll(items);
  }

  addIf(q.contains('srdc') || q.contains('heart') || q.contains('love') || q.contains('lask'),
      ['❤️', '💖', '🥰', '😍', '💕', '💞', '💓', '💗', '💘', '💔']);
  addIf(q.contains('smej') || q.contains('smich') || q.contains('laugh') || q.contains('lol') || q.contains('vtip'),
      ['😂', '🤣', '😆', '😅', '😄', '😃', '😀']);
  addIf(q.contains('palec') || q.contains('thumb') || q.contains('ok') || q.contains('dobre') || q.contains('super'),
      ['👍', '👎', '👌', '✌️', '👏', '🙌', '🤝']);
  addIf(q.contains('ohen') || q.contains('fire') || q.contains('plamen') || q.contains('hot'),
      ['🔥', '💥', '✨']);
  addIf(q.contains('lebk') || q.contains('skull') || q.contains('smrt') || q.contains('dead'),
      ['💀', '☠️', '👻']);
  addIf(q.contains('plac') || q.contains('cry') || q.contains('smut') || q.contains('sad') || q.contains('slza'),
      ['😢', '😭', '🥺', '😔', '😪']);
  addIf(q.contains('modl') || q.contains('pray') || q.contains('pros') || q.contains('dek') || q.contains('thanks'),
      ['🙏', '✨']);
  addIf(q.contains('part') || q.contains('oslav') || q.contains('slav') || q.contains('darek') || q.contains('gift'),
      ['🎉', '🥳', '🎊', '🎁', '🎈']);
  addIf(q.contains('pes') || q.contains('dog') || q.contains('kock') || q.contains('cat') || q.contains('zvire'),
      ['🐶', '🐱', '🦊', '🐻', '🦁', '🐵', '🐸']);
  addIf(q.contains('piv') || q.contains('beer') || q.contains('vino') || q.contains('wine'),
      ['🍺', '🍻', '🥂', '🍷', '🥃', '🍸']);
  addIf(q.contains('jidlo') || q.contains('food') || q.contains('pizza') || q.contains('burger'),
      ['🍕', '🍔', '🍟', '🌭', '🥪', '🌮']);
  addIf(q.contains('kafe') || q.contains('coffee') || q.contains('caj') || q.contains('tea'),
      ['☕', '🍵', '🧋', '🥤']);
  addIf(q.contains('auto') || q.contains('car') || q.contains('let') || q.contains('plane'),
      ['🚗', '🏎️', '🚕', '🚌', '✈️', '🚀', '🏍️']);
  addIf(q.contains('peniz') || q.contains('money') || q.contains('cash'),
      ['💰', '💸', '💵', '💳', '🤑']);

  for (final cat in _emojiCategories) {
    if (cat.nameCs.toLowerCase().contains(q) ||
        cat.nameEn.toLowerCase().contains(q)) {
      out.addAll(cat.emojis);
    }
  }
  return out.toList();
}

/// Categorized emoji picker matching `src/ui/emoji.rs`.
class EmojiPickerPanel extends StatefulWidget {
  const EmojiPickerPanel({
    super.key,
    required this.palette,
    required this.tr,
    required this.onSelect,
    this.onClose,
    this.title,
  });

  final WaPalette palette;
  final Tr tr;
  final ValueChanged<String> onSelect;
  final VoidCallback? onClose;
  final String? title;

  @override
  State<EmojiPickerPanel> createState() => _EmojiPickerPanelState();
}

class _EmojiPickerPanelState extends State<EmojiPickerPanel> {
  final _searchCtrl = TextEditingController();
  int _category = 0;

  @override
  void dispose() {
    _searchCtrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final p = widget.palette;
    final tr = widget.tr;
    final query = _searchCtrl.text.trim();
    final emojis = query.isNotEmpty
        ? searchEmojis(query)
        : <String>{
            if (_category == 0) ..._popularEmojis,
            ..._emojiCategories[_category].emojis,
          }.toList();

    return Container(
      width: 340,
      height: 350,
      decoration: BoxDecoration(
        color: p.surface,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: p.divider),
        boxShadow: const [
          BoxShadow(color: Colors.black54, blurRadius: 18, offset: Offset(0, 6)),
        ],
      ),
      padding: const EdgeInsets.all(10),
      child: Column(
        children: [
          if (widget.title != null || widget.onClose != null)
            Padding(
              padding: const EdgeInsets.only(bottom: 6),
              child: Row(
                children: [
                  Expanded(
                    child: Text(
                      widget.title ?? tr.t('Emoji', 'Emoji'),
                      style: const TextStyle(
                        fontSize: 13,
                        fontWeight: FontWeight.w600,
                        color: WaPalette.textPrimary,
                      ),
                    ),
                  ),
                  if (widget.onClose != null)
                    InkWell(
                      onTap: widget.onClose,
                      child: const Icon(Icons.close,
                          size: 16, color: WaPalette.textSecondary),
                    ),
                ],
              ),
            ),
          TextField(
            controller: _searchCtrl,
            onChanged: (_) => setState(() {}),
            style: const TextStyle(fontSize: 13),
            decoration: InputDecoration(
              isDense: true,
              filled: true,
              fillColor: p.bg,
              prefixIcon: const Icon(Icons.search, size: 17),
              suffixIcon: query.isNotEmpty
                  ? IconButton(
                      icon: const Icon(Icons.close, size: 15),
                      onPressed: () {
                        _searchCtrl.clear();
                        setState(() {});
                      },
                    )
                  : null,
              hintText: tr.t('Hledat emoji (srdce, oheň, pivo…)',
                  'Search emoji (heart, fire, beer…)'),
              border: OutlineInputBorder(
                borderRadius: BorderRadius.circular(10),
                borderSide: BorderSide.none,
              ),
            ),
          ),
          const SizedBox(height: 6),
          if (query.isEmpty) ...[
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: List.generate(_emojiCategories.length, (idx) {
                final cat = _emojiCategories[idx];
                final active = _category == idx;
                return Tooltip(
                  message: tr.isEn ? cat.nameEn : cat.nameCs,
                  child: InkWell(
                    onTap: () => setState(() => _category = idx),
                    borderRadius: BorderRadius.circular(6),
                    child: Container(
                      width: 34,
                      height: 30,
                      alignment: Alignment.center,
                      decoration: BoxDecoration(
                        color: active ? WaPalette.accentDark : Colors.transparent,
                        borderRadius: BorderRadius.circular(6),
                      ),
                      child: Text(cat.icon, style: const TextStyle(fontSize: 17)),
                    ),
                  ),
                );
              }),
            ),
            Divider(color: p.divider, height: 10),
          ],
          Expanded(
            child: emojis.isEmpty
                ? Center(
                    child: Text(
                      tr.t('Nenalezena žádná emoji', 'No emojis found'),
                      style: const TextStyle(
                          fontSize: 12.5, color: WaPalette.textSecondary),
                    ),
                  )
                : GridView.builder(
                    gridDelegate:
                        const SliverGridDelegateWithFixedCrossAxisCount(
                      crossAxisCount: 8,
                      mainAxisSpacing: 2,
                      crossAxisSpacing: 2,
                    ),
                    itemCount: emojis.length,
                    itemBuilder: (_, idx) {
                      final emoji = emojis[idx];
                      return InkWell(
                        onTap: () => widget.onSelect(emoji),
                        borderRadius: BorderRadius.circular(6),
                        child: Center(
                          child: Text(emoji, style: const TextStyle(fontSize: 21)),
                        ),
                      );
                    },
                  ),
          ),
        ],
      ),
    );
  }
}

/// Sticker picker dialog/panel showing cached WebP stickers + file upload.
class StickerPickerPanel extends StatelessWidget {
  const StickerPickerPanel({
    super.key,
    required this.stickers,
    required this.palette,
    required this.tr,
    required this.onSendSticker,
    required this.onClose,
  });

  final List<String> stickers;
  final WaPalette palette;
  final Tr tr;
  final ValueChanged<String> onSendSticker;
  final VoidCallback onClose;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: 340,
      height: 320,
      decoration: BoxDecoration(
        color: palette.surface,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: palette.divider),
        boxShadow: const [
          BoxShadow(color: Colors.black54, blurRadius: 18, offset: Offset(0, 6)),
        ],
      ),
      padding: const EdgeInsets.all(12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const Icon(Icons.sticky_note_2_outlined,
                  size: 18, color: WaPalette.accent),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  tr.t('Samolepky', 'Stickers'),
                  style: const TextStyle(
                    fontSize: 14,
                    fontWeight: FontWeight.w600,
                    color: WaPalette.textPrimary,
                  ),
                ),
              ),
              IconButton(
                onPressed: onClose,
                icon: const Icon(Icons.close, size: 17),
                visualDensity: VisualDensity.compact,
              ),
            ],
          ),
          Row(
            children: [
              TextButton.icon(
                onPressed: () async {
                  const typeGroup = XTypeGroup(
                    label: 'WebP Stickers',
                    extensions: ['webp'],
                  );
                  final file =
                      await openFile(acceptedTypeGroups: const [typeGroup]);
                  if (file != null) {
                    onSendSticker(file.path);
                  }
                },
                icon: const Icon(Icons.add, size: 16),
                label: Text(tr.t('Přidat ze souboru…', 'Add from file…')),
              ),
              const Spacer(),
              const Text(
                'WebP, max 1 MB',
                style: TextStyle(fontSize: 11, color: WaPalette.textSecondary),
              ),
            ],
          ),
          Divider(color: palette.divider, height: 10),
          Expanded(
            child: stickers.isEmpty
                ? Center(
                    child: Padding(
                      padding: const EdgeInsets.all(16),
                      child: Text(
                        tr.t(
                          'Zatím žádné samolepky. Přijaté a odeslané WebP soubory se tu objeví.',
                          'No stickers yet. Received and sent WebP stickers appear here.',
                        ),
                        textAlign: TextAlign.center,
                        style: const TextStyle(
                          fontSize: 12.5,
                          color: WaPalette.textSecondary,
                        ),
                      ),
                    ),
                  )
                : GridView.builder(
                    gridDelegate:
                        const SliverGridDelegateWithFixedCrossAxisCount(
                      crossAxisCount: 4,
                      mainAxisSpacing: 8,
                      crossAxisSpacing: 8,
                    ),
                    itemCount: stickers.length,
                    itemBuilder: (_, idx) {
                      final path = stickers[idx];
                      return InkWell(
                        onTap: () => onSendSticker(path),
                        borderRadius: BorderRadius.circular(8),
                        child: Container(
                          padding: const EdgeInsets.all(4),
                          decoration: BoxDecoration(
                            color: palette.bg,
                            borderRadius: BorderRadius.circular(8),
                          ),
                          child: Image.file(
                            File(path),
                            fit: BoxFit.contain,
                            errorBuilder: (_, _, _) => const Icon(
                              Icons.sticky_note_2_outlined,
                              color: WaPalette.textSecondary,
                            ),
                          ),
                        ),
                      );
                    },
                  ),
          ),
        ],
      ),
    );
  }
}
