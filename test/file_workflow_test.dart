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

/// Builds a scanned-style PDF (noise images) that must be resampled to shrink.
Future<Uint8List> buildScannedPdf(int pages, {int side = 1200}) async {
  final doc = pw.Document();
  var state = 11;
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
    final jpg = img.encodeJpg(noise, quality: 92);
    doc.addPage(pw.Page(
      pageFormat: PdfPageFormat.a4,
      build: (ctx) => pw.Center(child: pw.Image(pw.MemoryImage(jpg))),
    ));
  }
  return doc.save();
}

/// A text PDF whose pages are identifiable, so page order can be verified.
Future<Uint8List> buildMarkedPdf(List<String> markers) async {
  final doc = pw.Document();
  for (final m in markers) {
    doc.addPage(pw.Page(
      pageFormat: PdfPageFormat.a4,
      build: (ctx) => pw.Center(child: pw.Text(m)),
    ));
  }
  return doc.save();
}

void main() {
  late Directory tmp;
  late FileService files;

  setUpAll(() async {
    final so = File('build/native_assets/linux/libpdfium.so');
    if (so.existsSync()) Pdfrx.pdfiumModulePath = so.absolute.path;
    await pdfrxInitialize();
  });

  setUp(() async {
    tmp = await Directory.systemTemp.createTemp('pdffit_workflow_');
    files = FileService.withRoot(tmp);
  });

  tearDown(() async {
    if (tmp.existsSync()) await tmp.delete(recursive: true);
  });

  group('generated PDFs survive the file-handling workflow', () {
    test('a compressed output can be reopened from disk and re-processed', () async {
      final source = await buildScannedPdf(2);
      final result = await compressPdf(
        source,
        targetBytes: (source.length * 0.35).round(),
        config: const CompressionConfig(allowDownscale: true),
      );

      // 1. Written through the real saveOutput path.
      final path = await files.saveOutput(bytes: result.bytes, baseName: 'reopen');
      expect(File(path).existsSync(), isTrue);

      // 2. Reopened from disk (not from memory) — this is what the preview
      //    viewer and a second operation do.
      final reread = File(path).readAsBytesSync();
      expect(reread.length, File(path).lengthSync());

      final doc = await PdfSource.open(reread, name: 'reopen.pdf');
      expect(doc.pageCount, 2);
      await doc.close();

      // 3. Re-processing the output must also work (compress a compression).
      final again = await compressPdf(
        reread,
        targetBytes: (reread.length * 0.6).round(),
        config: const CompressionConfig(allowDownscale: true),
      );
      expect(await PdfSource.verifyPageCount(again.bytes), 2);
    }, timeout: const Timeout(Duration(minutes: 8)));

    test('fileSize reports the real length used for history "after"', () async {
      final source = await buildScannedPdf(1, side: 800);
      final result = await compressPdf(
        source,
        targetBytes: (source.length * 0.4).round(),
        config: const CompressionConfig(allowDownscale: true),
      );
      final path = await files.saveOutput(bytes: result.bytes, baseName: 'sized');

      final measured = await files.fileSize(path);
      expect(measured, isNotNull);
      expect(measured, File(path).lengthSync());
      expect(measured, result.bytes.length);
    }, timeout: const Timeout(Duration(minutes: 8)));

    test('missing file is reported, not silently shared', () async {
      // shareFile/openFile must refuse a path that no longer exists. The share
      // sheet itself needs a platform channel, but the guard before it does not.
      final ghost = '${tmp.path}/PDF Fit/output/ghost.pdf';
      expect(File(ghost).existsSync(), isFalse);
      await expectLater(
        () => files.shareFile(ghost),
        throwsA(isA<FilePickException>().having(
          (e) => e.message,
          'message',
          contains('no longer exists'),
        )),
      );
      await expectLater(
        () => files.openFile(ghost),
        throwsA(isA<FilePickException>().having(
          (e) => e.message,
          'message',
          contains('no longer exists'),
        )),
      );
    });

    test('output names are sanitised and never overwrite each other', () async {
      final source = await buildMarkedPdf(['only page']);
      final path1 = await files.saveOutput(bytes: source, baseName: 'my/report:2026');
      final path2 = await files.saveOutput(bytes: source, baseName: 'my/report:2026');

      expect(path1, isNot(path2));
      // Path separators and colons must not survive into the file name.
      expect(File(path1).uri.pathSegments.last, isNot(contains(':')));
      expect(File(path1).parent.path, File(path2).parent.path);
      expect(File(path1).lengthSync(), source.length);
      expect(File(path2).lengthSync(), source.length);
    });

    test('multi-document workflow: merge then reopen preserves page order', () async {
      final a = await buildMarkedPdf(['A1', 'A2']);
      final b = await buildMarkedPdf(['B1']);

      final srcA = await PdfSource.open(a, name: 'a.pdf');
      final srcB = await PdfSource.open(b, name: 'b.pdf');
      final merged = await buildDocument([
        SourcePage(document: srcA.address, pageIndex: 0),
        SourcePage(document: srcB.address, pageIndex: 0),
        SourcePage(document: srcA.address, pageIndex: 1),
      ]);
      await srcA.close();
      await srcB.close();

      final path = await files.saveOutput(bytes: merged, baseName: 'merged');
      final reopened = await PdfSource.open(
        File(path).readAsBytesSync(),
        name: 'merged.pdf',
      );
      expect(reopened.pageCount, 3);

      // Verify the order really is A1, B1, A2 by reading the text.
      final texts = <String>[];
      for (var i = 0; i < reopened.pageCount; i++) {
        texts.add((await reopened.pageText(i)).replaceAll(RegExp(r'\s+'), ' ').trim());
      }
      await reopened.close();
      expect(texts[0], contains('A1'));
      expect(texts[1], contains('B1'));
      expect(texts[2], contains('A2'));
    }, timeout: const Timeout(Duration(minutes: 8)));
  });
}
