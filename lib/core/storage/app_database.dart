import 'dart:convert';

import 'package:sqflite/sqflite.dart';

/// A processing preset the user can re-apply to any document.
class Preset {
  const Preset({
    required this.id,
    required this.name,
    required this.targetBytes,
    this.grayscale = false,
    this.allowDownscale = true,
    this.builtIn = false,
    required this.createdAt,
  });

  final int id;
  final String name;

  /// Target output size in bytes. Null means "optimise as much as possible".
  final int? targetBytes;
  final bool grayscale;
  final bool allowDownscale;
  final bool builtIn;
  final DateTime createdAt;

  Map<String, Object?> toRow() => {
        'name': name,
        'target_bytes': targetBytes,
        'grayscale': grayscale ? 1 : 0,
        'allow_downscale': allowDownscale ? 1 : 0,
        'build_in': builtIn ? 1 : 0,
        'created_at': createdAt.millisecondsSinceEpoch,
      };

  static Preset fromRow(Map<String, Object?> row) => Preset(
        id: row['id'] as int,
        name: row['name'] as String,
        targetBytes: row['target_bytes'] as int?,
        grayscale: (row['grayscale'] as int? ?? 0) == 1,
        allowDownscale: (row['allow_downscale'] as int? ?? 1) == 1,
        builtIn: (row['build_in'] as int? ?? 0) == 1,
        createdAt: DateTime.fromMillisecondsSinceEpoch(row['created_at'] as int? ?? 0),
      );

  /// Human readable target, e.g. "200 KB" or "Best effort".
  String get targetLabel => targetBytes == null ? 'Best effort' : formatBytes(targetBytes!);

  @override
  String toString() => 'Preset($name, $targetLabel)';
}

/// One entry of document history: what was produced, from what, and where.
class HistoryEntry {
  const HistoryEntry({
    this.id,
    required this.operation,
    required this.sourceName,
    required this.outputName,
    required this.outputPath,
    required this.originalBytes,
    required this.outputBytes,
    required this.pageCount,
    required this.createdAt,
    this.details = const {},
    this.success = true,
    this.errorMessage,
  });

  final int? id;
  final String operation;
  final String sourceName;
  final String outputName;

  /// Absolute path of the produced file inside app storage. Empty when the
  /// operation failed and produced nothing.
  final String outputPath;
  final int originalBytes;
  final int outputBytes;
  final int pageCount;
  final DateTime createdAt;
  final Map<String, Object?> details;
  final bool success;
  final String? errorMessage;

  double get ratio => originalBytes == 0 ? 1 : outputBytes / originalBytes;

  Map<String, Object?> toRow() => {
        'operation': operation,
        'source_name': sourceName,
        'output_name': outputName,
        'output_path': outputPath,
        'original_bytes': originalBytes,
        'output_bytes': outputBytes,
        'page_count': pageCount,
        'created_at': createdAt.millisecondsSinceEpoch,
        'details': jsonEncode(details),
        'success': success ? 1 : 0,
        'error_message': errorMessage,
      };

  static HistoryEntry fromRow(Map<String, Object?> row) => HistoryEntry(
        id: row['id'] as int?,
        operation: row['operation'] as String,
        sourceName: row['source_name'] as String? ?? '',
        outputName: row['output_name'] as String? ?? '',
        outputPath: row['output_path'] as String? ?? '',
        originalBytes: row['original_bytes'] as int? ?? 0,
        outputBytes: row['output_bytes'] as int? ?? 0,
        pageCount: row['page_count'] as int? ?? 0,
        createdAt: DateTime.fromMillisecondsSinceEpoch(row['created_at'] as int? ?? 0),
        details: row['details'] == null
            ? const {}
            : Map<String, Object?>.from(jsonDecode(row['details'] as String) as Map),
        success: (row['success'] as int? ?? 1) == 1,
        errorMessage: row['error_message'] as String?,
      );
}

/// SQLite-backed persistence for presets and history.
///
/// A real database is used (not a list held in memory) so history survives app
/// restarts and can be trimmed with a single query.
class AppDatabase {
  AppDatabase._();

  static final AppDatabase instance = AppDatabase._();
  static const int _version = 1;
  static const String _dbName = 'pdf_fit.db';

  Database? _db;
  Database? _testDb;

  /// Overrides the database for tests (e.g. an in-memory instance).
  // ignore: use_setters_to_change_properties
  void useTestDatabase(Database db) => _testDb = db;

