import 'package:flutter/material.dart';

import 'tool_registry.dart';

/// "All tools" tab laid out like Acrobat's tool grid.
class ToolsScreen extends StatelessWidget {
  const ToolsScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Scaffold(
      appBar: AppBar(toolbarHeight: 8),
      body: ListView(
        padding: const EdgeInsets.only(bottom: 32),
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 8),
            child: Text('All tools', style: theme.textTheme.headlineSmall),
          ),
          for (final cat in ToolCategory.values) ...[
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
              child: Text(cat.label, style: theme.textTheme.titleSmall),
            ),
            LayoutBuilder(
              builder: (context, c) {
                final tools = ToolRegistry.all.where((t) => t.category == cat).toList();
                final cols = (c.maxWidth / 92).floor().clamp(3, 6);
                final w = (c.maxWidth - 16) / cols;
                return Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 8),
                  child: Wrap(
                    children: [for (final t in tools) ToolChip(tool: t, width: w, onTap: () => t.launch(context))],
                  ),
                );
              },
            ),
          ],
        ],
      ),
    );
  }
}
