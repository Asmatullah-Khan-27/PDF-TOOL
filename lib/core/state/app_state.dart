import 'package:flutter/foundation.dart';

import 'package:pdf_fit/core/ads/ad_service.dart';
import 'package:pdf_fit/core/entitlements/billing_service.dart';
import 'package:pdf_fit/core/entitlements/entitlement_service.dart';
import 'package:pdf_fit/core/storage/app_database.dart';

/// Quota information for the Basic plan, derived from real history rows.
class QuotaState {
  const QuotaState({required this.used, required this.limit, required this.isPremium});

  final int used;

  /// -1 means unlimited.
  final int limit;
  final bool isPremium;

  int get remaining => limit < 0 ? -1 : (limit - used).clamp(0, limit);
  bool get exhausted => limit >= 0 && used >= limit;

  String get label => isPremium || limit < 0 ? 'Unlimited' : '$remaining of $limit left';
}

/// Application-wide state: entitlements, billing, ads, quota and history.
///
/// Everything that gates a feature lives here so the UI can never disagree with
/// the engine about whether an operation is allowed.
class AppState extends ChangeNotifier {
  AppState({
    required this.entitlements,
    required this.billing,
    required this.ads,
    AppDatabase? database,
  }) : db = database ?? AppDatabase.instance;

  final EntitlementService entitlements;
  final BillingService billing;
  final AdService ads;
  final AppDatabase db;

  List<HistoryEntry> _history = const [];
  List<Preset> _presets = const [];
  QuotaState _quota = const QuotaState(used: 0, limit: 0, isPremium: false);
  bool _busy = false;
  String? _lastBillingMessage;
  bool _initialised = false;

  List<HistoryEntry> get history => _history;
  List<Preset> get presets => _presets;
  QuotaState get quota => _quota;
  bool get isBusy => _busy;
  bool get isPremium => entitlements.isPremium;
  String? get lastBillingMessage => _lastBillingMessage;
  bool get initialised => _initialised;

  Future<void> initialize() async {
    await entitlements.load();
    await billing.initialize();
    await ads.initialize();
    billing.results.listen((result) {
      _lastBillingMessage = result.message;
      notifyListeners();
    });
    await refreshAll();
    _initialised = true;
    notifyListeners();
  }

  Future<void> refreshAll() async {
    _history = await db.history(limit: entitlements.historyLimit);
    _presets = await db.presets();
    await refreshQuota();
    notifyListeners();
  }

  Future<void> refreshQuota() async {
    final now = DateTime.now();
    final monthStart = DateTime(now.year, now.month);
    final used = await db.compressionCountSince(monthStart);
    _quota = QuotaState(
      used: used,
      limit: entitlements.monthlyCompressionLimit,
      isPremium: entitlements.isPremium,
    );
  }

  /// Records a produced document and enforces the Basic history cap.
  Future<HistoryEntry> record({
    required String operation,
    required String sourceName,
    required String outputPath,
    required String outputName,
    required int originalBytes,
    required int outputBytes,
    required int pageCount,
    Map<String, Object?> details = const {},
    bool success = true,
    String? errorMessage,
  }) async {
    final entry = HistoryEntry(
      operation: operation,
      sourceName: sourceName,
      outputName: outputName,
      outputPath: outputPath,
      originalBytes: originalBytes,
      outputBytes: outputBytes,
      pageCount: pageCount,
      createdAt: DateTime.now(),
      details: details,
      success: success,
      errorMessage: errorMessage,
    );
    final id = await db.addHistory(entry);
    // Basic plan keeps a bounded history; older rows (and only the rows, never
    // the files the user may have saved elsewhere) are trimmed.
    await db.trimHistory(entitlements.historyLimit);
    await refreshAll();
    return HistoryEntry(
      id: id,
      operation: entry.operation,
      sourceName: entry.sourceName,
      outputName: entry.outputName,
      outputPath: entry.outputPath,
      originalBytes: entry.originalBytes,
      outputBytes: entry.outputBytes,
      pageCount: entry.pageCount,
      createdAt: entry.createdAt,
      details: entry.details,
      success: entry.success,
      errorMessage: entry.errorMessage,
    );
  }

  Future<void> deleteHistory(HistoryEntry entry) async {
    if (entry.id != null) await db.deleteHistory(entry.id!);
    await refreshAll();
  }

  Future<void> clearHistory() async {
    await db.clearHistory();
    await refreshAll();
  }

  Future<void> addPreset({required String name, required int? targetBytes, bool grayscale = false}) async {
    final id = await db.addPreset(Preset(
      id: 0,
      name: name,
      targetBytes: targetBytes,
      grayscale: grayscale,
      createdAt: DateTime.now(),
    ));
    if (id <= 0) throw StateError('Preset could not be saved.');
    await refreshAll();
  }

  Future<void> deletePreset(Preset preset) async {
    if (preset.builtIn) return;
    await db.deletePreset(preset.id);
    await refreshAll();
  }

  /// Gate for compression runs; returns an error message or null when allowed.
  String? compressionBlockedReason() {
    if (isPremium) return null;
    if (_quota.exhausted) {
      return 'You have used all ${AppConfigLimits.freeMonthlyCompressions} free '
          'compressions this month. Upgrade for unlimited compression.';
    }
    return null;
  }

  void setUpBusy(bool value) {
    if (_busy == value) return;
    _busy = value;
    notifyListeners();
  }

  void setBillingMessage(String? message) {
    _lastBillingMessage = message;
    notifyListeners();
  }
}

/// Small indirection so the UI does not import AppConfig just for one number.
class AppConfigLimits {
  AppConfigLimits._();
  static const int freeMonthlyCompressions = 20;
}
