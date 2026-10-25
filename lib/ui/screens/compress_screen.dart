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

/// Preset target sizes offered as quick chips.
class TargetPreset {
  const TargetPreset(this.label, this.bytes);
  final String label;
  final int? bytes;
}

const _targets = <TargetPreset>[
  TargetPreset('100 KB', 100 * 1024),
  TargetPreset('200 KB', 200 * 1024),
  TargetPreset('500 KB', 500 * 1024),
  TargetPreset('1 MB', 1024 * 1024),
  TargetPreset('2 MB', 2 * 1024 * 1024),
  TargetPreset('5 MB', 5 * 1024 * 1024),
  TargetPreset('Best effort', null),
];

class CompressScreen extends StatefulWidget {
  const CompressScreen({
    super.key,
    this.preselectTargetBytes,
    this.preselectGrayscale = false,
  });

  /// Used when arriving from a preset or the upload checker.
  final int? preselectTargetBytes;
  final bool preselectGrayscale;

  @override
  State<CompressScreen> createState() => _CompressScreenState();
}

class _CompressScreenState extends State<CompressScreen> {
  PickedFile? _file;
  PdfInspection? _inspection;
  int? _targetBytes = 500 * 1024;
  bool _grayscale = false;

  @override
  void initState() {
    super.initState();
    if (widget.preselectTargetBytes != null) {
      _targetBytes = widget.preselectTargetBytes;
      // A preset target that is not one of the quick chips opens the custom field.
      if (!_targets.any((t) => t.bytes == widget.preselectTargetBytes)) {
        _customTarget = true;
        _customController.text = (widget.preselectTargetBytes! ~/ 1024).toString();
      }
    }
    _grayscale = widget.preselectGrayscale;
  }

  bool _allowDownscale = true;
  bool _customTarget = false;
  final _customController = TextEditingController();

  bool _loadingFile = false;
  bool _running = false;
  String? _error;
  CompressionResult? _result;
  String? _outputPath;

  @override
  void dispose() {
    _customController.dispose();
    super.dispose();
  }

  Future<void> _pick() async {
    setState(() {
      _loadingFile = true;
      _error = null;
      _result = null;
      _outputPath = null;
    });
    try {
      final files = await context.read<FileService>().pickPdfs();
      if (files.isEmpty) {
        setState(() => _loadingFile = false);
        return;
      }
      final file = files.first;
      final inspection = await inspectPdf(file.bytes, name: file.name);
      if (!mounted) return;
      setState(() {
        _file = file;
        _inspection = inspection;
        _loadingFile = false;
        // Default the target to something smaller than the source.
        if (_targetBytes != null && file.size <= _targetBytes!) {
          _targetBytes = 500 * 1024;
        }
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = _describe(e);
        _loadingFile = false;
      });
    }
  }

  String _describe(Object e) {
    if (e is PdfOperationException) return e.message;
    if (e is FilePickException) return e.message;
    return e.toString();
  }

