import 'package:flutter/material.dart';

import '../../core/native/pdf_engine.dart';
import '../../core/services.dart';
import '../../theme/app_theme.dart';
import '../common/brand_widgets.dart';
import '../common/dialogs.dart';
import '../common/document_picker.dart';
import '../convert/create_pdf_screen.dart';
import '../convert/export_screen.dart';
import '../convert/ocr_screen.dart';
import '../organize/combine_screen.dart';
import '../organize/crop_screen.dart';
import '../organize/organize_screen.dart';
import '../organize/split_screen.dart';
import '../reflow/reflow_screen.dart';
import '../scanner/scanner_screen.dart';
import '../security/properties_screen.dart';
import '../security/protect_screen.dart';
import '../viewer/viewer_screen.dart';
import '../viewer/viewer_state.dart';
import 'compress_screen.dart';
import 'stamp_dialogs.dart';
import 'package:material_symbols_icons/symbols.dart';

enum ToolCategory {
  create('Create & combine'),
  edit('Edit & review'),
  organize('Organize'),
  convert('Convert'),
  protect('Protect');

  const ToolCategory(this.label);

  final String label;
}

typedef ToolLauncher = Future<void> Function(BuildContext context, String? path, String? password);

class PdfTool {
  const PdfTool({
    required this.id,
    required this.title,
    required this.subtitle,
    required this.icon,
    required this.color,
    required this.category,
    required this.launcher,
    this.needsFile = true,
  });

  final String id;
  final String title;
  final String subtitle;
  final IconData icon;
  final Color color;
  final ToolCategory category;
  final bool needsFile;
  final ToolLauncher launcher;

  Future<void> launch(BuildContext context, {String? path}) async {
    AppServices.instance.settings.useTool(id);
    String? password;
    if (needsFile) {
      path ??= await pickDocument(context, title: title);
      if (path == null || !context.mounted) return;
      final unlocked = await unlockDocument(context, path);
      if (unlocked == null || !context.mounted) return;
      password = unlocked.password;
    }
    if (!context.mounted) return;
    await launcher(context, path, password);
  }
}

/// Checks whether [path] needs a password and asks for it. Returns null if cancelled.
Future<({String? password})?> unlockDocument(BuildContext context, String path) async {
  String? password;
  var attempts = 0;
  while (true) {
    try {
      await PdfEngine.instance.info(path, password: password);
      return (password: password);
    } on PdfEngineException catch (e) {
      if (!e.isPasswordError || !context.mounted) {
        if (context.mounted) showSnack(context, e.message, error: true);
        return null;
      }
      final pw = await askPassword(context, wrong: attempts > 0);
      if (pw == null) return null;
      password = pw;
      attempts++;
    }
  }
}

Future<void> _push(BuildContext context, Widget w) => Navigator.of(context).push(MaterialPageRoute(builder: (_) => w));

Future<void> _withSession(
  BuildContext context,
  String path,
  String? password,
  Widget Function(dynamic session) build,
) async {
  final session = AppServices.instance.newSession(path, password: password);
  try {
    await _push(context, build(session));
  } finally {
    session.dispose();
  }
}

Future<void> _viewer(BuildContext context, String? path, String? password, ViewerMode mode) =>
    _push(context, ViewerScreen(path: path!, password: password, initialMode: mode));

