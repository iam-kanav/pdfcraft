import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../core/library/library_store.dart';
import '../../core/services.dart';
import '../../theme/app_theme.dart';
import '../common/doc_widgets.dart';
import '../common/open_actions.dart';
import '../settings/settings_screen.dart';
import '../tools/tool_registry.dart';
import 'search_screen.dart';

class HomeScreen extends StatelessWidget {
  const HomeScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final lib = context.watch<LibraryStore>();
    final recents = lib.recents;
    final settings = AppServices.instance.settings;
    final quickIds = [...settings.recentTools.where(ToolRegistry.quickIds.contains), ...ToolRegistry.quickIds];
    final quick = {for (final id in quickIds) id}.map(ToolRegistry.byId).toList();
    return Scaffold(
      appBar: AppBar(
        titleSpacing: 16,
        title: Row(
          children: [
            Container(
              width: 32,
              height: 32,
              decoration: BoxDecoration(color: Brand.red, borderRadius: BorderRadius.circular(8)),
              alignment: Alignment.center,
              child: const Text('P', style: TextStyle(color: Colors.white, fontWeight: FontWeight.w700, fontSize: 18)),
            ),
            const SizedBox(width: 10),
            const Text('PDFCraft'),
          ],
        ),
        actions: [
          IconButton(tooltip: 'Search', icon: const Icon(Icons.search), onPressed: () => Navigator.of(context).push(MaterialPageRoute(builder: (_) => const SearchScreen()))),
          IconButton(tooltip: 'Settings', icon: const Icon(Icons.settings_outlined), onPressed: () => Navigator.of(context).push(MaterialPageRoute(builder: (_) => const SettingsScreen()))),
        ],
      ),
      body: RefreshIndicator(
        onRefresh: () async => lib.load(),
        child: CustomScrollView(
          slivers: [
            SliverToBoxAdapter(
              child: Padding(
                padding: const EdgeInsets.fromLTRB(16, 16, 16, 4),
                child: Text('Recommended tools', style: Theme.of(context).textTheme.titleSmall?.copyWith(fontWeight: FontWeight.w600)),
              ),
            ),
            SliverToBoxAdapter(
              child: SizedBox(
                height: 96,
                child: ListView(
                  scrollDirection: Axis.horizontal,
                  padding: const EdgeInsets.symmetric(horizontal: 8),
                  children: [for (final t in quick) ToolChip(tool: t, onTap: () => t.launch(context))],
                ),
              ),
            ),
            SliverToBoxAdapter(
              child: Padding(
                padding: const EdgeInsets.fromLTRB(16, 12, 8, 4),
                child: Row(
                  children: [
                    Text('Recent', style: Theme.of(context).textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w600)),
                    const Spacer(),
                    if (recents.isNotEmpty)
                      PopupMenuButton<String>(
                        icon: const Icon(Icons.more_horiz),
                        onSelected: (v) => lib.clearRecents(),
                        itemBuilder: (_) => const [PopupMenuItem(value: 'clear', child: Text('Clear recent files'))],
                      ),
                  ],
                ),
              ),
            ),
            if (recents.isEmpty)
              SliverFillRemaining(
                hasScrollBody: false,
                child: EmptyState(
                  icon: Icons.picture_as_pdf_outlined,
                  title: 'No recent files',
                  message: 'Open a PDF from your device or scan a document to get started.',
                  action: Wrap(
                    spacing: 8,
                    children: [
                      FilledButton.icon(onPressed: () => pickAndOpenPdf(context), icon: const Icon(Icons.folder_open), label: const Text('Open file')),
                      OutlinedButton.icon(onPressed: () => ToolRegistry.byId('scan').launch(context), icon: const Icon(Icons.document_scanner_outlined), label: const Text('Scan')),
                    ],
                  ),
                ),
              )
            else
              SliverList.builder(
                itemCount: recents.length,
                itemBuilder: (context, i) {
                  final r = recents[i];
                  return DocListTile(path: r.path, showRecentActions: true, onTap: () => openDocument(context, r.path));
                },
              ),
            const SliverToBoxAdapter(child: SizedBox(height: 96)),
          ],
        ),
      ),
    );
  }
}
