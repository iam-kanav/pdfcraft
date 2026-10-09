import 'dart:io';

import 'package:flutter/material.dart';
import 'package:path_provider/path_provider.dart';
import 'package:provider/provider.dart';

import '../../core/app_settings.dart';
import '../../core/native/platform_bridge.dart';
import '../../core/services.dart';
import '../../core/util/format.dart';
import '../common/dialogs.dart';
import 'package:material_symbols_icons/symbols.dart';

class SettingsScreen extends StatefulWidget {
  const SettingsScreen({super.key});

  @override
  State<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends State<SettingsScreen> {
  int? _cacheBytes;
  int? _libraryBytes;
  bool? _allFiles;

  @override
  void initState() {
    super.initState();
    _measure();
  }

  Future<int> _dirSize(Directory d) async {
    var total = 0;
    if (!await d.exists()) return 0;
    await for (final e in d.list(recursive: true, followLinks: false)) {
      if (e is File) total += await e.length();
    }
    return total;
  }

  Future<void> _measure() async {
    final cache = await getTemporaryDirectory();
    final c = await _dirSize(cache);
    final l = await _dirSize(AppServices.instance.files.root);
    final a = await PlatformBridge.instance.hasAllFilesAccess();
    if (mounted) {
      setState(() {
        _cacheBytes = c;
        _libraryBytes = l;
        _allFiles = a;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final s = context.watch<AppSettings>();
    return Scaffold(
      appBar: AppBar(title: const Text('Settings')),
      body: ListView(
        children: [
          const _Header('Appearance'),
          ListTile(
            leading: const Icon(Symbols.brightness_6),
            title: const Text('Theme'),
            trailing: DropdownButton<ThemeMode>(
              value: s.themeMode,
              underline: const SizedBox(),
              onChanged: (v) => s.themeMode = v!,
              items: const [
                DropdownMenuItem(value: ThemeMode.system, child: Text('System')),
                DropdownMenuItem(value: ThemeMode.light, child: Text('Light')),
                DropdownMenuItem(value: ThemeMode.dark, child: Text('Dark')),
              ],
            ),
          ),
          SwitchListTile(
            secondary: const Icon(Symbols.dark_mode),
            title: const Text('Night mode for pages'),
            value: s.nightPages,
            onChanged: (v) => s.nightPages = v,
          ),
          ListTile(
            leading: const Icon(Symbols.view_day),
            title: const Text('Page layout'),
            trailing: DropdownButton<PageScrollMode>(
              value: s.scrollMode,
              underline: const SizedBox(),
              onChanged: (v) => s.scrollMode = v!,
              items: const [
                DropdownMenuItem(value: PageScrollMode.continuous, child: Text('Continuous')),
                DropdownMenuItem(value: PageScrollMode.singlePage, child: Text('Single page')),
              ],
            ),
          ),
          const _Header('Commenting'),
          ListTile(
            leading: const Icon(Symbols.person_outline),
            title: const Text('Author name'),
            subtitle: Text(s.authorName),
            onTap: () async {
              final v = await showTextInputDialog(context, title: 'Author name', initial: s.authorName);
              if (v != null && v.trim().isNotEmpty) s.authorName = v.trim();
            },
          ),
          const _Header('Storage'),
          ListTile(
            leading: const Icon(Symbols.folder),
            title: const Text('My Files'),
            subtitle: Text(_libraryBytes == null ? '…' : formatBytes(_libraryBytes!)),
          ),
          ListTile(
            leading: const Icon(Symbols.cleaning_services),
            title: const Text('Clear cache'),
            subtitle: Text(_cacheBytes == null ? '…' : formatBytes(_cacheBytes!)),
            onTap: () async {
              final cache = await getTemporaryDirectory();
              await for (final e in cache.list()) {
                try {
                  await e.delete(recursive: true);
                } catch (_) {}
              }
              await AppServices.instance.tempDir.create(recursive: true);
              if (context.mounted) showSnack(context, 'Cache cleared');
              _measure();
            },
          ),
          ListTile(
            leading: const Icon(Symbols.phone_android),
            title: const Text('All files access'),
            subtitle: Text(
              _allFiles == true
                  ? 'Allowed — PDFs anywhere on the device are listed'
                  : 'Not allowed — only files you open or import',
            ),
            trailing: _allFiles == true
                ? const Icon(Symbols.check, color: Colors.green)
                : TextButton(onPressed: PlatformBridge.instance.requestAllFilesAccess, child: const Text('Allow')),
          ),
          const _Header('About'),
          const ListTile(
            leading: Icon(Symbols.offline_bolt),
            title: Text('Works offline'),
            subtitle: Text(
              'All processing — reading, editing, OCR, conversion and encryption — happens on this device. No account and no cloud.',
            ),
          ),
          const AboutListTile(
            icon: Icon(Symbols.info),
            applicationName: 'PDFCraft',
            applicationVersion: '1.0.0',
            applicationLegalese:
                'Uses PDFium (pdfrx), PDFBox-Android, Google ML Kit on-device text recognition and Noto fonts.',
          ),
        ],
      ),
    );
  }
}

class _Header extends StatelessWidget {
  const _Header(this.text);

  final String text;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.fromLTRB(16, 20, 16, 4),
    child: Text(
      text,
      style: Theme.of(context).textTheme.labelLarge?.copyWith(color: Theme.of(context).colorScheme.primary),
    ),
  );
}
