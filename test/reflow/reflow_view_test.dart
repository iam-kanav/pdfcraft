import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pdfcraft/core/models/doc_structure.dart';
import 'package:pdfcraft/features/common/fast_scroller.dart';
import 'package:pdfcraft/features/reflow/reading_settings.dart';
import 'package:pdfcraft/features/reflow/widgets/reading_settings_sheet.dart';
import 'package:pdfcraft/features/reflow/widgets/reflow_view.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'fixtures.dart';

Finder selectable(String text) => find.byWidgetPredicate(
  (w) => w is Text && (w.data ?? w.textSpan?.toPlainText()) == text,
  description: 'Text "$text"',
);

DocStructure sampleDoc() => DocStructure(
  title: 'Guide',
  blocks: [
    const HeadingBlock(level: 1, spans: [TextSpanData('Guide')], pageNumber: 1),
    const ParagraphBlock(spans: [TextSpanData('Intro text with '), TextSpanData('bold', bold: true)], pageNumber: 1),
    const HeadingBlock(level: 2, spans: [TextSpanData('Setup')], pageNumber: 1),
    const ParagraphBlock(spans: [TextSpanData('Install the tool.')], pageNumber: 1),
    const ListItemBlock(spans: [TextSpanData('Step one')], ordered: true, marker: '1.', pageNumber: 2),
    const HeadingBlock(level: 2, spans: [TextSpanData('Usage')], pageNumber: 2),
    const QuoteBlock(spans: [TextSpanData('Quoted wisdom.')], pageNumber: 2),
    const TableBlock(
      rows: [
        ['Name', 'Value'],
        ['a', '1'],
      ],
      hasHeader: true,
      pageNumber: 2,
    ),
    ImageBlock(bytes: tinyPng, width: 40, height: 30, caption: 'Figure 1: Pixel', pageNumber: 2),
    const HeadingBlock(level: 1, spans: [TextSpanData('Appendix')], pageNumber: 3),
    const ParagraphBlock(spans: [TextSpanData('The end.')], pageNumber: 3),
  ],
);

Future<ReadingSettings> loadedSettings() async {
  SharedPreferences.setMockInitialValues({});
  final s = ReadingSettings();
  await s.load();
  return s;
}

Widget host(Widget child) => MaterialApp(home: Scaffold(body: child));

/// A button of the reflow view's selection menu.
ContextMenuButtonItem menuButton(WidgetTester tester, ContextMenuButtonType type) {
  final area = tester.widget<SelectionArea>(find.byType(SelectionArea));
  final region = tester.state<SelectableRegionState>(find.byType(SelectableRegion));
  final menu = area.contextMenuBuilder!(region.context, region) as AdaptiveTextSelectionToolbar;
  return menu.buttonItems!.firstWhere((b) => b.type == type);
}

