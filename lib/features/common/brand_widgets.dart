import 'package:flutter/material.dart';

import '../../theme/app_theme.dart';

/// The PDFCraft mark: a red document glyph with a folded corner.
class AppLogo extends StatelessWidget {
  const AppLogo({super.key, this.size = 28});

  final double size;

  @override
  Widget build(BuildContext context) => SizedBox(
    width: size,
    height: size,
    child: CustomPaint(painter: _LogoPainter()),
  );
}

class _LogoPainter extends CustomPainter {
  @override
  void paint(Canvas canvas, Size size) {
    final w = size.width, h = size.height;
    final fold = w * 0.3;
    final body = Path()
      ..moveTo(w * 0.12, 0)
      ..lineTo(w * 0.88 - fold * 0.4, 0)
      ..lineTo(w * 0.88, fold)
      ..lineTo(w * 0.88, h)
      ..lineTo(w * 0.12, h)
      ..close();
    canvas.drawPath(body, Paint()..color = Brand.red);
    final corner = Path()
      ..moveTo(w * 0.88 - fold * 0.4, 0)
      ..lineTo(w * 0.88 - fold * 0.4, fold)
      ..lineTo(w * 0.88, fold)
      ..close();
    canvas.drawPath(corner, Paint()..color = const Color(0xFFFF8A80));
    final tp = TextPainter(
      text: TextSpan(
        text: 'P',
        style: TextStyle(
          fontFamily: Brand.fontFamily,
          fontWeight: FontWeight.w700,
          fontSize: h * 0.62,
          color: Colors.white,
        ),
      ),
      textDirection: TextDirection.ltr,
    )..layout();
    tp.paint(canvas, Offset((w - tp.width) / 2 - w * 0.02, h * 0.58 - tp.height / 2));
  }

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) => false;
}

/// Acrobat-style pastel tool tile (square, rounded, tinted background, colored line icon).
class ToolIconTile extends StatelessWidget {
  const ToolIconTile({super.key, required this.icon, required this.color, this.size = 56});

  final IconData icon;
  final Color color;
  final double size;

  @override
  Widget build(BuildContext context) {
    final dark = Theme.of(context).brightness == Brightness.dark;
    return Container(
      width: size,
      height: size,
      decoration: BoxDecoration(
        color: dark ? color.withValues(alpha: 0.18) : Brand.tileBackground(color),
        borderRadius: BorderRadius.circular(size * 0.18),
      ),
      child: Icon(icon, color: color, size: size * 0.5, weight: 300),
    );
  }
}

/// Section header text used throughout lists.
class SectionHeader extends StatelessWidget {
  const SectionHeader(this.text, {super.key, this.trailing, this.padding = const EdgeInsets.fromLTRB(16, 20, 8, 8)});

  final String text;
  final Widget? trailing;
  final EdgeInsets padding;

  @override
  Widget build(BuildContext context) => Padding(
    padding: padding,
    child: Row(
      children: [
        Expanded(child: Text(text, style: Theme.of(context).textTheme.titleSmall)),
        ?trailing,
      ],
    ),
  );
}
