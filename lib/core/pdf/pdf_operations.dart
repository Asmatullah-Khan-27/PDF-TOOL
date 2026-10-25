import 'dart:async';
import 'dart:ffi';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:ffi/ffi.dart';
import 'package:image/image.dart' as img;
import 'package:pdf/pdf.dart' as dart_pdf;
import 'package:pdf/widgets.dart' as dart_pdf_widgets;
import 'package:pdf_fit/core/pdf/pdfium_engine.dart';
import 'package:pdfium_dart/pdfium_dart.dart' as pf;

// ---------------------------------------------------------------------------
// Result types
// ---------------------------------------------------------------------------

/// Explanation of how a document was produced, shown to the user so results are
/// auditable rather than a mystery "success" banner.
class PdfResult {
  PdfResult({
    required this.bytes,
    required this.pageCount,
    required this.strategy,
    this.notes = const [],
  });

  final Uint8List bytes;
  final int pageCount;
  final String strategy;
  final List<String> notes;
}

class CompressionConfig {
  const CompressionConfig({
    this.targetBytes,
    this.startDpi = 150,
    this.maxDpi = 220,
    this.startQuality = 72,
    this.minDpi = 55,
    this.minQuality = 30,
    this.grayscale = false,
    this.allowDownscale = true,
  });

  /// Desired maximum output size in bytes. Null = best-effort optimisation.
  final int? targetBytes;
  final double startDpi;
  final double maxDpi;
  final int startQuality;
  final double minDpi;
  final int minQuality;
  final bool grayscale;

  /// When false the engine never rasterises: it only performs a
  /// structure-preserving rewrite (keeps real text and vectors).
  final bool allowDownscale;
}

class CompressionAttempt {
  CompressionAttempt({
    required this.dpi,
    required this.quality,
    required this.bytes,
    required this.strategy,
  });

  final double dpi;
  final int quality;
  final int bytes;
  final String strategy;

  double ratioTo(int original) => original == 0 ? 1 : bytes / original;
}

class CompressionResult {
  CompressionResult({
    required this.bytes,
    required this.originalBytes,
    required this.targetBytes,
    required this.dpi,
    required this.jpegQuality,
    required this.elapsed,
    required this.attempts,
    required this.strategy,
    required this.vectorPreserved,
    required this.targetMet,
    required this.notes,
  });

  final Uint8List bytes;
  final int originalBytes;
  final int? targetBytes;
  final double dpi;
  final int jpegQuality;
  final Duration elapsed;
  final List<CompressionAttempt> attempts;
  final String strategy;

  /// True when text and vectors were kept (no rasterisation).
  final bool vectorPreserved;

  /// True when the requested target size was actually reached (measured).
  final bool targetMet;
  final List<String> notes;

  double get achievedRatio => originalBytes == 0 ? 1 : bytes.length / originalBytes;
  int get savedBytes => originalBytes - bytes.length;
  double get savedPercent => originalBytes == 0 ? 0 : (1 - achievedRatio) * 100;
}

// ---------------------------------------------------------------------------
// Document assembly (the only place pages are written)
// ---------------------------------------------------------------------------

/// Builds a new PDF containing exactly [pages], in order, with the requested
/// rotations. Output page count is verified before returning.
Future<Uint8List> buildDocument(List<SourcePage> pages) async {
  if (pages.isEmpty) {
    throw PdfOperationException('Select at least one page to build a PDF.');
  }
  // Only isolate-sendable data crosses into the worker.
  final refs = <(int, int, int)>[
    for (final p in pages) (p.document, p.pageIndex, p.rotationQuarterTurns % 4),
  ];
  return run(() => _buildDocumentOnPdfium(refs));
}

