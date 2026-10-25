import 'dart:io';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import 'package:pdf_fit/core/files/file_service.dart';
import 'package:pdf_fit/core/state/app_state.dart';
import 'package:pdf_fit/core/storage/app_database.dart';
import 'package:pdf_fit/ui/widgets/common.dart';
import 'package:pdf_fit/ui/widgets/pdf_viewer_screen.dart';

/// Document history backed by real SQLite rows; each entry points at a file that
/// actually exists on disk (existence is re-checked before offering actions).
class HistoryScreen extends StatelessWidget {
  const HistoryScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final app = context.watch<AppState>();
    final scheme = Theme.of(context).colorScheme;

    return Scaffold(
      appBar: AppBar(
        title: const Text('History'),
        actions: [
          if (app.history.isNotEmpty)
            IconButton(
              tooltip: 'Clear history',
              icon: const Icon(Icons.delete_sweep_outlined),
              onPressed: () => _confirmClear(context, app),
            ),
        ],
      ),
      body: SafeArea(
        child: RefreshIndicator(
          onRefresh: app.refreshAll,
          child: app.history.isEmpty
              ? ListView(
                  children: const [
                    EmptyState(
                      icon: Icons.history,
                      title: 'Nothing here yet',
                      message: 'Documents you compress or edit appear here with their '
                          'exact before/after sizes.',
                    ),
                  ],
                )
              : ListView.separated(
                  padding: const EdgeInsets.fromLTRB(16, 8, 16, 24),
                  itemCount: app.history.length + 1,
                  separatorBuilder: (_, __) => const SizedBox(height: 8),
                  itemBuilder: (context, index) {
                    if (index == app.history.length) {
                      return Padding(
                        padding: const EdgeInsets.only(top: 12),
                        child: Text(
                          app.isPremium
                              ? 'Premium keeps your full history.'
                              : 'Basic keeps the last ${app.entitlements.historyLimit} entries. '
                                  'Files you already shared or saved are unaffected.',
                          textAlign: TextAlign.center,
                          style: TextStyle(fontSize: 11.5, color: scheme.onSurfaceVariant),
                        ),
                      );
                    }
                    final entry = app.history[index];
                    return _HistoryTile(entry: entry);
                  },
                ),
        ),
      ),
    );
  }

  Future<void> _confirmClear(BuildContext context, AppState app) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Clear history?'),
        content: const Text(
          'This removes the history list. Files already saved or shared are not deleted.',
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('Cancel')),
          FilledButton(onPressed: () => Navigator.pop(context, true), child: const Text('Clear')),
        ],
      ),
    );
    if (confirmed ?? false) await app.clearHistory();
  }
}

class _HistoryTile extends StatelessWidget {
  const _HistoryTile({required this.entry});

  final HistoryEntry entry;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final exists = entry.outputPath.isNotEmpty && File(entry.outputPath).existsSync();
    final saved = entry.originalBytes - entry.outputBytes;
    final improvement = entry.originalBytes == 0 ? 0.0 : (saved / entry.originalBytes) * 100;

    return Card(
      child: InkWell(
        borderRadius: BorderRadius.circular(18),
        onTap: exists
            ? () => Navigator.of(context).push(
                  MaterialPageRoute(
                    builder: (_) => PdfViewerScreen(
                      filePath: entry.outputPath,
                      title: entry.outputName,
                    ),
                  ),
                )
            : null,
        child: Padding(
          padding: const EdgeInsets.all(14),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  CircleAvatar(
                    radius: 16,
                    backgroundColor: scheme.primaryContainer,
                    child: Icon(_iconFor(entry.operation), size: 17),
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          _labelFor(entry.operation),
                          style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 14),
                        ),
                        Text(
                          entry.sourceName,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(fontSize: 11.5, color: scheme.onSurfaceVariant),
                        ),
                      ],
                    ),
                  ),
                  Text(
                    relativeTime(entry.createdAt),
                    style: TextStyle(fontSize: 11, color: scheme.onSurfaceVariant),
                  ),
                ],
              ),
              const SizedBox(height: 10),
              Wrap(
                spacing: 14,
                runSpacing: 4,
                children: [
                  _Stat(label: 'Before', value: formatBytes(entry.originalBytes)),
                  _Stat(label: 'After', value: formatBytes(entry.outputBytes)),
                  if (entry.operation == 'compress' && entry.originalBytes > 0)
                    _Stat(
                      label: 'Change',
                      value: '${improvement >= 0 ? "-" : "+"}${improvement.abs().toStringAsFixed(0)}%',
                      highlight: improvement > 0,
                    ),
                  if (entry.pageCount > 0) _Stat(label: 'Pages', value: '${entry.pageCount}'),
                ],
              ),
              if (!exists) ...[
                const SizedBox(height: 8),
                Row(
                  children: [
                    Icon(Icons.info_outline, size: 14, color: scheme.error),
                    const SizedBox(width: 4),
                    Expanded(
                      child: Text(
                        'The output file is no longer on this device.',
                        style: TextStyle(fontSize: 11.5, color: scheme.error),
                      ),
                    ),
                  ],
                ),
              ],
              if (exists)
                Align(
                  alignment: Alignment.centerRight,
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      IconButton(
                        tooltip: 'Share',
                        icon: const Icon(Icons.share, size: 19),
                        onPressed: () async {
                          try {
                            await context.read<FileService>().shareFile(entry.outputPath);
                          } catch (e) {
                            if (!context.mounted) return;
                            ScaffoldMessenger.of(context)
                                .showSnackBar(SnackBar(content: Text(e.toString())));
                          }
                        },
                      ),
                      IconButton(
                        tooltip: 'Delete entry',
                        icon: const Icon(Icons.delete_outline, size: 19),
                        onPressed: () async {
                          final fileService = context.read<FileService>();
                          final app = context.read<AppState>();
                          await fileService.deleteFile(entry.outputPath);
                          await app.deleteHistory(entry);
                        },
                      ),
                    ],
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }

  static String _labelFor(String operation) => switch (operation) {
        'compress' => 'Compressed',
        'merge' => 'Merged',
        'split' => 'Split',
        'rotate' => 'Rotated',
        'images_to_pdf' => 'Images to PDF',
        'resize' => 'Resized',
        _ => operation,
      };

  static IconData _iconFor(String operation) => switch (operation) {
        'compress' => Icons.compress,
        'merge' => Icons.merge_type,
        'split' => Icons.content_cut,
        'rotate' => Icons.rotate_right,
        'images_to_pdf' => Icons.photo_library_outlined,
        _ => Icons.description_outlined,
      };
}

class _Stat extends StatelessWidget {
  const _Stat({required this.label, required this.value, this.highlight = false});

  final String label;
  final String value;
  final bool highlight;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(label, style: TextStyle(fontSize: 10, color: scheme.onSurfaceVariant)),
        Text(
          value,
          style: TextStyle(
            fontSize: 13,
            fontWeight: FontWeight.w700,
            color: highlight ? Colors.green.shade700 : null,
          ),
        ),
      ],
    );
  }
}
