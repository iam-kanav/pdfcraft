import 'package:flutter/material.dart';

import 'tool_registry.dart';

/// "All tools" tab, grouped like Acrobat's tool center.
class ToolsScreen extends StatelessWidget {
  const ToolsScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('All tools')),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(16, 8, 16, 32),
        children: [
          for (final cat in ToolCategory.values) ...[
            Padding(
              padding: const EdgeInsets.fromLTRB(4, 16, 4, 8),
              child: Text(cat.label, style: Theme.of(context).textTheme.titleSmall?.copyWith(fontWeight: FontWeight.w600)),
            ),
            LayoutBuilder(
              builder: (context, c) {
                final tools = ToolRegistry.all.where((t) => t.category == cat).toList();
                final cols = c.maxWidth > 600 ? 3 : 2;
                return GridView.count(
                  crossAxisCount: cols,
                  shrinkWrap: true,
                  physics: const NeverScrollableScrollPhysics(),
                  crossAxisSpacing: 10,
                  mainAxisSpacing: 10,
                  childAspectRatio: cols == 2 ? 2.15 : 2.6,
                  children: [for (final t in tools) ToolTile(tool: t, onTap: () => t.launch(context))],
                );
              },
            ),
          ],
        ],
      ),
    );
  }
}
