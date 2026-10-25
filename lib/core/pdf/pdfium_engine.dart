import 'dart:async';
import 'dart:ffi';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:ffi/ffi.dart';
import 'package:pdfium_dart/pdfium_dart.dart' as pf;
import 'package:pdfrx_engine/pdfrx_engine.dart' as rx;

/// FPDF_ANNOT: render annotations as part of the page bitmap.
const int kRenderAnnotations = 0x01;

/// Raised when a PDF operation cannot be completed safely.
///
/// The engine never returns a partially written or invalid file: any failure
/// surfaces as this exception with a user-facing message.
class PdfOperationException implements Exception {
  PdfOperationException(this.message, {this.details});

  final String message;
  final String? details;

  @override
  String toString() => details == null ? message : '$message ($details)';
}

/// A reference to one page inside an opened source document.
class SourcePage {
  const SourcePage({
    required this.document,
    required this.pageIndex,
    this.rotationQuarterTurns = 0,
  });

  /// Native `FPDF_DOCUMENT` address. Owned by [PdfSource], not by this object.
  final int document;
  final int pageIndex;

  /// 0..3, multiplied by 90 degrees.
  final int rotationQuarterTurns;
}

/// PDFium library instance (single, process-wide, shared with pdfrx).
pf.PDFium get engine => pf.getPdfium(modulePath: rx.Pdfrx.pdfiumModulePath);

/// Runs [action] inside pdfrx's background worker isolate, the only isolate
/// allowed to call PDFium.
///
/// This is a hard requirement, not a nicety: PDFium callbacks are registered
/// per-isolate, and touching PDFium from any other isolate aborts the Dart VM
/// ("Cannot invoke native callback from a different isolate"). pdfrx is built
/// around a single worker isolate for exactly this reason.
///
/// Consequences for callers:
///  * only isolate-sendable values may cross the boundary (ints, doubles,
///    bools, byte lists, strings),
///  * `Pointer`/`Struct` instances must never be captured by [action];
///    native handles are therefore passed as plain `int` addresses.
/// Runs [action] on the PDFium worker isolate.
///
/// The worker transports results across an isolate boundary, which cannot carry
/// custom exception types: anything we throw inside the callback arrives back
/// wrapped as an internal compute error, and the useful message would be lost.
/// Every operation here therefore funnels its errors through this method, which
/// converts them back into the app's typed [PdfOperationException] so the UI can
/// show a real reason instead of an internal stack trace.
Future<T> run<T>(FutureOr<T> Function() action) async {
  try {
    return await rx.PdfrxEntryFunctions.instance
        .compute<void, T>((_) => action(), null);
  } catch (e) {
    throw _translateWorkerError(e);
  }
}

/// Maps an error coming back from the PDFium worker onto a typed exception.
PdfOperationException _translateWorkerError(Object error) {
  if (error is PdfOperationException) return error;

  final raw = error.toString();

  // The compute wrapper prefixes our message with its own description; keep the
  // innermost, user-relevant part.
  const marker = 'BackgroundWorker.compute callback:';
  var message = raw.contains(marker)
      ? raw.substring(raw.indexOf(marker) + marker.length).trim()
      : raw;

  // Trim a trailing stack trace if one was embedded in the description.
  final newline = message.indexOf('\n');
  if (newline > 0) message = message.substring(0, newline).trim();

  final lower = message.toLowerCase();
  if (lower.contains('password') || lower.contains('encrypted')) {
    return PdfOperationException(
      'This PDF is password-protected. Remove the password and try again.',
      details: message,
    );
  }
  if (lower.contains('format') || lower.contains('corrupt') || lower.contains('damaged')) {
    return PdfOperationException(
      'This file is damaged or uses a PDF feature that cannot be read. '
      'Try opening it in another PDF app to confirm it is intact.',
      details: message,
    );
  }
  if (message.isEmpty) {
    return PdfOperationException('The PDF could not be processed.',
        details: raw);
  }
  return PdfOperationException(message, details: raw);
}

/// An opened PDF held in memory by PDFium.
///
/// All methods are asynchronous because they execute on the PDFium isolate.
/// The source bytes stay allocated until [close] because PDFium reads lazily.
class PdfSource {
  PdfSource._(this._buffer, this._address, this.name, this.pageCount);

  final Pointer<Uint8> _buffer;
  int _address;
  final String name;

  /// Page count, read once when the document was opened.
  final int pageCount;

  bool _closed = false;