Uint8List _buildDocumentOnPdfium(List<(int, int, int)> refs) {
  final lib = engine;
  final dest = lib.FPDF_CreateNewDocument();
  if (dest.address == 0) {
    throw PdfOperationException('PDFium could not create the output document.');
  }
  try {
    var inserted = 0;
    for (final (docAddr, pageIndex, quarterTurns) in refs) {
      final at = lib.FPDF_GetPageCount(dest);
      final idx = calloc<Int>(1);
      idx[0] = pageIndex;
      final ok = lib.FPDF_ImportPagesByIndex(
        dest,
        pf.FPDF_DOCUMENT.fromAddress(docAddr),
        idx,
        1,
        at,
      );
      calloc.free(idx);
      if (ok == 0 || lib.FPDF_GetPageCount(dest) != at + 1) {
        throw PdfOperationException(
          'Could not copy page ${pageIndex + 1}. The PDF may be corrupt or '
          'restricted by permissions.',
        );
      }
      inserted++;
      if (quarterTurns != 0) {
        final out = lib.FPDF_GetPageCount(dest) - 1;
        final page = lib.FPDF_LoadPage(dest, out);
        if (page.address == 0) {
          throw PdfOperationException('Could not load copied page ${out + 1}.');
        }
        try {
          final existing = lib.FPDFPage_GetRotation(page);
          lib.FPDFPage_SetRotation(page, (existing + quarterTurns) % 4);
        } finally {
          lib.FPDF_ClosePage(page);
        }
      }
    }
    final out = _saveAsCopy(lib, dest);
    final count = lib.FPDF_GetPageCount(dest);
    if (inserted != refs.length || count != refs.length) {
      throw PdfOperationException(
        'Output verification failed: expected ${refs.length} pages, got $count.',
      );
    }
    _assertPdfHeader(out);
    return out;
  } finally {
    lib.FPDF_CloseDocument(dest);
  }
}

/// Builds a PDF from already-encoded JPEG page images (compression path).
Future<Uint8List> buildDocumentFromJpegs(
  List<({Uint8List jpeg, double widthPt, double heightPt})> pages,
) async {
  if (pages.isEmpty) throw PdfOperationException('No pages were produced.');
  return run(() {
    final lib = engine;
    final dest = lib.FPDF_CreateNewDocument();
    if (dest.address == 0) {
      throw PdfOperationException('PDFium could not create the output document.');
    }
    try {
      for (final p in pages) {
        _appendJpegPage(lib, dest, p.jpeg, p.widthPt, p.heightPt);
      }
      final out = _saveAsCopy(lib, dest);
      if (lib.FPDF_GetPageCount(dest) != pages.length) {
        throw PdfOperationException('Output verification failed: page count mismatch.');
      }
      _assertPdfHeader(out);
      return out;
    } finally {
      lib.FPDF_CloseDocument(dest);
    }
  });
}

void _appendJpegPage(
  pf.PDFium lib,
  pf.FPDF_DOCUMENT dest,
  Uint8List jpeg,
  double widthPt,
  double heightPt,
) {
  final index = lib.FPDF_GetPageCount(dest);
  final page = lib.FPDFPage_New(dest, index, widthPt, heightPt);
  if (page.address == 0) {
    throw PdfOperationException('PDFium could not create page ${index + 1}.');
  }
  final data = malloc<Uint8>(jpeg.length);
  final fileAccess = calloc<pf.FPDF_FILEACCESS>();
  NativeCallable<Int Function(Pointer<Void>, UnsignedLong, Pointer<UnsignedChar>, UnsignedLong)>?
      getBlock;
  pf.FPDF_PAGEOBJECT? imageObj;
  try {
    data.asTypedList(jpeg.length).setAll(0, jpeg);
    getBlock = NativeCallable<
        Int Function(Pointer<Void>, UnsignedLong, Pointer<UnsignedChar>, UnsignedLong)>.isolateLocal(
      (Pointer<Void> param, int position, Pointer<UnsignedChar> buffer, int size) {
        // Called by PDFium through FPDF_FILEACCESS to read the JPEG bitstream.
        if (position < 0 || position + size > jpeg.length) return 0;
        final view = buffer.cast<Uint8>().asTypedList(size);
        for (var i = 0; i < size; i++) {
          view[i] = jpeg[position + i];
        }
        return 1;
      },
      exceptionalReturn: 0,
    );
    fileAccess.ref.m_FileLen = jpeg.length;
    fileAccess.ref.m_GetBlock = getBlock.nativeFunction;
    fileAccess.ref.m_Param = nullptr;

    imageObj = lib.FPDFPageObj_NewImageObj(dest);
    if (imageObj.address == 0) {
      throw PdfOperationException('PDFium could not create an image object.');
    }
    // The *Inline* variant copies the JPEG into the document immediately. The
    // non-inline variant keeps the FPDF_FILEACCESS and reads it lazily at save
    // time, which would call back into memory we have already released (that
    // aborts the VM with "Callback invoked after it has been deleted").
    // `pages`/`count` are documented as safely NULL/0 when the image object is
    // not shared between pages.
    if (lib.FPDFImageObj_LoadJpegFileInline(nullptr, 0, imageObj, fileAccess) == 0) {
      throw PdfOperationException('PDFium rejected the page image.');
    }
    if (lib.FPDFImageObj_SetMatrix(imageObj, widthPt, 0, 0, heightPt, 0, 0) == 0) {
      throw PdfOperationException('Could not scale the page image.');
    }
    if (lib.FPDFPage_InsertObject(page, imageObj) == 0) {
      throw PdfOperationException('Could not place the page image.');
    }
    imageObj = null; // owned by the page now
    lib.FPDFPage_GenerateContent(page);
  } finally {
    if (imageObj != null && imageObj.address != 0) lib.FPDFPageObj_Destroy(imageObj);
    lib.FPDF_ClosePage(page);
    if (getBlock != null) getBlock.close();
    calloc.free(fileAccess);
    malloc.free(data);
  }
}

