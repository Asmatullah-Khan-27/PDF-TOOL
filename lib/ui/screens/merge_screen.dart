import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import 'package:pdf_fit/core/files/file_service.dart';
import 'package:pdf_fit/core/pdf/pdf_operations.dart';
import 'package:pdf_fit/core/pdf/pdfium_engine.dart';
import 'package:pdf_fit/core/state/app_state.dart';
import 'package:pdf_fit/core/storage/app_database.dart';
import 'package:pdf_fit/ui/screens/premium_screen.dart';
import 'package:pdf_fit/ui/widgets/common.dart';
import 'package:pdf_fit/ui/widgets/pdf_viewer_screen.dart';

class MergeScreen extends StatefulWidget {
  const MergeScreen({super.key});

  @override
  State<MergeScreen> createState() => _MergeScreenState();
}

class _MergeScreenState extends State<MergeScreen> {
  final List<PickedFile> _files = [];
  int? _pageTotal;
  bool _running = false;
  String? _error;
  String? _outputPath;

  Future<void> _add() async {
    final app = context.read<AppState>();
    final limit = app.entitlements.mergeFileLimit;
    try {
      final picked = await context.read<FileService>().pickPdfs(allowMultiple: true);
      if (picked.isEmpty) return;
      final allowed = picked.take(limit - _files.length).toList();
      final rejected = picked.length - allowed.length;
      setState(() {
        _files.addAll(allowed);
        _error = null;
      });
      if (rejected > 0) {
        _showLimit('The Basic plan merges up to $limit documents.', rejected);
      }
      await _sumPages();
    } catch (e) {
      if (!mounted) return;
      setState(() => _error = _describe(e));
    }
  }

  Future<void> _sumPages() async {
    var total = 0;
    for (final file in _files) {
      try {
        final inspection = await inspectPdf(file.bytes, name: file.name);
        total += inspection.pageCount;
      } catch (_) {
        // A file that cannot be inspected is surfaced when merging starts.
      }
    }
    if (mounted) setState(() => _pageTotal = total);
  }

  String _describe(Object e) {
    if (e is PdfOperationException) return e.message;
    if (e is FilePickException) return e.message;
    return e.toString();
  }

