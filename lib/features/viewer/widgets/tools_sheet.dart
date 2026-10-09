import 'package:flutter/material.dart';

import '../../../theme/app_theme.dart';
import '../../convert/export_screen.dart';
import '../../convert/ocr_screen.dart';
import '../../organize/organize_screen.dart';
import '../../reflow/reflow_screen.dart';
import '../../security/protect_screen.dart';
import '../../tools/compress_screen.dart';
import '../../tools/stamp_dialogs.dart';
import '../viewer_screen.dart';
import '../viewer_state.dart';

class _ViewerTool {
  const _ViewerTool(this.label, this.icon, this.color, this.onTap);

  final String label;
  final IconData icon;
  final Color color;
  final void Function(BuildContext context, ViewerHost host) onTap;
}

final _tools = <_ViewerTool>[
  _ViewerTool('Comment', Icons.chat_bubble_outline, Brand.comment, (c, h) => h.setMode(ViewerMode.comment)),
  _ViewerTool('Edit PDF', Icons.edit_note, Brand.edit, (c, h) => h.setMode(ViewerMode.edit)),
  _ViewerTool('Fill & Sign', Icons.draw_outlined, Brand.sign, (c, h) => h.setMode(ViewerMode.fillSign)),
  _ViewerTool('Organize pages', Icons.grid_view, Brand.organize, (c, h) => _push(c, h, OrganizeScreen(session: h.session))),
  _ViewerTool('Smart reading', Icons.chrome_reader_mode_outlined, Brand.convert, (c, h) => _push(c, h, ReflowScreen(path: h.session.path, password: h.session.password))),
  _ViewerTool('Recognize text', Icons.document_scanner_outlined, Brand.scan, (c, h) => _push(c, h, OcrScreen(session: h.session))),
  _ViewerTool('Export PDF', Icons.ios_share, Brand.convert, (c, h) => _push(c, h, ExportScreen(path: h.session.path, password: h.session.password))),
  _ViewerTool('Compress', Icons.compress, Brand.compress, (c, h) => _push(c, h, CompressScreen(session: h.session))),
  _ViewerTool('Protect', Icons.lock_outline, Brand.protect, (c, h) => _push(c, h, ProtectScreen(session: h.session))),
  _ViewerTool('Redact', Icons.format_color_fill, Colors.black87, (c, h) => h.setMode(ViewerMode.redact)),
  _ViewerTool('Watermark', Icons.water_drop_outlined, Brand.edit, (c, h) => showWatermarkDialog(c, session: h.session)),
  _ViewerTool('Page numbers', Icons.format_list_numbered, Brand.edit, (c, h) => showPageNumbersDialog(c, session: h.session)),
];

Future<void> _push(BuildContext context, ViewerHost host, Widget screen) async {
  await Navigator.of(context).push(MaterialPageRoute(builder: (_) => screen));
  host.refreshAnnotations();
}

/// Acrobat-like "All tools" panel inside the viewer.
Future<void> showViewerTools(BuildContext context, ViewerHost host) => showModalBottomSheet<void>(
  context: context,
  isScrollControlled: true,
  builder: (ctx) => SafeArea(
    child: Padding(
      padding: const EdgeInsets.fromLTRB(12, 0, 12, 12),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(8, 0, 8, 12),
            child: Text('All tools', style: Theme.of(ctx).textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w600)),
          ),
          GridView.count(
            crossAxisCount: 4,
            shrinkWrap: true,
            mainAxisSpacing: 8,
            crossAxisSpacing: 4,
            childAspectRatio: 0.82,
            physics: const NeverScrollableScrollPhysics(),
            children: [
              for (final t in _tools)
                InkWell(
                  borderRadius: BorderRadius.circular(12),
                  onTap: () {
                    Navigator.pop(ctx);
                    t.onTap(context, host);
                  },
                  child: Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      Container(
                        width: 48,
                        height: 48,
                        decoration: BoxDecoration(color: t.color.withValues(alpha: 0.12), borderRadius: BorderRadius.circular(14)),
                        child: Icon(t.icon, color: t.color),
                      ),
                      const SizedBox(height: 6),
                      Text(t.label, textAlign: TextAlign.center, maxLines: 2, style: const TextStyle(fontSize: 12)),
                    ],
                  ),
                ),
            ],
          ),
        ],
      ),
    ),
  ),
);