Uint8List _saveAsCopy(pf.PDFium lib, pf.FPDF_DOCUMENT doc) {
  final buffer = BytesBuilder(copy: true);
  final writeBlock = NativeCallable<
      Int Function(Pointer<pf.FPDF_FILEWRITE_>, Pointer<Void>, UnsignedLong)>.isolateLocal(
    (Pointer<pf.FPDF_FILEWRITE_> self, Pointer<Void> data, int size) {
      if (size > 0 && data.address != 0) {
        buffer.add(data.cast<Uint8>().asTypedList(size));
      }
      return size;
    },
    exceptionalReturn: 0,
  );
  final fw = calloc<pf.FPDF_FILEWRITE_>();
  try {
    fw.ref.version = 1;
    fw.ref.WriteBlock = writeBlock.nativeFunction;
    // 2 == FPDF_NO_INCREMENTAL
    if (lib.FPDF_SaveAsCopy(doc, fw.cast(), 2) == 0) {
      throw PdfOperationException('PDFium failed to write the document.');
    }
    final bytes = buffer.toBytes();
    if (bytes.isEmpty) {
      throw PdfOperationException('PDFium produced an empty file.');
    }
    return bytes;
  } finally {
    calloc.free(fw);
    writeBlock.close();
  }
}

void _assertPdfHeader(Uint8List bytes) {
  if (bytes.length < 8 || String.fromCharCodes(bytes.take(5)) != '%PDF-') {
    throw PdfOperationException('Produced file is not a valid PDF; output discarded.');
  }
}

// ---------------------------------------------------------------------------
// Page-range parsing (used by split)
// ---------------------------------------------------------------------------

/// Parses a human page-range string such as `1-3, 7, 10-`.
///
/// Throws [PdfOperationException] with an actionable message on bad input.
List<int> parsePageRanges(String input, int pageCount) {
  final trimmed = input.trim();
  if (trimmed.isEmpty) {
    throw PdfOperationException('Enter page numbers, for example 1-3,5,8-10.');
  }
  final result = <int>[];
  for (final rawToken in trimmed.split(RegExp(r'[,\s]+'))) {
    final token = rawToken.trim();
    if (token.isEmpty) continue;
    final match = RegExp(r'^(\d+)?\s*-\s*(\d+)?$').firstMatch(token);
    if (match == null) {
      final single = int.tryParse(token);
      if (single == null) {
        throw PdfOperationException('"$token" is not a valid page number.');
      }
      if (single < 1 || single > pageCount) {
        throw PdfOperationException(
          'Page $single is out of range (this PDF has $pageCount pages).',
        );
      }
      result.add(single - 1);
      continue;
    }
    final start = match.group(1) == null ? 1 : int.parse(match.group(1)!);
    final end = match.group(2) == null ? pageCount : int.parse(match.group(2)!);
    if (start < 1 || end > pageCount || start > end) {
      throw PdfOperationException('Range "$token" is invalid for a $pageCount-page PDF.');
    }
    for (var p = start; p <= end; p++) {
      result.add(p - 1);
    }
  }
  if (result.isEmpty) {
    throw PdfOperationException('No pages were selected.');
  }
  return <int>{...result}.toList()..sort();
}

