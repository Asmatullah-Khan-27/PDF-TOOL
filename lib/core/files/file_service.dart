import 'dart:io';
import 'dart:typed_data';

import 'package:file_picker/file_picker.dart';
import 'package:open_filex/open_filex.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:share_plus/share_plus.dart';

/// A document chosen by the user.
///
/// `bytes` are kept in memory because every operation reads the document twice
/// (inspect, then process). The original file on disk is never modified.
class PickedFile {
  PickedFile({
    required this.name,
    required this.bytes,
    this.sourcePath,
  });

  final String name;
  final Uint8List bytes;

  /// Where the user picked it from, when the picker exposed a path.
  final String? sourcePath;

  int get size => bytes.length;
  String get extension => p.extension(name).toLowerCase();
}

/// Handles picking and storing files.
///
/// Output policy: results are always written to this app's own documents
/// directory. The user's original file is never overwritten, and sharing /
/// "open with" is offered so the file can leave the sandbox when the user wants.
class FileService {
  FileService._() : _root = null;

  /// Creates a service rooted at [root] instead of the app documents
  /// directory.
  ///
  /// This exists so tests can drive the *real* write path ([saveOutput] and its
  /// size verification) without a platform channel. Production code always uses
  /// [instance]; behaviour is identical apart from where files are rooted.
  FileService.withRoot(Directory root) : _root = root;

  static final FileService instance = FileService._();

  /// When non-null, replaces the documents-directory lookup (tests only).
  final Directory? _root;

  /// Directory where results live: `<appdocs>/PDF Fit/output`.
  Future<Directory> outputDirectory() async {
    final docs = _root ?? await getApplicationDocumentsDirectory();
    final dir = Directory(p.join(docs.path, 'PDF Fit', 'output'));
    if (!await dir.exists()) {
      await dir.create(recursive: true);
    }
    return dir;
  }

  /// Directory for temporary previews (safe to clear at any time).
  Future<Directory> previewDirectory() async {
    final tmp = await getTemporaryDirectory();
    final dir = Directory(p.join(tmp.path, 'pdf_fit_previews'));
    if (!await dir.exists()) await dir.create(recursive: true);
    return dir;
  }

  /// Opens the system file picker for one or more PDFs.
  ///
  /// Returns an empty list when the user cancels. Bytes are read through
  /// [PlatformFile.readAsBytes], which works for content URIs as well as paths
  /// (Android 13+ scoped storage).
  Future<List<PickedFile>> pickPdfs({bool allowMultiple = false}) async {
    final picked = await FilePicker.pickFiles(
      dialogTitle: allowMultiple ? 'Select PDFs' : 'Select a PDF',
      type: FileType.custom,
      allowedExtensions: ['pdf'],
      // The Android plugin reads content URIs for us; multiple selection is
      // handled natively when allowMultiple is enabled by the platform picker.
    );
    if (picked.isEmpty) return const [];
    final files = <PickedFile>[];
    for (final file in picked) {
      files.add(await _toPicked(file));
    }
    if (!allowMultiple && files.length > 1) {
      return [files.first];
    }
    return files;
  }

  /// Opens the image picker for the image-to-PDF tool.
  Future<List<PickedFile>> pickImages() async {
    final picked = await FilePicker.pickFiles(
      dialogTitle: 'Select images',
      type: FileType.image,
    );
    if (picked.isEmpty) return const [];
    return [for (final file in picked) await _toPicked(file)];
  }

  Future<PickedFile> _toPicked(PlatformFile file) async {
    Uint8List bytes;
    try {
      bytes = await file.readAsBytes();
    } catch (e) {
      throw FilePickException(
        'Could not read "${file.name}". Grant storage access and try again.',
      );
    }
    if (bytes.isEmpty) {
      throw FilePickException('"${file.name}" is empty.');
    }
    return PickedFile(name: file.name, bytes: bytes, sourcePath: file.path);
  }

