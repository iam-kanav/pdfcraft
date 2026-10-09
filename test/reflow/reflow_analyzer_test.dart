import 'package:flutter_test/flutter_test.dart';
import 'package:pdfcraft/core/models/doc_structure.dart';
import 'package:pdfcraft/core/models/raw_page_content.dart';
import 'package:pdfcraft/features/reflow/analyzer/reflow_analyzer.dart';

import 'fixtures.dart';

/// Compact, exact description of a block for sequence assertions.
String d(DocBlock b) => switch (b) {
  HeadingBlock h => 'H${h.level}:${h.text}',
  ParagraphBlock p => 'P:${p.text}',
  ListItemBlock l => 'LI${l.indent}${l.ordered ? '#' : '*'}[${l.marker}]:${l.text}',
  QuoteBlock q => 'Q:${q.text}',
  ImageBlock i => 'IMG(${i.width}x${i.height}):${i.caption ?? ''}',
  TableBlock t => 'T${t.hasHeader ? 'h' : ''}:${t.rows.map((r) => r.join('|')).join(' / ')}',
  PageBreakBlock _ => 'BR',
};

List<String> describe(DocStructure doc) => doc.blocks.map(d).toList();

const double r = 540; // right edge of a full-width single-column line

RawPageContent articlePage() => page(1, [
  tl('A Study of Things and', 72, size: 24),
  tl('Their Many Properties', 100, size: 24),
  // Paragraph 1: hyphenated word and a real hyphenated compound.
  tl('This article examines the nature of things in great detail and gives an exam-', 150, right: r),
  tl('ple of the many ways in which the famous and frequently discussed Franco-', 162, right: r),
  tl('Prussian conflict shaped modern research on the subject of things.', 174),
  // Paragraph 2: mixed styles.
  ln(
    seq([
      ('Some findings are ', ''),
      ('very important', 'b'),
      (' for the field, and ', ''),
      ('others', 'i'),
      (' are less so but still', ''),
    ], right: r),
    196,
  ),
  tl('worth noting in a short summary.', 208),
  tl('Background', 236, size: 16, bold: true),
  tl('Earlier work on things was limited to small samples and narrow research', 262, right: r),
  tl('questions about their properties.', 274),
  tl('Key observations', 296, bold: true),
  tl('Things are never quite what they seem to be, and every', 316, x: 108, italic: true, right: 504),
  tl('observer sees them differently.', 328, x: 108, italic: true),
  tl('After the quote the text resumes at the normal margin.', 350),
  tl('2.1 Methods', 378, size: 16, bold: true),
  tl('We measured everything twice.', 402),
]);

/// Two-column academic page. When [grouped], the extractor merged left and
/// right column text sharing a baseline into a single line (with a gap).
RawPageContent twoColumnPage({required bool grouped}) {
  const lx = 72.0, lr = 296.0, rx = 316.0, rr = 540.0;
  final left = <(double, RawTextSpan)>[
    (140, sp('1 Introduction', lx, size: 12, bold: true)),
    (160, sp('Multi-column layouts are common in academic', lx, x1: lr)),
    (172, sp('papers and magazines, but they are hard to', lx, x1: lr)),
    (184, sp('read on small screens because the reader must', lx, x1: lr)),
    (196, sp('scroll back up to continue reading the next', lx, x1: lr)),
    (208, sp('column of text, which breaks the flow of', lx, x1: lr)),
  ];
  final right = <(double, RawTextSpan)>[
    (140, sp('reading and makes long articles tiring for', rx, x1: rr)),
    (152, sp('most people who use phones and tablets.', rx)),
    (176, sp('2 Methods', rx, size: 12, bold: true)),
    (196, sp('We converted each page into lines and spans', rx, x1: rr)),
    (208, sp('and grouped them into columns using gaps.', rx)),
  ];
  final lines = <RawTextLine>[
    centered('Columnar Layouts in Practice', 72, size: 20),
    centered('Jane Doe and John Roe', 104, italic: true),
  ];
  if (grouped) {
    final ys = {...left.map((e) => e.$1), ...right.map((e) => e.$1)}.toList()..sort();
    for (final y in ys) {
      lines.add(
        ln([
          for (final e in left)
            if (e.$1 == y) e.$2,
          for (final e in right)
            if (e.$1 == y) e.$2,
        ], y),
      );
    }
  } else {
    for (final e in [...left, ...right]) {
      lines.add(ln([e.$2], e.$1));
    }
  }
  return page(1, lines);
}

