import 'package:material_ui/material_ui.dart';

/// Original WhatsApp Desktop / Web dark color tokens, with support for the
/// three dark theme presets offered by Warust.
class WaPalette {
  const WaPalette({
    required this.bg,
    required this.chatCanvas,
    required this.surface,
    required this.surfaceElevated,
    required this.hover,
    required this.divider,
    required this.outgoingBubble,
    required this.incomingBubble,
    required this.quoteBg,
    required this.pillBg,
  });

  final Color bg;
  final Color chatCanvas;
  final Color surface;
  final Color surfaceElevated;
  final Color hover;
  final Color divider;
  final Color outgoingBubble;
  final Color incomingBubble;
  final Color quoteBg;
  final Color pillBg;

  static const Color accent = Color(0xFF00A884);
  static const Color accentDark = Color(0xFF008069);
  static const Color accentBright = Color(0xFF25D366);
  static const Color tickRead = Color(0xFF53BDEB);
  static const Color linkBlue = Color(0xFF53BDEB);
  static const Color textPrimary = Color(0xFFE9EDEF);
  static const Color textSecondary = Color(0xFF8696A0);
  static const Color danger = Color(0xFFF15C5C);

  static const WaPalette whatsappDark = WaPalette(
    bg: Color(0xFF111B21),
    chatCanvas: Color(0xFF0B141A),
    surface: Color(0xFF202C33),
    surfaceElevated: Color(0xFF2A3942),
    hover: Color(0xFF1F2C34),
    divider: Color(0xFF222E35),
    outgoingBubble: Color(0xFF005C4B),
    incomingBubble: Color(0xFF202C33),
    quoteBg: Color(0x33000000),
    pillBg: Color(0xFF182229),
  );

  static const WaPalette oledBlack = WaPalette(
    bg: Color(0xFF000000),
    chatCanvas: Color(0xFF000000),
    surface: Color(0xFF111111),
    surfaceElevated: Color(0xFF1E1E1E),
    hover: Color(0xFF161616),
    divider: Color(0xFF1E1E1E),
    outgoingBubble: Color(0xFF004B3E),
    incomingBubble: Color(0xFF181818),
    quoteBg: Color(0x44000000),
    pillBg: Color(0xFF121212),
  );

  static const WaPalette midnightBlue = WaPalette(
    bg: Color(0xFF0A192F),
    chatCanvas: Color(0xFF071222),
    surface: Color(0xFF112240),
    surfaceElevated: Color(0xFF1D3557),
    hover: Color(0xFF15294A),
    divider: Color(0xFF1D3557),
    outgoingBubble: Color(0xFF005C4B),
    incomingBubble: Color(0xFF112240),
    quoteBg: Color(0x33000000),
    pillBg: Color(0xFF0F203C),
  );

  static WaPalette forPreset(int preset) => switch (preset) {
        1 => oledBlack,
        2 => midnightBlue,
        _ => whatsappDark,
      };
}

/// Consistent WhatsApp-like color for group sender names, keyed by JID/name.
Color senderColor(String key) {
  const palette = [
    Color(0xFF53BDEB),
    Color(0xFF25D366),
    Color(0xFFE5989B),
    Color(0xFFFFB703),
    Color(0xFFA8DADC),
    Color(0xFFC77DFF),
    Color(0xFFFF8FAB),
    Color(0xFF06D6A0),
  ];
  var hash = 0;
  for (final code in key.codeUnits) {
    hash = (hash * 31 + code) & 0x7fffffff;
  }
  return palette[hash % palette.length];
}

String formatBytes(int bytes) {
  if (bytes < 1024) return '$bytes B';
  if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(1)} KB';
  if (bytes < 1024 * 1024 * 1024) {
    return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';
  }
  return '${(bytes / (1024 * 1024 * 1024)).toStringAsFixed(2)} GB';
}

String formatJidPhone(String jid) {
  final user = jid.split('@').first.split(':').first;
  if (user.isEmpty) return jid;
  if (RegExp(r'^\d{7,}$').hasMatch(user)) {
    return '+$user';
  }
  return user;
}