  void _showLimit(String message, int rejected) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text('$message $rejected file(s) were not added.'),
        action: SnackBarAction(
          label: 'Premium',
          onPressed: () => Navigator.of(context).push(
            MaterialPageRoute(builder: (_) => const PremiumScreen()),
          ),
        ),
      ),
    );
  }

  Future<void> _merge() async {
    if (_files.length < 2) {
      setState(() => _error = 'Add at least two PDFs to merge.');
      return;
    }
    setState(() {
      _running = true;
      _error = null;
      _outputPath = null;
    });
    try {
      final result = await mergePdfs([
        for (final f in _files) (name: f.name, bytes: f.bytes),
      ]);
      final path = await context.read<FileService>().saveOutput(
            bytes: result.bytes,
            baseName: 'merged_${DateTime.now().millisecondsSinceEpoch}',
          );
      if (!mounted) return;
      final app = context.read<AppState>();
      final entry = await app.record(
        operation: 'merge',
        sourceName: _files.map((f) => f.name).join(', '),
        outputPath: path,
        outputName: path.split('/').last,
        originalBytes: _files.fold<int>(0, (sum, f) => sum + f.size),
        outputBytes: await measuredOutputBytes(context.read<FileService>(), path,
            fallback: result.bytes.length),
        pageCount: result.pageCount,
        details: {'files': _files.length, 'notes': result.notes},
      );
      setState(() {
        _running = false;
        _outputPath = path;
      });
      if (mounted) {
        await showModalBottomSheet<void>(
          context: context,
          isScrollControlled: true,
          builder: (_) => ResultSheet(
            title: 'Merged ${_files.length} documents',
            subtitle: '${result.pageCount} pages, ${formatBytes(result.bytes.length)}',
            rows: [
              (label: 'Documents', value: '${_files.length}'),
              (label: 'Total pages', value: '${result.pageCount}'),
              (label: 'Size', value: formatBytes(result.bytes.length)),
              (label: 'Saved as', value: entry.outputName),
            ],
            notes: result.notes,
            onOpen: () => context.read<FileService>().openFile(path),
            onShare: () => context.read<FileService>().shareFile(path, subject: 'Merged PDF'),
          ),
        );
      }
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = _describe(e);
        _running = false;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final premium = context.watch<AppState>().isPremium;

    return Scaffold(
      appBar: AppBar(title: const Text('Merge PDFs')),
      body: SafeArea(
        child: ListView(
          padding: const EdgeInsets.all(16),
          children: [
            Text(
              premium
                  ? 'Add two or more PDFs. Drag the handle to change the order.'
                  : 'Basic plan merges up to 2 PDFs. Premium is unlimited.',
              style: TextStyle(fontSize: 13, color: scheme.onSurfaceVariant),
            ),
            const SizedBox(height: 12),
            if (_files.isEmpty)
              const EmptyState(
                icon: Icons.merge_type,
                title: 'No documents yet',
                message: 'Add PDFs to combine them into a single file.',
              ),
            if (_files.isNotEmpty)
              Card(
                child: Column(
                  children: [
                    for (var i = 0; i < _files.length; i++)
                      ListTile(
                        leading: CircleAvatar(
                          radius: 14,
                          child: Text('${i + 1}', style: const TextStyle(fontSize: 12)),
                        ),
                        title: Text(
                          _files[i].name,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                        subtitle: Text(formatBytes(_files[i].size)),
                        trailing: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            IconButton(
                              tooltip: 'Move up',
                              onPressed: i == 0
                                  ? null
                                  : () {
                                      setState(() {
                                        final f = _files.removeAt(i);
                                        _files.insert(i - 1, f);
                                      });
                                    },
                              icon: const Icon(Icons.arrow_upward, size: 18),
                            ),
                            IconButton(
                              tooltip: 'Remove',
                              onPressed: () {
                                setState(() => _files.removeAt(i));
                                _sumPages();
                              },
                              icon: const Icon(Icons.close, size: 18),
                            ),
                          ],
                        ),
                      ),
                    if (_pageTotal != null)
                      Padding(
                        padding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
                        child: Row(
                          children: [
                            Icon(Icons.info_outline, size: 15, color: scheme.onSurfaceVariant),
                            const SizedBox(width: 6),
                            Text(
                              'Combined document will have $_pageTotal pages',
                              style: TextStyle(fontSize: 12, color: scheme.onSurfaceVariant),
                            ),
                          ],
                        ),
                      ),
                  ],
                ),
              ),
            const SizedBox(height: 12),
            OutlinedButton.icon(
              onPressed: _add,
              icon: const Icon(Icons.add),
              label: const Text('Add PDFs'),
            ),
            const SizedBox(height: 10),
            FilledButton.icon(
              onPressed: _running || _files.length < 2 ? null : _merge,
              icon: _running
                  ? const SizedBox(
                      width: 18,
                      height: 18,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : const Icon(Icons.merge_type),
              label: Text(_running ? 'Merging…' : 'Merge into one PDF'),
            ),
            if (_error != null) ...[
              const SizedBox(height: 14),
              ErrorCard(message: _error!, onRetry: _merge),
            ],
            if (_outputPath != null) ...[
              const SizedBox(height: 14),
              Card(
                child: ListTile(
                  leading: const PdfThumbnail(path: ''),
                  title: const Text('Merged PDF ready'),
                  subtitle: Text(_outputPath!.split('/').last),
                  trailing: const Icon(Icons.chevron_right),
                  onTap: () => Navigator.of(context).push(
                    MaterialPageRoute(
                      builder: (_) => PdfViewerScreen(
                        filePath: _outputPath,
                        title: 'Merged PDF',
                      ),
                    ),
                  ),
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }
}