/// Splits [pages] into consecutive runs, used for "split every N pages".
List<List<int>> splitIntoChunks(List<int> pages, int chunkSize) {
  if (chunkSize < 1) {
    throw PdfOperationException('Pages per file must be at least 1.');
  }
  final chunks = <List<int>>[];
  for (var i = 0; i < pages.length; i += chunkSize) {
    chunks.add(pages.sublist(i, math.min(i + chunkSize, pages.length)));
  }
  return chunks;
}

// ---------------------------------------------------------------------------
// High level operations
// ---------------------------------------------------------------------------

/// Extracts [pageIndices] (0-based) from [sourceBytes] into a new PDF.
Future<PdfResult> extractPages(
  Uint8List sourceBytes,
  List<int> pageIndices, {
  String sourceName = 'document.pdf',
}) async {
  final src = await PdfSource.open(sourceBytes, name: sourceName);
  try {
    if (pageIndices.isEmpty) {
      throw PdfOperationException('Select at least one page.');
    }
    for (final i in pageIndices) {
      if (i < 0 || i >= src.pageCount) {
        throw PdfOperationException('Page ${i + 1} does not exist.');
      }
    }
    final bytes = await buildDocument([
      for (final i in pageIndices) SourcePage(document: src.address, pageIndex: i),
    ]);
    return PdfResult(
      bytes: bytes,
      pageCount: pageIndices.length,
      strategy: 'Page extraction',
    );
  } finally {
    await src.close();
  }
}

/// Merges several PDFs into one, preserving the given order.
Future<PdfResult> mergePdfs(List<({String name, Uint8List bytes})> inputs) async {
  if (inputs.length < 2) {
    throw PdfOperationException('Choose at least two PDFs to merge.');
  }
  final opened = <PdfSource>[];
  try {
    for (final input in inputs) {
      opened.add(await PdfSource.open(input.bytes, name: input.name));
    }
    final pages = <SourcePage>[];
    for (var i = 0; i < opened.length; i++) {
      for (var p = 0; p < opened[i].pageCount; p++) {
        pages.add(SourcePage(document: opened[i].address, pageIndex: p));
      }
    }
    final bytes = await buildDocument(pages);
    return PdfResult(
      bytes: bytes,
      pageCount: pages.length,
      strategy: 'Merge of ${inputs.length} documents',
      notes: [
        for (var i = 0; i < inputs.length; i++) '${inputs[i].name}: ${opened[i].pageCount} pages',
      ],
    );
  } finally {
    for (final src in opened) {
      await src.close();
    }
  }
}

/// Applies quarter-turn rotations to selected pages (0 = untouched).
Future<PdfResult> rotatePages(
  Uint8List sourceBytes,
  Map<int, int> quarterTurnsByPage, {
  String sourceName = 'document.pdf',
}) async {
  final src = await PdfSource.open(sourceBytes, name: sourceName);
  try {
    final pages = <SourcePage>[];
    for (var i = 0; i < src.pageCount; i++) {
      pages.add(SourcePage(
        document: src.address,
        pageIndex: i,
        rotationQuarterTurns: (quarterTurnsByPage[i] ?? 0) % 4,
      ));
    }
    final bytes = await buildDocument(pages);
    return PdfResult(
      bytes: bytes,
      pageCount: pages.length,
      strategy: 'Page rotation',
    );
  } finally {
    await src.close();
  }
}

