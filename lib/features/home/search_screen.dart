import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:material_symbols_icons/symbols.dart';
import 'package:path/path.dart' as p;

import '../../core/native/platform_bridge.dart';
import '../../core/services.dart';
import '../common/doc_widgets.dart';
import '../common/open_actions.dart';

/// Search tab: finds files by name across PDFCraft, recents and (if allowed) the whole device.
class SearchScreen extends StatefulWidget {
  const SearchScreen({super.key, this.embedded = false});

  /// True when shown as a bottom-navigation tab (no back button).
  final bool embedded;

  @override
  State<SearchScreen> createState() => SearchScreenState();
}

class SearchScreenState extends State<SearchScreen> {
  final _controller = TextEditingController();
  final _focus = FocusNode();
  Timer? _debounce;
  List<String> _results = [];
  bool _searching = false;
  List<String>? _devicePdfs;

  void focus() => _focus.requestFocus();

  @override
  void initState() {
    super.initState();
    PlatformBridge.instance.hasAllFilesAccess().then((ok) async {
      if (!ok) return;
      final list = await PlatformBridge.instance.scanDevicePdfs();
      _devicePdfs = list.map((e) => e.path).toList();
    });
  }

  @override
  void dispose() {
    _debounce?.cancel();
    _controller.dispose();
    _focus.dispose();
    super.dispose();
  }

  Future<void> _search(String q) async {
    final query = q.trim().toLowerCase();
    if (query.isEmpty) {
      setState(() => _results = []);
      return;
    }
    setState(() => _searching = true);
    final services = AppServices.instance;
    final lib = await services.files.search(query);
    final recents = services.library.recents
        .map((r) => r.path)
        .where((f) => p.basename(f).toLowerCase().contains(query));
    final device = (_devicePdfs ?? const []).where((f) => p.basename(f).toLowerCase().contains(query));
    final all = <String>{
      ...recents,
      ...lib.where((e) => !e.isDirectory).map((e) => e.path),
      ...device,
    }.where((f) => File(f).existsSync()).toList();
    if (mounted) {
      setState(() {
        _results = all;
        _searching = false;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Scaffold(
      appBar: AppBar(
        automaticallyImplyLeading: !widget.embedded,
        titleSpacing: widget.embedded ? 16 : 0,
        toolbarHeight: 64,
        title: Container(
          height: 44,
          decoration: BoxDecoration(
            color: theme.colorScheme.surfaceContainerHighest,
            borderRadius: BorderRadius.circular(22),
          ),
          child: TextField(
            controller: _controller,
            focusNode: _focus,
            autofocus: !widget.embedded,
            textInputAction: TextInputAction.search,
            decoration: InputDecoration(
              hintText: 'Search files',
              prefixIcon: const Icon(Symbols.search),
              suffixIcon: _controller.text.isEmpty
                  ? null
                  : IconButton(
                      icon: const Icon(Symbols.close),
                      onPressed: () {
                        _controller.clear();
                        _search('');
                      },
                    ),
              border: InputBorder.none,
              enabledBorder: InputBorder.none,
              focusedBorder: InputBorder.none,
              contentPadding: const EdgeInsets.symmetric(vertical: 11),
            ),
            onChanged: (v) {
              setState(() {});
              _debounce?.cancel();
              _debounce = Timer(const Duration(milliseconds: 250), () => _search(v));
            },
          ),
        ),
      ),
      body: _searching
          ? const LinearProgressIndicator(minHeight: 2)
          : _results.isEmpty
          ? EmptyState(
              icon: Symbols.manage_search,
              title: _controller.text.isEmpty ? 'Search your files' : 'No results',
              message: _controller.text.isEmpty ? 'Find PDFs by name on this device.' : 'Try a different file name.',
            )
          : ListView.builder(
              itemCount: _results.length,
              itemBuilder: (context, i) =>
                  DocListTile(path: _results[i], onTap: () => openDocument(context, _results[i])),
            ),
    );
  }
}
