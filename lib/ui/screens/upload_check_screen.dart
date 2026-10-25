import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import 'package:pdf_fit/core/files/file_service.dart';
import 'package:pdf_fit/core/pdf/pdf_operations.dart';
import 'package:pdf_fit/core/pdf/pdfium_engine.dart';
import 'package:pdf_fit/core/pdf/upload_rules.dart';
import 'package:pdf_fit/ui/screens/compress_screen.dart';
import 'package:pdf_fit/ui/widgets/common.dart';
import 'package:pdf_fit/ui/widgets/pdf_viewer_screen.dart';

/// Real upload-readiness checker.
///
/// Every result shown here comes from opening the file with PDFium and measuring
/// it (page count, page size, text, annotations, encryption, bytes). There is no
/// static checklist and no assumed pass.
class UploadCheckScreen extends StatefulWidget {
  const UploadCheckScreen({super.key});

  @override
  State<UploadCheckScreen> createState() => _UploadCheckScreenState();
}

class _UploadCheckScreenState extends State<UploadCheckScreen> {
  UploadProfile _profile = UploadProfiles.all.first;
  PickedFile? _file;
  PdfInspection? _inspection;
  List<RuleResult>? _results;
  bool _checking = false;
  String? _error;

  Future<void> _pick() async {
    try {
      final files = await context.read<FileService>().pickPdfs();
      if (files.isEmpty) return;
      setState(() {
        _file = files.first;
        _inspection = null;
        _results = null;
        _error = null;
      });
      await _check();
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

  Future<void> _check() async {
    final file = _file;
    if (file == null) return;
    setState(() {
      _checking = true;
      _error = null;
    });
    try {
      final inspection = await inspectPdf(file.bytes, name: file.name);
      final results = evaluateUploadReadiness(_profile, inspection);
      if (!mounted) return;
      setState(() {
        _inspection = inspection;
        _results = results;
        _checking = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = _describe(e);
        _checking = false;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final failures = _results?.where((r) => r.isBlocking).length ?? 0;
    final warnings = _results?.where((r) => r.status == RuleStatus.warning).length ?? 0;
    final passes = _results?.where((r) => r.status == RuleStatus.pass).length ?? 0;
    final overall = _results == null ? RuleStatus.notApplicable : overallStatus(_results!);

    return Scaffold(
      appBar: AppBar(title: const Text('Upload readiness')),
      body: SafeArea(
        child: ListView(
          padding: const EdgeInsets.all(16),
          children: [
            Text(
              'Pick the portal you are submitting to, then check your PDF against '
              'its real requirements.',
              style: TextStyle(fontSize: 13, color: scheme.onSurfaceVariant),
            ),
            const SizedBox(height: 12),
            DropdownButtonFormField<UploadProfile>(
              initialValue: _profile,
              decoration: const InputDecoration(labelText: 'Upload target'),
              items: [
                for (final profile in UploadProfiles.all)
                  DropdownMenuItem(
                    value: profile,
                    child: Text(profile.name, overflow: TextOverflow.ellipsis),
                  ),
              ],
              onChanged: (profile) {
                if (profile == null) return;
                setState(() => _profile = profile);
                if (_file != null) _check();
              },
            ),
            const SizedBox(height: 6),
            Text(
              _profile.description,
              style: TextStyle(fontSize: 12, color: scheme.onSurfaceVariant),
            ),
            const SizedBox(height: 14),
            Card(
              child: ListTile(
                leading: const Icon(Icons.picture_as_pdf),
                title: Text(_file?.name ?? 'Select the PDF you will upload'),
                subtitle: _file == null
                    ? const Text('Tap to choose a file')
                    : Text(formatBytes(_file!.size)),
                trailing: TextButton(
                  onPressed: _checking ? null : _pick,
                  child: Text(_file == null ? 'Choose' : 'Change'),
                ),
                onTap: _checking ? null : _pick,
              ),
            ),
            if (_checking) ...[
              const SizedBox(height: 16),
              const LinearProgressIndicator(),
              const SizedBox(height: 8),
              const Text('Reading the document…', style: TextStyle(fontSize: 12)),
            ],
            if (_error != null) ...[
              const SizedBox(height: 14),
              ErrorCard(message: _error!, onRetry: _check),
            ],
            if (_results != null && _inspection != null) ...[
              const SizedBox(height: 16),
              Card(
                color: switch (overall) {
                  RuleStatus.fail => scheme.errorContainer,
                  RuleStatus.warning => scheme.tertiaryContainer,
                  RuleStatus.pass => scheme.secondaryContainer,
                  RuleStatus.notApplicable => scheme.surfaceContainerHighest,
                },
                child: Padding(
                  padding: const EdgeInsets.all(16),
                  child: Row(
                    children: [
                      Icon(
                        switch (overall) {
                          RuleStatus.fail => Icons.report_problem,
                          RuleStatus.warning => Icons.warning_amber,
                          RuleStatus.pass => Icons.verified,
                          RuleStatus.notApplicable => Icons.help_outline,
                        },
                        color: switch (overall) {
                          RuleStatus.fail => scheme.onErrorContainer,
                          RuleStatus.warning => scheme.onTertiaryContainer,
                          RuleStatus.pass => scheme.onSecondaryContainer,
                          RuleStatus.notApplicable => scheme.onSurfaceVariant,
                        },
                        size: 30,
                      ),
                      const SizedBox(width: 12),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              switch (overall) {
                                RuleStatus.fail => '$failures requirement(s) not met',
                                RuleStatus.warning => 'Probably ready — $warnings advisory note(s)',
                                RuleStatus.pass => 'Ready to upload',
                                RuleStatus.notApplicable => 'No rules could be evaluated',
                              },
                              style: TextStyle(
                                fontWeight: FontWeight.w800,
                                color: switch (overall) {
                                  RuleStatus.fail => scheme.onErrorContainer,
                                  RuleStatus.warning => scheme.onTertiaryContainer,
                                  RuleStatus.pass => scheme.onSecondaryContainer,
                                  RuleStatus.notApplicable => scheme.onSurfaceVariant,
                                },
                              ),
                            ),
                            const SizedBox(height: 2),
                            Text(
                              '$passes passed · $warnings advisory · $failures blocking '
                              'for ${_profile.name}.',
                              style: TextStyle(
                                fontSize: 12,
                                color: switch (overall) {
                                  RuleStatus.fail => scheme.onErrorContainer,
                                  RuleStatus.warning => scheme.onTertiaryContainer,
                                  RuleStatus.pass => scheme.onSecondaryContainer,
                                  RuleStatus.notApplicable => scheme.onSurfaceVariant,
                                },
                              ),
                            ),
                          ],
                        ),
                      ),
                    ],
                  ),
                ),
              ),
              const SizedBox(height: 12),
              for (final result in _results!)
                Card(
                  child: ListTile(
                    leading: Icon(
                      switch (result.status) {
                        RuleStatus.pass => Icons.check_circle,
                        RuleStatus.fail => Icons.cancel,
                        RuleStatus.warning => Icons.warning_amber,
                        RuleStatus.notApplicable => Icons.remove_circle_outline,
                      },
                      color: switch (result.status) {
                        RuleStatus.pass => Colors.green,
                        RuleStatus.fail => scheme.error,
                        _ => scheme.tertiary,
                      },
                    ),
                    title: Text(result.rule.label),
                    subtitle: Text(result.message, style: const TextStyle(fontSize: 12)),
                  ),
                ),
              const SizedBox(height: 8),
              Card(
                child: Padding(
                  padding: const EdgeInsets.all(14),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const Text('Measured details', style: TextStyle(fontWeight: FontWeight.w700)),
                      const SizedBox(height: 6),
                      InfoRow(label: 'Pages', value: '${_inspection!.pageCount}'),
                      InfoRow(label: 'File size', value: _inspection!.byteSize == 0 ? '-' : formatBytes(_inspection!.byteSize)),
                      InfoRow(label: 'Page size', value: _inspection!.pageSizeLabel),
                      InfoRow(
                        label: 'Uniform size',
                        value: _inspection!.mixedPageSizes ? 'No (mixed)' : 'Yes',
                      ),
                      InfoRow(
                        label: 'Text layer',
                        value: _inspection!.hasExtractableText
                            ? '${_inspection!.textCharacterCount} chars sampled'
                            : 'None (scan)',
                      ),
                      InfoRow(label: 'Protected', value: _inspection!.isEncrypted ? 'Yes' : 'No'),
                      InfoRow(
                        label: 'Annotations',
                        value: _inspection!.hasAnnotations ? 'Present' : 'None',
                      ),
                    ],
                  ),
                ),
              ),
              const SizedBox(height: 12),
              if (failures > 0)
                FilledButton.icon(
                  onPressed: () => _offerFix(failures),
                  icon: const Icon(Icons.build_outlined),
                  label: const Text('Fix this document'),
                ),
              const SizedBox(height: 8),
              OutlinedButton.icon(
                onPressed: () => Navigator.of(context).push(
                  MaterialPageRoute(
                    builder: (_) => PdfViewerScreen(
                      bytes: _file!.bytes,
                      title: _file!.name,
                    ),
                  ),
                ),
                icon: const Icon(Icons.visibility_outlined),
                label: const Text('Open the PDF'),
              ),
            ],
          ],
        ),
      ),
    );
  }

  /// Suggests the concrete tool that fixes the failure and pre-selects the
  /// profile's size limit where possible.
  void _offerFix(int failures) {
    final suggestedBytes = _profile.maxBytes;
    showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      builder: (context) => SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(20, 20, 20, 28),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text('How to fix it', style: Theme.of(context).textTheme.titleLarge),
              const SizedBox(height: 12),
              const Text(
                'The checker found real problems with this file. These tools change a '
                'copy — your original stays untouched.',
                style: TextStyle(fontSize: 13),
              ),
              const SizedBox(height: 16),
              FilledButton.icon(
                onPressed: () {
                  Navigator.of(context).pop();
                  Navigator.of(context).push(
                    MaterialPageRoute(
                      builder: (_) => CompressScreen(preselectTargetBytes: suggestedBytes),
                    ),
                  );
                },
                icon: const Icon(Icons.compress),
                label: Text(
                  suggestedBytes == null
                      ? 'Compress the PDF'
                      : 'Compress to ${formatBytes(suggestedBytes)}',
                ),
              ),
              const SizedBox(height: 8),
              OutlinedButton.icon(
                onPressed: () {
                  Navigator.of(context).pop();
                  ScaffoldMessenger.of(context).showSnackBar(
                    const SnackBar(
                      content: Text('Use Tools → Rotate pages to fix orientation, or '
                          'Tools → Split to reduce the page count.'),
                    ),
                  );
                },
                icon: const Icon(Icons.rotate_right),
                label: const Text('Fix orientation / page count'),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
