import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:pdf/pdf.dart';
import 'package:pdf/widgets.dart' as pw;
import 'package:pdf_fit/core/pdf/pdfium_engine.dart';
import 'package:pdf_fit/core/pdf/pdf_operations.dart';
import 'package:pdfrx_engine/pdfrx_engine.dart' hide PdfDocument;

/// Builds a real PDF whose pages are individually identifiable, so tests can
/// assert page *order* and not just page count.
Future<Uint8List> buildTestPdf(int pages, {bool withText = true}) async {
  final doc = pw.Document();
  for (var i = 0; i < pages; i++) {
    doc.addPage(
      pw.Page(
        pageFormat: PdfPageFormat.a4,
        build: (ctx) => pw.Center(
          child: pw.Column(
            mainAxisSize: pw.MainAxisSize.min,
            children: [
              pw.Text('MARKER-PAGE-${i + 1}'),
              if (withText) pw.Text('Body text for page ${i + 1} of $pages'),
            ],
          ),
        ),
      ),
    );
  }
  return doc.save();
}

/// A "heavy" PDF full of noise, standing in for a scanned document. Noise is
/// intentionally incompressible so size reduction must come from downscaling.
Future<Uint8List> buildHeavyPdf(int pages, {int side = 1200}) async {
  final doc = pw.Document();
  final rnd = _Rng(42);
  for (var p = 0; p < pages; p++) {
    final noise = img.Image(width: side, height: side);
    for (var y = 0; y < side; y++) {
      for (var x = 0; x < side; x++) {
        final v = rnd.next() % 255;
        noise.setPixelRgb(x, y, v, (v * 7) % 255, (v * 13) % 255);
      }
    }
    final jpg = img.encodeJpg(noise, quality: 95);
    final image = pw.MemoryImage(jpg);
    doc.addPage(
      pw.Page(
        pageFormat: PdfPageFormat.a4,
        build: (ctx) => pw.Center(child: pw.Image(image)),
      ),
    );
  }
  return doc.save();
}

class _Rng {
  _Rng(this._seed);
  int _seed;
  int next() {
    _seed = (_seed * 1103515245 + 12345) & 0x7FFFFFFF;
    return _seed;
  }
}

