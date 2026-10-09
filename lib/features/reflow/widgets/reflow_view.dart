import 'dart:typed_data';

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/scheduler.dart';
import 'package:pdfcraft/core/models/doc_structure.dart';
import 'package:pdfcraft/features/reflow/reading_settings.dart';
import 'package:material_symbols_icons/symbols.dart';

/// Imperative control over a [ReflowView]: jumping to blocks and
/// collapsing/expanding sections.
class ReflowController extends ChangeNotifier {
  _ReflowViewState? _state;

  bool get isAttached => _state != null;

  /// Scrolls so that block [index] (index into `doc.blocks`) is at the top of
  /// the viewport, expanding any collapsed section that hides it.
  Future<void> jumpToBlock(int index) async {
    final s = _state;
    if (s == null) return;
    await s._jumpToBlock(index);
  }

  /// Whether the section of the heading at block [index] is collapsed.
  bool isCollapsed(int index) => _state?._collapsed.contains(index) ?? false;

  /// Collapses or expands the section under the heading at block [index].
  void toggleSection(int index) => _state?._toggle(index);

  void expandAll() => _state?._setCollapsed(const {});

  /// Collapses every top-level section (headings with the smallest level).
  void collapseAll() {
    final s = _state;
    if (s == null) return;
    final headings = s.widget.doc.headings;
    if (headings.isEmpty) return;
    final top = headings.map((h) => h.level).reduce((a, b) => a < b ? a : b);
    final blocks = s.widget.doc.blocks;
    s._setCollapsed({
      for (var i = 0; i < blocks.length; i++)
        if (blocks[i] case HeadingBlock h when h.level == top) i,
    });
  }

  /// Block index of the first block currently laid out in the viewport.
  int? get firstVisibleBlock => _state?._firstVisibleBlock();

  void _attach(_ReflowViewState s) => _state = s;

  void _detach(_ReflowViewState s) {
    if (identical(_state, s)) _state = null;
  }

  void _changed() => notifyListeners();
}

/// Liquid-Mode-style reflowed rendering of a [DocStructure].
class ReflowView extends StatefulWidget {
  const ReflowView({
    super.key,
    required this.doc,
    required this.settings,
    this.controller,
    this.onOpenPage,
    this.highlightQuery,
    this.reflowController,
    this.onLinkTap,
  });

  final DocStructure doc;
  final ReadingSettings settings;
  final ScrollController? controller;

  /// Called with a 1-based page number when the user taps a "p. N" marker.
  final void Function(int pageNumber)? onOpenPage;

  /// Case-insensitive text to highlight with the theme accent color.
  final String? highlightQuery;

  final ReflowController? reflowController;

  /// Called when a span carrying a link is tapped.
  final void Function(String link)? onLinkTap;

  /// Key of the background container (its color follows the reading theme).
  static const Key backgroundKey = ValueKey('reflow-background');

  @override
  State<ReflowView> createState() => _ReflowViewState();
}

class _ReflowViewState extends State<ReflowView> {
  ScrollController? _ownController;
  ScrollController get _scroll => widget.controller ?? (_ownController ??= ScrollController());

  /// Heading block indices whose sections are collapsed.
  Set<int> _collapsed = {};

  /// For heading block i: exclusive end of its section.
  late List<int> _sectionEnd;

  /// Visible block indices in display order.
  late List<int> _visible;

  /// Blocks that start a new source page.
  late Set<int> _pageStarts;

  /// Last measured extent of each block's list item.
  final Map<int, double> _heights = {};

  /// Contexts of currently built items, by block index.
  final Map<int, BuildContext> _built = {};

  static const double _listPadTop = 16;
  static const double _maxContentWidth = 760;

  @override
  void initState() {
    super.initState();
    _computeStructure();
    widget.reflowController?._attach(this);
    widget.settings.addListener(_onSettings);
  }

