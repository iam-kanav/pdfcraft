import 'package:flutter/material.dart';
import 'package:material_symbols_icons/symbols.dart';

import '../common/open_actions.dart';
import '../convert/create_pdf_screen.dart';
import '../files/files_screen.dart';
import '../home/home_screen.dart';
import '../home/search_screen.dart';
import '../organize/combine_screen.dart';
import '../scanner/scanner_screen.dart';
import '../tools/tools_screen.dart';

/// Bottom-navigation shell modelled on Acrobat: Home · Files · Tools · Search, with a blue (+) button.
class MainShell extends StatefulWidget {
  const MainShell({super.key});

  @override
  State<MainShell> createState() => _MainShellState();
}

class _MainShellState extends State<MainShell> {
  int _tab = 0;
  final _searchKey = GlobalKey<SearchScreenState>();

  void _showCreate() {
    showModalBottomSheet<void>(
      context: context,
      builder: (ctx) {
        Widget item(IconData icon, String label, VoidCallback onTap) => ListTile(
          leading: Icon(icon),
          title: Text(label),
          onTap: () {
            Navigator.pop(ctx);
            onTap();
          },
        );
        return SafeArea(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              item(Symbols.document_scanner, 'Scan a document', () => Navigator.of(context).push(MaterialPageRoute(builder: (_) => const ScannerScreen()))),
              item(Symbols.note_add, 'Create a PDF', () => Navigator.of(context).push(MaterialPageRoute(builder: (_) => const CreatePdfScreen()))),
              item(Symbols.picture_as_pdf, 'Combine files', () => Navigator.of(context).push(MaterialPageRoute(builder: (_) => const CombineScreen()))),
              item(Symbols.folder_open, 'Open a file', () => pickAndOpenPdf(context)),
              const SizedBox(height: 8),
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
      SearchScreen(key: _searchKey, embedded: true),
    ];
    return Scaffold(
      body: IndexedStack(index: _tab, children: pages),
      floatingActionButton: _tab <= 1 ? FloatingActionButton(tooltip: 'Create', onPressed: _showCreate, child: const Icon(Symbols.add, weight: 400)) : null,
      bottomNavigationBar: DecoratedBox(
        decoration: BoxDecoration(border: Border(top: BorderSide(color: Theme.of(context).dividerColor))),
        child: BottomNavigationBar(
          currentIndex: _tab,
          onTap: (i) {
            setState(() => _tab = i);
            if (i == 3) _searchKey.currentState?.focus();
          },
          items: const [
            BottomNavigationBarItem(icon: Icon(Symbols.home), label: 'Home'),
            BottomNavigationBarItem(icon: Icon(Symbols.description), label: 'Files'),
            BottomNavigationBarItem(icon: Icon(Symbols.apps), label: 'Tools'),
            BottomNavigationBarItem(icon: Icon(Symbols.search), label: 'Search'),
          ],
        ),
      ),
    );
  }
}
