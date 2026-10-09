import 'package:flutter/material.dart';

import '../common/open_actions.dart';
import '../convert/create_pdf_screen.dart';
import '../files/files_screen.dart';
import '../home/home_screen.dart';
import '../home/starred_screen.dart';
import '../organize/combine_screen.dart';
import '../scanner/scanner_screen.dart';
import '../tools/tools_screen.dart';

/// Bottom-navigation shell: Home · Files · Tools · Starred, with a create (+) button.
class MainShell extends StatefulWidget {
  const MainShell({super.key});

  @override
  State<MainShell> createState() => _MainShellState();
}

class _MainShellState extends State<MainShell> {
  int _tab = 0;

  void _showCreate() {
    showModalBottomSheet<void>(
      context: context,
      builder: (ctx) {
        Widget item(IconData icon, String label, String sub, VoidCallback onTap) => ListTile(
          leading: CircleAvatar(backgroundColor: Theme.of(ctx).colorScheme.primary.withValues(alpha: 0.1), child: Icon(icon, color: Theme.of(ctx).colorScheme.primary)),
          title: Text(label),
          subtitle: Text(sub),
          onTap: () {
            Navigator.pop(ctx);
            onTap();
          },
        );
        return SafeArea(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              item(Icons.document_scanner_outlined, 'Scan', 'Use the camera to scan documents', () => Navigator.of(context).push(MaterialPageRoute(builder: (_) => const ScannerScreen()))),
              item(Icons.note_add_outlined, 'Create PDF', 'From images or documents', () => Navigator.of(context).push(MaterialPageRoute(builder: (_) => const CreatePdfScreen()))),
              item(Icons.merge_type, 'Combine files', 'Merge several PDFs', () => Navigator.of(context).push(MaterialPageRoute(builder: (_) => const CombineScreen()))),
              item(Icons.folder_open_outlined, 'Open a file', 'Browse files on this device', () => pickAndOpenPdf(context)),
            ],
          ),
        );
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    final pages = [
      const HomeScreen(),
      const FilesScreen(),
      const ToolsScreen(),
      const StarredScreen(),
    ];
    return Scaffold(
      body: IndexedStack(index: _tab, children: pages),
      floatingActionButton: _tab <= 1 ? FloatingActionButton(tooltip: 'Create', onPressed: _showCreate, child: const Icon(Icons.add, size: 30)) : null,
      bottomNavigationBar: NavigationBar(
        selectedIndex: _tab,
        onDestinationSelected: (i) => setState(() => _tab = i),
        destinations: const [
          NavigationDestination(icon: Icon(Icons.home_outlined), selectedIcon: Icon(Icons.home), label: 'Home'),
          NavigationDestination(icon: Icon(Icons.folder_outlined), selectedIcon: Icon(Icons.folder), label: 'Files'),
          NavigationDestination(icon: Icon(Icons.apps_outlined), selectedIcon: Icon(Icons.apps), label: 'Tools'),
          NavigationDestination(icon: Icon(Icons.star_border_rounded), selectedIcon: Icon(Icons.star_rounded), label: 'Starred'),
        ],
      ),
    );
  }
}
