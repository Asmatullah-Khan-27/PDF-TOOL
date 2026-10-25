import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:pdf/pdf.dart';
import 'package:pdf/widgets.dart' as pw;
import 'package:pdf_fit/core/files/file_service.dart';
import 'package:pdf_fit/core/pdf/pdf_operations.dart';
import 'package:pdf_fit/core/pdf/pdfium_engine.dart';
import 'package:pdfrx_engine/pdfrx_engine.dart' hide PdfDocument;

/// A "scanned document": full-page noise images, which cannot be shrunk by
/// structural rewriting and must be resampled. Noise is deliberate: it is
/// incompressible, so size reduction has to come from reducing pixel count.
Future<Uint8List> buildScannedPdf(int pages, {int side = 1400, int seed = 7}) async {
  final doc = pw.Document();
  var state = seed;
  int next() {
    state = (state * 1103515245 + 12345) & 0x7FFFFFFF;
    return state;
  }

  for (var p = 0; p < pages; p++) {
    final noise = img.Image(width: side, height: side);
    for (var y = 0; y < side; y++) {
      for (var x = 0; x < side; x++) {
        final v = next() % 255;
        noise.setPixelRgb(x, y, v, (v * 7) % 255, (v * 13) % 255);
      }
    }
    final jpg = img.encodeJpg(noise, quality: 95);
    doc.addPage(pw.Page(
      pageFormat: PdfPageFormat.a4,
      build: (ctx) => pw.Center(child: pw.Image(pw.MemoryImage(jpg))),
    ));
  }
  return doc.save();
}

/// A small, text-based PDF (vector, highly compressible output).
Future<Uint8List> buildTextPdf(int pages) async {
  final doc = pw.Document();
  for (var i = 0; i < pages; i++) {
    doc.addPage(pw.Page(
      pageFormat: PdfPageFormat.a4,
      build: (ctx) => pw.Center(child: pw.Text('MARKER-PAGE-${i + 1}')),
    ));
  }
  return doc.save();
}