void main() {
  group('DocumentStats', () {
    test('computes body size, heading sizes and line spacing', () {
      final stats = DocumentStats.fromPages([articlePage()]);
      expect(stats.bodyFontSize, 10);
      expect(stats.headingSizes, [24, 16]);
      expect(stats.headingLevelForSize(24), 1);
      expect(stats.headingLevelForSize(16), 2);
      expect(stats.headingLevelForSize(10), isNull);
      expect(stats.boldHeadingLevel, 3);
      expect(stats.lineSpacing, 12);
    });

    test('recognizes standalone page numbers', () {
      for (final t in ['12', '- 12 -', '— 7 —', 'Page 3 of 10', 'page 4', '3 / 10', 'iv', 'XII', 'p. 9']) {
        expect(DocumentStats.isPageNumberText(t), isTrue, reason: t);
      }
      for (final t in ['Introduction', '12 apples', 'Chapter 3', 'Mixed', 'I am']) {
        expect(DocumentStats.isPageNumberText(t), isFalse, reason: t);
      }
    });
  });

  group('analyzeDocument', () {
    test('single-column article: title, headings, paragraphs, quote', () {
      final doc = analyzeDocument([articlePage()]);
      expect(describe(doc), [
        'H1:A Study of Things and Their Many Properties',
        'P:This article examines the nature of things in great detail and gives an example of the many ways '
            'in which the famous and frequently discussed Franco-Prussian conflict shaped modern research on the '
            'subject of things.',
        'P:Some findings are very important for the field, and others are less so but still worth noting in a short summary.',
        'H2:Background',
        'P:Earlier work on things was limited to small samples and narrow research questions about their properties.',
        'H3:Key observations',
        'Q:Things are never quite what they seem to be, and every observer sees them differently.',
        'P:After the quote the text resumes at the normal margin.',
        'H2:2.1 Methods',
        'P:We measured everything twice.',
      ]);
      expect(doc.title, 'A Study of Things and Their Many Properties');
      expect(doc.blocks.every((b) => b.pageNumber == 1), isTrue);

      final p2 = doc.blocks[2] as ParagraphBlock;
      expect(p2.spans.map((s) => s.toString()).toList(), [
        'Span("Some findings are ")',
        'Span(b"very important")',
        'Span(" for the field, and ")',
        'Span(i"others")',
        'Span(" are less so but still worth noting in a short summary.")',
      ]);
    });

    for (final grouped in [true, false]) {
      test('two-column academic layout with full-width title (grouped lines: $grouped)', () {
        final doc = analyzeDocument([twoColumnPage(grouped: grouped)]);
        expect(describe(doc), [
          'H1:Columnar Layouts in Practice',
          'P:Jane Doe and John Roe',
          'H2:1 Introduction',
          'P:Multi-column layouts are common in academic papers and magazines, but they are hard to read on small '
              'screens because the reader must scroll back up to continue reading the next column of text, which '
              'breaks the flow of reading and makes long articles tiring for most people who use phones and tablets.',
          'H2:2 Methods',
          'P:We converted each page into lines and spans and grouped them into columns using gaps.',
        ]);
      });
    }

    test('single-column top half above a two-column bottom half', () {
      const lr = 296.0, rx = 316.0, rr = 540.0;
      final lines = <RawTextLine>[
        tl('Mixed Layouts', 72, size: 20),
        tl('This introduction spans the full width of the page and is set in a single', 100, right: r),
        tl('wide column, as magazines often do for the opening paragraph of a long', 112, right: r),
        tl('feature article, before the body switches to two narrower columns that', 124, right: r),
        tl('are much easier to scan on a printed page than one very wide block of', 136, right: r),
        tl('text that ends here.', 148),
      ];
      const left = [
        'The body begins in the left column and runs',
        'down the page for several lines of text that',
        'eventually reach the bottom of this column',
      ];
      const right = [
        'and then continue at the top of the right',
        'column until the paragraph is finally done.',
        'A second paragraph follows in this column.',
      ];
      for (var k = 0; k < 3; k++) {
        lines.add(
          ln([
            sp(left[k], 72, x1: lr),
            if (k == 1) sp(right[k], rx) else sp(right[k], rx, x1: k == 2 ? rx + advance(right[k], 10) : rr),
          ], 166.0 + 12 * k),
        );
      }
      // The second right-column paragraph starts with a first-line indent.
      final fixed = [
        ...lines.take(lines.length - 1),
        ln([sp(left[2], 72, x1: lr)], 190),
        tl(right[2], 202, x: rx + 15),
      ];
      final doc = analyzeDocument([page(1, fixed)]);
      expect(describe(doc), [
        'H1:Mixed Layouts',
        'P:This introduction spans the full width of the page and is set in a single wide column, as magazines often do '
            'for the opening paragraph of a long feature article, before the body switches to two narrower columns that '
            'are much easier to scan on a printed page than one very wide block of text that ends here.',
        'P:The body begins in the left column and runs down the page for several lines of text that eventually reach '
            'the bottom of this column and then continue at the top of the right column until the paragraph is finally done.',
        'P:A second paragraph follows in this column.',
      ]);
    });

    test('three-column layout is read column by column', () {
      const xs = [72.0, 247.0, 422.0];
      const w = 160.0;
      final cols = [
        ['First column starts here and', 'carries on for a few lines', 'of text before it ends.'],
        ['Second column has its own', 'paragraph with some more', 'words that end it here.'],
        ['Third column closes the page', 'with yet another paragraph', 'of words that ends now.'],
      ];
      final lines = [
        for (var row = 0; row < 3; row++)
          ln([for (var c = 0; c < 3; c++) sp(cols[c][row], xs[c], x1: row < 2 ? xs[c] + w : null)], 100.0 + 12 * row),
      ];
      final doc = analyzeDocument([page(1, lines)]);
      expect(describe(doc), [
        'P:First column starts here and carries on for a few lines of text before it ends.',
        'P:Second column has its own paragraph with some more words that end it here.',
        'P:Third column closes the page with yet another paragraph of words that ends now.',
      ]);
    });

    test('figure inside one column of a two-column page, and a line poking into the gutter', () {
      const lr = 296.0, rx = 316.0, rr = 540.0;
      final doc = analyzeDocument([
        page(
          1,
          [
            ln([
              sp('The left column opens with a short paragraph', 72, x1: lr),
              sp('The right column text keeps flowing along', rx, x1: rr),
            ], 100),
            ln([
              sp('that introduces the figure shown below.', 72),
              sp('the page while the figure sits on the left', rx, x1: rr),
            ], 112),
            // Slightly over-wide justified line in the right column (starts in the gutter).
            ln([sp('side of the page, and it does not interrupt', rx - 4, x1: rr)], 124),
            ln([sp('this column at all because figures float.', rx)], 136),
            tl('Figure 2: Column figure.', 262, size: 9),
            tl('After the figure the left column resumes.', 290),
          ],
          images: [img(72, 130, 296, 255, pw: 448, ph: 250)],
        ),
      ]);
      expect(describe(doc), [
        'P:The left column opens with a short paragraph that introduces the figure shown below.',
        'IMG(448x250):Figure 2: Column figure.',
        'P:After the figure the left column resumes.',
        'P:The right column text keeps flowing along the page while the figure sits on the left side of the page, and it '
            'does not interrupt this column at all because figures float.',
      ]);
    });

    test('removes repeated headers and page numbers', () {
      final footers = ['1', '- 2 -', 'Page 3 of 3'];
      final pages = [
        for (var i = 0; i < 3; i++)
          page(i + 1, [
            tl('Journal of Things', 36, size: 9, italic: true),
            tl('Body text of page ${i + 1} is written here and it fills the whole width of the', 100, right: r),
            tl('text column before wrapping.', 112),
            tl('It ends on this second paragraph.', 132),
            centered(footers[i], 750, size: 9),
          ]),
      ];
      final doc = analyzeDocument(pages);
      expect(describe(doc), [
        for (var i = 1; i <= 3; i++) ...[
          'P:Body text of page $i is written here and it fills the whole width of the text column before wrapping.',
          'P:It ends on this second paragraph.',
        ],
      ]);
      expect([for (final b in doc.blocks) b.pageNumber], [1, 1, 2, 2, 3, 3]);

      final kept = analyzeDocument(pages, options: const ReflowOptions(removeHeadersFooters: false));
      expect(describe(kept).first, 'P:Journal of Things');
      expect(describe(kept), contains('P:Page 3 of 3'));
    });

    test('bulleted and numbered lists with continuation lines and nesting', () {
      final doc = analyzeDocument([
        page(1, [
          tl('Things to bring:', 72),
          ln([sp('•', 72), sp('Sunscreen with a high protection factor that will hopefully', 84, x1: r)], 90),
          tl('last all day long.', 102, x: 84),
          ln([sp('•', 72), sp('A hat', 84)], 114),
          ln([sp('◦', 96), sp('A spare hat for windy days', 108)], 126),
          ln([sp('•', 72), sp('Water', 84)], 138),
          tl('Steps to follow:', 160),
          tl('1. Pack the bag.', 178),
          tl('2) Check the weather forecast for the whole trip and adjust the', 190, right: r),
          tl('plan if needed.', 202, x: 86),
          tl('(a) Leave early.', 214),
          tl('iv) Arrive on time.', 226),
          tl('– Bring snacks', 238),
        ]),
      ]);
      expect(describe(doc), [
        'P:Things to bring:',
        'LI0*[•]:Sunscreen with a high protection factor that will hopefully last all day long.',
        'LI0*[•]:A hat',
        'LI1*[◦]:A spare hat for windy days',
        'LI0*[•]:Water',
        'P:Steps to follow:',
        'LI0#[1.]:Pack the bag.',
        'LI0#[2)]:Check the weather forecast for the whole trip and adjust the plan if needed.',
        'LI0#[(a)]:Leave early.',
        'LI0#[iv)]:Arrive on time.',
        'LI0*[–]:Bring snacks',
      ]);
    });

    test('a numbered line that is just wrapped paragraph text is not a list item', () {
      final doc = analyzeDocument([
        page(1, [
          tl('The committee met in the spring and reviewed the results for chapter', 72, right: r),
          tl('2. The members agreed with all of the recommendations.', 84),
        ]),
      ]);
      expect(describe(doc), [
        'P:The committee met in the spring and reviewed the results for chapter 2. The members agreed with all of the recommendations.',
      ]);
    });

    RawPageContent tablePage() => page(1, [
      tl('The prices are listed below.', 72),
      ln([sp('Fruit', 72, bold: true), sp('Color', 200, bold: true), sp('Price', 375, bold: true)], 100),
      ln([sp('Apple', 72), sp('Red', 200), sp('1.20', 380)], 116),
      ln([sp('Banana', 72), sp('Yellow', 200), sp('0.50', 380)], 132),
      ln([sp('Cherry', 72), sp('Dark red', 200), sp('3.75', 380)], 148),
      tl('Prices may change without notice.', 176),
    ]);

    test('table of aligned spans with bold header', () {
      final doc = analyzeDocument([tablePage()]);
      expect(describe(doc), [
        'P:The prices are listed below.',
        'Th:Fruit|Color|Price / Apple|Red|1.20 / Banana|Yellow|0.50 / Cherry|Dark red|3.75',
        'P:Prices may change without notice.',
      ]);
      final t = doc.blocks[1] as TableBlock;
      expect(t.columnCount, 3);
      expect(t.rows.every((row) => row.length == 3), isTrue);
    });

    test('table detection can be disabled', () {
      final doc = analyzeDocument([tablePage()], options: const ReflowOptions(detectTables: false));
      expect(doc.blocks.whereType<TableBlock>(), isEmpty);
      expect(doc.plainText, contains('Banana Yellow 0.50'));
    });

    test('justified single-span paragraphs are not tables', () {
      final doc = analyzeDocument([
        page(1, [
          tl('Lorem ipsum dolor sit amet, consectetur adipiscing elit, sed do eiusmod', 72, right: r),
          tl('tempor incididunt ut labore et dolore magna aliqua. Ut enim ad minim', 84, right: r),
          tl('veniam, quis nostrud exercitation ullamco laboris nisi ut aliquip ex', 96, right: r),
          tl('ea commodo consequat.', 108),
        ]),
      ]);
      expect(doc.blocks, hasLength(1));
      expect(doc.blocks.single, isA<ParagraphBlock>());
    });

    test('image with a Figure caption; tiny images are skipped', () {
      final doc = analyzeDocument([
        page(
          1,
          [
            tl('The diagram below shows the process.', 72),
            tl('Figure 1: A diagram of things.', 310, size: 9, italic: true),
            tl('As the figure shows, things are connected.', 340),
          ],
          images: [img(72, 100, 400, 300, pw: 656, ph: 400), img(500, 360, 510, 370, pw: 10, ph: 10)],
        ),
      ]);
      expect(describe(doc), [
        'P:The diagram below shows the process.',
        'IMG(656x400):Figure 1: A diagram of things.',
        'P:As the figure shows, things are connected.',
      ]);
    });

    test('images can be excluded', () {
      final doc = analyzeDocument([
        page(1, [tl('Only text.', 72)], images: [img(72, 100, 400, 300)]),
      ], options: const ReflowOptions(includeImages: false));
      expect(describe(doc), ['P:Only text.']);
    });

    test('paragraph continuing across a page break is merged', () {
      final doc = analyzeDocument([
        page(1, [
          tl('Introduction', 72, size: 16, bold: true),
          tl('This paragraph starts on the first page and keeps going until it reaches', 680, right: r),
          tl('the very bottom of the page where it is interrupted by the follow-', 692, right: r),
        ]),
        page(2, [tl('ing page, on which it finally ends.', 72), tl('A new paragraph begins here.', 96)]),
      ]);
      expect(describe(doc), [
        'H1:Introduction',
        'P:This paragraph starts on the first page and keeps going until it reaches the very bottom of the page '
            'where it is interrupted by the following page, on which it finally ends.',
        'P:A new paragraph begins here.',
      ]);
      expect(doc.blocks[1].pageNumber, 1);
      expect(doc.blocks[2].pageNumber, 2);
    });

    test('a page with only a full-page image keeps it; scanned backgrounds behind text are dropped', () {
      final doc = analyzeDocument([
        page(1, [], images: [img(0, 0, 612, 792, pw: 1224, ph: 1584)]),
        page(2, [tl('Searchable text over a scan.', 100)], images: [img(0, 0, 612, 792, pw: 1224, ph: 1584)]),
      ]);
      expect(describe(doc), ['IMG(1224x1584):', 'P:Searchable text over a scan.']);
      expect(doc.blocks.first.pageNumber, 1);
    });

    test('empty input produces an empty structure', () {
      final doc = analyzeDocument(const <RawPageContent>[]);
      expect(doc.blocks, isEmpty);
      expect(doc.title, isNull);
    });
  });
}
