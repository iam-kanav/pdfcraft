import 'dart:async';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import 'core/app_settings.dart';
import 'core/library/library_store.dart';
import 'core/native/platform_bridge.dart';
import 'core/services.dart';
import 'features/common/open_actions.dart';
import 'features/reflow/reading_settings.dart';
import 'features/shell/main_shell.dart';
import 'theme/app_theme.dart';

final navigatorKey = GlobalKey<NavigatorState>();

class PdfCraftApp extends StatefulWidget {
  const PdfCraftApp({super.key, required this.services, this.handleIntents = true});

  final AppServices services;
  final bool handleIntents;

  @override
  State<PdfCraftApp> createState() => _PdfCraftAppState();
}

class _PdfCraftAppState extends State<PdfCraftApp> {
  StreamSubscription<List<IncomingFile>>? _sub;

  @override
  void initState() {
    super.initState();
    if (widget.handleIntents) {
      WidgetsBinding.instance.addPostFrameCallback((_) async {
        _sub = PlatformBridge.instance.incomingFiles.listen(_handleIncoming);
        final initial = await PlatformBridge.instance.takeInitialFiles();
        if (initial.isNotEmpty) _handleIncoming(initial);
      });
    }
  }

  void _handleIncoming(List<IncomingFile> files) {
    final ctx = navigatorKey.currentContext;
    if (ctx == null) return;
    handleIncomingFiles(ctx, files);
  }

  @override
  void dispose() {
    _sub?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final s = widget.services;
    return MultiProvider(
      providers: [
        Provider<AppServices>.value(value: s),
        ChangeNotifierProvider<AppSettings>.value(value: s.settings),
        ChangeNotifierProvider<LibraryStore>.value(value: s.library),
        ChangeNotifierProvider<ReadingSettings>.value(value: s.reading),
      ],
      child: Consumer<AppSettings>(
        builder: (context, settings, _) => MaterialApp(
          navigatorKey: navigatorKey,
          title: 'PDFCraft',
          debugShowCheckedModeBanner: false,
          theme: buildTheme(Brightness.light),
          darkTheme: buildTheme(Brightness.dark),
          themeMode: settings.themeMode,
          home: const MainShell(),
        ),
      ),
    );
  }
}
