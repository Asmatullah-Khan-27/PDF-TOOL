import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:pdfrx/pdfrx.dart';

/// Real in-app PDF preview backed by pdfrx (PDFium rendering).
///
/// Accepts either bytes (a freshly picked document) or a file path (a produced
/// result). Nothing is stubbed: the widget fails visibly if the document cannot
/// be opened instead of showing a blank page.
class PdfViewerScreen extends StatefulWidget {
  const PdfViewerScreen({
    super.key,
    this.bytes,
    this.filePath,
    required this.title,
  }) : assert(bytes != null || filePath != null, 'Provide bytes or a file path');

  final Uint8List? bytes;
  final String? filePath;
  final String title;

  @override
  State<PdfViewerScreen> createState() => _PdfViewerScreenState();
}

class _PdfViewerScreenState extends State<PdfViewerScreen> {
  PdfDocumentRef? _ref;
  Object? _error;

  @override
  void initState() {
    super.initState();
    // PdfDocumentRefData opens lazily and reports failures through its own error
    // state, which the viewer widget renders.
    if (widget.filePath != null) {
      _ref = PdfDocumentRefFile(widget.filePath!);
    } else if (widget.bytes != null) {
      _ref = PdfDocumentRefData(
        widget.bytes!,
        sourceName: widget.title,
        // The bytes belong to the caller; do not hand ownership to pdfrx.
        allowDataOwnershipTransfer: false,
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Scaffold(
      appBar: AppBar(title: Text(widget.title, overflow: TextOverflow.ellipsis)),
      body: _error != null
          ? Center(
              child: Padding(
                padding: const EdgeInsets.all(24),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(Icons.error_outline, color: scheme.error, size: 40),
                    const SizedBox(height: 12),
                    Text('This PDF could not be displayed.\n$_error', textAlign: TextAlign.center),
                  ],
                ),
              ),
            )
          : PdfViewer(
              _ref!,
              params: PdfViewerParams(
                backgroundColor: scheme.surface,
                errorBannerBuilder: (context, error, stackTrace, documentRef) {
                  WidgetsBinding.instance.addPostFrameCallback((_) {
                    if (mounted && _error == null) setState(() => _error = error);
                  });
                  return Center(
                    child: Padding(
                      padding: const EdgeInsets.all(24),
                      child: Text('Unable to render this PDF: $error',
                          textAlign: TextAlign.center),
                    ),
                  );
                },
              ),
            ),
    );
  }
}