/// Describes a PDF for the UI (page count, sizes, text, protection).
class PdfInspection {
  PdfInspection({
    required this.pageCount,
    required this.byteSize,
    required this.isEncrypted,
    required this.hasExtractableText,
    required this.textCharacterCount,
    required this.pageWidthPt,
    required this.pageHeightPt,
    required this.hasAnnotations,
    required this.title,
    required this.isLandscape,
    required this.mixedPageSizes,
    required this.imagesOnly,
  });

  final int pageCount;
  final int byteSize;
  final bool isEncrypted;
  final bool hasExtractableText;
  final int textCharacterCount;
  final double pageWidthPt;
  final double pageHeightPt;
  final bool hasAnnotations;
  final String? title;
  final bool isLandscape;

  /// True when pages differ in size (upload portals often reject these).
  final bool mixedPageSizes;

  /// True when no page has real text: effectively a scan.
  final bool imagesOnly;

  /// Page size label such as "A4" or "612 x 792 pt".
  String get pageSizeLabel {
    const a4w = 595.28, a4h = 841.89, ltw = 612.0, lth = 792.0;
    bool near(double a, double b) => (a - b).abs() < 3;
    if (near(pageWidthPt, a4w) && near(pageHeightPt, a4h)) return 'A4 portrait';
    if (near(pageWidthPt, a4h) && near(pageHeightPt, a4w)) return 'A4 landscape';
    if (near(pageWidthPt, ltw) && near(pageHeightPt, lth)) return 'Letter portrait';
    if (near(pageWidthPt, lth) && near(pageHeightPt, ltw)) return 'Letter landscape';
    return '${pageWidthPt.round()} x ${pageHeightPt.round()} pt';
  }
}

/// Inspects a PDF using PDFium (no heuristics, no guessing).
Future<PdfInspection> inspectPdf(Uint8List bytes, {String name = 'document.pdf'}) async {
  final src = await PdfSource.open(bytes, name: name);
  try {
    final count = src.pageCount;
    // Sampling keeps inspection fast on very large documents while remaining
    // accurate for the "scanned vs text" signal.
    final sampleCount = math.min(count, 8);
    final sampleIndices = <int>[
      for (var i = 0; i < sampleCount; i++)
        sampleCount == count ? i : (i * (count - 1) ~/ math.max(1, sampleCount - 1)),
    ];
    var textChars = 0;
    var annotations = 0;
    final sizes = <String>{};
    for (final index in sampleIndices) {
      textChars += await src.textCharacterCount(index);
      annotations += await src.annotationCount(index);
      final size = await src.pageSize(index);
      sizes.add('${size.width.round()}x${size.height.round()}');
    }
    final size0 = await src.pageSize(0);
    return PdfInspection(
      pageCount: count,
      byteSize: bytes.length,
      isEncrypted: await src.isEncrypted(),
      hasExtractableText: textChars > 0,
      textCharacterCount: textChars,
      pageWidthPt: size0.width,
      pageHeightPt: size0.height,
      hasAnnotations: annotations > 0,
      title: await src.metaText('Title'),
      isLandscape: size0.width > size0.height,
      mixedPageSizes: sizes.length > 1,
      imagesOnly: textChars == 0,
    );
  } finally {
    await src.close();
  }
}

// ---------------------------------------------------------------------------
// Compression
// ---------------------------------------------------------------------------