  @override
  void didUpdateWidget(covariant ReflowView old) {
    super.didUpdateWidget(old);
    if (!identical(old.doc, widget.doc)) {
      _collapsed = {};
      _heights.clear();
      _computeStructure();
    }
    if (!identical(old.reflowController, widget.reflowController)) {
      old.reflowController?._detach(this);
      widget.reflowController?._attach(this);
    }
    if (!identical(old.settings, widget.settings)) {
      old.settings.removeListener(_onSettings);
      widget.settings.addListener(_onSettings);
      _heights.clear();
    }
  }

  @override
  void dispose() {
    widget.settings.removeListener(_onSettings);
    widget.reflowController?._detach(this);
    _ownController?.dispose();
    super.dispose();
  }

  void _onSettings() {
    _heights.clear();
    setState(() {});
  }

  void _computeStructure() {
    final blocks = widget.doc.blocks;
    _sectionEnd = List<int>.filled(blocks.length, blocks.length);
    // Monotonic stack of open headings.
    final stack = <int>[];
    for (var i = 0; i < blocks.length; i++) {
      final b = blocks[i];
      if (b is HeadingBlock) {
        while (stack.isNotEmpty && (blocks[stack.last] as HeadingBlock).level >= b.level) {
          _sectionEnd[stack.removeLast()] = i;
        }
        stack.add(i);
      }
    }
    _pageStarts = {};
    int? prevPage;
    for (var i = 0; i < blocks.length; i++) {
      final p = blocks[i].pageNumber;
      if (p != null && p != prevPage) _pageStarts.add(i);
      if (p != null) prevPage = p;
    }
    _computeVisible();
  }

  void _computeVisible() {
    final blocks = widget.doc.blocks;
    final v = <int>[];
    var i = 0;
    while (i < blocks.length) {
      v.add(i);
      i = _collapsed.contains(i) ? _sectionEnd[i] : i + 1;
    }
    _visible = v;
  }

  void _setCollapsed(Set<int> c) {
    setState(() {
      _collapsed = Set.of(c);
      _computeVisible();
    });
    widget.reflowController?._changed();
  }

  void _toggle(int index) {
    if (index < 0 || index >= widget.doc.blocks.length || widget.doc.blocks[index] is! HeadingBlock) return;
    final c = Set.of(_collapsed);
    if (!c.remove(index)) c.add(index);
    _setCollapsed(c);
  }

  int? _firstVisibleBlock() {
    if (!_scroll.hasClients) return null;
    final offset = _scroll.offset;
    int? best;
    double? bestTop;
    for (final e in _built.entries) {
      final top = _itemTop(e.value);
      if (top == null) continue;
      final bottom = top + (_heights[e.key] ?? 0);
      if (bottom <= offset) continue;
      if (bestTop == null || top < bestTop) {
        bestTop = top;
        best = e.key;
      }
    }
    return best;
  }

  /// Scroll offset of the top of a built item.
  double? _itemTop(BuildContext ctx) {
    final ro = ctx.findRenderObject();
    if (ro == null || !ro.attached) return null;
    final viewport = RenderAbstractViewport.maybeOf(ro);
    if (viewport == null) return null;
    return viewport.getOffsetToReveal(ro, 0).offset;
  }

  double _averageHeight() {
    if (_heights.isEmpty) return widget.settings.fontSize * widget.settings.lineHeight * 4;
    return _heights.values.reduce((a, b) => a + b) / _heights.length;
  }

  double _estimatedExtent(int fromPos, int toPos) {
    final avg = _averageHeight();
    var sum = 0.0;
    for (var p = fromPos; p < toPos; p++) {
      sum += _heights[_visible[p]] ?? avg;
    }
    return sum;
  }

