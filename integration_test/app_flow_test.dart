import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:material_symbols_icons/symbols.dart';
import 'package:path/path.dart' as p;
import 'package:pdfcraft/app.dart';
import 'package:pdfcraft/core/services.dart';
import 'package:pdfcraft/features/viewer/viewer_screen.dart';
import 'package:pdfrx/pdfrx.dart';

import 'samples.dart';

/// Pumps frames until [finder] matches (or fails after [timeout]).
Future<void> pumpUntil(WidgetTester tester, Finder finder, {Duration timeout = const Duration(seconds: 20)}) async {
  final end = DateTime.now().add(timeout);
  while (DateTime.now().isBefore(end)) {
    await tester.pump(const Duration(milliseconds: 100));
    if (finder.evaluate().isNotEmpty) return;
  }
  throw TestFailure('Timed out waiting for $finder');
}

Future<void> popRoute(WidgetTester tester) async {
  tester.state<NavigatorState>(find.byType(Navigator).first).pop();
}

Future<void> settle(WidgetTester tester, [int frames = 10]) async {
  for (var i = 0; i < frames; i++) {
    await tester.pump(const Duration(milliseconds: 100));
  }
}

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('main navigation, viewer modes, tools and smart reading', (tester) async {
    await pdfrxFlutterInitialize();
    final services = await AppServices.init();
    final samples = Samples(services.files.root);
    final name = 'UI Flow ${DateTime.now().millisecondsSinceEpoch}.pdf';
    final path = await samples.textDoc(name: name);
    services.library.markOpened(path, pageCount: 3);

    await tester.pumpWidget(PdfCraftApp(services: services, handleIntents: false));
    await pumpUntil(tester, find.text('Welcome'));

    // Home lists the recent document.
    final title = p.basenameWithoutExtension(path);
    await pumpUntil(tester, find.text(title));

    // Bottom navigation.
    await tester.tap(find.text('Files'));
    await settle(tester);
    expect(find.text('On this device'), findsOneWidget);
    await tester.tap(find.text('My Files').first);
    await pumpUntil(tester, find.text(title));
    await tester.tap(find.byType(BackButton).first);
    await settle(tester);

    await tester.tap(find.text('Tools'));
    await settle(tester);
    expect(find.text('All tools'), findsOneWidget);
    expect(find.text('Organize pages'), findsOneWidget);

    await tester.tap(find.text('Search'));
    await settle(tester);
    await tester.enterText(find.byType(TextField).last, 'UI Flow');
    await settle(tester, 15);
    expect(find.text(title), findsWidgets);

    await tester.tap(find.text('Home'));
    await settle(tester);

    // Open the document in the viewer.
    await tester.tap(find.text(title).first);
    await pumpUntil(tester, find.byType(ViewerScreen));
    await pumpUntil(tester, find.text('More tools'));
    await settle(tester, 20);

    // Overflow sheet.
    await tester.tap(find.byTooltip('More'));
    await settle(tester);
    expect(find.text('Bookmarks & Table of Contents'), findsOneWidget);
    expect(find.text('Document properties'), findsOneWidget);
    await tester.tapAt(const Offset(200, 120));
    await settle(tester);

    // In-document search.
    await tester.tap(find.byTooltip('Search'));
    await settle(tester);
    await tester.enterText(find.byType(TextField).first, 'SECRET');
    await pumpUntil(tester, find.textContaining('of 3'));
    await tester.tap(find.byIcon(Symbols.arrow_back).first);
    await settle(tester);

    // Comment mode from the quick tools bar, then back.
    await tester.tap(find.text('Comment'));
    await settle(tester);
    expect(find.text('Sticky note'), findsOneWidget);
    await tester.tap(find.byTooltip('Done'));
    await settle(tester);

    // Fill & Sign mode.
    await tester.tap(find.text('Fill & Sign'));
    await settle(tester);
    expect(find.text('Tap a form field to fill it, or choose a tool'), findsOneWidget);
    await tester.tap(find.byTooltip('Done'));
    await settle(tester);

    // More tools → Edit PDF mode shows the edit toolbar.
    await tester.tap(find.text('More tools'));
    await settle(tester);
    await tester.tap(find.text('Edit PDF').last);
    await settle(tester, 20);
    expect(find.text('Add text'), findsOneWidget);
    await tester.tap(find.byTooltip('Done'));
    await settle(tester);

    // More tools → Organize pages screen.
    await tester.tap(find.text('More tools'));
    await settle(tester);
    await tester.tap(find.text('Organize pages').last);
    await pumpUntil(tester, find.text('Insert'));
    expect(find.text('1'), findsWidgets);
    await popRoute(tester);
    await settle(tester, 15);

    // Smart reading mode.
    await tester.tap(find.byTooltip('Smart reading mode'));
    await pumpUntil(tester, find.text('Chapter 1 Heading'));
    expect(find.textContaining('Hello World page 1'), findsWidgets);
    await popRoute(tester);
    await settle(tester, 15);

    // Bookmark the page through the overflow sheet and check the library recorded it.
    await tester.tap(find.byTooltip('More'));
    await settle(tester);
    await tester.tap(find.text('Add bookmark'));
    await settle(tester, 15);
    expect(services.library.peek(path)!.bookmarks, isNotEmpty);

    await popRoute(tester);
    await settle(tester);
    expect(find.text('Welcome'), findsOneWidget);
    File(path).deleteSync();
  });
}