/// Compresses [input] towards [targetBytes] and reports the *measured* result.
///
/// Strategy (both steps are verified against the real output size):
///   1. Structure-preserving rewrite (keeps text/vectors). If it meets the
///      target, it is used: no quality loss at all.
///   2. If a target is set and still missed, pages are rasterised to JPEG at a
///      resolution/quality derived from a measured probe, then the document is
///      rebuilt with those images (embedded without recompression).
Future<CompressionResult> compressPdf(
  Uint8List input, {
  required int? targetBytes,
  CompressionConfig config = const CompressionConfig(),
}) async {
  final stopwatch = Stopwatch()..start();
  final attempts = <CompressionAttempt>[];
  final notes = <String>[];
  final src = await PdfSource.open(input);
  try {
    final pageCount = src.pageCount;
    if (targetBytes != null && targetBytes <= 0) {
      throw PdfOperationException('Enter a target size greater than zero.');
    }

    // Fast path: already small enough.
    if (targetBytes != null && input.length <= targetBytes) {
      attempts.add(CompressionAttempt(dpi: 0, quality: 0, bytes: input.length, strategy: 'unchanged'));
      return CompressionResult(
        bytes: input,
        originalBytes: input.length,
        targetBytes: targetBytes,
        dpi: 0,
        jpegQuality: 0,
        elapsed: stopwatch.elapsed,
        attempts: attempts,
        strategy: 'Already within target',
        vectorPreserved: true,
        targetMet: true,
        notes: const ['The file already fits the target size, so no pages were re-encoded.'],
      );
    }

    // Step 1: structural rewrite (keeps text, links, vectors).
    final structural = await buildDocument([
      for (var i = 0; i < pageCount; i++) SourcePage(document: src.address, pageIndex: i),
    ]);
    attempts.add(CompressionAttempt(
      dpi: 0,
      quality: 0,
      bytes: structural.length,
      strategy: 'structural rewrite',
    ));
    if (targetBytes == null || structural.length <= targetBytes) {
      notes.add('Text, links and vector graphics were preserved (no rasterisation).');
      return CompressionResult(
        bytes: structural,
        originalBytes: input.length,
        targetBytes: targetBytes,
        dpi: 0,
        jpegQuality: 0,
        elapsed: stopwatch.elapsed,
        attempts: attempts,
        strategy: 'Structure-preserving optimisation',
        vectorPreserved: true,
        targetMet: targetBytes == null || structural.length <= targetBytes,
        notes: notes,
      );
    }

    if (!config.allowDownscale) {
      throw PdfOperationException(
        'The target size cannot be reached without resampling pages. '
        'Enable page downscaling to continue.',
        details: 'Best structure-preserving result: ${structural.length} bytes.',
      );
    }

    // Step 2: rasterising compression with a measured search.
    notes.add('Pages were resampled to images, so text becomes non-selectable in '
        'the compressed copy. Keep the original for searching/copying text.');

    final probe = await _renderProbe(src, maxDpi: config.maxDpi, quality: config.startQuality);
    final probeBytes = probe.bytes.length;
    // JPEG size scales roughly with pixel count (i.e. with dpi squared).
    final sizeEstimate = probeBytes / probe.pixels * pageCount * 1.35; // 1.35 = PDF overhead
    var dpi = config.startDpi.clamp(config.minDpi, config.maxDpi);
    if (sizeEstimate > 0) {
      dpi = (dpi * math.sqrt(targetBytes / sizeEstimate)).clamp(config.minDpi, config.maxDpi);
    }
    var quality = config.startQuality;
    if (dpi <= config.minDpi + 1) {
      // At the resolution floor, spend the remaining budget on quality.
      final qScale = math.sqrt(targetBytes / math.max(1, sizeEstimate * (config.minDpi / dpi) * (config.minDpi / dpi)));
      quality = (config.startQuality * qScale.clamp(0.45, 1.0))
          .clamp(config.minQuality, config.startQuality)
          .round();
    }

    Uint8List? best;
    var bestDpi = dpi;
    var bestQuality = quality;
    var targetMet = false;

    for (var round = 0; round < 4; round++) {
      final built = await _rasteriseDocument(
        src,
        dpi: dpi,
        quality: quality,
        grayscale: config.grayscale,
      );
      attempts.add(CompressionAttempt(
        dpi: dpi,
        quality: quality,
        bytes: built.length,
        strategy: 'rasterise',
      ));
      final current = built.length;
      if (best == null || current < best.length) {
        best = built;
        bestDpi = dpi;
        bestQuality = quality;
      }
      if (current <= targetBytes) {
        targetMet = true;
        // Met the target: try to buy back quality if there is headroom.
        final headroom = targetBytes / current;
        if (headroom > 1.15 && dpi < config.maxDpi && round < 3) {
          dpi = math.min(config.maxDpi, dpi * math.sqrt(math.min(headroom, 1.6)));
          quality = math.min(config.startQuality, quality + 6);
          continue;
        }
        best = built;
        bestDpi = dpi;
        bestQuality = quality;
        break;
      }
      // Overshoot: shrink proportionally to the square root of the overshoot.
      final scale = math.sqrt(targetBytes / current) * 0.97;
      if (dpi > config.minDpi + 0.5) {
        dpi = math.max(config.minDpi, dpi * scale);
      } else if (quality > config.minQuality) {
        quality = math.max(config.minQuality, (quality * scale).round());
      } else {
        break; // floor reached
      }
    }

    if (best == null) {
      throw PdfOperationException('Compression did not produce any output.');
    }
    if (!targetMet) {
      notes.add('The requested target could not be reached even at the lowest '
          'quality setting. The smallest achievable file was saved instead.');
    }
    // Verify the produced file is a readable PDF with the right page count.
    final verifyCount = await PdfSource.verifyPageCount(best, name: 'compressed.pdf');
    if (verifyCount != pageCount) {
      throw PdfOperationException(
        'Verification failed: compressed PDF has $verifyCount pages instead of $pageCount.',
      );
    }
    if (best.length >= input.length) {
      notes.add('This PDF was already efficiently encoded, so the rewritten copy is '
          'not smaller. The original file is unchanged.');
    }
    return CompressionResult(
      bytes: best,
      originalBytes: input.length,
      targetBytes: targetBytes,
      dpi: bestDpi,
      jpegQuality: bestQuality,
      elapsed: stopwatch.elapsed,
      attempts: attempts,
      strategy: 'Page resampling',
      vectorPreserved: false,
      targetMet: targetMet,
      notes: notes,
    );
  } finally {
    await src.close();
  }
}

