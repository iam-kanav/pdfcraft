import 'package:flutter/material.dart';
import 'package:material_symbols_icons/symbols.dart';
import 'package:provider/provider.dart';

import '../../core/library/library_store.dart';
import '../../theme/app_theme.dart';
import '../common/brand_widgets.dart';
import '../common/doc_widgets.dart';
import '../common/open_actions.dart';
import '../settings/settings_screen.dart';
import '../tools/tool_registry.dart';

/// Acrobat-style Home: "Welcome", feature cards, Recent / Starred tabs.
class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key});

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> with SingleTickerProviderStateMixin {
  late final _tabs = TabController(length: 2, vsync: this)..addListener(() => setState(() {}));

  static const _cards = [
    ('scan', 'Scan a document', 'Turn paper into a searchable PDF with your camera.', 'Scan now', Brand.scan),
    ('edit', 'Easily edit PDFs', 'Fix typos, change images and add text right on the page.', 'Edit now', Brand.edit),
    ('fillsign', 'Fill & sign forms', 'Complete forms and add your signature in seconds.', 'Try now', Brand.sign),
    ('combine', 'Combine files', 'Merge several PDFs into one document.', 'Combine', Brand.organize),
  ];

  @override
  Widget build(BuildContext context) {
    final lib = context.watch<LibraryStore>();
    final list = _tabs.index == 0 ? lib.recents : lib.starred;
    final theme = Theme.of(context);
    return Scaffold(
      appBar: AppBar(
        titleSpacing: 16,
        title: const AppLogo(size: 26),
        actions: [
          IconButton(
            tooltip: 'Settings',
            icon: const Icon(Symbols.account_circle),
            onPressed: () => Navigator.of(context).push(MaterialPageRoute(builder: (_) => const SettingsScreen())),
          ),
          const SizedBox(width: 4),
        ],
      ),
      body: RefreshIndicator(
        onRefresh: () async => lib.load(),
        child: CustomScrollView(
          slivers: [
            SliverToBoxAdapter(
              child: Padding(
                padding: const EdgeInsets.fromLTRB(16, 12, 16, 12),
                child: Text('Welcome', style: theme.textTheme.headlineSmall),
              ),
            ),
            SliverToBoxAdapter(
              child: SizedBox(
                height: 112,
                child: ListView.separated(
                  scrollDirection: Axis.horizontal,
                  padding: const EdgeInsets.symmetric(horizontal: 16),
                  itemCount: _cards.length,
                  separatorBuilder: (_, _) => const SizedBox(width: 12),
                  itemBuilder: (context, i) {
                    final (id, title, body, action, color) = _cards[i];
                    return _FeatureCard(
                      title: title,
                      body: body,
                      action: action,
                      color: color,
                      icon: ToolRegistry.byId(id).icon,
                      onTap: () => ToolRegistry.byId(id).launch(context),
                    );
                  },
                ),
              ),
            ),
            SliverToBoxAdapter(
              child: Padding(
                padding: const EdgeInsets.fromLTRB(16, 16, 4, 0),
                child: Row(
                  children: [
                    Expanded(
                      child: TabBar(
                        controller: _tabs,
                        isScrollable: true,
                        tabAlignment: TabAlignment.start,
                        labelPadding: const EdgeInsets.only(right: 24),
                        indicatorSize: TabBarIndicatorSize.label,
                        tabs: const [
                          Tab(text: 'Recent', height: 40),
                          Tab(text: 'Starred', height: 40),
                        ],
                      ),
                    ),
                    PopupMenuButton<String>(
                      icon: const Icon(Symbols.more_vert),
                      onSelected: (v) => lib.clearRecents(),
                      itemBuilder: (_) => const [PopupMenuItem(value: 'clear', child: Text('Clear recent files'))],
                    ),
                  ],
                ),
              ),
            ),
            const SliverToBoxAdapter(child: Divider(indent: 16, endIndent: 16)),
            if (list.isEmpty)
              SliverFillRemaining(
                hasScrollBody: false,
                child: _tabs.index == 0
                    ? EmptyState(
                        icon: Symbols.picture_as_pdf,
                        title: 'No recent files',
                        message: 'Files you open will appear here.',
                        action: FilledButton(
                          onPressed: () => pickAndOpenPdf(context),
                          child: const Text('Open a file'),
                        ),
                      )
                    : const EmptyState(
                        icon: Symbols.star,
                        title: 'No starred files',
                        message: 'Star files to find them quickly.',
                      ),
              )
            else
              SliverList.builder(
                itemCount: list.length,
                itemBuilder: (context, i) => DocListTile(
                  path: list[i].path,
                  showRecentActions: _tabs.index == 0,
                  onTap: () => openDocument(context, list[i].path),
                ),
              ),
            const SliverToBoxAdapter(child: SizedBox(height: 96)),
          ],
        ),
      ),
    );
  }
}

class _FeatureCard extends StatelessWidget {
  const _FeatureCard({
    required this.title,
    required this.body,
    required this.action,
    required this.color,
    required this.icon,
    required this.onTap,
  });

  final String title;
  final String body;
  final String action;
  final Color color;
  final IconData icon;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Material(
      color: theme.colorScheme.surface,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(4),
        side: BorderSide(color: theme.dividerColor),
      ),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: onTap,
        child: SizedBox(
          width: 300,
          child: Row(
            children: [
              Container(
                width: 82,
                color: theme.brightness == Brightness.dark
                    ? color.withValues(alpha: 0.25)
                    : Brand.tileBackground(color),
                alignment: Alignment.center,
                child: Icon(icon, size: 40, color: color, weight: 300),
              ),
              Expanded(
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(12, 10, 12, 8),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(title, style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w600)),
                      const SizedBox(height: 2),
                      Expanded(
                        child: Text(
                          body,
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(fontSize: 13.5, height: 1.25, color: theme.colorScheme.onSurfaceVariant),
                        ),
                      ),
                      Align(
                        alignment: Alignment.bottomRight,
                        child: Text(
                          action,
                          style: TextStyle(color: theme.colorScheme.primary, fontWeight: FontWeight.w600, fontSize: 14),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