  /// Native document address. Valid only inside [run] blocks.
  int get address {
    if (_closed) throw StateError('PdfSource "$name" is already closed.');
    return _address;
  }

  bool get isClosed => _closed;

  static Future<PdfSource> open(
    Uint8List bytes, {
    String name = 'document.pdf',
    String? password,
  }) async {
    if (bytes.isEmpty) {
      throw PdfOperationException('The selected file is empty.');
    }
    if (bytes.length < 5 || String.fromCharCodes(bytes.take(5)) != '%PDF-') {
      throw PdfOperationException(
        '"$name" is not a PDF file.',
        details: 'A valid PDF starts with the %PDF- header.',
      );
    }
    // Native memory is process-wide, so the buffer is allocated here and the
    // (unsendable) pointer stays on this isolate; only its address is used
    // inside the PDFium worker.
    final buffer = malloc<Uint8>(bytes.length);
    buffer.asTypedList(bytes.length).setAll(0, bytes);
    try {
      final opened = await run(
        () => _openDocumentOnPdfium(buffer.address, bytes.length, password, name),
      );
      return PdfSource._(buffer, opened.address, name, opened.pageCount);
    } catch (_) {
      malloc.free(buffer);
      rethrow;
    }
  }

  /// Opens a document only to read its page count, then closes it.
  ///
  /// Used to verify every produced file before it is handed back to the user.
  static Future<int> verifyPageCount(Uint8List bytes, {String name = 'output.pdf'}) async {
    final src = await open(bytes, name: name);
    try {
      return src.pageCount;
    } finally {
      await src.close();
    }
  }

  /// Visible page size in points, honouring the page's own /Rotate entry.
  Future<({double width, double height})> pageSize(int pageIndex) {
    _checkPageIndex(pageIndex);
    return run(() => _pageSizeOnPdfium(_address, pageIndex));
  }

  Future<int> pageRotationQuarterTurns(int pageIndex) {
    _checkPageIndex(pageIndex);
    return run(() => _pageRotationOnPdfium(_address, pageIndex));
  }

  Future<int> annotationCount(int pageIndex) {
    _checkPageIndex(pageIndex);
    return run(() => _annotCountOnPdfium(_address, pageIndex));
  }

  /// Number of extractable text characters on a page (0 for scanned pages).
  Future<int> textCharacterCount(int pageIndex) {
    _checkPageIndex(pageIndex);
    return run(() => _textCountOnPdfium(_address, pageIndex));
  }

  /// Extracts the visible text of one page.
  Future<String> pageText(int pageIndex) {
    _checkPageIndex(pageIndex);
    return run(() => _pageTextOnPdfium(_address, pageIndex));
  }

  /// Whether the PDF carries an encryption handler (owner/password protected).
  Future<bool> isEncrypted() {
    final addr = _address;
    return run(
      () => engine.FPDF_GetSecurityHandlerRevision(pf.FPDF_DOCUMENT.fromAddress(addr)) > 0,
    );
  }

  /// Reads a document info entry (e.g. `Title`). Returns null when absent.
  Future<String?> metaText(String tag) {
    final addr = _address;
    return run(() => _metaTextOnPdfium(addr, tag));
  }

  /// Renders a page to BGRA pixels at [dpi].
  ///
  /// The pixel buffer is copied out of native memory before returning, so the
  /// caller never holds an FFI pointer and nothing leaks if a later step throws.
  Future<RenderedPage> renderPage(
    int pageIndex, {
    required double dpi,
    bool annotations = false,
  }) {
    if (dpi <= 0 || dpi > 1200) {
      throw ArgumentError.value(dpi, 'dpi', 'DPI must be between 1 and 1200');
    }
    _checkPageIndex(pageIndex);
    final addr = _address;
    return run(() => _renderPageOnPdfium(addr, pageIndex, dpi, annotations));
  }

  void _checkPageIndex(int pageIndex) {
    if (_closed) throw StateError('PdfSource "$name" is already closed.');
    if (pageIndex < 0 || pageIndex >= pageCount) {
      throw RangeError.range(pageIndex, 0, pageCount - 1, 'pageIndex');
    }
  }