void main() {
  late Directory tmp;
  late FileService files;

  setUpAll(() async {
    // The engine runs out of process against the host PDFium build.
    final so = File('build/native_assets/linux/libpdfium.so');
    if (so.existsSync()) Pdfrx.pdfiumModulePath = so.absolute.path;
    await pdfrxInitialize();
  });

  setUp(() async {
    tmp = await Directory.systemTemp.createTemp('pdffit_size_test_');
    files = FileService.withRoot(tmp);
  });

  tearDown(() async {
    if (tmp.existsSync()) await tmp.delete(recursive: true);
  });

  group('target size is measured against real bytes', () {
    test('200 KB target: output file on disk is <= 204800 bytes', () async {
      final source = await buildScannedPdf(2);
      const target = 200 * 1024; // exactly what the "200 KB" preset means

      // The input must genuinely be larger than the target, otherwise the
      // "already small enough" fast path would be exercised instead and the
      // test would prove nothing.
      expect(source.length, greaterThan(target),
          reason: 'fixture must be heavier than the 200 KB target');

      final result = await compressPdf(
        source,
        targetBytes: target,
        config: const CompressionConfig(allowDownscale: true),
      );

      // The claimed size must be the real length of the produced bytes.
      expect(result.bytes.length, lessThanOrEqualTo(target));
      expect(result.targetMet, isTrue);

      // ...and, the point of this test, the real file written to storage must
      // be the same size. This is measured with File.length(), not trusted
      // from the result object.
      final path = await files.saveOutput(
        bytes: result.bytes,
        baseName: 'compressed_to_200kb',
      );
      final onDisk = File(path).lengthSync();
      // ignore: avoid_print
      print('200 KB target -> result=${result.bytes.length} B, on-disk=$onDisk B, '
          'source=${source.length} B, dpi=${result.dpi}, q=${result.jpegQuality}');
      expect(onDisk, result.bytes.length);
      expect(onDisk, lessThanOrEqualTo(target));
    }, timeout: const Timeout(Duration(minutes: 8)));

    test('reported before/after sizes match the files they describe', () async {
      final source = await buildScannedPdf(1, side: 900);
      final result = await compressPdf(
        source,
        targetBytes: (source.length * 0.4).round(),
        config: const CompressionConfig(allowDownscale: true),
      );
      final path = await files.saveOutput(bytes: result.bytes, baseName: 'ratio');
      final onDisk = File(path).lengthSync();

      // Before = original buffer / original file size.
      expect(result.originalBytes, source.length);
      // After = bytes actually written.
      expect(result.bytes.length, onDisk);

      // Derived ratios must agree with the real numbers.
      expect(result.savedBytes, source.length - onDisk);
      expect(result.achievedRatio, closeTo(onDisk / source.length, 1e-9));
      expect(result.savedPercent,
          closeTo((1 - onDisk / source.length) * 100, 1e-6));
      // ignore: avoid_print
      print('ratio: ${source.length} -> $onDisk B '
          '(${result.savedPercent.toStringAsFixed(1)}% saved, '
          'savedBytes=${result.savedBytes})');
    }, timeout: const Timeout(Duration(minutes: 8)));

    test('output written twice is byte-identical (sizes are stable)', () async {
      final source = await buildScannedPdf(1, side: 700);
      final result = await compressPdf(
        source,
        targetBytes: (source.length * 0.5).round(),
        config: const CompressionConfig(allowDownscale: true),
      );
      final a = await files.saveOutput(bytes: result.bytes, baseName: 'stable');
      final b = await files.saveOutput(bytes: result.bytes, baseName: 'stable');
      expect(a, isNot(b), reason: 'second write must not overwrite the first');
      expect(File(a).lengthSync(), File(b).lengthSync());
    }, timeout: const Timeout(Duration(minutes: 8)));
  });

  group('failure to reach the target is reported honestly', () {
    test('impossible target: targetMet is false and nothing is faked', () async {
      final source = await buildScannedPdf(1, side: 700);
      const impossible = 3000; // below what a valid PDF page can encode to
      final result = await compressPdf(
        source,
        targetBytes: impossible,
        config: const CompressionConfig(
          allowDownscale: true,
          minDpi: 60,
          minQuality: 30,
        ),
      );

      expect(result.targetMet, isFalse,
          reason: 'must not claim an unreachable target was met');
      expect(result.bytes.length, greaterThan(impossible));
      expect(result.notes.join(' '), contains('smallest achievable'));

      // The file it does return must still be a valid, openable PDF.
      final path = await files.saveOutput(bytes: result.bytes, baseName: 'fallback');
      final reopened = await PdfSource.open(
        File(path).readAsBytesSync(),
        name: 'fallback.pdf',
      );
      expect(reopened.pageCount, 1);
      await reopened.close();
    }, timeout: const Timeout(Duration(minutes: 8)));

    test('structurally-optimised path reports when it cannot reach target', () async {
      // A text PDF cannot be shrunk much without rasterising.
      final source = await buildTextPdf(3);
      await expectLater(
        () => compressPdf(
          source,
          targetBytes: (source.length * 0.5).round(),
          config: const CompressionConfig(allowDownscale: false),
        ),
        throwsA(isA<PdfOperationException>()),
        reason: 'without downscaling it must refuse rather than lie',
      );
    });
  });

  group('corrupted and invalid input', () {
    test('truncated PDF header is rejected, not written out', () async {
      final good = await buildTextPdf(1);
      final truncated = Uint8List.sublistView(good, 0, good.length ~/ 3);
      await expectLater(
        () => compressPdf(truncated, targetBytes: 100 * 1024),
        throwsA(isA<PdfOperationException>()),
      );
    });

    test('non-PDF bytes are rejected', () async {
      final junk = Uint8List.fromList(
        List<int>.generate(4096, (i) => (i * 37) % 256),
      );
      await expectLater(
        () => compressPdf(junk, targetBytes: 100 * 1024),
        throwsA(isA<PdfOperationException>()),
      );
    });

    test('zero and negative targets are rejected with a clear message', () async {
      final source = await buildTextPdf(1);
      for (final bad in [0, -1]) {
        await expectLater(
          () => compressPdf(source, targetBytes: bad),
          throwsA(isA<PdfOperationException>().having(
            (e) => e.message,
            'message',
            contains('greater than zero'),
          )),
        );
      }
    });

    test('a rejected input produces no output file', () async {
      final junk = Uint8List.fromList(List<int>.filled(2048, 1));
      await expectLater(
        () => compressPdf(junk, targetBytes: 100 * 1024),
        throwsA(isA<PdfOperationException>()),
      );
      expect(tmp.listSync(), isEmpty,
          reason: 'no file may be created for a failed operation');
    });
  });
}
