import 'dart:io';

import 'package:material_ui/material_ui.dart';

import '../theme.dart';

/// Circular WhatsApp avatar: displays cached local JPEG if present, otherwise
/// WhatsApp-style neutral/tinted circle with initials or group icon.
class WaAvatar extends StatelessWidget {
  const WaAvatar({
    super.key,
    required this.name,
    this.avatarPath,
    this.radius = 22,
    this.isGroup = false,
    this.online = false,
    this.backgroundColor,
  });

  final String name;
  final String? avatarPath;
  final double radius;
  final bool isGroup;
  final bool online;
  final Color? backgroundColor;

  String _initials() {
    final parts = name.trim().split(RegExp(r'\s+')).where((p) => p.isNotEmpty);
    final letters = parts.take(2).map((p) => p.characters.first.toUpperCase()).join();
    if (letters.isNotEmpty) return letters;
    return isGroup ? 'G' : '?';
  }

  @override
  Widget build(BuildContext context) {
    final hasPath = avatarPath != null && avatarPath!.isNotEmpty;

    Widget circle;
    if (hasPath) {
      circle = ClipOval(
        child: Image.file(
          File(avatarPath!),
          width: radius * 2,
          height: radius * 2,
          cacheWidth: (radius * 4).round(),
          fit: BoxFit.cover,
          errorBuilder: (_, _, _) => _fallback(),
        ),
      );
    } else {
      circle = _fallback();
    }

    if (!online) return circle;
    return Stack(
      clipBehavior: Clip.none,
      children: [
        circle,
        Positioned(
          right: 0,
          bottom: 0,
          child: Container(
            width: radius * 0.52,
            height: radius * 0.52,
            decoration: BoxDecoration(
              color: WaPalette.accentBright,
              shape: BoxShape.circle,
              border: Border.all(color: const Color(0xFF111B21), width: 2),
            ),
          ),
        ),
      ],
    );
  }

  Widget _fallback() {
    final bg = backgroundColor ?? const Color(0xFF6A7175);
    final initials = _initials();
    return Container(
      width: radius * 2,
      height: radius * 2,
      decoration: BoxDecoration(
        color: bg,
        shape: BoxShape.circle,
      ),
      alignment: Alignment.center,
      child: initials == '?' && isGroup
          ? Icon(Icons.group, color: Colors.white, size: radius * 1.05)
          : Text(
              initials,
              style: TextStyle(
                color: Colors.white,
                fontSize: radius * 0.72,
                fontWeight: FontWeight.w500,
              ),
            ),
    );
  }
}

/// WhatsApp message delivery ticks (`sending`, `sent`, `delivered`, `read`, `failed`).
class StatusTicks extends StatelessWidget {
  const StatusTicks({
    super.key,
    required this.status,
    this.size = 15,
  });

  final String status;
  final double size;

  @override
  Widget build(BuildContext context) {
    return switch (status) {
      'sending' => Icon(
          Icons.schedule,
          size: size - 2,
          color: WaPalette.textSecondary,
        ),
      'sent' => Icon(
          Icons.done,
          size: size,
          color: WaPalette.textSecondary,
        ),
      'delivered' => Icon(
          Icons.done_all,
          size: size,
          color: WaPalette.textSecondary,
        ),
      'read' => Icon(
          Icons.done_all,
          size: size,
          color: WaPalette.tickRead,
        ),
      'failed' => Icon(
          Icons.error_outline,
          size: size - 1,
          color: WaPalette.danger,
        ),
      _ => Icon(
          Icons.done,
          size: size,
          color: WaPalette.textSecondary,
        ),
    };
  }
}

/// Three gentle bouncing dots for the "píše…" typing indicator.
class BouncingDots extends StatefulWidget {
  const BouncingDots({
    super.key,
    this.color = WaPalette.accentBright,
    this.size = 4,
  });

  final Color color;
  final double size;

  @override
  State<BouncingDots> createState() => _BouncingDotsState();
}

class _BouncingDotsState extends State<BouncingDots>
    with SingleTickerProviderStateMixin {
  late final AnimationController _ctrl;

  @override
  void initState() {
    super.initState();
    _ctrl = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1100),
    )..repeat();
  }

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: _ctrl,
      builder: (_, _) {
        return Row(
          mainAxisSize: MainAxisSize.min,
          children: List.generate(3, (i) {
            final phase = ((_ctrl.value - i * 0.16) % 1.0 + 1.0) % 1.0;
            final lift = phase < 0.4 ? (1 - (phase / 0.4 - 0.5).abs() * 2) : 0.0;
            return Padding(
              padding: const EdgeInsets.symmetric(horizontal: 1.5),
              child: Transform.translate(
                offset: Offset(0, -lift * 3.0),
                child: Container(
                  width: widget.size,
                  height: widget.size,
                  decoration: BoxDecoration(
                    color: widget.color,
                    shape: BoxShape.circle,
                  ),
                ),
              ),
            );
          }),
        );
      },
    );
  }
}