void main() {
  testWidgets('renders headings, paragraphs, lists, quotes, tables, images and page markers', (tester) async {
    final settings = await loadedSettings();
    final opened = <int>[];
    await tester.pumpWidget(host(ReflowView(doc: sampleDoc(), settings: settings, onOpenPage: opened.add)));

    expect(find.text('Guide'), findsOneWidget);
    expect(find.text('Setup'), findsOneWidget);
    expect(selectable('Intro text with bold'), findsOneWidget);
    expect(selectable('Install the tool.'), findsOneWidget);
    expect(selectable('Step one'), findsOneWidget);
    expect(find.text('1.'), findsOneWidget);
    expect(selectable('Quoted wisdom.'), findsOneWidget);
    expect(find.text('Name'), findsOneWidget);
    expect(find.byType(Table), findsOneWidget);
    expect(find.byType(Image), findsOneWidget);
    expect(find.text('Figure 1: Pixel'), findsOneWidget);
    expect(find.text('p. 1'), findsOneWidget);
    expect(find.text('p. 2'), findsOneWidget);

    // Bold span is rendered bold.
    final para = tester.widget<Text>(selectable('Intro text with bold'));
    final boldSpan = ((para.textSpan! as TextSpan).children!).cast<TextSpan>().firstWhere((s) => s.text == 'bold');
    expect(boldSpan.style!.fontWeight, FontWeight.w700);

    await tester.tap(find.text('p. 2'));
    expect(opened, [2]);
  });

  testWidgets('tapping a heading collapses and expands its section', (tester) async {
    final settings = await loadedSettings();
    await tester.pumpWidget(host(ReflowView(doc: sampleDoc(), settings: settings)));

    // Collapse "Setup" (H2): hides its content up to the next H2 "Usage".
    await tester.tap(find.text('Setup'));
    await tester.pump();
    expect(selectable('Install the tool.'), findsNothing);
    expect(selectable('Step one'), findsNothing);
    expect(find.text('Usage'), findsOneWidget);
    expect(selectable('Intro text with bold'), findsOneWidget);

    // Collapse "Guide" (H1): hides everything until the next H1.
    await tester.tap(find.text('Guide'));
    await tester.pump();
    expect(find.text('Setup'), findsNothing);
    expect(find.text('Usage'), findsNothing);
    expect(find.text('Appendix'), findsOneWidget);

    // Expanding restores the inner collapsed state.
    await tester.tap(find.text('Guide'));
    await tester.pump();
    expect(find.text('Usage'), findsOneWidget);
    expect(selectable('Install the tool.'), findsNothing);
    await tester.tap(find.text('Setup'));
    await tester.pump();
    expect(selectable('Install the tool.'), findsOneWidget);
  });

  testWidgets('switching the theme changes the background color', (tester) async {
    final settings = await loadedSettings();
    await tester.pumpWidget(host(ReflowView(doc: sampleDoc(), settings: settings)));

    Color bg() => tester.widget<ColoredBox>(find.byKey(ReflowView.backgroundKey)).color;
    expect(bg(), ReadingTheme.light.colors.background);

    await settings.setTheme(ReadingTheme.dark);
    await tester.pump();
    expect(bg(), ReadingTheme.dark.colors.background);

    await settings.setTheme(ReadingTheme.sepia);
    await tester.pump();
    expect(bg(), ReadingTheme.sepia.colors.background);
    final text = tester.widget<Text>(selectable('Install the tool.'));
    expect(text.style!.color, ReadingTheme.sepia.colors.text);
  });

  testWidgets('highlightQuery marks case-insensitive matches with the accent color', (tester) async {
    final settings = await loadedSettings();
    await tester.pumpWidget(host(ReflowView(doc: sampleDoc(), settings: settings, highlightQuery: 'TOOL')));
    final para = tester.widget<Text>(selectable('Install the tool.'));
    final spans = (para.textSpan! as TextSpan).children!.cast<TextSpan>();
    final hit = spans.singleWhere((s) => s.style?.backgroundColor != null);
    expect(hit.text, 'tool');
    expect(hit.style!.backgroundColor, ReadingTheme.light.colors.accent.withValues(alpha: 0.35));
  });

  test('highlight spans can cross style boundaries', () {
    final spans = buildHighlightedSpans(
      const [TextSpanData('ab'), TextSpanData('cd', bold: true)],
      const TextStyle(),
      'bc',
      const Color(0xFF000000),
    ).cast<TextSpan>();
    expect(spans.map((s) => s.text).toList(), ['a', 'b', 'c', 'd']);
    expect(spans.map((s) => s.style!.backgroundColor != null).toList(), [false, true, true, false]);
    expect(spans.map((s) => s.style!.fontWeight == FontWeight.w700).toList(), [false, false, true, true]);
  });

  testWidgets('ReflowController.jumpToBlock scrolls a long document to the block', (tester) async {
    final settings = await loadedSettings();
    final blocks = <DocBlock>[
      for (var i = 0; i < 400; i++)
        if (i % 25 == 0)
          HeadingBlock(level: 1, spans: [TextSpanData('Chapter $i')], pageNumber: i ~/ 10 + 1)
        else
          ParagraphBlock(
            spans: [TextSpanData('Paragraph $i. ${'Lorem ipsum dolor sit amet. ' * (1 + i % 4)}')],
            pageNumber: i ~/ 10 + 1,
          ),
    ];
    final doc = DocStructure(blocks: blocks);
    final controller = ReflowController();
    await tester.pumpWidget(host(ReflowView(doc: doc, settings: settings, reflowController: controller)));

    // Collapse chapter 300 so the target is hidden; the jump must expand it.
    controller.toggleSection(300);
    await tester.pump();
    expect(controller.isCollapsed(300), isTrue);

    final done = controller.jumpToBlock(312);
    for (var i = 0; i < 30; i++) {
      await tester.pump();
    }
    await done;
    await tester.pump();

    expect(controller.isCollapsed(300), isFalse);
    final target = find.byWidgetPredicate(
      (w) => w is Text && (w.textSpan?.toPlainText() ?? '').startsWith('Paragraph 312.'),
    );
    expect(target, findsOneWidget);
    final top = tester.getTopLeft(target).dy;
    final viewport = tester.getRect(find.byType(ReflowView));
    expect(top, greaterThanOrEqualTo(viewport.top));
    expect(top, lessThan(viewport.top + 120));
    expect(controller.firstVisibleBlock, 312);

    // And back up to an earlier block.
    final back = controller.jumpToBlock(26);
    for (var i = 0; i < 30; i++) {
      await tester.pump();
    }
    await back;
    await tester.pump();
    final early = find.byWidgetPredicate(
      (w) => w is Text && (w.textSpan?.toPlainText() ?? '').startsWith('Paragraph 26.'),
    );
    expect(early, findsOneWidget);
    expect(tester.getTopLeft(early).dy, lessThan(viewport.top + 120));
  });

  testWidgets('a selection spans blocks and copies text that scrolled out of view', (tester) async {
    final settings = await loadedSettings();
    final doc = DocStructure(
      blocks: [
        const HeadingBlock(level: 1, spans: [TextSpanData('Title')], pageNumber: 1),
        for (var i = 0; i < 120; i++)
          ParagraphBlock(spans: [TextSpanData('Paragraph $i. ${'Lorem ipsum dolor sit amet. ' * 3}')], pageNumber: 1),
      ],
    );
    String? copied;
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(SystemChannels.platform, (call) async {
      if (call.method == 'Clipboard.setData') copied = (call.arguments as Map)['text'] as String;
      return null;
    });
    addTearDown(() => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(SystemChannels.platform, null));
    final scroll = ScrollController();
    addTearDown(scroll.dispose);
    await tester.pumpWidget(host(ReflowView(doc: doc, settings: settings, controller: scroll)));
    await tester.pumpAndSettle(); // Nested selectables register over a few frames.

    // Drag from the title to past the bottom edge, so the view auto-scrolls
    // well beyond the first paragraphs.
    final gesture = await tester.startGesture(tester.getTopLeft(find.text('Title')), kind: PointerDeviceKind.mouse);
    addTearDown(gesture.removePointer);
    await tester.pump();
    await gesture.moveTo(tester.getBottomRight(find.byType(CustomScrollView)) + const Offset(0, 20));
    for (var i = 0; i < 200 && scroll.offset < 2000; i++) {
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));
    }
    await gesture.up();
    await tester.pump();

    final view = tester.getRect(find.byType(ReflowView));
    expect(scroll.offset, greaterThan(view.height * 2));
    expect(find.text('Title'), findsNothing, reason: 'the start of the selection is no longer built');

    menuButton(tester, ContextMenuButtonType.copy).onPressed!();
    await tester.pump();

    expect(copied, isNotNull);
    expect(copied, startsWith('Title\n\nParagraph 0. '));
    final last = RegExp(r'Paragraph (\d+)\.').allMatches(copied!).map((m) => int.parse(m.group(1)!)).toList();
    expect(last.length, greaterThan(10));
    expect(last, List.generate(last.length, (i) => i), reason: 'every paragraph in between is copied, in order');
  });

  testWidgets('select all copies the whole document', (tester) async {
    final settings = await loadedSettings();
    String? copied;
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(SystemChannels.platform, (call) async {
      if (call.method == 'Clipboard.setData') copied = (call.arguments as Map)['text'] as String;
      return null;
    });
    addTearDown(() => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(SystemChannels.platform, null));
    final doc = sampleDoc();
    await tester.pumpWidget(host(ReflowView(doc: doc, settings: settings)));
    await tester.pumpAndSettle();
    // Long-press a word first so the menu exists.
    final press = await tester.startGesture(tester.getTopLeft(find.text('Guide')) + const Offset(8, 8));
    await tester.pump(const Duration(milliseconds: 500));
    await press.up();
    await tester.pumpAndSettle();
    menuButton(tester, ContextMenuButtonType.selectAll).onPressed!();
    await tester.pump();
    menuButton(tester, ContextMenuButtonType.copy).onPressed!();
    await tester.pump();
    expect(copied, startsWith('Guide\n\nIntro text with bold\n\nSetup'));
    expect(copied, contains('1. Step one'));
    expect(copied, contains('Name\tValue\na\t1'));
    expect(copied, endsWith('The end.'));
  });

  testWidgets('the fast scroller appears on scroll and drags through a long document', (tester) async {
    final settings = await loadedSettings();
    final doc = DocStructure(
      blocks: [
        for (var i = 0; i < 300; i++)
          ParagraphBlock(
            spans: [TextSpanData('Paragraph $i. ${'Lorem ipsum dolor sit amet. ' * 3}')],
            pageNumber: i ~/ 10 + 1,
          ),
      ],
    );
    final scroll = ScrollController();
    addTearDown(scroll.dispose);
    await tester.pumpWidget(host(ReflowView(doc: doc, settings: settings, controller: scroll)));
    final handle = find.byKey(FastScroller.handleKey);
    expect(handle, findsNothing, reason: 'hidden until the document scrolls');

    await tester.drag(find.byType(CustomScrollView), const Offset(0, -300));
    await tester.pump();
    expect(handle, findsOneWidget);

    // Drag the handle to the bottom of the track.
    final gesture = await tester.startGesture(tester.getCenter(handle));
    await gesture.moveBy(const Offset(0, 20));
    await tester.pump();
    final view = tester.getRect(find.byType(ReflowView));
    for (var y = tester.getCenter(handle).dy; y < view.bottom; y += 60) {
      await gesture.moveTo(Offset(tester.getCenter(handle).dx, y));
      await tester.pump();
    }
    await gesture.moveTo(Offset(tester.getCenter(handle).dx, view.bottom + 40));
    await tester.pump();
    expect(find.textContaining(RegExp(r'^Page \d+$')), findsOneWidget, reason: 'page bubble while dragging');
    await gesture.up();
    await tester.pump();

    for (var i = 0; i < 5; i++) {
      await tester.pump();
    }
    // The end of the document fills the screen: last paragraph at the bottom.
    final last = find.textContaining('Paragraph 299.');
    expect(last, findsOneWidget);
    expect(tester.getBottomLeft(last).dy, greaterThan(view.bottom - 120));
    expect(tester.getBottomLeft(last).dy, lessThanOrEqualTo(view.bottom));
    expect(find.textContaining('Paragraph 296.'), findsOneWidget);

    // It fades out once idle.
    await tester.pump(const Duration(seconds: 2));
    await tester.pumpAndSettle();
    expect(
      tester.widget<AnimatedOpacity>(find.ancestor(of: handle, matching: find.byType(AnimatedOpacity))).opacity,
      0,
    );
  });

  testWidgets('the fast scroller moves steadily while scrolling by hand', (tester) async {
    final settings = await loadedSettings();
    // Very uneven paragraph lengths make the list's total height estimate jump.
    final doc = DocStructure(
      blocks: [
        for (var i = 0; i < 200; i++)
          ParagraphBlock(spans: [TextSpanData('Paragraph $i. ${'Lorem ipsum dolor sit amet. ' * (1 + (i * 7) % 23)}')]),
      ],
    );
    await tester.pumpWidget(host(ReflowView(doc: doc, settings: settings)));
    final handle = find.byKey(FastScroller.handleKey);
    var previous = -1.0;
    for (var i = 0; i < 25; i++) {
      await tester.drag(find.byType(Scrollable).first, const Offset(0, -250));
      await tester.pump();
      await tester.pump();
      final top = tester.getTopLeft(handle).dy;
      expect(top, greaterThanOrEqualTo(previous - 0.5), reason: 'handle went back up after scroll $i');
      previous = top;
    }
  });

  testWidgets('ReflowOutline lists headings with indentation and reports selection', (tester) async {
    final doc = sampleDoc();
    final outline = buildOutline(doc);
    expect(
      [for (final e in outline) '${e.level}:${e.text}@${e.blockIndex}'],
      ['1:Guide@0', '2:Setup@2', '2:Usage@5', '1:Appendix@9'],
    );

    final selected = <int>[];
    await tester.pumpWidget(host(ReflowOutline(doc: doc, onSelect: selected.add)));
    expect(find.text('Usage'), findsOneWidget);
    final guideX = tester.getTopLeft(find.text('Guide')).dx;
    final usageX = tester.getTopLeft(find.text('Usage')).dx;
    expect(usageX, greaterThan(guideX));
    await tester.tap(find.text('Usage'));
    expect(selected, [5]);
  });

  group('ReadingSettings', () {
    test('persists values via SharedPreferences', () async {
      SharedPreferences.setMockInitialValues({});
      final s = ReadingSettings();
      await s.load();
      expect(s.fontScale, 1.0);
      expect(s.theme, ReadingTheme.light);

      await s.setFontScale(1.5);
      await s.setLineHeight(2.0);
      await s.setFontFamily('serif');
      await s.setTextAlign(TextAlign.justify);
      await s.setMargin(ReadingMargin.wide);
      await s.setTheme(ReadingTheme.sepia);

      final again = ReadingSettings();
      await again.load();
      expect(again.fontScale, 1.5);
      expect(again.lineHeight, 2.0);
      expect(again.fontFamily, 'serif');
      expect(again.flutterFontFamily, 'serif');
      expect(again.textAlign, TextAlign.justify);
      expect(again.margin, ReadingMargin.wide);
      expect(again.theme, ReadingTheme.sepia);
    });

    test('loads initial values and clamps out-of-range input', () async {
      SharedPreferences.setMockInitialValues({
        'reflow.fontScale': 9.0,
        'reflow.lineHeight': 0.5,
        'reflow.fontFamily': 'mono',
        'reflow.theme': 'black',
      });
      final s = ReadingSettings();
      var notified = 0;
      s.addListener(() => notified++);
      await s.load();
      expect(s.fontScale, ReadingSettings.maxFontScale);
      expect(s.lineHeight, ReadingSettings.minLineHeight);
      expect(s.flutterFontFamily, 'monospace');
      expect(s.theme, ReadingTheme.black);
      expect(notified, 1);

      await s.setFontScale(0.1);
      expect(s.fontScale, ReadingSettings.minFontScale);
      await s.setFontFamily('sans');
      expect(s.flutterFontFamily, isNull);
      expect(() => s.setFontFamily('comic'), throwsArgumentError);
    });
  });

  testWidgets('settings sheet adjusts font size and theme', (tester) async {
    final settings = await loadedSettings();
    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (context) => Scaffold(
            body: Center(
              child: ElevatedButton(
                onPressed: () => ReadingSettingsSheet.show(context, settings),
                child: const Text('Aa'),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('Aa'));
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const ValueKey('reading-font-larger')));
    await tester.pump();
    expect(settings.fontScale, closeTo(1.1, 1e-9));

    Future<void> tapVisible(Finder f) async {
      await tester.ensureVisible(f);
      await tester.pumpAndSettle();
      await tester.tap(f);
    }

    await tapVisible(find.byKey(const ValueKey('reading-theme-dark')));
    await tester.pump();
    expect(settings.theme, ReadingTheme.dark);

    await tapVisible(find.text('Serif'));
    await tester.pump();
    expect(settings.fontFamily, 'serif');

    await tapVisible(find.text('Justify'));
    await tester.pump();
    expect(settings.textAlign, TextAlign.justify);

    await tapVisible(find.text('Wide'));
    await tester.pump();
    expect(settings.margin, ReadingMargin.wide);

    final prefs = await SharedPreferences.getInstance();
    expect(prefs.getString('reflow.theme'), 'dark');
  });
}
