import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:pdfcraft/core/models/doc_structure.dart';
import 'package:pdfcraft/features/convert/engine/html_writer.dart';
import 'package:pdfcraft/features/convert/engine/markdown_reader.dart';
import 'package:pdfcraft/features/convert/engine/markdown_writer.dart';
import 'package:pdfcraft/features/convert/engine/text_export.dart';
import 'package:pdfcraft/features/convert/engine/text_reader.dart';

import 'test_helpers.dart';

void main() {
  final png = makePng(30, 10);
  final jpeg = makeJpeg(20, 40);

  DocStructure sample() => DocStructure(
    blocks: [
      const HeadingBlock(level: 1, spans: [TextSpanData('Title # with hash')]),
      const ParagraphBlock(
        spans: [
          TextSpanData('Text with '),
          TextSpanData('bold', bold: true),
          TextSpanData(', '),
          TextSpanData('italic', italic: true),
          TextSpanData(' and '),
          TextSpanData('bold-italic', bold: true, italic: true),
          TextSpanData(' plus '),
          TextSpanData('under', underline: true),
          TextSpanData(' and a '),
          TextSpanData('link (with parens)', link: 'https://example.com/a_(b)?x=1&y=2'),
          TextSpanData('.'),
        ],
      ),
      const ParagraphBlock(
        spans: [TextSpanData('Special chars: *stars* _under_ [brackets] <html> `code` \\ back ~tilde~ &amp; 5 > 3')],
      ),
      const ParagraphBlock(spans: [TextSpanData('# not a heading\n- not a list\n1. not ordered\nline')]),
      const ParagraphBlock(
        spans: [
          TextSpanData('adjacent'),
          TextSpanData('italic', italic: true),
          TextSpanData('bold(punct)', bold: true),
          TextSpanData('end'),
        ],
      ),
      const HeadingBlock(level: 3, spans: [TextSpanData('Lists')]),
      const ListItemBlock(spans: [TextSpanData('one')]),
      const ListItemBlock(spans: [TextSpanData('nested '), TextSpanData('two', bold: true)], indent: 1),
      const ListItemBlock(spans: [TextSpanData('deep ordered')], ordered: true, indent: 2),
      const ListItemBlock(spans: [TextSpanData('three')]),
      const ParagraphBlock(spans: [TextSpanData('Between lists.')]),
      const ListItemBlock(spans: [TextSpanData('first')], ordered: true),
      const ListItemBlock(spans: [TextSpanData('second\ncontinued')], ordered: true),
      const QuoteBlock(spans: [TextSpanData('Quoted '), TextSpanData('text', italic: true)]),
      ImageBlock(bytes: png, width: 30, height: 10),
      ImageBlock(bytes: jpeg, width: 20, height: 40, caption: 'A caption'),
      const TableBlock(
        rows: [
          ['Col | A', 'Col *B*'],
          ['1', 'x\ny'],
          ['', 'last'],
        ],
        hasHeader: true,
      ),
      const TableBlock(
        rows: [
          ['n1', 'n2'],
        ],
      ),
      const PageBreakBlock(),
      const HeadingBlock(level: 6, spans: [TextSpanData('End')]),
    ],
  );

  group('Markdown writer', () {
    final export = buildMarkdownWithImages(sample());
    final md = export.markdown;

    test('emits headings, emphasis, links, lists, tables and image references', () {
      expect(md, contains('# Title # with hash'));
      expect(md, contains('**bold**'));
      expect(md, contains('*italic*'));
      expect(md, contains('<u>under</u>'));
      // Emphasis bounded by punctuation falls back to HTML tags (CommonMark
      // flanking rules would not recognise `**` there).
      expect(md, contains('adjacent*italic*<strong>bold(punct)</strong>end'));
      expect(md, contains('[link (with parens)](<https://example.com/a_(b)?x=1&y=2>)'));
      expect(md, contains(r'\*stars\* \_under\_ \[brackets\] \<html\> \`code\` \\ back \~tilde\~ \&amp; 5 \> 3'));
      expect(md, contains('![image 1](image-1.png)'));
      expect(md, contains('![A caption](image-2.jpg)'));
      expect(md, contains(r'| Col \| A | Col \*B\* |'));
      expect(md, contains('| --- | --- |'));
      expect(md, contains('| 1 | x<br>y |'));
      expect(md, contains('- one\n    - nested **two**\n        1. deep ordered\n- three'));
      expect(md, contains('1. first\n2. second\\\n   continued'));
      expect(md, contains(markdownPageBreak));
      expect(export.images.keys, ['image-1.png', 'image-2.jpg']);
      expect(export.images['image-1.png'], png);
      expect(buildMarkdown(sample()), md);
    });

    test('round trips through parseMarkdown', () {
      final parsed = parseMarkdown(md, images: export.images);
      expect(parsed.blocks.map(describe).toList(), sample().blocks.map(describe).toList());
      final link = (parsed.blocks[1] as ParagraphBlock).spans.firstWhere((s) => s.link != null);
      expect(link.link, 'https://example.com/a_(b)?x=1&y=2');
      final images = parsed.blocks.whereType<ImageBlock>().toList();
      expect(images[0].bytes, png);
      expect(images[1].caption, 'A caption');
      expect(images[1].width, 20);
      expect(images[1].height, 40);
    });
  });

  group('Markdown reader', () {
    test('ATX and setext headings, closing hashes', () {
      final d = parseMarkdown('# One #\n\nTwo\n===\n\nThree\n---\n\n###### Six\n\n####### seven');
      expect(d.blocks.map(describe).toList(), [
        [
          'H',
          1,
          ['"One"'],
        ],
        [
          'H',
          1,
          ['"Two"'],
        ],
        [
          'H',
          2,
          ['"Three"'],
        ],
        [
          'H',
          6,
          ['"Six"'],
        ],
        [
          'P',
          ['"####### seven"'],
        ],
      ]);
    });

    test('soft-wrapped lines are joined, hard breaks kept', () {
      final d = parseMarkdown('line one\nline two  \nline three\\\nline four');
      expect((d.blocks.single as ParagraphBlock).text, 'line one line two\nline three\nline four');
    });

    test('emphasis variants', () {
      final d = parseMarkdown('**b** __b2__ *i* _i2_ ***bi*** snake_case_word 2*3*4 ** not **');
      final spans = (d.blocks.single as ParagraphBlock).spans.map(describeSpan).toList();
      expect(spans, [
        'B"b"',
        '" "',
        'B"b2"',
        '" "',
        'I"i"',
        '" "',
        'I"i2"',
        '" "',
        'BI"bi"',
        '" snake_case_word 2"',
        'I"3"',
        '"4 ** not **"',
      ]);
    });

    test('links: inline, reference, autolink and bare URLs', () {
      final d = parseMarkdown(
        'See [Dart](https://dart.dev "Dart site"), [ref][r], [Short], <https://a.b/c> and www.example.org.\n\n'
        '[r]: https://ref.example\n[short]: https://short.example',
      );
      final links = (d.blocks.single as ParagraphBlock).spans.where((s) => s.link != null).toList();
      expect(links.map((s) => '${s.text}->${s.link}').toList(), [
        'Dart->https://dart.dev',
        'ref->https://ref.example',
        'Short->https://short.example',
        'https://a.b/c->https://a.b/c',
        'www.example.org->http://www.example.org',
      ]);
    });

    test('nested lists with different markers and lazy continuation', () {
      final d = parseMarkdown('* a\n  continued\n  + b\n    1) c\n    2) d\n* e\n\n10. ten\n11. eleven');
      expect(d.blocks.map(describe).toList(), [
        [
          'LI',
          false,
          0,
          ['"a continued"'],
        ],
        [
          'LI',
          false,
          1,
          ['"b"'],
        ],
        [
          'LI',
          true,
          2,
          ['"c"'],
        ],
        [
          'LI',
          true,
          2,
          ['"d"'],
        ],
        [
          'LI',
          false,
          0,
          ['"e"'],
        ],
        [
          'LI',
          true,
          0,
          ['"ten"'],
        ],
        [
          'LI',
          true,
          0,
          ['"eleven"'],
        ],
      ]);
      expect(d.blocks.whereType<ListItemBlock>().last.marker, '11.');
    });

    test('quotes, code fences, tables, rules and page breaks', () {
      final d = parseMarkdown(
        [
          '> quoted **bold**',
          'lazy line',
          '',
          '```dart',
          'void main() {',
          '  print(1);',
          '}',
          '```',
          '',
          '***',
          '',
          '| A | B |',
          '|:--|--:|',
          '| 1 | `a|b` |',
          '| only one |',
          '',
          r'\pagebreak',
          '',
          '    indented code',
          '    more',
        ].join('\n'),
      );
      expect(d.blocks.map(describe).toList(), [
        [
          'Q',
          ['"quoted "', 'B"bold"', '" lazy line"'],
        ],
        [
          'P',
          ['"void main() {\n  print(1);\n}"'],
        ],
        [
          'T',
          true,
          [
            ['A', 'B'],
            ['1', 'a|b'],
            ['only one', ''],
          ],
        ],
        ['BR'],
        [
          'P',
          ['"indented code\nmore"'],
        ],
      ]);
    });

    test('inline HTML: emphasis tags kept, others stripped, entities decoded', () {
      final d = parseMarkdown('<b>bold</b> <span class="x">plain</span> <!-- c --> &copy; &#x41; &unknown;');
      final spans = (d.blocks.single as ParagraphBlock).spans.map(describeSpan).toList();
      expect(spans, ['B"bold"', '" plain  © A &unknown;"']);
    });

    test('data URI images are decoded, unresolved images dropped', () {
      final d = parseMarkdown('![Logo](data:image/png;base64,${base64Encode(png)})\n\n![x](missing.png)');
      final img = d.blocks.single as ImageBlock;
      expect(img.bytes, png);
      expect(img.caption, 'Logo');
      expect(img.width, 30);
    });

    test('empty and whitespace-only input', () {
      expect(parseMarkdown('').blocks, isEmpty);
      expect(parseMarkdown('\n  \n\t\n').blocks, isEmpty);
    });
  });

  group('HTML writer', () {
    test('produces semantic, standalone HTML', () {
      final html = buildHtml(sample(), title: 'My <Doc>');
      expect(html, startsWith('<!DOCTYPE html>'));
      expect(html, contains('<meta name="viewport"'));
      expect(html, contains('<title>My &lt;Doc&gt;</title>'));
      expect(html, contains('<style>'));
      expect(html, contains('<h1>Title # with hash</h1>'));
      expect(html, contains('<strong>bold</strong>'));
      expect(html, contains('<em>italic</em>'));
      expect(html, contains('<strong><em>bold-italic</em></strong>'));
      expect(html, contains('<u>under</u>'));
      expect(html, contains('<a href="https://example.com/a_(b)?x=1&amp;y=2" rel="noopener noreferrer">'));
      expect(html, contains('&lt;html&gt;'));
      expect(
        html,
        contains(
          '<ul>\n<li>one<ul>\n<li>nested <strong>two</strong><ol>\n<li>deep ordered</li>\n</ol>\n</li>\n</ul>\n</li>\n<li>three</li>\n</ul>',
        ),
      );
      expect(html, contains('<ol>\n<li>first</li>\n<li>second<br>\ncontinued</li>\n</ol>'));
      expect(html, contains('<blockquote><p>Quoted <em>text</em></p></blockquote>'));
      expect(html, contains('src="data:image/png;base64,${base64Encode(png)}"'));
      expect(html, contains('<figcaption>A caption</figcaption>'));
      expect(html, contains('<thead><tr><th scope="col">Col | A</th>'));
      expect(html, contains('<tbody>'));
      expect(html, contains('<td>x<br>\ny</td>'));
      expect(html, contains('class="page-break"'));
      expect(html, contains('<h6>End</h6>'));
      expect(html.trimRight(), endsWith('</html>'));
    });

    test('escapes script injection and drops unsafe link schemes', () {
      final html = buildHtml(
        DocStructure(
          blocks: const [
            ParagraphBlock(
              spans: [
                TextSpanData('<script>alert("x")</script>'),
                TextSpanData('click', link: 'javascript:alert(1)'),
                TextSpanData('ok', link: 'https://x.y/"onmouseover="z'),
              ],
            ),
            TableBlock(
              rows: [
                ['<script>bad()</script>'],
              ],
            ),
          ],
          title: '</title><script>',
        ),
      );
      expect(html, isNot(contains('<script>')));
      expect(html, contains('&lt;script&gt;alert(&quot;x&quot;)&lt;/script&gt;'));
      expect(html, isNot(contains('javascript:')));
      expect(html, contains('href="https://x.y/&quot;onmouseover=&quot;z"'));
      expect(html, contains('<title>&lt;/title&gt;&lt;script&gt;</title>'));
    });
  });

  group('plain text', () {
    test('parsePlainText splits paragraphs and detects bullets', () {
      final d = parsePlainText(
        'First line\nsecond line\n\n\n- item one\n  - nested\n• dot\n1. num\n2) other\ncontinued\n\fPage two',
      );
      expect(d.blocks.map(describe).toList(), [
        [
          'P',
          ['"First line\nsecond line"'],
        ],
        [
          'LI',
          false,
          0,
          ['"item one"'],
        ],
        [
          'LI',
          false,
          1,
          ['"nested"'],
        ],
        [
          'LI',
          false,
          0,
          ['"dot"'],
        ],
        [
          'LI',
          true,
          0,
          ['"num"'],
        ],
        [
          'LI',
          true,
          0,
          ['"other\ncontinued"'],
        ],
        ['BR'],
        [
          'P',
          ['"Page two"'],
        ],
      ]);
      expect(parsePlainText('\r\n\r\n').blocks, isEmpty);
      expect(parsePlainText('A. Smith wrote this.').blocks.single, isA<ParagraphBlock>());
    });

    test('structureToPlainText formats every block type', () {
      final text = structureToPlainText(sample());
      expect(text, startsWith('Title # with hash\n=================\n\nText with bold'));
      expect(text, contains('link (with parens) (https://example.com/a_(b)?x=1&y=2).'));
      expect(text, contains('• one\n    – nested two\n        i. deep ordered\n• three'));
      expect(text, contains('1. first\n2. second\n   continued'));
      expect(text, contains('> Quoted text'));
      expect(text, contains('[Image]\n\n[Image: A caption]'));
      expect(text, contains('Col | A\tCol *B*\n1\tx y\n\tlast'));
      expect(text, contains('n1\tn2\n\nEnd\n'));
    });
  });
}
