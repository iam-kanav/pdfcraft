import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pdfcraft/features/reflow/reading_settings.dart';
import 'package:pdfcraft/features/reflow/reflow_screen.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// A fake page: a heading and a paragraph naming the page.
Map<String, Object?> fakePage(int index) {
  final n = index + 1;
  Map<String, Object?> line(String text, double size, double y) => {
    'x0': 50.0,
    'y0': y,
    'x1': 400.0,
    'y1': y + size,
    'spans': [
      {'text': text, 'size': size, 'x0': 50.0, 'x1': 400.0, 'bold': size > 12},
    ],
  };
  return {
    'page': n,
    'width': 600.0,
    'height': 800.0,
    'lines': [
      line('Chapter $n', 20, 60),
      for (var k = 0; k < 6; k++)
        line('Text of page $n, line $k, with enough words to wrap a bit.', 11, 100.0 + k * 14),
    ],
    'images': const [],
  };
}

void main() {
  late Directory tmp;
  final calls = <List<int>>[];

  setUp(() {
    tmp = Directory.systemTemp.createTempSync('reflow_screen');
    calls.clear();
    SharedPreferences.setMockInitialValues({});
    final messenger = TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(const MethodChannel('pdfcraft/engine'), (call) async {
      final args = call.arguments as Map;
      return switch (call.method) {
        'info' => {'pageCount': 300, 'encrypted': false, 'version': 1.7},
        'extractPages' => () {
          final pages = (args['pages'] as List).cast<int>();
          calls.add(pages);
          return [for (final p in pages) fakePage(p)];
        }(),
        _ => null,
      };
    });
    messenger.setMockMethodCallHandler(
      const MethodChannel('plugins.flutter.io/path_provider'),
      (call) async => tmp.path,
    );
    messenger.setMockMethodCallHandler(const MethodChannel('flutter_tts'), (call) async => 1);
  });

  tearDown(() => tmp.deleteSync(recursive: true));

  Future<void> loadAll(WidgetTester tester) async {
    for (var i = 0; i < 200; i++) {
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 20)));
      await tester.pump();
      if (find.byType(LinearProgressIndicator).evaluate().isEmpty &&
          find.textContaining('Chapter').evaluate().isNotEmpty) {
        break;
      }
    }
    await tester.pumpAndSettle();
  }

  Future<int?> openAt(WidgetTester tester, int page) async {
    final settings = ReadingSettings();
    await settings.load();
    int? popped;
    await tester.pumpWidget(
      ChangeNotifierProvider.value(
        value: settings,
        child: MaterialApp(
          home: Builder(
            builder: (context) => TextButton(
              onPressed: () async {
                popped = await Navigator.of(context).push<int>(
                  MaterialPageRoute(
                    builder: (_) => ReflowScreen(path: '/doc.pdf', startPage: page),
                  ),
                );
              },
              child: const Text('open'),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('open'));
    await loadAll(tester);
    return popped;
  }

  /// Top of the first chapter heading on screen.
  String topChapter(WidgetTester tester) {
    final shown = find.textContaining(RegExp(r'^Chapter \d+$')).evaluate().toList()
      ..sort(
        (a, b) =>
            tester.getTopLeft(find.byWidget(a.widget)).dy.compareTo(tester.getTopLeft(find.byWidget(b.widget)).dy),
      );
    final visible = shown.where((e) => tester.getBottomLeft(find.byWidget(e.widget)).dy > 80);
    return (visible.first.widget as Text).data ?? (visible.first.widget as Text).textSpan!.toPlainText();
  }

  testWidgets('opens at the page being read and stays there as the rest loads', (tester) async {
    await openAt(tester, 200);
    expect(calls.first.first, 199, reason: 'the start page is extracted first');
    expect(calls.expand((c) => c).length, 300, reason: 'every page loaded');
    expect(topChapter(tester), 'Chapter 200');
  });

  testWidgets('reopens from the saved result at the page being read', (tester) async {
    final file = File('${tmp.path}/doc.pdf')..writeAsStringSync('pdf');
    Future<void> open(int page) async {
      await tester.pumpWidget(const SizedBox());
      final settings = ReadingSettings();
      await settings.load();
      await tester.pumpWidget(
        ChangeNotifierProvider.value(
          value: settings,
          child: MaterialApp(
            home: ReflowScreen(path: file.path, startPage: page),
          ),
        ),
      );
      await loadAll(tester);
    }

    await open(200);
    // Let the cache write finish.
    for (var i = 0; i < 50 && !tmp.listSync(recursive: true).any((e) => e.path.endsWith('.bin')); i++) {
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 20)));
    }
    calls.clear();
    await open(150);
    expect(calls, isEmpty, reason: 'loaded from the saved result');
    expect(topChapter(tester), 'Chapter 150');
  });
}
