import 'package:flutter/material.dart';

const kAnnotationColors = <Color>[
  Color(0xFFFFD400),
  Color(0xFF7CFC00),
  Color(0xFF00E5FF),
  Color(0xFFFF6FD8),
  Color(0xFFE11D48),
  Color(0xFF2563EB),
  Color(0xFF16A34A),
  Color(0xFF000000),
];

class ColorDot extends StatelessWidget {
  const ColorDot({super.key, required this.color, required this.selected, required this.onTap, this.size = 28});

  final Color color;
  final bool selected;
  final VoidCallback onTap;
  final double size;

  @override
  Widget build(BuildContext context) => GestureDetector(
    onTap: onTap,
    child: Container(
      width: size,
      height: size,
      margin: const EdgeInsets.all(4),
      decoration: BoxDecoration(
        color: color,
        shape: BoxShape.circle,
        border: Border.all(color: selected ? Theme.of(context).colorScheme.onSurface : Colors.black12, width: selected ? 3 : 1),
      ),
    ),
  );
}

/// Bottom sheet to choose a color, stroke width and opacity.
Future<void> showStyleSheet(
  BuildContext context, {
  required Color color,
  required ValueChanged<Color> onColor,
  double? width,
  ValueChanged<double>? onWidth,
  double? opacity,
  ValueChanged<double>? onOpacity,
  double? fontSize,
  ValueChanged<double>? onFontSize,
}) => showModalBottomSheet<void>(
  context: context,
  builder: (ctx) {
    var c = color;
    var w = width;
    var o = opacity;
    var f = fontSize;
    return StatefulBuilder(
      builder: (ctx, setState) => SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text('Color'),
              Wrap(
                children: [
                  for (final k in kAnnotationColors)
                    ColorDot(
                      color: k,
                      selected: k.toARGB32() == c.toARGB32(),
                      onTap: () {
                        setState(() => c = k);
                        onColor(k);
                      },
                    ),
                ],
              ),
              if (w != null) ...[
                const SizedBox(height: 8),
                Text('Thickness: ${w!.toStringAsFixed(1)} pt'),
                Slider(
                  value: w!,
                  min: 0.5,
                  max: 12,
                  onChanged: (v) {
                    setState(() => w = v);
                    onWidth?.call(v);
                  },
                ),
              ],
              if (o != null) ...[
                Text('Opacity: ${(o! * 100).round()}%'),
                Slider(
                  value: o!,
                  min: 0.1,
                  max: 1,
                  onChanged: (v) {
                    setState(() => o = v);
                    onOpacity?.call(v);
                  },
                ),
              ],
              if (f != null) ...[
                Text('Font size: ${f!.round()} pt'),
                Slider(
                  value: f!,
                  min: 6,
                  max: 48,
                  divisions: 42,
                  onChanged: (v) {
                    setState(() => f = v);
                    onFontSize?.call(v);
                  },
                ),
              ],
            ],
          ),
        ),
      ),
    );
  },
);
