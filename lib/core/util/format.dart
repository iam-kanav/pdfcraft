import 'package:intl/intl.dart';
import 'package:path/path.dart' as p;

String formatBytes(int bytes) {
  if (bytes < 1024) return '$bytes B';
  const units = ['KB', 'MB', 'GB'];
  var v = bytes / 1024;
  var i = 0;
  while (v >= 1024 && i < units.length - 1) {
    v /= 1024;
    i++;
  }
  return '${v.toStringAsFixed(v >= 100 ? 0 : 1)} ${units[i]}';
}

String formatRelativeDate(DateTime d, {DateTime? now}) {
  now ??= DateTime.now();
  final today = DateTime(now.year, now.month, now.day);
  final day = DateTime(d.year, d.month, d.day);
  final diff = today.difference(day).inDays;
  if (diff == 0) return 'Today, ${DateFormat.jm().format(d)}';
  if (diff == 1) return 'Yesterday';
  if (diff < 7) return DateFormat.EEEE().format(d);
  if (d.year == now.year) return DateFormat.MMMd().format(d);
  return DateFormat.yMMMd().format(d);
}

/// File name without the extension.
String baseName(String path) => p.basenameWithoutExtension(path);

/// Removes characters that are invalid in Android file names.
String sanitizeFileName(String name) {
  final cleaned = name.replaceAll(RegExp(r'[\\/:*?"<>|\x00-\x1F]'), '_').trim();
  return cleaned.isEmpty ? 'Untitled' : cleaned;
}

/// Parses page range text like "1-3, 5, 8-10" into 1-based page numbers (sorted, unique).
List<int> parsePageRanges(String text, int pageCount) {
  final result = <int>{};
  for (final part in text.split(',')) {
    final t = part.trim();
    if (t.isEmpty) continue;
    final m = RegExp(r'^(\d+)\s*(?:-\s*(\d+))?$').firstMatch(t);
    if (m == null) throw FormatException('Invalid range "$t"');
    final a = int.parse(m.group(1)!);
    final b = m.group(2) == null ? a : int.parse(m.group(2)!);
    if (a < 1 || b < 1 || a > pageCount || b > pageCount) throw FormatException('Pages must be between 1 and $pageCount');
    final lo = a <= b ? a : b;
    final hi = a <= b ? b : a;
    for (var i = lo; i <= hi; i++) {
      result.add(i);
    }
  }
  if (result.isEmpty) throw const FormatException('Enter at least one page');
  return result.toList()..sort();
}
