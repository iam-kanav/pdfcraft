import 'package:flutter/material.dart';
import 'package:pdfcraft/features/reflow/reading_settings.dart';

/// The "Aa" panel of Smart Reading Mode: text size, spacing, font, alignment,
/// margins and color theme.
class ReadingSettingsSheet extends StatelessWidget {
  const ReadingSettingsSheet({super.key, required this.settings});

  final ReadingSettings settings;

  /// Shows the sheet as a modal bottom sheet.
  static Future<void> show(BuildContext context, ReadingSettings settings) {
    return showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      isScrollControlled: true,
      useSafeArea: true,
      builder: (_) => ReadingSettingsSheet(settings: settings),
    );
  }

  static const _familyLabels = {'sans': 'Sans', 'serif': 'Serif', 'mono': 'Mono'};

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: settings,
      builder: (context, _) {
        final theme = Theme.of(context);
        final labelStyle = theme.textTheme.labelLarge?.copyWith(color: theme.colorScheme.onSurfaceVariant);
        Widget label(String text) => Padding(
              padding: const EdgeInsets.only(top: 16, bottom: 6),
              child: Text(text, style: labelStyle),
            );

        return SingleChildScrollView(
          padding: const EdgeInsets.fromLTRB(20, 0, 20, 24),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            mainAxisSize: MainAxisSize.min,
            children: [
              Row(
                children: [
                  Text('Reading settings', style: theme.textTheme.titleMedium),
                  const Spacer(),
                  TextButton(onPressed: settings.reset, child: const Text('Reset')),
                ],
              ),
              label('Text size  ${(settings.fontScale * 100).round()}%'),
              Row(
                children: [
                  IconButton(
                    key: const ValueKey('reading-font-smaller'),
                    tooltip: 'Smaller text',
                    onPressed: settings.fontScale > ReadingSettings.minFontScale
                        ? () => settings.adjustFontScale(-0.1)
                        : null,
                    icon: const Text('A-', style: TextStyle(fontSize: 14, fontWeight: FontWeight.w600)),
                  ),
                  Expanded(
                    child: Slider(
                      value: settings.fontScale,
                      min: ReadingSettings.minFontScale,
                      max: ReadingSettings.maxFontScale,
                      divisions: 12,
                      label: '${(settings.fontScale * 100).round()}%',
                      onChanged: settings.setFontScale,
                    ),
                  ),
                  IconButton(
                    key: const ValueKey('reading-font-larger'),
                    tooltip: 'Larger text',
                    onPressed: settings.fontScale < ReadingSettings.maxFontScale
                        ? () => settings.adjustFontScale(0.1)
                        : null,
                    icon: const Text('A+', style: TextStyle(fontSize: 20, fontWeight: FontWeight.w600)),
                  ),
                ],
              ),
              label('Line spacing  ${settings.lineHeight.toStringAsFixed(1)}'),
              Row(
                children: [
                  const Icon(Icons.density_small, size: 20),
                  Expanded(
                    child: Slider(
                      value: settings.lineHeight,
                      min: ReadingSettings.minLineHeight,
                      max: ReadingSettings.maxLineHeight,
                      divisions: 10,
                      label: settings.lineHeight.toStringAsFixed(1),
                      onChanged: settings.setLineHeight,
                    ),
                  ),
                  const Icon(Icons.density_large, size: 20),
                ],
              ),
              label('Font'),
              Wrap(
                spacing: 8,
                children: [
                  for (final f in ReadingSettings.fontFamilies)
                    ChoiceChip(
                      label: Text(
                        _familyLabels[f]!,
                        style: TextStyle(fontFamily: switch (f) {
                          'serif' => 'serif',
                          'mono' => 'monospace',
                          _ => null,
                        }),
                      ),
                      selected: settings.fontFamily == f,
                      onSelected: (_) => settings.setFontFamily(f),
                    ),
                ],
              ),
              label('Alignment'),
              SegmentedButton<TextAlign>(
                segments: const [
                  ButtonSegment(value: TextAlign.left, icon: Icon(Icons.format_align_left), label: Text('Left')),
                  ButtonSegment(value: TextAlign.justify, icon: Icon(Icons.format_align_justify), label: Text('Justify')),
                ],
                selected: {settings.textAlign},
                onSelectionChanged: (s) => settings.setTextAlign(s.first),
              ),
              label('Margins'),
              SegmentedButton<ReadingMargin>(
                segments: [
                  for (final m in ReadingMargin.values) ButtonSegment(value: m, label: Text(m.label)),
                ],
                selected: {settings.margin},
                onSelectionChanged: (s) => settings.setMargin(s.first),
              ),
              label('Theme'),
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceAround,
                children: [
                  for (final t in ReadingTheme.values)
                    _ThemeSwatch(
                      theme: t,
                      selected: settings.theme == t,
                      onTap: () => settings.setTheme(t),
                    ),
                ],
              ),
            ],
          ),
        );
      },
    );
  }
}

class _ThemeSwatch extends StatelessWidget {
  const _ThemeSwatch({required this.theme, required this.selected, required this.onTap});

  final ReadingTheme theme;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final c = theme.colors;
    final ring = Theme.of(context).colorScheme.primary;
    return Semantics(
      button: true,
      selected: selected,
      label: '${theme.label} theme',
      child: InkWell(
        key: ValueKey('reading-theme-${theme.name}'),
        customBorder: const CircleBorder(),
        onTap: onTap,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            AnimatedContainer(
              duration: const Duration(milliseconds: 150),
              width: 52,
              height: 52,
              alignment: Alignment.center,
              decoration: BoxDecoration(
                color: c.background,
                shape: BoxShape.circle,
                border: Border.all(color: selected ? ring : c.divider, width: selected ? 3 : 1),
              ),
              child: Text('Aa', style: TextStyle(color: c.text, fontWeight: FontWeight.w600, fontSize: 16)),
            ),
            const SizedBox(height: 4),
            Text(theme.label, style: Theme.of(context).textTheme.labelSmall),
          ],
        ),
      ),
    );
  }
}
