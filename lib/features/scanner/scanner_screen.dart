import 'dart:io';
import 'dart:async';
import 'dart:isolate';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:camera/camera.dart';
import 'package:file_picker/file_picker.dart';
import '../../core/file_picking.dart';
import 'package:flutter/material.dart';
import 'package:image/image.dart' as img;

import '../common/dialogs.dart';
import '../viewer/viewer_screen.dart';
import 'processing/edge_detector.dart';
import 'processing/geometry.dart';
import 'scan_review_screen.dart';

/// Camera capture with live document edge detection (Acrobat Scan-style).
class ScannerScreen extends StatefulWidget {
  const ScannerScreen({super.key, this.existing});

  /// Pages already captured (when adding more pages from the review screen).
  final List<ScanPage>? existing;

  @override
  State<ScannerScreen> createState() => _ScannerScreenState();
}

class _ScannerScreenState extends State<ScannerScreen> with WidgetsBindingObserver {
  CameraController? _camera;
  String? _error;
  late final List<ScanPage> _pages = [...?widget.existing];
  bool _capturing = false;
  bool _flash = false;
  bool _autoCapture = true;

  // Live detection state (normalized 0..1 coordinates in portrait preview space).
  List<Offset>? _liveQuad;
  bool _detecting = false;
  DateTime _lastDetect = DateTime(0);
  List<Offset>? _stableRef;
  DateTime? _stableSince;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _init();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _camera?.dispose();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    final c = _camera;
    if (c == null || !c.value.isInitialized) return;
    if (state == AppLifecycleState.inactive) {
      c.dispose();
      _camera = null;
    } else if (state == AppLifecycleState.resumed) {
      _init();
    }
  }

  Future<void> _init() async {
    try {
      final cameras = await availableCameras();
      if (cameras.isEmpty) {
        setState(() => _error = 'No camera available. You can still import photos.');
        return;
      }
      final back = cameras.firstWhere((c) => c.lensDirection == CameraLensDirection.back, orElse: () => cameras.first);
      final c = CameraController(back, ResolutionPreset.veryHigh, enableAudio: false, imageFormatGroup: ImageFormatGroup.yuv420);
      await c.initialize();
      try {
        await c.setFlashMode(FlashMode.off);
        await c.setFocusMode(FocusMode.auto);
      } catch (_) {}
      if (!mounted) {
        await c.dispose();
        return;
      }
      setState(() {
        _camera = c;
        _error = null;
      });
      await c.startImageStream(_onFrame);
    } on CameraException catch (e) {
      setState(() => _error = e.code == 'CameraAccessDenied' ? 'Camera permission was denied. Allow it in Settings, or import photos instead.' : 'Camera error: ${e.description}');
    } catch (e) {
      setState(() => _error = 'Camera error: $e');
    }
  }

  void _onFrame(CameraImage frame) {
    if (_detecting || _capturing) return;
    final now = DateTime.now();
    if (now.difference(_lastDetect).inMilliseconds < 450) return;
    _lastDetect = now;
    _detecting = true;
    final plane = frame.planes.first;
    final sensor = _camera?.description.sensorOrientation ?? 90;
    final args = (Uint8List.fromList(plane.bytes), frame.width, frame.height, plane.bytesPerRow, sensor);
    Isolate.run(() => detectFromLuma(args.$1, args.$2, args.$3, args.$4, args.$5)).then((quad) {
      if (!mounted) return;
      setState(() => _liveQuad = quad);
      _checkStable(quad);
    }).whenComplete(() => _detecting = false);
  }

  void _checkStable(List<Offset>? quad) {
    if (!_autoCapture || quad == null || _capturing) {
      _stableRef = null;
      _stableSince = null;
      return;
    }
    final ref = _stableRef;
    final moved = ref == null || [for (var i = 0; i < 4; i++) (quad[i] - ref[i]).distance].reduce(math.max) > 0.03;
    if (moved) {
      _stableRef = quad;
      _stableSince = DateTime.now();
    } else if (DateTime.now().difference(_stableSince!).inMilliseconds > 1400) {
      _stableRef = null;
      _stableSince = null;
      _capture();
    }
  }

  Future<void> _capture() async {
    final c = _camera;
    if (c == null || _capturing || !c.value.isInitialized) return;
    setState(() => _capturing = true);
    try {
      if (c.value.isStreamingImages) await c.stopImageStream();
      final file = await c.takePicture();
      final bytes = await file.readAsBytes();
      final page = await ScanPage.create(bytes);
      if (!mounted) return;
      setState(() => _pages.add(page));
    } catch (e) {
      if (mounted) showSnack(context, 'Capture failed: ${friendlyError(e)}', error: true);
    } finally {
      if (mounted) setState(() => _capturing = false);
      try {
        if (c.value.isInitialized && !c.value.isStreamingImages) await c.startImageStream(_onFrame);
      } catch (_) {}
    }
  }

  Future<void> _import() async {
    final r = await pickLocalFiles(type: FileType.image, multiple: true);
    for (final f in r) {
      final bytes = await File(f.path).readAsBytes();
      final page = await ScanPage.create(bytes);
      if (mounted) setState(() => _pages.add(page));
    }
  }

  Future<void> _review() async {
    if (_pages.isEmpty) return;
    await _camera?.stopImageStream().catchError((_) {});
    if (!mounted) return;
    if (widget.existing != null) {
      Navigator.pop(context, _pages);
      return;
    }
    final result = await Navigator.of(context).push<Object>(MaterialPageRoute(builder: (_) => ScanReviewScreen(pages: _pages)));
    if (!mounted) return;
    if (result is String) {
      // Saved: replace the scanner with the viewer for the new PDF.
      await Navigator.of(context).pushReplacement(MaterialPageRoute(builder: (_) => ViewerScreen(path: result)));
    } else if (result is List<ScanPage>) {
      setState(() {
        _pages
          ..clear()
          ..addAll(result);
      });
      final c = _camera;
      if (c != null && c.value.isInitialized && !c.value.isStreamingImages) await c.startImageStream(_onFrame);
    }
  }

  @override
  Widget build(BuildContext context) {
    final c = _camera;
    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(
        backgroundColor: Colors.black,
        foregroundColor: Colors.white,
        title: const Text('Scan'),
        actions: [
          IconButton(
            tooltip: _flash ? 'Flash off' : 'Flash on',
            icon: Icon(_flash ? Icons.flash_on : Icons.flash_off),
            onPressed: c == null
                ? null
                : () async {
                    _flash = !_flash;
                    await c.setFlashMode(_flash ? FlashMode.torch : FlashMode.off).catchError((_) {});
                    setState(() {});
                  },
          ),
          TextButton(
            onPressed: () => setState(() => _autoCapture = !_autoCapture),
            child: Text(_autoCapture ? 'Auto' : 'Manual', style: const TextStyle(color: Colors.white)),
          ),
        ],
      ),
      body: Column(
        children: [
          Expanded(
            child: _error != null
                ? Center(child: Padding(padding: const EdgeInsets.all(24), child: Text(_error!, textAlign: TextAlign.center, style: const TextStyle(color: Colors.white70))))
                : c == null || !c.value.isInitialized
                ? const Center(child: CircularProgressIndicator())
                : Center(
                    child: AspectRatio(
                      aspectRatio: 1 / c.value.aspectRatio,
                      child: Stack(
                        fit: StackFit.expand,
                        children: [
                          CameraPreview(c),
                          CustomPaint(painter: _QuadPainter(_liveQuad, stable: _stableSince != null)),
                          if (_capturing) Container(color: Colors.white24),
                        ],
                      ),
                    ),
                  ),
          ),
          Container(
            color: Colors.black,
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 24),
            child: SafeArea(
              top: false,
              child: Row(
                children: [
                  IconButton(onPressed: _import, icon: const Icon(Icons.photo_library_outlined, color: Colors.white), tooltip: 'Import photos'),
                  const Spacer(),
                  GestureDetector(
                    onTap: _capture,
                    child: Container(
                      width: 72,
                      height: 72,
                      decoration: BoxDecoration(shape: BoxShape.circle, border: Border.all(color: Colors.white, width: 4)),
                      padding: const EdgeInsets.all(4),
                      child: Container(decoration: BoxDecoration(shape: BoxShape.circle, color: _capturing ? Colors.white54 : Colors.white)),
                    ),
                  ),
                  const Spacer(),
                  GestureDetector(
                    onTap: _review,
                    child: SizedBox(
                      width: 56,
                      height: 64,
                      child: _pages.isEmpty
                          ? const SizedBox()
                          : Stack(
                              children: [
                                Positioned.fill(child: ClipRRect(borderRadius: BorderRadius.circular(6), child: Image.memory(_pages.last.thumbnail, fit: BoxFit.cover))),
                                Positioned(right: 0, top: 0, child: CircleAvatar(radius: 11, backgroundColor: Theme.of(context).colorScheme.primary, child: Text('${_pages.length}', style: const TextStyle(fontSize: 11, color: Colors.white)))),
                              ],
                            ),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// Detects a document quad in a camera luma plane; returns normalized portrait coordinates.
List<Offset>? detectFromLuma(Uint8List y, int width, int height, int stride, int sensorOrientation) {
  const target = 320;
  final step = math.max(1, (math.max(width, height) / target).floor());
  final w = width ~/ step, h = height ~/ step;
  final image = img.Image(width: w, height: h, numChannels: 3);
  for (var j = 0; j < h; j++) {
    final row = j * step * stride;
    for (var i = 0; i < w; i++) {
      final v = y[row + i * step];
      image.setPixelRgb(i, j, v, v, v);
    }
  }
  final quad = detectDocumentQuad(image);
  if (quad == null) return null;
  Offset norm(math.Point<double> p) {
    final nx = p.x / w, ny = p.y / h;
    return switch (sensorOrientation) {
      90 => Offset(1 - ny, nx),
      180 => Offset(1 - nx, 1 - ny),
      270 => Offset(ny, 1 - nx),
      _ => Offset(nx, ny),
    };
  }

  final pts = [quad.tl, quad.tr, quad.br, quad.bl].map(norm).toList();
  final ordered = Quad.orderPoints([for (final p in pts) math.Point(p.dx, p.dy)]);
  return [for (final p in ordered.points) Offset(p.x, p.y)];
}

class _QuadPainter extends CustomPainter {
  _QuadPainter(this.quad, {required this.stable});

  final List<Offset>? quad;
  final bool stable;

  @override
  void paint(Canvas canvas, Size size) {
    final q = quad;
    if (q == null) return;
    final path = Path()..moveTo(q[0].dx * size.width, q[0].dy * size.height);
    for (final p in q.skip(1)) {
      path.lineTo(p.dx * size.width, p.dy * size.height);
    }
    path.close();
    final color = stable ? const Color(0xFF22C55E) : const Color(0xFF3B82F6);
    canvas.drawPath(path, Paint()..color = color.withValues(alpha: 0.18));
    canvas.drawPath(path, Paint()
      ..color = color
      ..style = PaintingStyle.stroke
      ..strokeWidth = 3);
  }

  @override
  bool shouldRepaint(covariant _QuadPainter old) => old.quad != quad || old.stable != stable;
}
