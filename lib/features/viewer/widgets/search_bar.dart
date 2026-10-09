import 'dart:async';

import 'package:flutter/material.dart';
import 'package:pdfrx/pdfrx.dart';
import 'package:material_symbols_icons/symbols.dart';

/// Acrobat-style in-document search bar (replaces the app bar).
class ViewerSearchBar extends StatefulWidget implements PreferredSizeWidget {
  const ViewerSearchBar({super.key, required this.searcher, required this.onClose});

  final PdfTextSearcher searcher;
  final VoidCallback onClose;

  @override
  Size get preferredSize => const Size.fromHeight(kToolbarHeight + 28);

  @override
  State<ViewerSearchBar> createState() => _ViewerSearchBarState();
}

class _ViewerSearchBarState extends State<ViewerSearchBar> {
  final _controller = TextEditingController();
  Timer? _debounce;
  bool _matchCase = false;
  bool _wholeWord = false;

  @override
  void initState() {
    super.initState();
    widget.searcher.addListener(_changed);
  }

  @override
  void dispose() {
    _debounce?.cancel();
    widget.searcher.removeListener(_changed);
    _controller.dispose();
    super.dispose();
  }

  void _changed() {
    if (mounted) setState(() {});
  }

  void _search() {
    final q = _controller.text;
    if (q.trim().isEmpty) {
      widget.searcher.resetTextSearch();
      return;
    }
    widget.searcher.resetTextSearch();
    final Pattern pattern = _wholeWord ? RegExp('\\b${RegExp.escape(q)}\\b', caseSensitive: _matchCase) : q;
    widget.searcher.startTextSearch(pattern, caseInsensitive: !_matchCase, goToFirstMatch: true);
  }

  @override
  Widget build(BuildContext context) {
    final s = widget.searcher;
    final count = s.matches.length;
    final idx = s.currentIndex;
    final status = s.isSearching
        ? 'Searching… ${((s.searchProgress ?? 0) * 100).round()}%'
        : (_controller.text.isEmpty ? '' : (count == 0 ? 'No results' : '${(idx ?? 0) + 1} of $count'));
    return AppBar(
      leading: IconButton(icon: const Icon(Symbols.arrow_back), onPressed: widget.onClose),
      titleSpacing: 0,
      title: TextField(
        controller: _controller,
        autofocus: true,
        textInputAction: TextInputAction.search,
        decoration: const InputDecoration(
          hintText: 'Search document',
          filled: false,
          border: InputBorder.none,
          enabledBorder: InputBorder.none,
          focusedBorder: InputBorder.none,
        ),
        onChanged: (_) {
          _debounce?.cancel();
          _debounce = Timer(const Duration(milliseconds: 400), _search);
        },
        onSubmitted: (_) {
          if (count > 0) {
            s.goToNextMatch();
          } else {
            _search();
          }
        },
      ),
      actions: [
        IconButton(
          tooltip: 'Previous',
          icon: const Icon(Symbols.keyboard_arrow_up),
          onPressed: count > 0 ? s.goToPrevMatch : null,
        ),
        IconButton(
          tooltip: 'Next',
          icon: const Icon(Symbols.keyboard_arrow_down),
          onPressed: count > 0 ? s.goToNextMatch : null,
        ),
        if (_controller.text.isNotEmpty)
          IconButton(
            tooltip: 'Clear',
            icon: const Icon(Symbols.close),
            onPressed: () {
              _controller.clear();
              s.resetTextSearch();
            },
          ),
      ],
      bottom: PreferredSize(
        preferredSize: const Size.fromHeight(28),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 0, 8, 6),
          child: Row(
            children: [
              Expanded(child: Text(status, style: Theme.of(context).textTheme.bodySmall)),
              FilterChip(
                visualDensity: VisualDensity.compact,
                label: const Text('Match case'),
                selected: _matchCase,
                onSelected: (v) {
                  setState(() => _matchCase = v);
                  _search();
                },
              ),
              const SizedBox(width: 6),
              FilterChip(
                visualDensity: VisualDensity.compact,
                label: const Text('Whole words'),
                selected: _wholeWord,
                onSelected: (v) {
                  setState(() => _wholeWord = v);
                  _search();
                },
              ),
            ],
          ),
        ),
      ),
    );
  }
}
