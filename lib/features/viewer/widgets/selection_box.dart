import 'package:flutter/material.dart';

/// A movable/resizable rectangle overlay. Works in page display units scaled by [scale].
class SelectionBox extends StatefulWidget {
  const SelectionBox({
    super.key,
    required this.rect,
    required this.scale,
    required this.onChanged,
    this.color = const Color(0xFF2563EB),
    this.keepAspect = false,
    this.resizable = true,
    this.onTap,
  });

  final Rect rect;
  final double scale;
  final ValueChanged<Rect> onChanged;
  final Color color;
  final bool keepAspect;
  final bool resizable;
  final VoidCallback? onTap;

  @override
  State<SelectionBox> createState() => _SelectionBoxState();
}

class _SelectionBoxState extends State<SelectionBox> {
  late Rect _rect = widget.rect;
  bool _dragging = false;

  @override
  void didUpdateWidget(SelectionBox old) {
    super.didUpdateWidget(old);
    if (!_dragging && old.rect != widget.rect) _rect = widget.rect;
  }

  Rect get _scaled => Rect.fromLTRB(_rect.left * widget.scale, _rect.top * widget.scale, _rect.right * widget.scale, _rect.bottom * widget.scale);

  void _move(Offset delta) {
    setState(() => _rect = _rect.shift(delta / widget.scale));
  }

  void _resize(Alignment corner, Offset delta) {
    final d = delta / widget.scale;
    var l = _rect.left, t = _rect.top, r = _rect.right, b = _rect.bottom;
    if (corner.x < 0) l += d.dx; else r += d.dx;
    if (corner.y < 0) t += d.dy; else b += d.dy;
    const minSize = 8.0;
    if (r - l < minSize) {
      if (corner.x < 0) l = r - minSize; else r = l + minSize;
    }
    if (b - t < minSize) {
      if (corner.y < 0) t = b - minSize; else b = t + minSize;
    }
    var next = Rect.fromLTRB(l, t, r, b);
    if (widget.keepAspect) {
      final aspect = _rect.width / _rect.height;
      final w = next.width;
      final h = w / aspect;
      next = corner.y < 0 ? Rect.fromLTRB(next.left, next.bottom - h, next.right, next.bottom) : Rect.fromLTWH(next.left, next.top, w, h);
    }
    setState(() => _rect = next);
  }

  void _end() {
    _dragging = false;
    widget.onChanged(_rect);
  }

  @override
  Widget build(BuildContext context) {
    final s = _scaled;
    const handle = 22.0;
    return Positioned(
      left: s.left - handle / 2,
      top: s.top - handle / 2,
      width: s.width + handle,
      height: s.height + handle,
      child: Stack(
        clipBehavior: Clip.none,
        children: [
          Positioned.fill(
            left: handle / 2,
            top: handle / 2,
            right: handle / 2,
            bottom: handle / 2,
            child: GestureDetector(
              behavior: HitTestBehavior.opaque,
              onTap: widget.onTap,
              onPanStart: (_) => _dragging = true,
              onPanUpdate: (d) => _move(d.delta),
              onPanEnd: (_) => _end(),
              child: Container(
                decoration: BoxDecoration(
                  border: Border.all(color: widget.color, width: 1.5),
                  color: widget.color.withValues(alpha: 0.06),
                ),
              ),
            ),
          ),
          if (widget.resizable)
            for (final a in const [Alignment.topLeft, Alignment.topRight, Alignment.bottomLeft, Alignment.bottomRight])
              Align(
                alignment: a,
                child: GestureDetector(
                  behavior: HitTestBehavior.opaque,
                  onPanStart: (_) => _dragging = true,
                  onPanUpdate: (d) => _resize(a, d.delta),
                  onPanEnd: (_) => _end(),
                  child: SizedBox(
                    width: handle,
                    height: handle,
                    child: Center(
                      child: Container(
                        width: 12,
                        height: 12,
                        decoration: BoxDecoration(color: Colors.white, border: Border.all(color: widget.color, width: 2), shape: BoxShape.circle),
                      ),
                    ),
                  ),
                ),
              ),
        ],
      ),
    );
  }
}

/// Converts a rect in page display units to overlay coordinates.
Rect scaleRect(Rect r, double s) => Rect.fromLTRB(r.left * s, r.top * s, r.right * s, r.bottom * s);