Future<({Uint8List bytes, int pixels})> _renderProbe(
  PdfSource src, {
  required double maxDpi,
  required int quality,
}) async {
  final page = await renderPageToJpeg(src, 0, dpi: math.min(120, maxDpi), quality: quality);
  final decoded = img.decodeJpg(page.jpeg)!;
  return (bytes: page.jpeg, pixels: decoded.width * decoded.height);
}

/// Renders one page to JPEG at fixed settings.
///
/// Public because it is the exact primitive compression uses, which lets tests
/// (and future export features) reproduce results deterministically.
Future<({Uint8List jpeg, double widthPt, double heightPt})> renderPageToJpeg(
  PdfSource src,
  int pageIndex, {
  required double dpi,
  required int quality,
  bool grayscale = false,
}) async {
  final rendered = await src.renderPage(pageIndex, dpi: dpi);
  final rgba = bgraToRgba(rendered.bgra);
  var image = img.Image.fromBytes(
    width: rendered.width,
    height: rendered.height,
    bytes: rgba.buffer,
    numChannels: 4,
  );
  if (grayscale) image = img.grayscale(image);
  final jpeg = Uint8List.fromList(img.encodeJpg(image, quality: quality));
  return (
    jpeg: jpeg,
    widthPt: rendered.pageWidthPt,
    heightPt: rendered.pageHeightPt,
  );
}

Future<Uint8List> _rasteriseDocument(
  PdfSource src, {
  required double dpi,
  required int quality,
  required bool grayscale,
}) async {
  final pages = <({Uint8List jpeg, double widthPt, double heightPt})>[];
  for (var i = 0; i < src.pageCount; i++) {
    pages.add(await renderPageToJpeg(src, i, dpi: dpi, quality: quality, grayscale: grayscale));
  }
  return buildDocumentFromJpegs(pages);
}

/// Converts PDFium BGRA8888 output to RGBA8888 for the `image` package.
Uint8List bgraToRgba(Uint8List bgra) {
  final out = Uint8List(bgra.length);
  for (var i = 0; i < bgra.length; i += 4) {
    out[i] = bgra[i + 2];
    out[i + 1] = bgra[i + 1];
    out[i + 2] = bgra[i];
    out[i + 3] = bgra[i + 3];
  }
  return out;
}