  /// Frees the document and its backing memory. Idempotent.
  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    final addr = _address;
    _address = 0;
    final buffer = _buffer;
    await run(() => engine.FPDF_CloseDocument(pf.FPDF_DOCUMENT.fromAddress(addr)));
    malloc.free(buffer);
  }

  @override
  String toString() => 'PdfSource($name, ${_closed ? "closed" : "open"}, $pageCount pages)';

  static String _describeLoadError(int code) {
    // FPDF_ERR_* from fpdfview.h
    return switch (code) {
      1 => 'Unknown PDF error while opening the file.',
      2 => 'The file is not a valid PDF and cannot be processed.',
      3 => 'This PDF uses a format PDFium does not support.',
      4 => 'The PDF is password protected. Enter the password and try again.',
      _ => 'The PDF could not be opened (PDFium error $code).',
    };
  }
}

/// A rendered page bitmap in BGRA8888 (already copied into Dart memory).
class RenderedPage {
  RenderedPage({
    required this.bgra,
    required this.width,
    required this.height,
    required this.pageWidthPt,
    required this.pageHeightPt,
  });

  final Uint8List bgra;
  final int width;
  final int height;

  /// Page size in points, used to build correctly sized output pages.
  final double pageWidthPt;
  final double pageHeightPt;

  int get pixelCount => width * height;

  /// Alias kept for readability at call sites.
  Uint8List toBgra() => bgra;

  /// No native resources are retained, so there is nothing to release. Kept so
  /// call sites stay correct if the implementation ever changes.
  void dispose() {}
}

// ---------------------------------------------------------------------------
// Everything below runs *inside* the PDFium worker isolate. These are top-level
// functions taking only isolate-sendable arguments (ints, doubles, bools,
// strings, byte lists) — never `PdfSource`, never `Pointer`s.
// ---------------------------------------------------------------------------

({int address, int pageCount}) _openDocumentOnPdfium(
  int bufferAddress,
  int length,
  String? password,
  String name,
) {
  final lib = engine;
  final pwdPtr = password == null ? nullptr : password.toNativeUtf8(allocator: malloc);
  final pf.FPDF_DOCUMENT doc;
  try {
    doc = lib.FPDF_LoadMemDocument64(
      Pointer<Void>.fromAddress(bufferAddress),
      length,
      pwdPtr == nullptr ? nullptr : pwdPtr.cast(),
    );
  } finally {
    if (pwdPtr != nullptr) malloc.free(pwdPtr);
  }
  if (doc.address == 0) {
    throw PdfOperationException(PdfSource._describeLoadError(lib.FPDF_GetLastError()));
  }
  final count = lib.FPDF_GetPageCount(doc);
  if (count <= 0) {
    lib.FPDF_CloseDocument(doc);
    throw PdfOperationException('"$name" contains no pages.');
  }
  return (address: doc.address, pageCount: count);
}

pf.FPDF_PAGE _loadPageOrThrow(int documentAddress, int pageIndex) {
  final page = engine.FPDF_LoadPage(pf.FPDF_DOCUMENT.fromAddress(documentAddress), pageIndex);
  if (page.address == 0) {
    throw PdfOperationException('Page ${pageIndex + 1} could not be loaded.');
  }
  return page;
}

({double width, double height}) _pageSizeOnPdfium(int documentAddress, int pageIndex) {
  final page = _loadPageOrThrow(documentAddress, pageIndex);
  try {
    // FPDF_GetPageWidthF/HeightF already account for the page's /Rotate entry,
    // so no manual swap here (verified by test: after a 90-degree rotation the
    // rotation value changes and these getters return the swapped size).
    return (
      width: engine.FPDF_GetPageWidthF(page),
      height: engine.FPDF_GetPageHeightF(page),
    );
  } finally {
    engine.FPDF_ClosePage(page);
  }
}

int _pageRotationOnPdfium(int documentAddress, int pageIndex) {
  final page = _loadPageOrThrow(documentAddress, pageIndex);
  try {
    return engine.FPDFPage_GetRotation(page) % 4;
  } finally {
    engine.FPDF_ClosePage(page);
  }
}

int _annotCountOnPdfium(int documentAddress, int pageIndex) {
  final page = _loadPageOrThrow(documentAddress, pageIndex);
  try {
    return engine.FPDFPage_GetAnnotCount(page);
  } finally {
    engine.FPDF_ClosePage(page);
  }
}

int _textCountOnPdfium(int documentAddress, int pageIndex) {
  final page = _loadPageOrThrow(documentAddress, pageIndex);
  pf.FPDF_TEXTPAGE? textPage;
  try {
    textPage = engine.FPDFText_LoadPage(page);
    if (textPage.address == 0) return 0;
    return engine.FPDFText_CountChars(textPage);
  } finally {
    if (textPage != null && textPage.address != 0) engine.FPDFText_ClosePage(textPage);
    engine.FPDF_ClosePage(page);
  }
}

