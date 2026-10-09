import 'package:flutter_test/flutter_test.dart';
import 'package:pdfcraft/core/util/format.dart';

void main() {
  test('formatBytes', () {
    expect(formatBytes(512), '512 B');
    expect(formatBytes(2048), '2.0 KB');
    expect(formatBytes(5 * 1024 * 1024), '5.0 MB');
    expect(formatBytes(150 * 1024 * 1024), '150 MB');
  });

  test('parsePageRanges handles ranges, singles, ordering and dedupe', () {
    expect(parsePageRanges('1-3, 5, 2', 10), [1, 2, 3, 5]);
    expect(parsePageRanges('4-2', 10), [2, 3, 4]);
    expect(() => parsePageRanges('0', 10), throwsFormatException);
    expect(() => parsePageRanges('11', 10), throwsFormatException);
    expect(() => parsePageRanges('a-b', 10), throwsFormatException);
    expect(() => parsePageRanges(' ', 10), throwsFormatException);
  });

  test('sanitizeFileName strips invalid characters', () {
    expect(sanitizeFileName('a/b:c*?.pdf'), 'a_b_c__.pdf');
    expect(sanitizeFileName('   '), 'Untitled');
  });

  test('formatRelativeDate', () {
    final now = DateTime(2026, 10, 10, 15);
    expect(formatRelativeDate(DateTime(2026, 10, 10, 9, 5), now: now), startsWith('Today'));
    expect(formatRelativeDate(DateTime(2026, 10, 9, 9), now: now), 'Yesterday');
    expect(formatRelativeDate(DateTime(2025, 1, 2), now: now), contains('2025'));
  });
}