  Future<void> _jumpToBlock(int index) async {
    final blocks = widget.doc.blocks;
    if (index < 0 || index >= blocks.length) return;
    final hiding = _collapsed.where((h) => h != index && h < index && index < _sectionEnd[h]).toSet();
    if (hiding.isNotEmpty) {
      _setCollapsed(_collapsed.difference(hiding));
      await SchedulerBinding.instance.endOfFrame;
      if (!mounted) return;
    }
    final pos = _visibleIndexOf(index);
    if (pos < 0) return;
    for (var attempt = 0; attempt < 12; attempt++) {
      if (!mounted) return;
      final ctx = _built[index];
      if (ctx != null && ctx.mounted) {
        await Scrollable.ensureVisible(ctx, alignment: 0, duration: Duration.zero);
        return;
      }
      if (!_scroll.hasClients) return;
      final position = _scroll.position;
      // Anchor on the built item closest to the target, whose exact scroll
      // offset is known, and add the estimated extent of the items between.
      double? target;
      var bestDistance = 1 << 30;
      for (final e in _built.entries) {
        final p = _visibleIndexOf(e.key);
        if (p < 0 || !e.value.mounted) continue;
        final top = _itemTop(e.value);
        if (top == null) continue;
        final distance = (p - pos).abs();
        if (distance < bestDistance) {
          bestDistance = distance;
          target = p <= pos ? top + _estimatedExtent(p, pos) : top - _estimatedExtent(pos, p);
        }
      }
      target ??= _listPadTop + _estimatedExtent(0, pos);
      final clamped = target.clamp(position.minScrollExtent, position.maxScrollExtent).toDouble();
      position.jumpTo(clamped);
      await SchedulerBinding.instance.endOfFrame;
    }
  }

  int _visibleIndexOf(int block) {
    var lo = 0, hi = _visible.length - 1;
    while (lo <= hi) {
      final mid = (lo + hi) >> 1;
      final v = _visible[mid];
      if (v == block) return mid;
      if (v < block) {
        lo = mid + 1;
      } else {
        hi = mid - 1;
      }
    }
    return -1;
  }

  @override
  Widget build(BuildContext context) {
    final s = widget.settings;
    final colors = s.colors;
    final style = _Styles(s);
    final query = widget.highlightQuery?.trim() ?? '';
    return ColoredBox(
      key: ReflowView.backgroundKey,
      color: colors.background,
      child: DefaultSelectionStyle(
        selectionColor: colors.accent.withValues(alpha: 0.3),
        cursorColor: colors.accent,
        child: Scrollbar(
          controller: _scroll,
          child: ListView.builder(
            controller: _scroll,
            padding: EdgeInsets.only(top: _listPadTop, bottom: 48 + MediaQuery.paddingOf(context).bottom),
            itemCount: _visible.length,
            itemBuilder: (context, pos) {
              final index = _visible[pos];
              return _ItemHost(
                key: ValueKey(index),
                index: index,
                built: _built,
                heights: _heights,
                child: Align(
                  alignment: Alignment.topCenter,
                  child: ConstrainedBox(
                    constraints: const BoxConstraints(maxWidth: _maxContentWidth),
                    child: SizedBox(
                      width: double.infinity,
                      child: Padding(
                        padding: EdgeInsets.symmetric(horizontal: s.margin.padding),
                        child: _buildItem(context, index, style, query),
                      ),
                    ),
                  ),
                ),
              );
            },
          ),
        ),
      ),
    );
  }

