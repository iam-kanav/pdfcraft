import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:path/path.dart' as p;

import '../../core/native/platform_bridge.dart';
import '../../core/services.dart';
import '../common/doc_widgets.dart';
import '../common/open_actions.dart';

/// Searches file names across the library, recents and (if allowed) the whole device.
class SearchScreen extends StatefulWidget {
  const SearchScreen({super.key});

  @override
  State<SearchScreen> createState() => _SearchScreenState();
}

class _SearchScreenState extends State<SearchScreen> {
  final _controller = TextEditingController();
  Timer? _debounce;
  List<String> _results = [];
  bool _searching = false;
  List<String>? _devicePdfs;

  @override
  void initState() {
    super.initState();
    PlatformBridge.instance.hasAllFilesAccess().then((ok) async {
      if (!ok) return;
      final list = await PlatformBridge.instance.scanDevicePdfs();
      _devicePdfs = list.map((e) => e.path).toList();
    });
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
    final recents = services.library.recents.map((r) => r.path).where((f) => p.basename(f).toLowerCase().contains(query));
    final device = (_devicePdfs ?? const []).where((f) => p.basename(f).toLowerCase().contains(query));
    final all = <String>{...recents, ...lib.where((e) => !e.isDirectory).map((e) => e.path), ...device}.where((f) => File(f).existsSync()).toList();
    if (mounted) {
      setState(() {
        _results = all;
        _searching = false;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        titleSpacing: 0,
        title: TextField(
          controller: _controller,
          autofocus: true,
          decoration: const InputDecoration(hintText: 'Search files by name', filled: false, border: InputBorder.none),
          onChanged: (v) {
            _debounce?.cancel();
            _debounce = Timer(const Duration(milliseconds: 250), () => _search(v));
          },
        ),
        actions: [
          if (_controller.text.isNotEmpty)
            IconButton(
              icon: const Icon(Icons.close),
              onPressed: () {
                _controller.clear();
                _search('');
              },
            ),
        ],
      ),
      body: _searching
          ? const LinearProgressIndicator()
          : _results.isEmpty
          ? EmptyState(icon: Icons.search, title: _controller.text.isEmpty ? 'Search your files' : 'No matching files')
          : ListView.builder(
              itemCount: _results.length,
              itemBuilder: (context, i) => DocListTile(path: _results[i], onTap: () => openDocument(context, _results[i])),
            ),
    );
  }
}
