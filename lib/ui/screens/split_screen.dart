import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import 'package:pdf_fit/core/files/file_service.dart';
import 'package:pdf_fit/core/pdf/pdf_operations.dart';
import 'package:pdf_fit/core/pdf/pdfium_engine.dart';
import 'package:pdf_fit/core/state/app_state.dart';
import 'package:pdf_fit/ui/screens/premium_screen.dart';
import 'package:pdf_fit/ui/widgets/common.dart';
import 'package:pdf_fit/ui/widgets/pdf_viewer_screen.dart';

enum SplitMode { everyN, ranges, singlePages, evenOdd }

class SplitScreen extends StatefulWidget {
  const SplitScreen({super.key});

  @override
  State<SplitScreen> createState() => _SplitScreenState();
}

class _SplitScreenState extends State<SplitScreen> {
  PickedFile? _file;
  PdfInspection? _inspection;
  SplitMode _mode = SplitMode.everyN;
  int _everyN = 1;
  final _rangesController = TextEditingController(text: '1-');
  bool _running = false;
  String? _error;
  final List<String> _outputs = [];

  @override
  void dispose() {
    _rangesController.dispose();
    super.dispose();
  }

  Future<void> _pick() async {
    setState(() {
      _error = null;
      _outputs.clear();
    });
    try {
      final files = await context.read<FileService>().pickPdfs();
      if (files.isEmpty) return;
      final file = files.first;
      final inspection = await inspectPdf(file.bytes, name: file.name);
      if (!mounted) return;
      setState(() {
        _file = file;
        _inspection = inspection;
        _rangesController.text = '1-';
      });
    } catch (e) {
      if (!mounted) return;
      setState(() => _error = _describe(e));
    }
  }

  String _describe(Object e) {
    if (e is PdfOperationException) return e.message;
    if (e is FilePickException) return e.message;
    return e.toString();
  }

