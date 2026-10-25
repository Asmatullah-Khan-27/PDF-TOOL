import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import 'package:pdf_fit/core/state/app_state.dart';
import 'package:pdf_fit/core/storage/app_database.dart';
import 'package:pdf_fit/ui/screens/compress_screen.dart';
import 'package:pdf_fit/ui/screens/premium_screen.dart';
import 'package:pdf_fit/ui/widgets/common.dart';

/// Saved compression presets. Built-ins are seeded in SQLite; user presets are
/// real rows with a Basic-plan cap.
class PresetsScreen extends StatelessWidget {
  const PresetsScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final app = context.watch<AppState>();
    final scheme = Theme.of(context).colorScheme;
    final customs = app.presets.where((p) => !p.builtIn).length;
    final cap = app.entitlements.customPresetLimit;

    return Scaffold(
      appBar: AppBar(
        title: const Text('Presets'),
        actions: [
          IconButton(
            tooltip: 'New preset',
            icon: const Icon(Icons.add),
            onPressed: () => _showNewPresetDialog(context, app),
          ),
        ],
      ),
      body: SafeArea(
        child: ListView(
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 24),
          children: [
            Text(
              'Presets remember a target size so you can re-apply it to any document '
              'in one tap.',
              style: TextStyle(fontSize: 13, color: scheme.onSurfaceVariant),
            ),
            SectionHeader(
              title: 'Ready-made',
              action: Text(
                '${app.presets.where((p) => p.builtIn).length} presets',
                style: TextStyle(fontSize: 12, color: scheme.onSurfaceVariant),
              ),
            ),
            for (final preset in app.presets.where((p) => p.builtIn))
              Padding(
                padding: const EdgeInsets.only(bottom: 8),
                child: _PresetTile(preset: preset),
              ),
            SectionHeader(
              title: 'My presets',
              action: Text(
                app.isPremium ? '$customs saved' : '$customs of $cap used',
                style: TextStyle(fontSize: 12, color: scheme.onSurfaceVariant),
              ),
            ),
            if (app.presets.where((p) => !p.builtIn).isEmpty)
              Card(
                child: Padding(
                  padding: const EdgeInsets.all(16),
                  child: Row(
                    children: [
                      Icon(Icons.bookmark_add_outlined, color: scheme.onSurfaceVariant),
                      const SizedBox(width: 10),
                      const Expanded(
                        child: Text(
                          'No custom presets yet. Save the target size you use most '
                          'often.',
                          style: TextStyle(fontSize: 12.5),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            for (final preset in app.presets.where((p) => !p.builtIn))
              Padding(
                padding: const EdgeInsets.only(bottom: 8),
                child: Dismissible(
                  key: ValueKey(preset.id),
                  direction: DismissDirection.endToStart,
                  background: Container(
                    alignment: Alignment.centerRight,
                    padding: const EdgeInsets.only(right: 20),
                    decoration: BoxDecoration(
                      color: scheme.errorContainer,
                      borderRadius: BorderRadius.circular(18),
                    ),
                    child: Icon(Icons.delete, color: scheme.onErrorContainer),
                  ),
                  onDismissed: (_) => app.deletePreset(preset),
                  child: _PresetTile(preset: preset),
                ),
              ),
          ],
        ),
      ),
    );
  }

  Future<void> _showNewPresetDialog(BuildContext context, AppState app) async {
    if (!app.isPremium && (await app.db.customPresetCount()) >= app.entitlements.customPresetLimit) {
      if (!context.mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('Basic plan saves ${app.entitlements.customPresetLimit} custom preset. '
              'Premium is unlimited.'),
          action: SnackBarAction(
            label: 'Premium',
            onPressed: () => Navigator.of(context).push(
              MaterialPageRoute(builder: (_) => const PremiumScreen()),
            ),
          ),
        ),
      );
      return;
    }
    final nameController = TextEditingController();
    final sizeController = TextEditingController(text: '500');
    var grayscale = false;
    final saved = await showDialog<bool>(
      context: context,
      builder: (context) => StatefulBuilder(
        builder: (context, setState) => AlertDialog(
          title: const Text('New preset'),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              TextField(
                controller: nameController,
                decoration: const InputDecoration(labelText: 'Name'),
              ),
              const SizedBox(height: 10),
              TextField(
                controller: sizeController,
                keyboardType: TextInputType.number,
                decoration: const InputDecoration(
                  labelText: 'Target size',
                  suffixText: 'KB',
                ),
              ),
              SwitchListTile(
                contentPadding: EdgeInsets.zero,
                title: const Text('Grayscale'),
                value: grayscale,
                onChanged: (v) => setState(() => grayscale = v),
              ),
            ],
          ),
          actions: [
            TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('Cancel')),
            FilledButton(onPressed: () => Navigator.pop(context, true), child: const Text('Save')),
          ],
        ),
      ),
    );
    if (saved == true) {
      final name = nameController.text.trim();
      final kb = int.tryParse(sizeController.text.trim());
      if (name.isEmpty || kb == null || kb <= 0) {
        if (context.mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('Enter a name and a target size in KB.')),
          );
        }
        return;
      }
      await app.addPreset(name: name, targetBytes: kb * 1024, grayscale: grayscale);
    }
    nameController.dispose();
    sizeController.dispose();
  }
}

class _PresetTile extends StatelessWidget {
  const _PresetTile({required this.preset});

  final Preset preset;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Card(
      child: ListTile(
        leading: CircleAvatar(
          backgroundColor: scheme.secondaryContainer,
          child: Icon(
            preset.grayscale ? Icons.filter_b_and_w : Icons.compress,
            size: 19,
            color: scheme.onSecondaryContainer,
          ),
        ),
        title: Text(preset.name, style: const TextStyle(fontWeight: FontWeight.w600)),
        subtitle: Text(
          [
            preset.targetLabel,
            if (preset.grayscale) 'grayscale',
            if (!preset.allowDownscale) 'structure only',
          ].join(' · '),
          style: const TextStyle(fontSize: 12),
        ),
        trailing: FilledButton.tonal(
          onPressed: () {
            Navigator.of(context).push(
              MaterialPageRoute(
                builder: (_) => CompressScreen(
                  preselectTargetBytes: preset.targetBytes,
                  preselectGrayscale: preset.grayscale,
                ),
              ),
            );
          },
          child: const Text('Use'),
        ),
      ),
    );
  }
}
