import 'dart:isolate';
import 'dart:math';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:pdfcraft/features/scanner/processing/filters.dart';
import 'package:pdfcraft/features/scanner/processing/geometry.dart';
import 'package:pdfcraft/features/scanner/processing/perspective.dart';
import 'package:pdfcraft/features/scanner/processing/scan_pipeline.dart';

import 'synthetic.dart';

/// A 1200x900 "photo" of a 3:4 portrait page rotated by 12 degrees.
(Uint8List, Quad) _photo() {
  final truth = rotatedRect(600, 450, 540, 720, 12);
  final c = Canvas(1200, 900)..fill(solid(80, 70, 60));
  c.fillPolygon(truth.points, solid(235, 232, 225));
  drawFakeText(c, truth, Random(1), lines: 20);
  c.applyLighting((x, y) => 1.05 - 0.3 * y / 900);
  c.addNoise(Random(1), 5);
  return (img.encodeJpg(c.toImage(), quality: 90), truth);
}

void main() {
  test('detectQuadFromBytes finds the page in an encoded photo', () async {
    final (jpeg, truth) = _photo();
    final res = await detectQuadFromBytes(jpeg);
    expect(res, isNotNull);
    expect(res!['width'], 1200);
    expect(res['height'], 900);
    final quad = Quad.fromJson(res['quad'] as Map<String, dynamic>);
    expect(maxCornerError(quad, truth), lessThan(0.03 * 1500));
  });

  test('detectQuadFromBytes returns null for garbage and empty scenes', () async {
    expect(await detectQuadFromBytes(Uint8List.fromList([1, 2, 3, 4])), isNull);
    final flat = img.Image(width: 300, height: 200);
    img.fill(flat, color: img.ColorRgb8(90, 90, 90));
    expect(await detectQuadFromBytes(img.encodeJpg(flat)), isNull);
  });

  test('end to end: detect, warp, filter, rotate, encode', () async {
    final (jpeg, _) = _photo();
    final det = (await detectQuadFromBytes(jpeg))!;
    final quadJson = det['quad'] as Map<String, dynamic>;

    for (final filter in ScanFilter.values) {
      final out = await processScanBytes(ScanRequest(imageBytes: jpeg, quad: quadJson, filter: filter.name));
      final decoded = img.decodeJpg(out);
      expect(decoded, isNotNull, reason: filter.name);
      // 540 x 720 page -> aspect 0.75.
      expect(decoded!.width / decoded.height, closeTo(0.75, 0.0225), reason: filter.name);
      expect(max(decoded.width, decoded.height), lessThanOrEqualTo(2400));
    }

    final rotated = img.decodeJpg(
      await processScanBytes(
        ScanRequest(
          imageBytes: jpeg,
          quad: quadJson,
          filter: 'blackWhite',
          rotation: 90,
          maxDimension: 500,
          jpegQuality: 70,
        ),
      ),
    )!;
    expect(rotated.width, 500);
    expect(rotated.height / rotated.width, closeTo(0.75, 0.0225));

    // Quarter-turn notation is accepted too.
    final quarter = img.decodeJpg(
      await processScanBytes(ScanRequest(imageBytes: jpeg, quad: quadJson, rotation: -1, maxDimension: 500)),
    )!;
    expect(quarter.width, rotated.width);
    expect(quarter.height, rotated.height);
  });

  test('B&W scan of the page is mostly white with black text', () async {
    final (jpeg, _) = _photo();
    final det = (await detectQuadFromBytes(jpeg))!;
    final out = img.decodeJpg(
      await processScanBytes(
        ScanRequest(imageBytes: jpeg, quad: det['quad'] as Map<String, dynamic>, filter: 'blackWhite', jpegQuality: 95),
      ),
    )!;
    var white = 0, black = 0;
    final bytes = out.getBytes();
    for (var i = 0; i < bytes.length; i += out.numChannels) {
      if (bytes[i] > 200) white++;
      if (bytes[i] < 60) black++;
    }
    final total = bytes.length / out.numChannels;
    expect(white / total, greaterThan(0.8));
    expect(black / total, greaterThan(0.02));
  });

  test('without a quad the whole image is processed', () async {
    final (jpeg, _) = _photo();
    final out = img.decodeJpg(await processScanBytes(ScanRequest(imageBytes: jpeg, maxDimension: 600)))!;
    expect(out.width, 600);
    expect(out.height, 450);
  });

  test('EXIF orientation is honoured', () async {
    final src = img.Image(width: 400, height: 300);
    img.fill(src, color: img.ColorRgb8(60, 60, 60));
    img.fillRect(src, x1: 80, y1: 50, x2: 320, y2: 250, color: img.ColorRgb8(240, 240, 240));
    src.exif.imageIfd.orientation = 6; // Rotate 90 degrees clockwise.
    final jpeg = img.encodeJpg(src);
    final oriented = decodeOriented(jpeg)!;
    expect(oriented.width, 300);
    expect(oriented.height, 400);

    final det = (await detectQuadFromBytes(jpeg))!;
    expect(det['width'], 300);
    expect(det['height'], 400);
    final quad = Quad.fromJson(det['quad'] as Map<String, dynamic>);
    // The 240x200 bright rectangle becomes 200x240 after rotation.
    final truth = Quad.fromList(const [Point(50.0, 80.0), Point(250.0, 80.0), Point(250.0, 320.0), Point(50.0, 320.0)]);
    expect(maxCornerError(quad, truth), lessThan(0.03 * 500));

    final thumb = img.decodeJpg(await makeThumbnail(jpeg, maxDim: 100))!;
    expect(thumb.width, 75);
    expect(thumb.height, 100);
  });

  test('makeThumbnail keeps small images and rejects garbage', () async {
    final (jpeg, _) = _photo();
    final t = img.decodeJpg(await makeThumbnail(jpeg))!;
    expect(t.width, 400);
    expect(t.height, 300);
    expect(() => makeThumbnail(Uint8List(10)), throwsFormatException);
    expect(() => processScanBytes(ScanRequest(imageBytes: Uint8List(10))), throwsFormatException);
  });

  test('entry points run inside Isolate.run', () async {
    final (jpeg, _) = _photo();
    final det = await Isolate.run(() => detectQuadFromBytes(jpeg));
    expect(det, isNotNull);
    final quad = det!['quad'] as Map<String, dynamic>;
    final out = await Isolate.run(
      () => processScanBytes(ScanRequest(imageBytes: jpeg, quad: quad, filter: 'autoColor', maxDimension: 600)),
    );
    expect(img.decodeJpg(out)!.height, 600);
  });

  test('timing: 2000x2600 warp + black & white stays fast', () {
    const w = 2000, h = 2600;
    final page = Quad.fromList(const [
      Point(120.0, 160.0),
      Point(1880.0, 110.0),
      Point(1940.0, 2500.0),
      Point(70.0, 2450.0),
    ]);
    final c = Canvas(w, h)..fill(solid(70));
    c.fillPolygon(page.points, solid(230));
    drawFakeText(c, page, Random(2), lines: 40, thickness: 6);
    final src = c.toImage();

    final sw = Stopwatch()..start();
    final warped = warpPerspective(src, page);
    final warpMs = sw.elapsedMilliseconds;
    final bw = applyScanFilter(warped, ScanFilter.blackWhite);
    sw.stop();
    // ignore: avoid_print
    print(
      'warp ${warpMs}ms, warp+B&W ${sw.elapsedMilliseconds}ms '
      '(${warped.width}x${warped.height})',
    );
    expect(bw.width, warped.width);
    expect(sw.elapsedMilliseconds, lessThan(4000));
  });
}
