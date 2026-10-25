import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import 'package:pdf_fit/core/files/file_service.dart';
import 'package:pdf_fit/core/pdf/pdf_operations.dart';
import 'package:pdf_fit/core/pdf/pdfium_engine.dart';
import 'package:pdf_fit/core/state/app_state.dart';
import 'package:pdf_fit/ui/widgets/common.dart';
import 'package:pdf_fit/ui/widgets/pdf_viewer_screen.dart';

class RotateScreen extends StatefulWidget {
  const RotateScreen({super.key});

  @override
  State<RotateScreen> createState() => _RotateScreenState();
}

class _RotateScreenState extends State<RotateScreen> {
  PickedFile? _file;
  PdfInspection? _inspection;
  bool _allPages = true;
  final Set<int> _selected = {};
  int _quarterTurns = 1; // 90° clockwise by default
  bool _running = false;
  String? _error;
  String? _outputPath;

  Future<void> _pick() async {
    setState(() {
      _error = null;
      _outputPath = null;
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
        _selected.clear();
        _allPages = true;
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
    if (!_allPages && _selected.isEmpty) {
      setState(() => _error = 'Select at least one page to rotate.');
      return;
    }
    setState(() {
      _running = true;
      _error = null;
      _outputPath = null;
    });
    try {
      final map = <int, int>{};
      if (_allPages) {
        for (var i = 0; i < inspection.pageCount; i++) {
          map[i] = _quarterTurns;
        }
      } else {
        for (final page in _selected) {
          map[page] = _quarterTurns;
        }
      }
      final result = await rotatePages(file.bytes, map, sourceName: file.name);
      final path = await context.read<FileService>().saveOutput(
            bytes: result.bytes,
            baseName: '${sanitizeFileName(file.name)}_rotated',
          );
      if (!mounted) return;
      await context.read<AppState>().record(
            operation: 'rotate',
            sourceName: file.name,
            outputPath: path,
            outputName: path.split('/').last,
            originalBytes: file.size,
            outputBytes: await measuredOutputBytes(context.read<FileService>(), path,
            fallback: result.bytes.length),
            pageCount: result.pageCount,
            details: {
              'degrees': _quarterTurns * 90,
              'pages': _allPages ? 'all' : _selected.length,
            },
          );
      if (!mounted) return;
      setState(() {
        _running = false;
        _outputPath = path;
      });
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('Rotated ${_allPages ? "all pages" : "${_selected.length} page(s)"} '
              'by ${_quarterTurns * 90}°.'),
          action: SnackBarAction(
            label: 'Preview',
            onPressed: () => Navigator.of(context).push(
              MaterialPageRoute(
                builder: (_) => PdfViewerScreen(filePath: path, title: 'Rotated PDF'),
              ),
            ),
          ),
        ),
      );
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
    final pages = _inspection?.pageCount ?? 0;
    return Scaffold(
      appBar: AppBar(title: const Text('Rotate pages')),
      body: SafeArea(
        child: ListView(
          padding: const EdgeInsets.all(16),
          children: [
            Card(
              child: ListTile(
                leading: const Icon(Icons.picture_as_pdf),
                title: Text(_file?.name ?? 'Select a PDF'),
                subtitle: Text(_file == null ? 'Tap to choose a document' : '$pages pages'),
                trailing: TextButton(onPressed: _pick, child: Text(_file == null ? 'Choose' : 'Change')),
                onTap: _pick,
              ),
            ),
            if (_file != null) ...[
              const SectionHeader(title: 'Rotation'),
              SegmentedButton<int>(
                segments: const [
                  ButtonSegment(value: 1, label: Text('90°'), icon: Icon(Icons.rotate_90_degrees_cw)),
                  ButtonSegment(value: 2, label: Text('180°'), icon: Icon(Icons.flip)),
                  ButtonSegment(value: 3, label: Text('270°'), icon: Icon(Icons.rotate_90_degrees_ccw)),
                ],
                selected: {_quarterTurns},
                onSelectionChanged: (s) => setState(() => _quarterTurns = s.first),
              ),
              const SizedBox(height: 8),
              SwitchListTile(
                contentPadding: EdgeInsets.zero,
                title: const Text('Apply to all pages'),
                value: _allPages,
                onChanged: (v) => setState(() => _allPages = v),
              ),
              if (!_allPages) ...[
                Text(
                  'Tap the pages to rotate (${_selected.length} selected)',
                  style: TextStyle(fontSize: 13, color: scheme.onSurfaceVariant),
                ),
                const SizedBox(height: 8),
                Wrap(
                  spacing: 6,
                  runSpacing: 6,
                  children: [
                    for (var i = 0; i < pages; i++)
                      FilterChip(
                        label: Text('${i + 1}'),
                        selected: _selected.contains(i),
                        onSelected: (on) => setState(() {
                          if (on) {
                            _selected.add(i);
                          } else {
                            _selected.remove(i);
                          }
                        }),
                      ),
                  ],
                ),
              ],
              const SizedBox(height: 16),
              FilledButton.icon(
                onPressed: _running ? null : _run,
                icon: _running
                    ? const SizedBox(
                        width: 18,
                        height: 18,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : const Icon(Icons.rotate_right),
                label: Text(_running ? 'Rotating…' : 'Rotate and save'),
              ),
            ],
            if (_error != null) ...[
              const SizedBox(height: 14),
              ErrorCard(message: _error!, onRetry: _run),
            ],
            if (_outputPath != null) ...[
              const SizedBox(height: 14),
              Card(
                child: ListTile(
                  leading: const Icon(Icons.check_circle, color: Colors.green),
                  title: const Text('Rotated PDF saved'),
                  subtitle: Text(_outputPath!.split('/').last),
                  trailing: const Icon(Icons.chevron_right),
                  onTap: () => Navigator.of(context).push(
                    MaterialPageRoute(
                      builder: (_) => PdfViewerScreen(filePath: _outputPath, title: 'Rotated PDF'),
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