class ToolRegistry {
  static final all = <PdfTool>[
    PdfTool(
      id: 'edit',
      title: 'Edit PDF',
      subtitle: 'Edit text and images, add content',
      icon: Symbols.edit_note,
      color: Brand.edit,
      category: ToolCategory.edit,
      launcher: (c, p, pw) => _viewer(c, p, pw, ViewerMode.edit),
    ),
    PdfTool(
      id: 'comment',
      title: 'Comment',
      subtitle: 'Highlight, draw, add notes',
      icon: Symbols.chat_bubble_outline,
      color: Brand.comment,
      category: ToolCategory.edit,
      launcher: (c, p, pw) => _viewer(c, p, pw, ViewerMode.comment),
    ),
    PdfTool(
      id: 'fillsign',
      title: 'Fill & Sign',
      subtitle: 'Fill forms and add signatures',
      icon: Symbols.draw,
      color: Brand.sign,
      category: ToolCategory.edit,
      launcher: (c, p, pw) => _viewer(c, p, pw, ViewerMode.fillSign),
    ),
    PdfTool(
      id: 'scan',
      title: 'Scan',
      subtitle: 'Camera scan to PDF with OCR',
      icon: Symbols.document_scanner,
      color: Brand.scan,
      category: ToolCategory.create,
      needsFile: false,
      launcher: (c, p, pw) => _push(c, const ScannerScreen()),
    ),
    PdfTool(
      id: 'create',
      title: 'Create PDF',
      subtitle: 'From images, Word, text, Excel',
      icon: Symbols.note_add,
      color: Brand.convert,
      category: ToolCategory.create,
      needsFile: false,
      launcher: (c, p, pw) => _push(c, const CreatePdfScreen()),
    ),
    PdfTool(
      id: 'combine',
      title: 'Combine files',
      subtitle: 'Merge PDFs into one',
      icon: Symbols.merge_type,
      color: Brand.organize,
      category: ToolCategory.create,
      needsFile: false,
      launcher: (c, p, pw) => _push(c, CombineScreen(initial: p == null ? const [] : [p])),
    ),
    PdfTool(
      id: 'organize',
      title: 'Organize pages',
      subtitle: 'Reorder, rotate, insert, delete',
      icon: Symbols.grid_view,
      color: Brand.organize,
      category: ToolCategory.organize,
      launcher: (c, p, pw) => _withSession(c, p!, pw, (s) => OrganizeScreen(session: s)),
    ),
    PdfTool(
      id: 'split',
      title: 'Split PDF',
      subtitle: 'Divide into multiple files',
      icon: Symbols.call_split,
      color: Brand.organize,
      category: ToolCategory.organize,
      launcher: (c, p, pw) => _push(c, SplitScreen(path: p!, password: pw)),
    ),
    PdfTool(
      id: 'crop',
      title: 'Crop pages',
      subtitle: 'Trim page margins',
      icon: Symbols.crop,
      color: Brand.organize,
      category: ToolCategory.organize,
      launcher: (c, p, pw) => _withSession(c, p!, pw, (s) => CropScreen(session: s)),
    ),
    PdfTool(
      id: 'compress',
      title: 'Compress PDF',
      subtitle: 'Reduce file size',
      icon: Symbols.compress,
      color: Brand.compress,
      category: ToolCategory.organize,
      launcher: (c, p, pw) => _withSession(c, p!, pw, (s) => CompressScreen(session: s)),
    ),
    PdfTool(
      id: 'export',
      title: 'Export PDF',
      subtitle: 'To Word, text, HTML, images',
      icon: Symbols.ios_share,
      color: Brand.convert,
      category: ToolCategory.convert,
      launcher: (c, p, pw) => _push(c, ExportScreen(path: p!, password: pw)),
    ),
    PdfTool(
      id: 'ocr',
      title: 'Recognize text',
      subtitle: 'Make scans searchable (OCR)',
      icon: Symbols.text_snippet,
      color: Brand.scan,
      category: ToolCategory.convert,
      launcher: (c, p, pw) => _withSession(c, p!, pw, (s) => OcrScreen(session: s)),
    ),
    PdfTool(
      id: 'reflow',
      title: 'Smart reading',
      subtitle: 'Reflowed, adjustable reading view',
      icon: Symbols.chrome_reader_mode,
      color: Brand.convert,
      category: ToolCategory.convert,
      launcher: (c, p, pw) => _push(c, ReflowScreen(path: p!, password: pw)),
    ),
    PdfTool(
      id: 'protect',
      title: 'Protect PDF',
      subtitle: 'Passwords and permissions',
      icon: Symbols.lock_outline,
      color: Brand.protect,
      category: ToolCategory.protect,
      launcher: (c, p, pw) => _withSession(c, p!, pw, (s) => ProtectScreen(session: s)),
    ),
    PdfTool(
      id: 'redact',
      title: 'Redact',
      subtitle: 'Permanently remove content',
      icon: Symbols.format_color_fill,
      color: Colors.black87,
      category: ToolCategory.protect,
      launcher: (c, p, pw) => _viewer(c, p, pw, ViewerMode.redact),
    ),
    PdfTool(
      id: 'watermark',
      title: 'Add watermark',
      subtitle: 'Text or image watermark',
      icon: Symbols.water_drop,
      color: Brand.edit,
      category: ToolCategory.edit,
      launcher: (c, p, pw) =>
          _withSession(c, p!, pw, (s) => _ToolDialogHost(run: (ctx) => showWatermarkDialog(ctx, session: s))),
    ),
    PdfTool(
      id: 'pagenumbers',
      title: 'Page numbers',
      subtitle: 'Headers, footers and numbering',
      icon: Symbols.format_list_numbered,
      color: Brand.edit,
      category: ToolCategory.edit,
      launcher: (c, p, pw) =>
          _withSession(c, p!, pw, (s) => _ToolDialogHost(run: (ctx) => showPageNumbersDialog(ctx, session: s))),
    ),
    PdfTool(
      id: 'properties',
      title: 'Properties',
      subtitle: 'Metadata and document info',
      icon: Symbols.info,
      color: Brand.protect,
      category: ToolCategory.protect,
      launcher: (c, p, pw) => _withSession(c, p!, pw, (s) => PropertiesScreen(path: p, session: s)),
    ),
  ];