  Widget _buildItem(BuildContext context, int index, _Styles st, String query) {
    final block = widget.doc.blocks[index];
    final child = _buildBlock(context, index, block, st, query);
    if (!_pageStarts.contains(index)) return child;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: [
        _PageMarker(page: block.pageNumber!, styles: st, onTap: widget.onOpenPage),
        child,
      ],
    );
  }

  Widget _buildBlock(BuildContext context, int index, DocBlock block, _Styles st, String query) {
    final gap = st.body.fontSize! * 0.9;
    switch (block) {
      case HeadingBlock h:
        final collapsed = _collapsed.contains(index);
        final hasContent = _sectionEnd[index] > index + 1;
        final hs = st.heading(h.level);
        return Padding(
          padding: EdgeInsets.only(top: gap * (h.level <= 2 ? 1.4 : 1.0), bottom: gap * 0.6),
          child: Semantics(
            header: true,
            button: hasContent,
            expanded: hasContent ? !collapsed : null,
            child: InkWell(
              borderRadius: BorderRadius.circular(8),
              onTap: hasContent ? () => _toggle(index) : null,
              child: Padding(
                padding: const EdgeInsets.symmetric(vertical: 4),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Expanded(
                      child: Text.rich(
                        TextSpan(
                          children: buildHighlightedSpans(
                            h.spans,
                            hs,
                            query,
                            st.colors.accent,
                            background: st.colors.background,
                            keepFamilies: st.keepFamilies,
                          ),
                        ),
                        style: hs,
                        textAlign: blockTextAlign(h.align, TextAlign.start),
                      ),
                    ),
                    if (hasContent)
                      Padding(
                        padding: EdgeInsets.only(left: 8, top: (hs.fontSize! * (hs.height ?? 1.2) - 24) / 2),
                        child: AnimatedRotation(
                          turns: collapsed ? -0.25 : 0,
                          duration: const Duration(milliseconds: 150),
                          child: Icon(Symbols.expand_more, size: 24, color: st.colors.secondaryText),
                        ),
                      ),
                  ],
                ),
              ),
            ),
          ),
        );
      case ParagraphBlock p:
        return Padding(
          padding: EdgeInsets.only(bottom: gap),
          child: _RichParagraph(
            spans: p.spans,
            style: st.body,
            textAlign: blockTextAlign(p.align, st.align),
            background: st.colors.background,
            keepFamilies: st.keepFamilies,
            query: query,
            accent: st.colors.accent,
            onLinkTap: widget.onLinkTap,
          ),
        );
      case ListItemBlock l:
        final markerText = l.ordered ? (l.marker ?? '•') : const ['•', '◦', '▪'][l.indent % 3];
        final indentWidth = st.body.fontSize! * 1.4;
        return Padding(
          padding: EdgeInsets.only(left: indentWidth * l.indent, bottom: gap * 0.45),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              SizedBox(
                width: st.body.fontSize! * (l.ordered ? 2.2 : 1.4),
                child: Text(markerText, style: st.body.copyWith(color: st.colors.secondaryText)),
              ),
              Expanded(
                child: _RichParagraph(
                  spans: l.spans,
                  style: st.body,
                  textAlign: st.align,
                  background: st.colors.background,
                  keepFamilies: st.keepFamilies,
                  query: query,
                  accent: st.colors.accent,
                  onLinkTap: widget.onLinkTap,
                ),
              ),
            ],
          ),
        );
      case QuoteBlock q:
        return Padding(
          padding: EdgeInsets.only(bottom: gap, top: gap * 0.3),
          child: Container(
            decoration: BoxDecoration(
              border: Border(left: BorderSide(color: st.colors.accent, width: 4)),
            ),
            padding: const EdgeInsets.only(left: 16, top: 2, bottom: 2),
            child: _RichParagraph(
              spans: q.spans,
              style: st.body.copyWith(fontStyle: FontStyle.italic, color: st.colors.secondaryText),
              textAlign: st.align,
              background: st.colors.background,
              keepFamilies: st.keepFamilies,
              query: query,
              accent: st.colors.accent,
              onLinkTap: widget.onLinkTap,
            ),
          ),
        );
      case ImageBlock im:
        return Padding(
          padding: EdgeInsets.only(bottom: gap, top: gap * 0.3),
          child: _ReflowImage(block: im, styles: st, query: query),
        );
      case TableBlock t:
        return Padding(
          padding: EdgeInsets.only(bottom: gap, top: gap * 0.3),
          child: _ReflowTable(block: t, styles: st, query: query),
        );
      case PageBreakBlock _:
        return Padding(
          padding: EdgeInsets.symmetric(vertical: gap),
          child: Divider(color: st.colors.divider, height: 1),
        );
    }
  }
}

/// Registers a built item's context and measures its extent.
class _ItemHost extends StatefulWidget {
  const _ItemHost({super.key, required this.index, required this.built, required this.heights, required this.child});

  final int index;
  final Map<int, BuildContext> built;
  final Map<int, double> heights;
  final Widget child;

  @override
  State<_ItemHost> createState() => _ItemHostState();
}