  Future<void> _run() async {
    final file = _file;
    final inspection = _inspection;
    if (file == null || inspection == null) return;
    final premium = context.read<AppState>().isPremium;

    if (_mode == SplitMode.ranges && !premium) {
      _requirePremium('Page-range splitting is a Premium feature. Basic includes '
          'every-N-pages, single pages and odd/even splits.');
      return;
    }

    setState(() {
      _running = true;
      _error = null;
      _outputs.clear();
    });
    try {
      final fs = context.read<FileService>();
      final app = context.read<AppState>();
      final all = List<int>.generate(inspection.pageCount, (i) => i);
      final groups = <String, List<int>>{};

      switch (_mode) {
        case SplitMode.everyN:
          final chunks = splitIntoChunks(all, _everyN);
          for (var i = 0; i < chunks.length; i++) {
            groups['part_${i + 1}'] = chunks[i];
          }
        case SplitMode.ranges:
          final requested = parsePageRanges(_rangesController.text, inspection.pageCount);
          groups['extracted'] = requested;
        case SplitMode.singlePages:
          for (final page in all) {
            groups['page_${page + 1}'] = [page];
          }
        case SplitMode.evenOdd:
          final even = all.where((i) => (i + 1).isEven).toList();
          final odd = all.where((i) => (i + 1).isOdd).toList();
          if (even.isNotEmpty) groups['even_pages'] = even;
          if (odd.isNotEmpty) groups['odd_pages'] = odd;
      }

      if (groups.isEmpty) {
        throw PdfOperationException('Nothing to split: check your selection.');
      }

      final baseName = sanitizeFileName(file.name);
      for (final entry in groups.entries) {
        final result = await extractPages(
          file.bytes,
          entry.value,
          sourceName: file.name,
        );
        final path = await fs.saveOutput(
          bytes: result.bytes,
          baseName: '${baseName}_${entry.key}',
        );
        _outputs.add(path);
        await app.record(
          operation: 'split',
          sourceName: file.name,
          outputPath: path,
          outputName: path.split('/').last,
          originalBytes: file.size,
          outputBytes: await measuredOutputBytes(context.read<FileService>(), path,
            fallback: result.bytes.length),
          pageCount: result.pageCount,
          details: {'mode': _mode.name, 'group': entry.key},
        );
      }
      if (!mounted) return;
      setState(() => _running = false);
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Created ${_outputs.length} file(s) in app storage.')),
      );
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = _describe(e);
        _running = false;
      });
    }
  }

  void _requirePremium(String message) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(message),
        action: SnackBarAction(
          label: 'Premium',
          onPressed: () => Navigator.of(context).push(
            MaterialPageRoute(builder: (_) => const PremiumScreen()),
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final pages = _inspection?.pageCount;
    return Scaffold(
      appBar: AppBar(title: const Text('Split & extract')),
      body: SafeArea(
        child: ListView(
          padding: const EdgeInsets.all(16),
          children: [
            Card(
              child: ListTile(
                leading: const Icon(Icons.picture_as_pdf),
                title: Text(_file?.name ?? 'Select a PDF'),
                subtitle: Text(
                  _inspection == null
                      ? 'Tap to choose a document'
                      : '${_inspection!.pageCount} pages · ${formatBytes(_file!.size)}',
                ),
                trailing: TextButton(onPressed: _pick, child: Text(_file == null ? 'Choose' : 'Change')),
                onTap: _pick,
              ),
            ),
            if (_file != null && pages != null) ...[
              const SectionHeader(title: 'How do you want to split it?'),
              RadioListTile<SplitMode>(
                value: SplitMode.everyN,
                groupValue: _mode,
                onChanged: (v) => setState(() => _mode = v!),
                title: const Text('Every N pages'),
                subtitle: const Text('Useful for scanning batches'),
              ),
              if (_mode == SplitMode.everyN)
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 16),
                  child: Row(
                    children: [
                      const Text('Pages per file'),
                      const SizedBox(width: 12),
                      DropdownButton<int>(
                        value: _everyN,
                        items: [
                          for (var i = 1; i <= (pages > 10 ? 10 : pages); i++)
                            DropdownMenuItem(value: i, child: Text('$i')),
                        ],
                        onChanged: (v) => setState(() => _everyN = v ?? 1),
                      ),
                      const SizedBox(width: 12),
                      Text(
                        '→ ${(pages / _everyN).ceil()} file(s)',
                        style: TextStyle(fontSize: 12, color: scheme.onSurfaceVariant),
                      ),
                    ],
                  ),
                ),
              RadioListTile<SplitMode>(
                value: SplitMode.singlePages,
                groupValue: _mode,
                onChanged: (v) => setState(() => _mode = v!),
                title: const Text('One file per page'),
                subtitle: Text('Creates $pages files'),
              ),
              RadioListTile<SplitMode>(
                value: SplitMode.evenOdd,
                groupValue: _mode,
                onChanged: (v) => setState(() => _mode = v!),
                title: const Text('Odd and even pages'),
                subtitle: const Text('Two files, handy for duplex scanning'),
              ),
              RadioListTile<SplitMode>(
                value: SplitMode.ranges,
                groupValue: _mode,
                onChanged: (v) => setState(() => _mode = v!),
                title: Row(
                  children: [
                    const Text('Page range'),
                    const SizedBox(width: 6),
                    if (!context.watch<AppState>().isPremium) const PremiumBadge(),
                  ],
                ),
                subtitle: const Text('For example 1-3, 7, 9-'),
              ),
              if (_mode == SplitMode.ranges)
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 16),
                  child: TextField(
                    controller: _rangesController,
                    decoration: const InputDecoration(
                      labelText: 'Pages',
                      hintText: '1-3,5,8-',
                      helperText: 'Use a dash for ranges; leave the end open for "to the end".',
                    ),
                  ),
                ),
              const SizedBox(height: 16),
              FilledButton.icon(
                onPressed: _running ? null : _run,
                icon: _running
                    ? const SizedBox(
                        width: 18,
                        height: 18,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : const Icon(Icons.content_cut),
                label: Text(_running ? 'Splitting…' : 'Split now'),
              ),
            ],
            if (_error != null) ...[
              const SizedBox(height: 14),
              ErrorCard(message: _error!, onRetry: _run),
            ],
            if (_outputs.isNotEmpty) ...[
              const SectionHeader(title: 'Created files'),
              for (final path in _outputs)
                Card(
                  child: ListTile(
                    leading: const Icon(Icons.picture_as_pdf),
                    title: Text(path.split('/').last, maxLines: 1, overflow: TextOverflow.ellipsis),
                    trailing: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        IconButton(
                          tooltip: 'Preview',
                          icon: const Icon(Icons.visibility_outlined),
                          onPressed: () => Navigator.of(context).push(
                            MaterialPageRoute(
                              builder: (_) => PdfViewerScreen(filePath: path, title: 'Preview'),
                            ),
                          ),
                        ),
                        IconButton(
                          tooltip: 'Share',
                          icon: const Icon(Icons.share),
                          onPressed: () async {
                            try {
                              await context.read<FileService>().shareFile(path);
                            } catch (e) {
                              if (!context.mounted) return;
                              ScaffoldMessenger.of(context)
                                  .showSnackBar(SnackBar(content: Text(_describe(e))));
                            }
                          },
                        ),
                      ],
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