  /// Writes [bytes] to the output directory and verifies the file on disk.
  ///
  /// Returns the absolute path. Throws [FilePickException] if the write did not
  /// produce a file of the expected size — a silent failure here would look like
  /// a successful operation to the user.
  Future<String> saveOutput({
    required Uint8List bytes,
    required String baseName,
    String extension = 'pdf',
  }) async {
    final dir = await outputDirectory();
    final path = await _uniquePath(dir, baseName, extension);
    final file = File(path);
    await file.writeAsBytes(bytes, flush: true);
    if (!await file.exists()) {
      throw FilePickException('The output file could not be written to storage.');
    }
    final written = await file.length();
    if (written != bytes.length) {
      await file.delete();
      throw FilePickException(
        'Storage write was incomplete ($written of ${bytes.length} bytes). '
        'Free up space and try again.',
      );
    }
    return path;
  }

  Future<String> _uniquePath(Directory dir, String baseName, String extension) async {
    final safe = sanitizeFileName(baseName);
    var candidate = p.join(dir.path, '$safe.$extension');
    var counter = 1;
    while (await File(candidate).exists()) {
      candidate = p.join(dir.path, '${safe}_$counter.$extension');
      counter++;
    }
    return candidate;
  }

  /// Writes a preview file (used by the in-app PDF viewer).
  Future<String> writePreview(Uint8List bytes, {String name = 'preview'}) async {
    final dir = await previewDirectory();
    final file = File(p.join(
      dir.path,
      '${sanitizeFileName(name)}_${DateTime.now().microsecondsSinceEpoch}.pdf',
    ));
    await file.writeAsBytes(bytes, flush: true);
    return file.path;
  }

  /// Shares a produced file with any installed app.
  Future<void> shareFile(String path, {String? subject}) async {
    final file = File(path);
    if (!await file.exists()) {
      throw FilePickException('That file no longer exists. Re-run the operation.');
    }
    await SharePlus.instance.share(
      ShareParams(
        files: [XFile(path, mimeType: 'application/pdf')],
        subject: subject,
        text: subject,
      ),
    );
  }

  /// Opens a produced file in the user's PDF viewer.
  Future<void> openFile(String path) async {
    final file = File(path);
    if (!await file.exists()) {
      throw FilePickException('That file no longer exists. Re-run the operation.');
    }
    final result = await OpenFilex.open(path);
    if (result.type != ResultType.done) {
      throw FilePickException('No app is available to open this PDF (${result.message}).');
    }
  }

  /// Deletes a produced file (used by history "delete").
  Future<void> deleteFile(String path) async {
    final file = File(path);
    if (await file.exists()) await file.delete();
  }

  Future<int?> fileSize(String path) async {
    final file = File(path);
    return await file.exists() ? file.length() : null;
  }

  /// Removes the generated preview cache.
  Future<void> clearPreviews() async {
    final dir = await previewDirectory();
    if (await dir.exists()) {
      await for (final entry in dir.list()) {
        if (entry is File) await entry.delete();
      }
    }
  }
}

/// Removes characters that are unsafe in file names across Android/Fire OS.
String sanitizeFileName(String input) {
  final cleaned = input
      .replaceAll(RegExp(r'[\\/:*?"<>|\x00-\x1F]'), '_')
      .replaceAll(RegExp(r'\s+'), ' ')
      .trim();
  final withoutExt =
      cleaned.toLowerCase().endsWith('.pdf') ? cleaned.substring(0, cleaned.length - 4) : cleaned;
  final base = withoutExt.isEmpty ? 'document' : withoutExt;
  return base.length > 80 ? base.substring(0, 80) : base;
}

class FilePickException implements Exception {
  FilePickException(this.message);
  final String message;
  @override
  String toString() => message;
}

/// Returns the size of the file actually written to storage.
///
/// History and the "after" figure shown to the user must describe the real
/// file, not the buffer held in memory. They are always identical when the write
/// succeeded, but measuring the file makes that a checked fact rather than an
/// assumption, and keeps history correct if a future change alters the bytes on
/// the way to disk. [fallback] is used only if the file cannot be read.
Future<int> measuredOutputBytes(
  FileService service,
  String path, {
  required int fallback,
}) async {
  final measured = await service.fileSize(path);
  return measured ?? fallback;
}
