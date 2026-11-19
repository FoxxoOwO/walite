import 'dart:io';
import 'dart:math' as math;

import 'package:material_ui/material_ui.dart';

/// Parses `#RRGGBB` or `RRGGBB` into an opaque [Color], returning null on bad input.
Color? parseHexColor(String? hex) {
  if (hex == null) return null;
  var clean = hex.trim().replaceFirst('#', '').replaceFirst('0x', '');
  if (clean.length == 6) clean = 'FF$clean';
  if (clean.length != 8) return null;
  final val = int.tryParse(clean, radix: 16);
  return val == null ? null : Color(val);
}

/// Subtle WhatsApp-style dark doodle pattern (or custom image/color) painted
/// behind the chat timeline.
class WaWallpaper extends StatelessWidget {
  const WaWallpaper({
    super.key,
    required this.backgroundColor,
    this.customColorHex,
    this.wallpaperPath,
    this.showDoodles = true,
    required this.child,
  });

  final Color backgroundColor;
  final String? customColorHex;
  final String? wallpaperPath;
  final bool showDoodles;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final bg = parseHexColor(customColorHex) ?? backgroundColor;
    final hasImage = wallpaperPath != null && wallpaperPath!.isNotEmpty;

    return Container(
      color: bg,
      child: Stack(
        fit: StackFit.expand,
        children: [
          if (hasImage || showDoodles)
            Positioned.fill(
              child: RepaintBoundary(
                child: Stack(
                  fit: StackFit.expand,
                  children: [
                    if (hasImage)
                      Image.file(
                        File(wallpaperPath!),
                        fit: BoxFit.cover,
                        color: Colors.black.withValues(alpha: 0.42),
                        colorBlendMode: BlendMode.darken,
                        errorBuilder: (_, _, _) => const SizedBox.shrink(),
                      ),
                    if (showDoodles)
                      const CustomPaint(painter: _WallpaperPainter()),
                  ],
                ),
              ),
            ),
          child,
        ],
      ),
    );
  }
}

class _WallpaperPainter extends CustomPainter {
  const _WallpaperPainter();

  @override
  void paint(Canvas canvas, Size size) {
    final stroke = Paint()
      ..color = Colors.white.withValues(alpha: 0.028)
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.25;

    const tile = 92.0;
    final cols = (size.width / tile).ceil() + 1;
    final rows = (size.height / tile).ceil() + 1;

    for (var r = 0; r < rows; r++) {
      for (var c = 0; c < cols; c++) {
        final ox = c * tile + (r.isOdd ? tile * 0.5 : 0);
        final oy = r * tile;
        final kind = (r * 7 + c * 13) % 5;
        final center = Offset(ox + 26, oy + 26);

        switch (kind) {
          case 0:
            // Tiny chat bubble motif
            final rect = RRect.fromRectAndRadius(
              Rect.fromCenter(center: center, width: 18, height: 13),
              const Radius.circular(4),
            );
            canvas.drawRRect(rect, stroke);
          case 1:
            // Subtle crescent / smile arc
            canvas.drawArc(
              Rect.fromCenter(center: center, width: 16, height: 16),
              0.2,
              math.pi * 1.1,
              false,
              stroke,
            );
          case 2:
            // Small diamond / star motif
            final p = Path()
              ..moveTo(center.dx, center.dy - 8)
              ..lineTo(center.dx + 7, center.dy)
              ..lineTo(center.dx, center.dy + 8)
              ..lineTo(center.dx - 7, center.dy)
              ..close();
            canvas.drawPath(p, stroke);
          case 3:
            // Small ring + dot
            canvas.drawCircle(center, 7, stroke);
          default:
            // Tiny phone / wave arc
            canvas.drawArc(
              Rect.fromCenter(center: center, width: 18, height: 18),
              -math.pi * 0.75,
              math.pi * 0.5,
              false,
              stroke,
            );
        }
      }
    }
  }

  @override
  bool shouldRepaint(covariant _WallpaperPainter oldDelegate) => false;
}
