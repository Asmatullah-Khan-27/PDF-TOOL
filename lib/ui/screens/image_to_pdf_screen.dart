import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import 'package:pdf_fit/core/files/file_service.dart';
import 'package:pdf_fit/core/pdf/pdf_operations.dart';
import 'package:pdf_fit/core/pdf/pdfium_engine.dart';
import 'package:pdf_fit/core/state/app_state.dart';
import 'package:pdf_fit/ui/screens/premium_screen.dart';
import 'package:pdf_fit/ui/widgets/common.dart';
import 'package:pdf_fit/ui/widgets/pdf_viewer_screen.dart';

class ImageToPdfScreen extends StatefulWidget {
  const ImageToPdfScreen({super.key});

  @override
  State<ImageToPdfScreen> createState() => _ImageToPdfScreenState();
}

class _ImageToPdfScreenState extends State<ImageToPdfScreen> {
  final List<PickedFile> _images = [];
  PageSizePreset _pageSize = PageSizePreset.a4;
  ImageFit _fit = ImageFit.fitPage;
  bool _running = false;
  String? _error;
  String? _outputPath;

  Future<void> _add() async {
    final limit = context.read<AppState>().entitlements.imagesPerDocument;
    try {
      final picked = await context.read<FileService>().pickImages();
      if (picked.isEmpty) return;
      final allowed = picked.take(limit - _images.length).toList();
      setState(() {
        _images.addAll(allowed);
        _error = null;
      });
      if (allowed.length < picked.length) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Basic plan allows $limit images per document.'),
            action: SnackBarAction(
              label: 'Premium',
              onPressed: () => Navigator.of(context).push(
                MaterialPageRoute(builder: (_) => const PremiumScreen()),
              ),
            ),
          ),
        );
      }
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
    if (_images.isEmpty) {
      setState(() => _error = 'Add at least one image.');
      return;
    }
    setState(() {
      _running = true;
      _error = null;
      _outputPath = null;
    });
    try {
      final result = await imagesToPdf(
        [for (final image in _images) image.bytes],
        pageSize: _pageSize,
        fit: _fit,
      );
      final path = await context.read<FileService>().saveOutput(
            bytes: result.bytes,
            baseName: 'images_${DateTime.now().millisecondsSinceEpoch}',
          );
      if (!mounted) return;
      await context.read<AppState>().record(
            operation: 'images_to_pdf',
            sourceName: _images.map((i) => i.name).join(', '),
            outputPath: path,
            outputName: path.split('/').last,
            originalBytes: _images.fold<int>(0, (sum, i) => sum + i.size),
            outputBytes: await measuredOutputBytes(context.read<FileService>(), path,
            fallback: result.bytes.length),
            pageCount: result.pageCount,
            details: {'pageSize': _pageSize.name, 'fit': _fit.name},
          );
      if (!mounted) return;
      setState(() {
        _running = false;
        _outputPath = path;
      });
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
    return Scaffold(
      appBar: AppBar(title: const Text('Images to PDF')),
      body: SafeArea(
        child: ListView(
          padding: const EdgeInsets.all(16),
          children: [
            if (_images.isEmpty)
              const EmptyState(
                icon: Icons.photo_library_outlined,
                title: 'No images yet',
                message: 'Pick photos or scans to build a PDF. Each image becomes one page.',
              )
            else
              SizedBox(
                height: 112,
                child: ListView.separated(
                  scrollDirection: Axis.horizontal,
                  itemCount: _images.length,
                  separatorBuilder: (_, __) => const SizedBox(width: 8),
                  itemBuilder: (context, i) => Stack(
                    children: [
                      ClipRRect(
                        borderRadius: BorderRadius.circular(12),
                        child: Image.memory(
                          Uint8List.fromList(_images[i].bytes),
                          width: 100,
                          height: 108,
                          fit: BoxFit.cover,
                          // A broken image must be visible, not silently blank.
                          errorBuilder: (context, error, stack) => Container(
                            width: 100,
                            height: 108,
                            color: scheme.errorContainer,
                            child: const Icon(Icons.broken_image),
                          ),
                        ),
                      ),
                      Positioned(
                        top: 2,
                        right: 2,
                        child: GestureDetector(
                          onTap: () => setState(() => _images.removeAt(i)),
                          child: CircleAvatar(
                            radius: 12,
                            backgroundColor: scheme.error,
                            child: const Icon(Icons.close, size: 14, color: Colors.white),
                          ),
                        ),
                      ),
                      Positioned(
                        bottom: 2,
                        left: 2,
                        child: CircleAvatar(
                          radius: 10,
                          backgroundColor: scheme.primary,
                          child: Text(
                            '${i + 1}',
                            style: const TextStyle(fontSize: 10, color: Colors.white),
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            const SizedBox(height: 12),
            OutlinedButton.icon(
              onPressed: _add,
              icon: const Icon(Icons.add_photo_alternate_outlined),
              label: const Text('Add images'),
            ),
            const SectionHeader(title: 'Page size'),
            Wrap(
              spacing: 8,
              children: [
                for (final preset in PageSizePreset.values)
                  ChoiceChip(
                    label: Text(switch (preset) {
                      PageSizePreset.a4 => 'A4',
                      PageSizePreset.letter => 'Letter',
                      PageSizePreset.a5 => 'A5',
                      PageSizePreset.fitToImage => 'Fit to image',
                    }),
                    selected: _pageSize == preset,
                    onSelected: (_) => setState(() => _pageSize = preset),
                  ),
              ],
            ),
            const SectionHeader(title: 'Image placement'),
            Wrap(
              spacing: 8,
              children: [
                for (final fit in ImageFit.values)
                  ChoiceChip(
                    label: Text(switch (fit) {
                      ImageFit.fitPage => 'Fit inside page',
                      ImageFit.fillPage => 'Fill page',
                      ImageFit.originalSize => 'Original size',
                    }),
                    selected: _fit == fit,
                    onSelected: (_) => setState(() => _fit = fit),
                  ),
              ],
            ),
            const SizedBox(height: 18),
            FilledButton.icon(
              onPressed: _running || _images.isEmpty ? null : _run,
              icon: _running
                  ? const SizedBox(
                      width: 18,
                      height: 18,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : const Icon(Icons.picture_as_pdf),
              label: Text(_running ? 'Building PDF…' : 'Create PDF (${_images.length} pages)'),
            ),
            if (_error != null) ...[
              const SizedBox(height: 14),
              ErrorCard(message: _error!, onRetry: _run),
            ],
            if (_outputPath != null) ...[
              const SizedBox(height: 14),
              Card(
                child: ListTile(
                  leading: const Icon(Icons.check_circle, color: Colors.green),
                  title: const Text('PDF created'),
                  subtitle: Text(_outputPath!.split('/').last),
                  trailing: const Icon(Icons.chevron_right),
                  onTap: () => Navigator.of(context).push(
                    MaterialPageRoute(
                      builder: (_) => PdfViewerScreen(filePath: _outputPath, title: 'Images to PDF'),
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