  Future<void> _run() async {
    final file = _file;
    final app = context.read<AppState>();
    if (file == null) return;

    // Free-tier quota is enforced from measured history, not a local counter.
    final blocked = app.compressionBlockedReason();
    if (blocked != null) {
      setState(() => _error = blocked);
      return;
    }
    if (!context.read<AppState>().entitlements.allowsTargetSize(_effectiveTarget)) {
      _showPremiumRequired('That target size is a Premium feature.');
      return;
    }

    setState(() {
      _running = true;
      _error = null;
      _result = null;
      _outputPath = null;
    });
    try {
      final result = await compressPdf(
        file.bytes,
        targetBytes: _effectiveTarget,
        config: CompressionConfig(
          targetBytes: _effectiveTarget,
          grayscale: _grayscale,
          allowDownscale: _allowDownscale,
        ),
      );
      final baseName = '${sanitizeFileName(file.name)}_${_targetBytes == null ? "optimised" : formatBytes(_targetBytes!).replaceAll(" ", "")}';
      final path = await context.read<FileService>().saveOutput(
            bytes: result.bytes,
            baseName: baseName,
          );
      if (!mounted) return;
      final entry = await app.record(
        operation: 'compress',
        sourceName: file.name,
        outputPath: path,
        outputName: path.split('/').last,
        originalBytes: result.originalBytes,
        outputBytes: await measuredOutputBytes(context.read<FileService>(), path,
            fallback: result.bytes.length),
        pageCount: _inspection?.pageCount ?? 0,
        details: {
          'target': result.targetBytes,
          'dpi': result.dpi,
          'quality': result.jpegQuality,
          'strategy': result.strategy,
          'vectorPreserved': result.vectorPreserved,
          'targetMet': result.targetMet,
          'grayscale': _grayscale,
          'ms': result.elapsed.inMilliseconds,
        },
      );
      setState(() {
        _result = result;
        _outputPath = path;
        _running = false;
      });
      if (mounted) _showResult(entry);
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = _describe(e);
        _running = false;
      });
    }
  }

  int? get _effectiveTarget {
    if (_customTarget) {
      final kb = int.tryParse(_customController.text.trim());
      if (kb == null || kb <= 0) return null;
      return kb * 1024;
    }
    return _targetBytes;
  }

  void _showPremiumRequired(String message) {
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

  void _showResult(HistoryEntry entry) {
    final result = _result;
    if (result == null) return;
    showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      showDragHandle: false,
      builder: (_) => ResultSheet(
        title: result.targetMet ? 'Target reached' : 'Compressed (target not reached)',
        subtitle: '${formatBytes(result.originalBytes)} → ${formatBytes(result.bytes.length)}'
            ' (${result.savedPercent >= 0 ? "-" : "+"}${result.savedPercent.abs().toStringAsFixed(1)}%)',
        rows: [
          (label: 'Original', value: formatBytes(result.originalBytes)),
          (label: 'Result', value: formatBytes(result.bytes.length)),
          if (_targetBytes != null || _effectiveTarget != null)
            (label: 'Target', value: formatBytes(_effectiveTarget ?? 0)),
          (label: 'Method', value: result.vectorPreserved ? 'Structure preserved' : 'Page resampling'),
          if (!result.vectorPreserved) ...[
            (label: 'Resolution', value: '${result.dpi.round()} dpi'),
            (label: 'JPEG quality', value: '${result.jpegQuality}'),
          ],
          (label: 'Time', value: '${(result.elapsed.inMilliseconds / 1000).toStringAsFixed(1)} s'),
          (label: 'Saved to', value: entry.outputName),
        ],
        notes: result.notes,
        onOpen: () => _openResult(entry),
        onShare: () => _shareResult(entry),
        onViewDetails: () {
          Navigator.of(context).pop();
          _showVerificationDetails(result);
        },
      ),
    );
  }

  void _showVerificationDetails(CompressionResult result) {
    showDialog<void>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Every attempt (measured)'),
        content: SingleChildScrollView(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                'Each row is the real output size of the PDF actually built. The '
                'smallest result that met the target was kept.',
                style: Theme.of(context).textTheme.bodySmall,
              ),
              const SizedBox(height: 12),
              for (final attempt in result.attempts)
                Padding(
                  padding: const EdgeInsets.symmetric(vertical: 3),
                  child: Row(
                    children: [
                      Expanded(
                        child: Text(
                          attempt.dpi == 0
                              ? attempt.strategy
                              : '${attempt.dpi.round()} dpi · q${attempt.quality}',
                          style: const TextStyle(fontSize: 12.5),
                        ),
                      ),
                      Text(
                        formatBytes(attempt.bytes),
                        style: const TextStyle(fontSize: 12.5, fontWeight: FontWeight.w600),
                      ),
                    ],
                  ),
                ),
            ],
          ),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.of(context).pop(), child: const Text('Close')),
        ],
      ),
    );
  }

  Future<void> _openResult(HistoryEntry entry) async {
    try {
      await context.read<FileService>().openFile(entry.outputPath);
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(_describe(e))));
    }
  }

  Future<void> _shareResult(HistoryEntry entry) async {
    try {
      await context.read<FileService>().shareFile(
            entry.outputPath,
            subject: entry.outputName,
          );
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(_describe(e))));
    }
  }

  @override
  Widget build(BuildContext context) {
    final premium = context.watch<AppState>().isPremium;
    final scheme = Theme.of(context).colorScheme;

    return Scaffold(
      appBar: AppBar(
        title: const Text('Compress PDF'),
        actions: [
          IconButton(
            tooltip: 'View this PDF',
            onPressed: _file == null
                ? null
                : () => Navigator.of(context).push(
                      MaterialPageRoute(
                        builder: (_) => PdfViewerScreen(
                          bytes: _file!.bytes,
                          title: _file!.name,
                        ),
                      ),
                    ),
            icon: const Icon(Icons.visibility_outlined),
          ),
        ],
      ),
      body: SafeArea(
        child: ListView(
          padding: const EdgeInsets.all(16),
          children: [
            if (_file == null)
              Card(
                child: Padding(
                  padding: const EdgeInsets.all(20),
                  child: Column(
                    children: [
                      Icon(Icons.upload_file, size: 46, color: scheme.primary),
                      const SizedBox(height: 10),
                      Text(
                        'Choose the PDF you need to shrink',
                        style: Theme.of(context).textTheme.titleMedium?.copyWith(
                              fontWeight: FontWeight.w700,
                            ),
                      ),
                      const SizedBox(height: 4),
                      Text(
                        'The original file is never modified. You get a new copy.',
                        textAlign: TextAlign.center,
                        style: Theme.of(context).textTheme.bodySmall?.copyWith(
                              color: scheme.onSurfaceVariant,
                            ),
                      ),
                      const SizedBox(height: 16),
                      FilledButton.icon(
                        onPressed: _loadingFile ? null : _pick,
                        icon: _loadingFile
                            ? const SizedBox(
                                width: 16,
                                height: 16,
                                child: CircularProgressIndicator(strokeWidth: 2),
                              )
                            : const Icon(Icons.folder_open),
                        label: Text(_loadingFile ? 'Reading…' : 'Select PDF'),
                      ),
                    ],
                  ),
                ),
              )
            else
              _FileSummaryCard(
                file: _file!,
                inspection: _inspection,
                onChange: _loadingFile ? null : _pick,
              ),

            if (_file != null) ...[
              const SectionHeader(title: 'Target size'),
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: [
                  for (final target in _targets)
                    ChoiceChip(
                      label: Text(target.label),
                      selected: !_customTarget && _targetBytes == target.bytes,
                      onSelected: (_) {
                        final isPremiumOnly = target.bytes != null &&
                            !_isFreeTarget(target.bytes!) &&
                            !premium;
                        setState(() {
                          _customTarget = false;
                          _targetBytes = target.bytes;
                        });
                        if (isPremiumOnly) {
                          _showPremiumRequired('${target.label} targets are Premium.');
                        }
                      },
                    ),
                  ChoiceChip(
                    avatar: premium ? null : const Icon(Icons.lock, size: 14),
                    label: const Text('Custom'),
                    selected: _customTarget,
                    onSelected: (_) {
                      if (!premium) {
                        _showPremiumRequired('Custom target sizes are Premium.');
                        return;
                      }
                      setState(() => _customTarget = true);
                    },
                  ),
                ],
              ),
              if (_customTarget) ...[
                const SizedBox(height: 10),
                TextField(
                  controller: _customController,
                  keyboardType: TextInputType.number,
                  decoration: const InputDecoration(
                    labelText: 'Target size in KB',
                    helperText: 'Between 20 KB and 100 MB',
                    suffixText: 'KB',
                  ),
                ),
              ],
              const SizedBox(height: 6),
              SwitchListTile(
                contentPadding: EdgeInsets.zero,
                title: const Text('Allow page resampling'),
                subtitle: const Text(
                  'Needed for big reductions. Text becomes non-selectable in the copy.',
                ),
                value: _allowDownscale,
                onChanged: (v) => setState(() => _allowDownscale = v),
              ),
              SwitchListTile(
                contentPadding: EdgeInsets.zero,
                title: const Text('Convert to grayscale'),
                subtitle: const Text('Smallest files for text scans'),
                value: _grayscale,
                onChanged: (v) => setState(() => _grayscale = v),
              ),

              if (_inspection != null && _inspection!.imagesOnly) ...[
                const SizedBox(height: 4),
                Card(
                  color: scheme.tertiaryContainer,
                  child: Padding(
                    padding: const EdgeInsets.all(12),
                    child: Row(
                      children: [
                        Icon(Icons.image_outlined, color: scheme.onTertiaryContainer),
                        const SizedBox(width: 10),
                        Expanded(
                          child: Text(
                            'This looks like a scanned PDF (no selectable text). It '
                            'usually compresses very well.',
                            style: TextStyle(fontSize: 12.5, color: scheme.onTertiaryContainer),
                          ),
                        ),
                      ],
                    ),
                  ),
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
                    : const Icon(Icons.compress),
                label: Text(_running ? 'Compressing…' : 'Compress now'),
              ),
              if (_running)
                const Padding(
                  padding: EdgeInsets.only(top: 12),
                  child: LinearProgressIndicator(),
                ),
            ],

            if (_error != null) ...[
              const SizedBox(height: 14),
              ErrorCard(message: _error!, onRetry: _file == null ? _pick : _run),
            ],

            if (_result != null && _outputPath != null) ...[
              const SizedBox(height: 14),
              Card(
                child: Padding(
                  padding: const EdgeInsets.all(14),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        _result!.targetMet ? 'Compressed successfully' : 'Smallest possible result',
                        style: const TextStyle(fontWeight: FontWeight.w700),
                      ),
                      const SizedBox(height: 8),
                      InfoRow(label: 'Original', value: formatBytes(_result!.originalBytes)),
                      InfoRow(label: 'Result', value: formatBytes(_result!.bytes.length)),
                      InfoRow(
                        label: 'Reduction',
                        value: '${_result!.savedPercent.toStringAsFixed(1)}%',
                      ),
                      const SizedBox(height: 10),
                      Row(
                        children: [
                          Expanded(
                            child: FilledButton.tonalIcon(
                              onPressed: () => Navigator.of(context).push(
                                MaterialPageRoute(
                                  builder: (_) => PdfViewerScreen(
                                    filePath: _outputPath,
                                    title: 'Compressed PDF',
                                  ),
                                ),
                              ),
                              icon: const Icon(Icons.visibility_outlined),
                              label: const Text('Preview'),
                            ),
                          ),
                          const SizedBox(width: 10),
                          Expanded(
                            child: OutlinedButton.icon(
                              onPressed: () async {
                                try {
                                  await context
                                      .read<FileService>()
                                      .shareFile(_outputPath!, subject: 'Compressed PDF');
                                } catch (e) {
                                  if (!context.mounted) return;
                                  ScaffoldMessenger.of(context).showSnackBar(
                                    SnackBar(content: Text(_describe(e))),
                                  );
                                }
                              },
                              icon: const Icon(Icons.share),
                              label: const Text('Share'),
                            ),
                          ),
                        ],
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

  bool _isFreeTarget(int bytes) => const [
        100 * 1024,
        200 * 1024,
        500 * 1024,
        1024 * 1024,
        2 * 1024 * 1024,
      ].contains(bytes);
}

class _FileSummaryCard extends StatelessWidget {
  const _FileSummaryCard({
    required this.file,
    required this.inspection,
    required this.onChange,
  });

  final PickedFile file;
  final PdfInspection? inspection;
  final VoidCallback? onChange;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(Icons.picture_as_pdf, color: scheme.error),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    file.name,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(fontWeight: FontWeight.w700),
                  ),
                ),
                TextButton(onPressed: onChange, child: const Text('Change')),
              ],
            ),
            const SizedBox(height: 4),
            InfoRow(label: 'Size', value: formatBytes(file.size)),
            if (inspection != null) ...[
              InfoRow(label: 'Pages', value: '${inspection!.pageCount}'),
              InfoRow(label: 'Page size', value: inspection!.pageSizeLabel),
              InfoRow(
                label: 'Text layer',
                value: inspection!.hasExtractableText ? 'Selectable text' : 'Scanned (image only)',
              ),
              if (inspection!.isEncrypted)
                const InfoRow(label: 'Protection', value: 'Password / owner protected'),
            ],
          ],
        ),
      ),
    );
  }
}