class _ItemHostState extends State<_ItemHost> {
  @override
  void initState() {
    super.initState();
    widget.built[widget.index] = context;
  }

  @override
  void didUpdateWidget(covariant _ItemHost old) {
    super.didUpdateWidget(old);
    if (old.index != widget.index && identical(old.built[old.index], context)) old.built.remove(old.index);
    widget.built[widget.index] = context;
  }

  @override
  void dispose() {
    if (identical(widget.built[widget.index], context)) widget.built.remove(widget.index);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) =>
      _SizeReporter(onSize: (size) => widget.heights[widget.index] = size.height, child: widget.child);
}

class _SizeReporter extends SingleChildRenderObjectWidget {
  const _SizeReporter({required this.onSize, super.child});

  final ValueChanged<Size> onSize;

  @override
  RenderObject createRenderObject(BuildContext context) => _RenderSizeReporter(onSize);

  @override
  void updateRenderObject(BuildContext context, _RenderSizeReporter renderObject) => renderObject.onSize = onSize;
}

class _RenderSizeReporter extends RenderProxyBox {
  _RenderSizeReporter(this.onSize);

  ValueChanged<Size> onSize;

  @override
  void performLayout() {
    super.performLayout();
    onSize(size);
  }
}

/// Resolved text styles for the current settings.
class _Styles {
  _Styles(ReadingSettings s)
    : colors = s.colors,
      align = s.textAlign,
      keepFamilies = s.fontFamily == 'original',
      body = TextStyle(
        fontSize: s.fontSize,
        height: s.lineHeight,
        fontFamily: s.flutterFontFamily,
        color: s.colors.text,
        letterSpacing: 0.1,
      );

  final ReadingThemeColors colors;
  final TextAlign align;
  final bool keepFamilies;
  final TextStyle body;

  static const _scale = [1.75, 1.5, 1.3, 1.15, 1.05, 1.0];

  TextStyle heading(int level) {
    final l = level.clamp(1, 6);
    return body.copyWith(
      fontSize: body.fontSize! * _scale[l - 1],
      height: 1.3,
      fontWeight: l <= 2 ? FontWeight.w700 : FontWeight.w600,
      letterSpacing: 0,
    );
  }

  TextStyle get small => body.copyWith(fontSize: body.fontSize! * 0.8, height: 1.4, color: colors.secondaryText);
}

/// Builds inline spans for [spans], highlighting case-insensitive matches of
/// [query] (which may cross span boundaries) with [accent].
/// Adapts an original text color so it stays readable on the reading theme
/// background (keeps the hue, adjusts lightness when contrast is too low).
Color adaptTextColor(Color original, Color background) {
  double contrast(Color a, Color b) {
    final la = a.computeLuminance(), lb = b.computeLuminance();
    final hi = la > lb ? la : lb, lo = la > lb ? lb : la;
    return (hi + 0.05) / (lo + 0.05);
  }

  if (contrast(original, background) >= 3) return original;
  final towards = background.computeLuminance() < 0.5 ? Colors.white : Colors.black;
  for (var t = 0.2; t <= 1.0; t += 0.2) {
    final c = Color.lerp(original, towards, t)!;
    if (contrast(c, background) >= 3) return c;
  }
  return towards;
}

String? _familyFor(String? family) => switch (family) {
  'serif' => 'serif',
  'mono' => 'monospace',
  'sans' => 'sans-serif',
  _ => null,
};

TextAlign blockTextAlign(BlockAlign align, TextAlign fallback) => switch (align) {
  BlockAlign.center => TextAlign.center,
  BlockAlign.end => TextAlign.right,
  BlockAlign.start => fallback,
};