String _pageTextOnPdfium(int documentAddress, int pageIndex) {
  final page = _loadPageOrThrow(documentAddress, pageIndex);
  pf.FPDF_TEXTPAGE? textPage;
  try {
    textPage = engine.FPDFText_LoadPage(page);
    if (textPage.address == 0) return '';
    final count = engine.FPDFText_CountChars(textPage);
    if (count <= 0) return '';
    final buffer = malloc<Uint16>(count + 1);
    try {
      final written = engine.FPDFText_GetText(textPage, 0, count, buffer.cast());
      final len = written > 0 ? written - 1 : 0;
      return String.fromCharCodes(<int>[for (var i = 0; i < len; i++) buffer[i]]);
    } finally {
      malloc.free(buffer);
    }
  } finally {
    if (textPage != null && textPage.address != 0) engine.FPDFText_ClosePage(textPage);
    engine.FPDF_ClosePage(page);
  }
}

String? _metaTextOnPdfium(int documentAddress, String tag) {
  final doc = pf.FPDF_DOCUMENT.fromAddress(documentAddress);
  final tagPtr = tag.toNativeUtf8();
  try {
    final needed = engine.FPDF_GetMetaText(doc, tagPtr.cast(), nullptr, 0);
    if (needed <= 2) return null;
    final buf = malloc<Uint8>(needed);
    try {
      engine.FPDF_GetMetaText(doc, tagPtr.cast(), buf.cast(), needed);
      // Result is UTF-16LE including the NUL terminator.
      final units = (needed ~/ 2) - 1;
      final codes = <int>[for (var i = 0; i < units; i++) buf[i * 2] | (buf[i * 2 + 1] << 8)];
      final text = String.fromCharCodes(codes).trim();
      return text.isEmpty ? null : text;
    } finally {
      malloc.free(buf);
    }
  } finally {
    malloc.free(tagPtr);
  }
}

RenderedPage _renderPageOnPdfium(
  int documentAddress,
  int pageIndex,
  double dpi,
  bool annotations,
) {
  final page = _loadPageOrThrow(documentAddress, pageIndex);
  Pointer<Uint8>? pixels;
  pf.FPDF_BITMAP? bitmap;
  try {
    final wPt = engine.FPDF_GetPageWidthF(page);
    final hPt = engine.FPDF_GetPageHeightF(page);
    final rotation = engine.FPDFPage_GetRotation(page);
    final width = math.max(1, (wPt * dpi / 72.0).round());
    final height = math.max(1, (hPt * dpi / 72.0).round());
    // Quarter-turned pages are rendered sideways so the bitmap comes out upright.
    final bitmapWidth = rotation.isOdd ? height : width;
    final bitmapHeight = rotation.isOdd ? width : height;

    pixels = malloc<Uint8>(bitmapWidth * bitmapHeight * 4);
    bitmap = engine.FPDFBitmap_CreateEx(
      bitmapWidth,
      bitmapHeight,
      pf.FPDFBitmap_BGRA,
      pixels.cast<Void>(),
      bitmapWidth * 4,
    );
    if (bitmap.address == 0) {
      throw PdfOperationException('Could not allocate a render bitmap.');
    }
    // PDF pages are transparent where nothing is drawn; use white paper.
    engine.FPDFBitmap_FillRect(bitmap, 0, 0, bitmapWidth, bitmapHeight, 0xFFFFFFFF);
    engine.FPDF_RenderPageBitmap(
      bitmap,
      page,
      0,
      0,
      bitmapWidth,
      bitmapHeight,
      rotation * 90,
      annotations ? kRenderAnnotations : 0,
    );
    // Copy out of native memory before the bitmap/page are released.
    final copy = Uint8List.fromList(pixels.asTypedList(bitmapWidth * bitmapHeight * 4));
    return RenderedPage(
      bgra: copy,
      width: bitmapWidth,
      height: bitmapHeight,
      pageWidthPt: rotation.isOdd ? hPt : wPt,
      pageHeightPt: rotation.isOdd ? wPt : hPt,
    );
  } finally {
    if (bitmap != null && bitmap.address != 0) engine.FPDFBitmap_Destroy(bitmap);
    if (pixels != null) malloc.free(pixels);
    engine.FPDF_ClosePage(page);
  }
}
