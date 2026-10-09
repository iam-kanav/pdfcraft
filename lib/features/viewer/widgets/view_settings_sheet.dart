import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../../core/app_settings.dart';
import 'package:material_symbols_icons/symbols.dart';

Future<void> showViewSettingsSheet(BuildContext context) =>
    showModalBottomSheet<void>(context: context, isScrollControlled: true, builder: (ctx) => const _ViewSettings());

class _ViewSettings extends StatelessWidget {
  const _ViewSettings();

  @override
  Widget build(BuildContext context) {
    final s = context.watch<AppSettings>();
    return SafeArea(
      child: SingleChildScrollView(
        padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'View settings',
              style: Theme.of(context).textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w600),
            ),
            const SizedBox(height: 16),
            const Text('Page layout'),
            const SizedBox(height: 8),
            SegmentedButton<PageScrollMode>(
              segments: const [
                ButtonSegment(
                  value: PageScrollMode.continuous,
                  icon: Icon(Symbols.view_day),
                  label: Text('Continuous'),
                ),
                ButtonSegment(
                  value: PageScrollMode.singlePage,
                  icon: Icon(Symbols.view_carousel),
                  label: Text('Single page'),
                ),
              ],
              selected: {s.scrollMode},
              onSelectionChanged: (v) => s.scrollMode = v.first,
            ),
            const SizedBox(height: 16),
            SwitchListTile(
              contentPadding: EdgeInsets.zero,
              secondary: const Icon(Symbols.dark_mode),
              title: const Text('Night mode'),
              subtitle: const Text('Invert page colors for reading in the dark'),
              value: s.nightPages,
              onChanged: (v) => s.nightPages = v,
            ),
            const SizedBox(height: 8),
            const Text('App theme'),
            const SizedBox(height: 8),
            SegmentedButton<ThemeMode>(
              segments: const [
                ButtonSegment(value: ThemeMode.system, label: Text('System')),
                ButtonSegment(value: ThemeMode.light, label: Text('Light')),
                ButtonSegment(value: ThemeMode.dark, label: Text('Dark')),
              ],
              selected: {s.themeMode},
              onSelectionChanged: (v) => s.themeMode = v.first,
            ),
            const SizedBox(height: 16),
            Text('Read aloud speed', style: Theme.of(context).textTheme.bodyMedium),
            Slider(
              value: s.ttsRate,
              min: 0.2,
              max: 1.0,
              divisions: 8,
              label: s.ttsRate.toStringAsFixed(1),
              onChanged: (v) => s.ttsRate = v,
            ),
            Text('Voice pitch', style: Theme.of(context).textTheme.bodyMedium),
            Slider(
              value: s.ttsPitch,
              min: 0.5,
              max: 2.0,
              divisions: 6,
              label: s.ttsPitch.toStringAsFixed(1),
              onChanged: (v) => s.ttsPitch = v,
            ),
          ],
        ),
      ),
    );
  }
}