  static PdfTool byId(String id) => all.firstWhere((t) => t.id == id);

  /// Tools shown in a file's action sheet.
  static List<PdfTool> get fileTools => all.where((t) => t.needsFile || t.id == 'combine').toList();

  static const quickIds = ['edit', 'comment', 'scan', 'fillsign', 'combine', 'organize', 'compress', 'export'];
}

/// Hosts a modal tool dialog on its own route (so standalone sessions have a lifetime).
class _ToolDialogHost extends StatefulWidget {
  const _ToolDialogHost({required this.run});

  final Future<void> Function(BuildContext context) run;

  @override
  State<_ToolDialogHost> createState() => _ToolDialogHostState();
}

class _ToolDialogHostState extends State<_ToolDialogHost> {
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      await widget.run(context);
      if (mounted) Navigator.pop(context);
    });
  }

  @override
  Widget build(BuildContext context) => const Scaffold(backgroundColor: Colors.transparent, body: SizedBox());
}

/// Acrobat "More tools" item: pastel tile with the label underneath.
class ToolChip extends StatelessWidget {
  const ToolChip({super.key, required this.tool, required this.onTap, this.width = 84});

  final PdfTool tool;
  final VoidCallback onTap;
  final double width;

  @override
  Widget build(BuildContext context) => InkWell(
    borderRadius: BorderRadius.circular(8),
    onTap: onTap,
    child: SizedBox(
      width: width,
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 6),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ToolIconTile(icon: tool.icon, color: tool.color, size: 56),
            const SizedBox(height: 8),
            Text(
              tool.title,
              textAlign: TextAlign.center,
              maxLines: 2,
              style: TextStyle(fontSize: 13, height: 1.15, color: Theme.of(context).colorScheme.onSurface),
            ),
          ],
        ),
      ),
    ),
  );
}

/// List-style tool row (icon tile, title, description).
class ToolTile extends StatelessWidget {
  const ToolTile({super.key, required this.tool, required this.onTap});

  final PdfTool tool;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) => InkWell(
    onTap: onTap,
    child: Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
      child: Row(
        children: [
          ToolIconTile(icon: tool.icon, color: tool.color, size: 44),
          const SizedBox(width: 16),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(tool.title, style: const TextStyle(fontSize: 16)),
                Text(tool.subtitle, maxLines: 1, overflow: TextOverflow.ellipsis, style: Theme.of(context).textTheme.bodySmall),
              ],
            ),
          ),
        ],
      ),
    ),
  );
}
