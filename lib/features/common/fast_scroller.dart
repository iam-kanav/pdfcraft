import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
import 'package:material_symbols_icons/symbols.dart';

/// Acrobat-style fast-scroll handle: a tab on the right edge that appears
/// while the content scrolls, fades out when idle, and can be dragged to move
/// through a long document quickly. While dragging, a bubble shows [label].
///
/// Place it over the scrolling content (e.g. in a [Stack] with
/// [Positioned.fill]); touches outside the tab pass through.
class FastScroller extends StatefulWidget {
  const FastScroller({
    super.key,
    required this.listenable,
    required this.position,
    required this.onDrag,
    this.positionChanged,
    this.label,
    this.enabled = true,
    this.padding = const EdgeInsets.symmetric(vertical: 8),
  });

  /// Notifies when the content scrolls; the handle shows and follows it.
  final Listenable listenable;

  /// Current position as a fraction from 0 (top) to 1 (end), or null when
  /// the content doesn't scroll.
  final double? Function() position;

  /// Notifies when [position] changes without the content scrolling (e.g. a
  /// value measured after layout). Moves the handle without showing it.
  final Listenable? positionChanged;

  /// Called while dragging with the target fraction, at most once a frame.
  final ValueChanged<double> onDrag;

  /// Text of the bubble shown while dragging to a fraction, e.g. "12 / 340".
  final String? Function(double fraction)? label;

  final bool enabled;

  /// Insets of the track the handle moves along.
  final EdgeInsets padding;

  static const handleKey = ValueKey('fast-scroller-handle');
  static const Size handleSize = Size(34, 52);

  /// Touch target around the visible tab.
  static const double _hitWidth = 52;

  @override
  State<FastScroller> createState() => _FastScrollerState();
}

class _FastScrollerState extends State<FastScroller> {
  bool _visible = false;
  Timer? _hide;

  /// Fraction under the finger while dragging, so the handle tracks the
  /// finger even when the content's extent is only estimated.
  double? _dragFraction;

  /// Distance from the handle's top to the finger when the drag started.
  double _grab = 0;

  /// Drag target not yet passed to [FastScroller.onDrag]. Touch events can
  /// arrive several times a frame; each jump costs a layout, so only the
  /// latest one per frame is applied.
  double? _pending;

  @override
  void initState() {
    super.initState();
    widget.listenable.addListener(_onScroll);
    widget.positionChanged?.addListener(_onPositionChanged);
  }

  @override
  void didUpdateWidget(covariant FastScroller old) {
    super.didUpdateWidget(old);
    if (!identical(old.listenable, widget.listenable)) {
      old.listenable.removeListener(_onScroll);
      widget.listenable.addListener(_onScroll);
    }
    if (!identical(old.positionChanged, widget.positionChanged)) {
      old.positionChanged?.removeListener(_onPositionChanged);
      widget.positionChanged?.addListener(_onPositionChanged);
    }
  }

  @override
  void dispose() {
    widget.listenable.removeListener(_onScroll);
    widget.positionChanged?.removeListener(_onPositionChanged);
    _hide?.cancel();
    super.dispose();
  }

  void _onScroll() {
    if (!mounted) return;
    // Scroll positions can change during layout, when setState isn't allowed.
    if (SchedulerBinding.instance.schedulerPhase == SchedulerPhase.persistentCallbacks) {
      SchedulerBinding.instance.addPostFrameCallback((_) => _onScroll());
      return;
    }
    setState(() => _visible = true);
    if (_dragFraction == null) _scheduleHide();
  }

  void _onPositionChanged() {
    if (mounted && SchedulerBinding.instance.schedulerPhase != SchedulerPhase.persistentCallbacks) setState(() {});
  }

  void _dragTo(double f) {
    setState(() => _dragFraction = f);
    if (_pending != null) {
      _pending = f;
      return;
    }
    _pending = f;
    SchedulerBinding.instance.scheduleFrameCallback((_) => _flush());
  }