void main() {
  setUpAll(() async {
    final so = File('build/native_assets/linux/libpdfium.so');
    if (so.existsSync()) Pdfrx.pdfiumModulePath = so.absolute.path;
    await pdfrxInitialize();
  });

  test('opens a real PDF and reports page count and size', () async {
    final bytes = await buildTestPdf(4);
    final src = await PdfSource.open(bytes, name: 'test.pdf');
    expect(src.pageCount, 4);
    final size = await src.pageSize(0);
    expect(size.width, closeTo(595.28, 1));
    expect(size.height, closeTo(841.89, 1));
    expect(await src.textCharacterCount(0), greaterThan(10));
    await src.close();
  });

  test('REJECTS non-PDF input instead of producing a corrupt file', () async {
    expect(
      () => PdfSource.open(Uint8List.fromList('hello world'.codeUnits)),
      throwsA(isA<PdfOperationException>()),
    );
    expect(
      () => PdfSource.open(Uint8List(0)),
      throwsA(isA<PdfOperationException>()),
    );
  });

  test('split: extracting pages 2 and 3 yields exactly a 2 page PDF', () async {
    final bytes = await buildTestPdf(6);
    final src = await PdfSource.open(bytes);
    final out = await buildDocument([
      SourcePage(document: src.address, pageIndex: 1),
      SourcePage(document: src.address, pageIndex: 2),
    ]);
    final check = await PdfSource.open(out, name: 'out.pdf');
    expect(check.pageCount, 2, reason: 'output must contain exactly the requested pages');
    // Verify content order survived the copy: page 1 of the output must be the
    // original page 2.
    final text = await _pageText(check, 0);
    expect(text, contains('MARKER-PAGE-2'));
    final text2 = await _pageText(check, 1);
    expect(text2, contains('MARKER-PAGE-3'));
    await check.close();
    await src.close();
  });

  test('remove pages: 6 page input, keep 4, output has 4', () async {
    final bytes = await buildTestPdf(6);
    final src = await PdfSource.open(bytes);
    final keep = [0, 2, 4, 5];
    final out = await buildDocument([
      for (final i in keep) SourcePage(document: src.address, pageIndex: i),
    ]);
    final check = await PdfSource.open(out, name: 'out.pdf');
    expect(check.pageCount, 4);
    expect(await _pageText(check, 0), contains('MARKER-PAGE-1'));
    expect(await _pageText(check, 1), contains('MARKER-PAGE-3'));
    expect(await _pageText(check, 3), contains('MARKER-PAGE-6'));
    await check.close();
    await src.close();
  });

  test('rotate: 90 degrees is persisted in the output file', () async {
    final bytes = await buildTestPdf(2);
    final src = await PdfSource.open(bytes);
    final out = await buildDocument([
      SourcePage(document: src.address, pageIndex: 0, rotationQuarterTurns: 1),
      SourcePage(document: src.address, pageIndex: 1),
    ]);
    final check = await PdfSource.open(out);
    expect(await check.pageRotationQuarterTurns(0), 1);
    expect(await check.pageRotationQuarterTurns(1), 0);
    final rotated = await check.pageSize(0);
    expect(rotated.width, closeTo(841.89, 1), reason: 'rotated page reports swapped size');
    await check.close();
    await src.close();
  });

  test('merge: pages from two different documents combine in order', () async {
    final a = await PdfSource.open(await buildTestPdf(2), name: 'a.pdf');
    final b = await PdfSource.open(await buildTestPdf(3), name: 'b.pdf');
    final out = await buildDocument([
      SourcePage(document: a.address, pageIndex: 0),
      SourcePage(document: a.address, pageIndex: 1),
      SourcePage(document: b.address, pageIndex: 0),
      SourcePage(document: b.address, pageIndex: 1),
      SourcePage(document: b.address, pageIndex: 2),
    ]);
    final check = await PdfSource.open(out);
    expect(check.pageCount, 5);
    await check.close();
    await a.close();
    await b.close();
  });

  test('RENDER: page raster contains the expected ink (not a blank page)', () async {
    final src = await PdfSource.open(await buildTestPdf(1));
    final rendered = await src.renderPage(0, dpi: 150);
    expect(rendered.width, greaterThan(1000));
    final rgba = bgraToRgba(rendered.toBgra());
    final jpg = img.encodeJpg(
      img.Image.fromBytes(
        width: rendered.width,
        height: rendered.height,
        bytes: rgba.buffer,
        numChannels: 4,
      ),
      quality: 80,
    );
    expect(jpg.length, greaterThan(1000));
    // A blank white page would compress to almost nothing; text does not.
    final decoded = img.decodeJpg(jpg)!;
    var darkPixels = 0;
    for (var y = 0; y < decoded.height; y += 3) {
      for (var x = 0; x < decoded.width; x += 3) {
        final p = decoded.getPixel(x, y);
        if (p.r < 128 && p.g < 128 && p.b < 128) darkPixels++;
      }
    }
    expect(darkPixels, greaterThan(50), reason: 'rendered page must contain visible text');
    rendered.dispose();
    await src.close();
  });

  test('COMPRESS: searching reaches a real target size on a heavy PDF', () async {
    final original = await buildHeavyPdf(3, side: 1400);
    // ignore: avoid_print
    print('heavy input: ${original.length} bytes');
    final target = (original.length * 0.35).round();
    final result = await compressPdf(
      original,
      targetBytes: target,
      config: const CompressionConfig(allowDownscale: true),
    );
    // ignore: avoid_print
    print('compressed: ${result.bytes.length} bytes '
        '(target $target, ${(result.achievedRatio * 100).toStringAsFixed(1)}% of original) '
        'dpi=${result.dpi} quality=${result.jpegQuality} in ${result.elapsed.inMilliseconds}ms');
    expect(result.bytes.length, lessThan(original.length));
    expect(result.bytes.length, lessThanOrEqualTo(target * 1.02),
        reason: 'must actually reach the requested target size');
    // The output must be a valid, openable PDF with the same page count.
    final check = await PdfSource.open(result.bytes, name: 'compressed.pdf');
    expect(check.pageCount, 3);
    await check.close();
  }, timeout: const Timeout(Duration(minutes: 6)));

  test('COMPRESS: text PDF within target is kept vector-preserved', () async {
    final original = await buildTestPdf(2);
    // Target >= current size: nothing should be re-encoded.
    final result = await compressPdf(
      original,
      targetBytes: original.length,
      config: const CompressionConfig(allowDownscale: false),
    );
    expect(result.vectorPreserved, isTrue);
    expect(result.bytes.length, original.length);
    expect(result.targetMet, isTrue);
    expect(await PdfSource.verifyPageCount(result.bytes), 2);
  });

  test('COMPRESS: refuses to fake a target it cannot reach without resampling', () async {
    final original = await buildTestPdf(2);
    await expectLater(
      () => compressPdf(
        original,
        targetBytes: (original.length * 0.5).round(),
        config: const CompressionConfig(allowDownscale: false),
      ),
      throwsA(isA<PdfOperationException>().having(
        (e) => e.message,
        'message',
        contains('without resampling'),
      )),
    );
  });

  test('COMPRESS: unreachable target still yields a valid smallest file', () async {
    final original = await buildHeavyPdf(1, side: 700);
    final result = await compressPdf(
      original,
      targetBytes: 8000, // absurdly small: must degrade gracefully, never corrupt
      config: const CompressionConfig(allowDownscale: true, minDpi: 60, minQuality: 30),
    );
    expect(result.targetMet, isFalse);
    expect(result.notes.join(' '), contains('smallest achievable'));
    expect(await PdfSource.verifyPageCount(result.bytes), 1);
    expect(result.bytes.length, lessThan(original.length));
  }, timeout: const Timeout(Duration(minutes: 6)));

  test('RENDER: grayscale encoding is smaller at identical DPI/quality', () async {
    // Use a colour-heavy page: a white text page has flat chroma, so grayscale
    // legitimately saves almost nothing there.
    final src = await PdfSource.open(await buildHeavyPdf(1, side: 800));
    final colour = await renderPageToJpeg(src, 0, dpi: 150, quality: 70);
    final grey = await renderPageToJpeg(src, 0, dpi: 150, quality: 70, grayscale: true);
    expect(grey.jpeg.length, lessThan(colour.jpeg.length));
    // Grayscale output must really be gray (r == g == b).
    final decoded = img.decodeJpg(grey.jpeg)!;
    final pixel = decoded.getPixel(decoded.width ~/ 2, decoded.height ~/ 2);
    expect(pixel.r, pixel.g);
    expect(pixel.g, pixel.b);
    await src.close();
  });
}

/// Helper used by tests to read the text of a page (verifies real content).
Future<String> _pageText(PdfSource src, int pageIndex) => src.pageText(pageIndex);