  Future<Database> get database async {
    if (_testDb != null) return _testDb!;
    if (_db != null) return _db!;
    final path = await getDatabasesPath();
    _db = await openDatabase(
      '$path/$_dbName',
      version: _version,
      onCreate: (db, version) async {
        await db.execute('''
          CREATE TABLE history(
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            operation TEXT NOT NULL,
            source_name TEXT NOT NULL,
            output_name TEXT NOT NULL,
            output_path TEXT NOT NULL,
            original_bytes INTEGER NOT NULL,
            output_bytes INTEGER NOT NULL,
            page_count INTEGER NOT NULL,
            created_at INTEGER NOT NULL,
            details TEXT,
            success INTEGER NOT NULL DEFAULT 1,
            error_message TEXT
          )
        ''');
        await db.execute('''
          CREATE TABLE presets(
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            name TEXT NOT NULL,
            target_bytes INTEGER,
            grayscale INTEGER NOT NULL DEFAULT 0,
            allow_downscale INTEGER NOT NULL DEFAULT 1,
            build_in INTEGER NOT NULL DEFAULT 0,
            created_at INTEGER NOT NULL
          )
        ''');
        await db.execute('CREATE INDEX idx_history_created ON history(created_at DESC)');
        await _seedPresets(db);
      },
      onOpen: (db) async {
        // Keep built-in presets present even if the row set was edited.
        final rows = await db.query('presets', where: 'build_in = 1', limit: 1);
        if (rows.isEmpty) await _seedPresets(db);
      },
    );
    return _db!;
  }

  static Future<void> _seedPresets(Database db) async {
    final now = DateTime.now();
    final builtIns = <Preset>[
      Preset(
        id: 0,
        name: 'Email attachment (5 MB)',
        targetBytes: 5 * 1024 * 1024,
        createdAt: now,
        builtIn: true,
      ),
      Preset(
        id: 0,
        name: 'Job portal (500 KB)',
        targetBytes: 500 * 1024,
        createdAt: now,
        builtIn: true,
      ),
      Preset(
        id: 0,
        name: 'Government form (200 KB)',
        targetBytes: 200 * 1024,
        createdAt: now,
        builtIn: true,
      ),
      Preset(
        id: 0,
        name: 'Tiny scan (100 KB, grayscale)',
        targetBytes: 100 * 1024,
        grayscale: true,
        createdAt: now,
        builtIn: true,
      ),
    ];
    for (final preset in builtIns) {
      await db.insert('presets', preset.toRow());
    }
  }

  // --- History -------------------------------------------------------------

  Future<int> addHistory(HistoryEntry entry) async {
    final db = await database;
    return db.insert('history', entry.toRow());
  }

  Future<List<HistoryEntry>> history({int limit = 200}) async {
    final db = await database;
    final rows = await db.query('history', orderBy: 'created_at DESC', limit: limit);
    return rows.map(HistoryEntry.fromRow).toList();
  }

  Future<void> deleteHistory(int id) async {
    final db = await database;
    await db.delete('history', where: 'id = ?', whereArgs: [id]);
  }

  Future<void> clearHistory() async {
    final db = await database;
    await db.delete('history');
  }

  /// Trims history to [keep] newest entries (used by the free plan cap).
  Future<void> trimHistory(int keep) async {
    final db = await database;
    await db.rawDelete(
      'DELETE FROM history WHERE id NOT IN '
      '(SELECT id FROM history ORDER BY created_at DESC LIMIT ?)',
      [keep],
    );
  }

  Future<int> historyCount() async {
    final db = await database;
    final result = await db.rawQuery('SELECT COUNT(*) AS c FROM history');
    return (result.first['c'] as int?) ?? 0;
  }

  /// Number of successful compressions since [since] — powers the free-tier
  /// monthly quota, measured from real history rather than a drifting counter.
  Future<int> compressionCountSince(DateTime since) async {
    final db = await database;
    final result = await db.rawQuery(
      "SELECT COUNT(*) AS c FROM history WHERE operation = 'compress' AND success = 1 AND created_at >= ?",
      [since.millisecondsSinceEpoch],
    );
    return (result.first['c'] as int?) ?? 0;
  }

  // --- Presets -------------------------------------------------------------

  Future<List<Preset>> presets() async {
    final db = await database;
    final rows = await db.query('presets', orderBy: 'build_in DESC, created_at ASC');
    return rows.map(Preset.fromRow).toList();
  }

  Future<int> addPreset(Preset preset) async {
    final db = await database;
    return db.insert('presets', preset.toRow());
  }

  Future<void> deletePreset(int id) async {
    final db = await database;
    await db.delete('presets', where: 'id = ? AND build_in = 0', whereArgs: [id]);
  }

  Future<int> customPresetCount() async {
    final db = await database;
    final result = await db.rawQuery('SELECT COUNT(*) AS c FROM presets WHERE build_in = 0');
    return (result.first['c'] as int?) ?? 0;
  }
}

/// Formats a byte count the way the UI shows file sizes.
String formatBytes(int bytes) {
  if (bytes < 1024) return '$bytes B';
  if (bytes < 1024 * 1024) {
    final kb = bytes / 1024;
    return kb >= 100 ? '${kb.round()} KB' : '${kb.toStringAsFixed(1)} KB';
  }
  final mb = bytes / (1024 * 1024);
  return mb >= 100 ? '${mb.round()} MB' : '${mb.toStringAsFixed(2)} MB';
}
