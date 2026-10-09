import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../core/library/library_store.dart';
import '../common/doc_widgets.dart';
import '../common/open_actions.dart';
import 'package:material_symbols_icons/symbols.dart';

class StarredScreen extends StatelessWidget {
  const StarredScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final starred = context.watch<LibraryStore>().starred;
    return Scaffold(
      appBar: AppBar(title: const Text('Starred')),
      body: starred.isEmpty
          ? const EmptyState(
              icon: Symbols.star_border_rounded,
              title: 'No starred files',
              message: 'Star files you use often to find them quickly.',
            )
          : ListView.builder(
              itemCount: starred.length,
              itemBuilder: (context, i) =>
                  DocListTile(path: starred[i].path, onTap: () => openDocument(context, starred[i].path)),
            ),
    );
  }
}