List<InlineSpan> buildHighlightedSpans(
  List<TextSpanData> spans,
  TextStyle base,
  String query,
  Color accent, {
  GestureRecognizer? Function(String link)? recognizerFor,
  Color? background,
  bool keepFamilies = true,
}) {
  final plain = spansToText(spans);
  final ranges = <(int, int)>[];
  if (query.isNotEmpty) {
    final hay = plain.toLowerCase();
    final needle = query.toLowerCase();
    var from = 0;
    while (true) {
      final i = hay.indexOf(needle, from);
      if (i < 0) break;
      ranges.add((i, i + needle.length));
      from = i + needle.length;
    }
  }
  final highlight = accent.withValues(alpha: 0.35);
  final out = <InlineSpan>[];
  var offset = 0;
  var r = 0;
  for (final s in spans) {
    var style = base;
    if (s.bold) style = style.copyWith(fontWeight: FontWeight.w700);
    if (s.italic) style = style.copyWith(fontStyle: FontStyle.italic);
    if (s.color != null) {
      final c = Color(s.color!);
      style = style.copyWith(color: background == null ? c : adaptTextColor(c, background));
    }
    if (keepFamilies && s.fontFamily != null) style = style.copyWith(fontFamily: _familyFor(s.fontFamily));
    if (s.sizeRatio != 1.0 && base.fontSize != null) {
      style = style.copyWith(fontSize: base.fontSize! * s.sizeRatio.clamp(0.55, 2.0));
    }
    final decorations = [
      if (s.underline || s.link != null) TextDecoration.underline,
      if (s.strike) TextDecoration.lineThrough,
    ];
    if (decorations.isNotEmpty) style = style.copyWith(decoration: TextDecoration.combine(decorations));
    if (s.link != null) style = style.copyWith(color: accent, decorationColor: accent);
    final recognizer = s.link != null && recognizerFor != null ? recognizerFor(s.link!) : null;
    final start = offset, end = offset + s.text.length;
    var pos = start;
    while (pos < end) {
      while (r < ranges.length && ranges[r].$2 <= pos) {
        r++;
      }
      if (r < ranges.length && ranges[r].$1 <= pos) {
        final stop = ranges[r].$2 < end ? ranges[r].$2 : end;
        out.add(
          TextSpan(
            text: plain.substring(pos, stop),
            style: style.copyWith(backgroundColor: highlight),
            recognizer: recognizer,
          ),
        );
        pos = stop;
      } else {
        final next = r < ranges.length && ranges[r].$1 < end ? ranges[r].$1 : end;
        out.add(TextSpan(text: plain.substring(pos, next), style: style, recognizer: recognizer));
        pos = next;
      }
    }
    offset = end;
  }
  return out;
}

/// Selectable rich paragraph that owns its link recognizers.
class _RichParagraph extends StatefulWidget {
  const _RichParagraph({
    required this.spans,
    required this.style,
    required this.textAlign,
    required this.query,
    required this.accent,
    this.onLinkTap,
    this.background,
    this.keepFamilies = true,
  });

  final List<TextSpanData> spans;
  final TextStyle style;
  final TextAlign textAlign;
  final String query;
  final Color accent;
  final void Function(String link)? onLinkTap;
  final Color? background;
  final bool keepFamilies;

  @override
  State<_RichParagraph> createState() => _RichParagraphState();
}

class _RichParagraphState extends State<_RichParagraph> {
  final List<TapGestureRecognizer> _recognizers = [];

  void _disposeRecognizers() {
    for (final r in _recognizers) {
      r.dispose();
    }
    _recognizers.clear();
  }

  @override
  void dispose() {
    _disposeRecognizers();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    _disposeRecognizers();
    final onLinkTap = widget.onLinkTap;
    final children = buildHighlightedSpans(
      widget.spans,
      widget.style,
      widget.query,
      widget.accent,
      background: widget.background,
      keepFamilies: widget.keepFamilies,
      recognizerFor: onLinkTap == null
          ? null
          : (link) {
              final r = TapGestureRecognizer()..onTap = () => onLinkTap(link);
              _recognizers.add(r);
              return r;
            },
    );
    return SelectableText.rich(
      TextSpan(children: children, style: widget.style),
      textAlign: widget.textAlign,
      style: widget.style,
    );
  }
}

class _PageMarker extends StatelessWidget {
  const _PageMarker({required this.page, required this.styles, this.onTap});

  final int page;
  final _Styles styles;
  final void Function(int page)? onTap;