  void _flush() {
    final f = _pending;
    _pending = null;
    if (f != null && mounted) widget.onDrag(f);
  }

  void _scheduleHide() {
    _hide?.cancel();
    _hide = Timer(const Duration(milliseconds: 1500), () {
      if (mounted && _dragFraction == null) setState(() => _visible = false);
    });
  }

  double _fractionAt(double y, double track) =>
      track <= 0 ? 0 : ((y - widget.padding.top - _grab) / track).clamp(0.0, 1.0);

  @override
  Widget build(BuildContext context) {
    final current = widget.position();
    if (!widget.enabled || current == null) return const SizedBox.shrink();
    final scheme = Theme.of(context).colorScheme;
    final size = FastScroller.handleSize;
    return LayoutBuilder(
      builder: (context, constraints) {
        final track = constraints.maxHeight - widget.padding.vertical - size.height;
        final fraction = _dragFraction ?? current.clamp(0.0, 1.0);
        final top = widget.padding.top + fraction * (track > 0 ? track : 0);
        final dragging = _dragFraction != null;
        final label = dragging ? widget.label?.call(fraction) : null;
        return Stack(
          children: [
            if (label != null)
              Positioned(
                key: const ValueKey('bubble'),
                right: size.width + 12,
                top: top + size.height / 2 - 20,
                height: 40,
                child: IgnorePointer(
                  child: Container(
                    padding: const EdgeInsets.symmetric(horizontal: 14),
                    alignment: Alignment.center,
                    decoration: BoxDecoration(
                      color: scheme.inverseSurface,
                      borderRadius: BorderRadius.circular(20),
                      boxShadow: const [BoxShadow(color: Color(0x33000000), blurRadius: 6, offset: Offset(0, 2))],
                    ),
                    child: Text(
                      label,
                      style: TextStyle(color: scheme.onInverseSurface, fontSize: 14, fontWeight: FontWeight.w600),
                    ),
                  ),
                ),
              ),
            // Keyed so the bubble appearing doesn't rebuild the handle and
            // cancel the drag in progress.
            Positioned(
              key: const ValueKey('handle'),
              right: 0,
              top: top,
              width: FastScroller._hitWidth,
              height: size.height,
              child: IgnorePointer(
                ignoring: !_visible,
                child: AnimatedOpacity(
                  opacity: _visible ? 1 : 0,
                  duration: const Duration(milliseconds: 200),
                  child: AnimatedSlide(
                    offset: _visible ? Offset.zero : const Offset(0.5, 0),
                    duration: const Duration(milliseconds: 200),
                    curve: Curves.easeOut,
                    child: GestureDetector(
                      key: FastScroller.handleKey,
                      behavior: HitTestBehavior.opaque,
                      onVerticalDragStart: (d) {
                        _hide?.cancel();
                        _grab = d.localPosition.dy.clamp(0.0, size.height);
                        setState(() => _dragFraction = fraction);
                      },
                      onVerticalDragUpdate: (d) {
                        final box = context.findRenderObject()! as RenderBox;
                        _dragTo(_fractionAt(box.globalToLocal(d.globalPosition).dy, track));
                      },
                      onVerticalDragEnd: (_) => _endDrag(),
                      onVerticalDragCancel: _endDrag,
                      child: Align(
                        alignment: Alignment.centerRight,
                        child: Container(
                          width: size.width,
                          height: size.height,
                          decoration: BoxDecoration(
                            color: dragging ? scheme.primary : scheme.inverseSurface.withValues(alpha: 0.85),
                            borderRadius: const BorderRadius.horizontal(left: Radius.circular(18)),
                            boxShadow: const [BoxShadow(color: Color(0x33000000), blurRadius: 4)],
                          ),
                          child: Icon(
                            Symbols.unfold_more,
                            size: 22,
                            color: dragging ? scheme.onPrimary : scheme.onInverseSurface,
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ],
        );
      },
    );
  }

  void _endDrag() {
    if (!mounted || _dragFraction == null) return;
    _flush();
    setState(() => _dragFraction = null);
    _scheduleHide();
  }
}