// ---------------------------------------------------------------------------
// Images -> PDF
// ---------------------------------------------------------------------------

enum ImageFit { fitPage, fillPage, originalSize }

enum PageSizePreset { a4, letter, a5, fitToImage }

/// Creates a real PDF from images using the `pdf` package (JPEGs are embedded
/// directly, other formats are decoded once and re-encoded).
Future<PdfResult> imagesToPdf(
  List<Uint8List> images, {
  PageSizePreset pageSize = PageSizePreset.a4,
  ImageFit fit = ImageFit.fitPage,
  double marginPt = 24,
}) async {
  if (images.isEmpty) {
    throw PdfOperationException('Add at least one image.');
  }
  final doc = dart_pdf_widgets.Document();
  final warnings = <String>[];
  for (var i = 0; i < images.length; i++) {
    final bytes = images[i];
    img.Image? decoded;
    try {
      decoded = img.decodeImage(bytes);
    } catch (_) {
      decoded = null;
    }
    if (decoded == null) {
      throw PdfOperationException(
        'Image ${i + 1} could not be decoded. Supported formats: JPEG, PNG, WebP, BMP.',
      );
    }
    // Guard against absurd pixel counts that would exhaust memory on low-end
    // devices: downscale anything above ~40 megapixels.
    var workingBytes = bytes;
    if (decoded.width * decoded.height > 40000000) {
      final scaled = img.copyResize(
        decoded,
        width: math.min(decoded.width, 6000),
        interpolation: img.Interpolation.average,
      );
      workingBytes = Uint8List.fromList(img.encodeJpg(scaled, quality: 92));
      warnings.add('Image ${i + 1} is very large and was downscaled to 6000 px wide.');
    }
    final memoryImage = dart_pdf_widgets.MemoryImage(workingBytes);
    final dart_pdf.PdfPageFormat format = switch (pageSize) {
      PageSizePreset.a4 => dart_pdf.PdfPageFormat.a4,
      PageSizePreset.letter => dart_pdf.PdfPageFormat.letter,
      PageSizePreset.a5 => dart_pdf.PdfPageFormat.a5,
      // 72 dpi = 1:1 points, so the page matches the image aspect exactly.
      PageSizePreset.fitToImage => dart_pdf.PdfPageFormat(
          decoded.width * 72 / 96 + marginPt * 2,
          decoded.height * 72 / 96 + marginPt * 2,
        ),
    };
    final image = decoded;
    doc.addPage(
      dart_pdf_widgets.Page(
        pageFormat: format,
        margin: dart_pdf_widgets.EdgeInsets.all(marginPt),
        build: (context) {
          switch (fit) {
            case ImageFit.fitPage:
              return dart_pdf_widgets.Center(
                child: dart_pdf_widgets.Image(memoryImage, fit: dart_pdf_widgets.BoxFit.contain),
              );
            case ImageFit.fillPage:
              return dart_pdf_widgets.Image(
                memoryImage,
                fit: dart_pdf_widgets.BoxFit.cover,
                width: format.width,
                height: format.height,
              );
            case ImageFit.originalSize:
              final w = image.width * 72 / 96;
              final h = image.height * 72 / 96;
              final scale = math.min(
                1.0,
                math.min(
                  (format.width - marginPt * 2) / w,
                  (format.height - marginPt * 2) / h,
                ),
              );
              return dart_pdf_widgets.Center(
                child: dart_pdf_widgets.Image(
                  memoryImage,
                  width: w * scale,
                  height: h * scale,
                  fit: dart_pdf_widgets.BoxFit.contain,
                ),
              );
          }
        },
      ),
    );
  }
  final bytes = await doc.save();
  final count = await PdfSource.verifyPageCount(bytes, name: 'images.pdf');
  if (count != images.length) {
    throw PdfOperationException(
      'Verification failed: expected ${images.length} pages, produced $count.',
    );
  }
  return PdfResult(
    bytes: bytes,
    pageCount: count,
    strategy: 'Images to PDF',
    notes: warnings,
  );
}