  @override
  Widget build(BuildContext context) {
    final c = styles.colors;
    return Padding(
      padding: const EdgeInsets.only(top: 4, bottom: 8),
      child: Row(
        children: [
          Expanded(child: Divider(color: c.divider, height: 1)),
          const SizedBox(width: 8),
          InkWell(
            borderRadius: BorderRadius.circular(12),
            onTap: onTap == null ? null : () => onTap!(page),
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 3),
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(12),
                border: Border.all(color: c.divider),
              ),
              child: Text(
                'p. $page',
                style: TextStyle(fontSize: 12, color: c.secondaryText, fontFamily: styles.body.fontFamily),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _ReflowImage extends StatelessWidget {
  const _ReflowImage({required this.block, required this.styles, required this.query});

  final ImageBlock block;
  final _Styles styles;
  final String query;

  @override
  Widget build(BuildContext context) {
    final c = styles.colors;
    final aspect = block.width > 0 && block.height > 0 ? block.width / block.height : 4 / 3;
    final image = ClipRRect(
      borderRadius: BorderRadius.circular(12),
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxHeight: 560),
        child: AspectRatio(
          aspectRatio: aspect,
          child: Image.memory(
            block.bytes,
            fit: BoxFit.contain,
            gaplessPlayback: true,
            errorBuilder: (context, error, stack) => ColoredBox(
              color: c.surface,
              child: Center(child: Icon(Symbols.broken_image, color: c.secondaryText)),
            ),
          ),
        ),
      ),
    );
    return Column(
      crossAxisAlignment: CrossAxisAlignment.center,
      mainAxisSize: MainAxisSize.min,
      children: [
        Semantics(
          image: true,
          label: block.caption ?? 'Image',
          button: true,
          child: GestureDetector(
            onTap: () => Navigator.of(context).push(
              MaterialPageRoute<void>(
                fullscreenDialog: true,
                builder: (_) => _FullScreenImage(bytes: block.bytes, caption: block.caption),
              ),
            ),
            child: image,
          ),
        ),
        if (block.caption != null && block.caption!.isNotEmpty)
          Padding(
            padding: const EdgeInsets.only(top: 8),
            child: Text.rich(
              TextSpan(
                children: buildHighlightedSpans(
                  [TextSpanData(block.caption!)],
                  styles.small.copyWith(fontStyle: FontStyle.italic),
                  query,
                  c.accent,
                ),
              ),
              textAlign: TextAlign.center,
            ),
          ),
      ],
    );
  }
}

class _FullScreenImage extends StatelessWidget {
  const _FullScreenImage({required this.bytes, this.caption});

  final Uint8List bytes;
  final String? caption;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(
        backgroundColor: Colors.transparent,
        foregroundColor: Colors.white,
        elevation: 0,
        leading: IconButton(
          icon: const Icon(Symbols.close),
          tooltip: 'Close',
          onPressed: () => Navigator.of(context).maybePop(),
        ),
      ),
      extendBodyBehindAppBar: true,
      body: Column(
        children: [
          Expanded(
            child: InteractiveViewer(
              minScale: 1,
              maxScale: 6,
              child: Center(
                child: Image.memory(
                  bytes,
                  fit: BoxFit.contain,
                  errorBuilder: (context, error, stack) =>
                      const Icon(Symbols.broken_image, color: Colors.white54, size: 48),
                ),
              ),
            ),
          ),
          if (caption != null && caption!.isNotEmpty)
            SafeArea(
              top: false,
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: Text(
                  caption!,
                  style: const TextStyle(color: Colors.white70),
                  textAlign: TextAlign.center,
                ),
              ),
            ),
        ],
      ),
    );
  }
}

class _ReflowTable extends StatelessWidget {
  const _ReflowTable({required this.block, required this.styles, required this.query});

  final TableBlock block;
  final _Styles styles;
  final String query;

  @override
  Widget build(BuildContext context) {
    final c = styles.colors;
    final cellStyle = styles.body.copyWith(fontSize: styles.body.fontSize! * 0.9, height: 1.35);
    final headerStyle = cellStyle.copyWith(fontWeight: FontWeight.w700);
    final cols = block.columnCount;
    if (cols == 0) return const SizedBox.shrink();
    return SingleChildScrollView(
      scrollDirection: Axis.horizontal,
      child: ClipRRect(
        borderRadius: BorderRadius.circular(6),
        child: Table(
          border: TableBorder.all(color: c.divider, borderRadius: BorderRadius.circular(6)),
          defaultColumnWidth: const IntrinsicColumnWidth(),
          defaultVerticalAlignment: TableCellVerticalAlignment.top,
          children: [
            for (var r = 0; r < block.rows.length; r++)
              TableRow(
                decoration: r == 0 && block.hasHeader ? BoxDecoration(color: c.accent.withValues(alpha: 0.12)) : null,
                children: [
                  for (var k = 0; k < cols; k++)
                    ConstrainedBox(
                      constraints: const BoxConstraints(maxWidth: 280),
                      child: Padding(
                        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
                        child: Text.rich(
                          TextSpan(
                            children: buildHighlightedSpans(
                              [TextSpanData(k < block.rows[r].length ? block.rows[r][k] : '')],
                              r == 0 && block.hasHeader ? headerStyle : cellStyle,
                              query,
                              c.accent,
                            ),
                          ),
                        ),
                      ),
                    ),
                ],
              ),
          ],
        ),
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Outline
// ---------------------------------------------------------------------------

/// A heading entry of the document outline.
class OutlineEntry {
  const OutlineEntry({required this.blockIndex, required this.level, required this.text, this.pageNumber});

  /// Index into `doc.blocks`; pass to [ReflowController.jumpToBlock].
  final int blockIndex;
  final int level;
  final String text;
  final int? pageNumber;
}

/// Headings of [doc] in order, with their block indices.
List<OutlineEntry> buildOutline(DocStructure doc) => [
  for (var i = 0; i < doc.blocks.length; i++)
    if (doc.blocks[i] case HeadingBlock h when h.text.trim().isNotEmpty)
      OutlineEntry(blockIndex: i, level: h.level, text: h.text.trim(), pageNumber: h.pageNumber),
];

/// Indented list of headings, e.g. for a navigation drawer.
class ReflowOutline extends StatelessWidget {
  const ReflowOutline({super.key, required this.doc, required this.onSelect, this.settings});

  final DocStructure doc;

  /// Called with the heading's block index.
  final void Function(int blockIndex) onSelect;

  /// When provided, the outline uses the reading theme colors.
  final ReadingSettings? settings;

  @override
  Widget build(BuildContext context) {
    final entries = buildOutline(doc);
    final theme = Theme.of(context);
    final colors = settings?.colors;
    final textColor = colors?.text ?? theme.colorScheme.onSurface;
    final secondary = colors?.secondaryText ?? theme.colorScheme.onSurfaceVariant;
    if (entries.isEmpty) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Text('No headings found', style: TextStyle(color: secondary)),
        ),
      );
    }
    final minLevel = entries.map((e) => e.level).reduce((a, b) => a < b ? a : b);
    return ListView.builder(
      itemCount: entries.length,
      itemBuilder: (context, i) {
        final e = entries[i];
        final depth = e.level - minLevel;
        return InkWell(
          onTap: () => onSelect(e.blockIndex),
          child: Padding(
            padding: EdgeInsets.fromLTRB(16 + 16.0 * depth, 10, 16, 10),
            child: Row(
              children: [
                Expanded(
                  child: Text(
                    e.text,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      color: depth == 0 ? textColor : textColor.withValues(alpha: 0.85),
                      fontWeight: depth == 0 ? FontWeight.w600 : FontWeight.w400,
                      fontSize: depth == 0 ? 15 : 14,
                    ),
                  ),
                ),
                if (e.pageNumber != null)
                  Padding(
                    padding: const EdgeInsets.only(left: 8),
                    child: Text('${e.pageNumber}', style: TextStyle(color: secondary, fontSize: 12)),
                  ),
              ],
            ),
          ),
        );
      },
    );
  }
}
