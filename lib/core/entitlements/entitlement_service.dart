import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:pdf_fit/core/config/app_config.dart';

/// How the current premium entitlement was obtained.
///
/// This distinction is deliberate: a locally simulated unlock must never be
/// mistaken for a paid, store-verified purchase.
enum EntitlementSource {
  /// No entitlement.
  none,

  /// Granted by a purchase that the store's billing library reported as
  /// purchased/restored. This is the only value that exists in release.
  storeVerified,

  /// Debug-only local toggle (`--dart-define=PDFFIT_ALLOW_MOCK_PURCHASE=true`).
  developmentMock,
}

class EntitlementState {
  const EntitlementState({
    required this.isPremium,
    required this.source,
    this.productId,
    this.checkedAt,
  });

  const EntitlementState.free()
      : isPremium = false,
        source = EntitlementSource.none,
        productId = null,
        checkedAt = null;

  final bool isPremium;
  final EntitlementSource source;
  final String? productId;
  final DateTime? checkedAt;

  /// True only for a real, store-verified entitlement.
  bool get isStoreVerified => isPremium && source == EntitlementSource.storeVerified;

  /// True when the unlock is a development mock; surfaced in the UI so the state
  /// is never silently misleading.
  bool get isMock => source == EntitlementSource.developmentMock;

  EntitlementState copyWith({
    bool? isPremium,
    EntitlementSource? source,
    String? productId,
    DateTime? checkedAt,
  }) =>
      EntitlementState(
        isPremium: isPremium ?? this.isPremium,
        source: source ?? this.source,
        productId: productId ?? this.productId,
        checkedAt: checkedAt ?? this.checkedAt,
      );
}

/// Persistence abstraction so tests do not need a real platform channel.
abstract class EntitlementStore {
  Future<({bool isPremium, String? source, String? productId})?> read();
  Future<void> write({required String source, String? productId});
  Future<void> clear();
}

class PrefsEntitlementStore implements EntitlementStore {
  static const _kPremium = 'entitlement_premium';
  static const _kSource = 'entitlement_source';
  static const _kProduct = 'entitlement_product';

  @override
  Future<({bool isPremium, String? source, String? productId})?> read() async {
    final prefs = await SharedPreferences.getInstance();
    if (!prefs.containsKey(_kPremium)) return null;
    return (
      isPremium: prefs.getBool(_kPremium) ?? false,
      source: prefs.getString(_kSource),
      productId: prefs.getString(_kProduct),
    );
  }

  @override
  Future<void> write({required String source, String? productId}) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_kPremium, true);
    await prefs.setString(_kSource, source);
    if (productId != null) await prefs.setString(_kProduct, productId);
  }

  @override
  Future<void> clear() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(_kPremium);
    await prefs.remove(_kSource);
    await prefs.remove(_kProduct);
  }
}

/// In-memory store used by tests.
class MemoryEntitlementStore implements EntitlementStore {
  ({bool isPremium, String? source, String? productId})? _value;

  @override
  Future<({bool isPremium, String? source, String? productId})?> read() async => _value;

  @override
  Future<void> write({required String source, String? productId}) async {
    _value = (isPremium: true, source: source, productId: productId);
  }

  @override
  Future<void> clear() async => _value = null;
}

/// Owns the Basic/Premium decision for the whole app.
///
/// Rules:
///  * In release builds no mock unlock is possible (compile-time flag AND a
///    [kReleaseMode] guard).
///  * Entitlement changes only come from the billing layer after the store
///    confirmed a purchase; nothing is inferred from a local button press.
class EntitlementService extends ChangeNotifier {
  EntitlementService({EntitlementStore? store}) : _store = store ?? PrefsEntitlementStore();

  final EntitlementStore _store;
  EntitlementState _state = const EntitlementState.free();

  EntitlementState get state => _state;
  bool get isPremium => _state.isPremium;

  /// Mock purchases are opt-in at compile time AND impossible in release mode.
  static const bool _mockFlag = bool.fromEnvironment('PDFFIT_ALLOW_MOCK_PURCHASE');
  static bool get mockPurchasesAllowed => !kReleaseMode && _mockFlag;

  Future<void> load() async {
    final stored = await _store.read();
    if (stored == null || !stored.isPremium) {
      _state = const EntitlementState.free();
    } else {
      final source = switch (stored.source) {
        'store' => EntitlementSource.storeVerified,
        'mock' => mockPurchasesAllowed ? EntitlementSource.developmentMock : EntitlementSource.none,
        _ => EntitlementSource.none,
      };
      // A stored mock grant must not survive into a build that disallows mocks.
      _state = source == EntitlementSource.none
          ? const EntitlementState.free()
          : EntitlementState(
              isPremium: true,
              source: source,
              productId: stored.productId,
              checkedAt: DateTime.now(),
            );
    }
    notifyListeners();
  }

  /// Called by the billing layer only after the store confirmed the purchase.
  Future<void> grantFromStore({required String productId}) async {
    await _store.write(source: 'store', productId: productId);
    _state = EntitlementState(
      isPremium: true,
      source: EntitlementSource.storeVerified,
      productId: productId,
      checkedAt: DateTime.now(),
    );
    notifyListeners();
  }

  /// Development-only unlock used to exercise premium screens without a store
  /// account. Throws in release builds.
  Future<void> grantMock({String productId = 'dev.mock.premium'}) async {
    if (!mockPurchasesAllowed) {
      throw StateError('Mock purchases are disabled in this build.');
    }
    await _store.write(source: 'mock', productId: productId);
    _state = EntitlementState(
      isPremium: true,
      source: EntitlementSource.developmentMock,
      productId: productId,
      checkedAt: DateTime.now(),
    );
    notifyListeners();
  }

  /// Called when the store reports the purchase as no longer owned.
  Future<void> revoke() async {
    await _store.clear();
    _state = const EntitlementState.free();
    notifyListeners();
  }

  /// Plan label for the UI.
  String get planLabel {
    if (!_state.isPremium) return 'Basic';
    return _state.isMock ? 'Premium (dev mock)' : 'Premium';
  }

  // --- Feature gates ---------------------------------------------------------

  int get historyLimit => isPremium ? 1000 : AppConfig.freeHistoryLimit;
  int get mergeFileLimit => isPremium ? 100 : AppConfig.freeMergeFileLimit;
  int get imagesPerDocument => isPremium ? 200 : AppConfig.freeImagesPerDocument;
  int get customPresetLimit => isPremium ? 100 : AppConfig.freeCustomPresets;
  int get monthlyCompressionLimit => isPremium ? -1 : AppConfig.freeMonthlyCompressions;

  /// Custom target sizes, and any target outside the free list, are premium.
  bool allowsTargetSize(int? targetBytes) {
    if (isPremium) return true;
    if (targetBytes == null) return true; // "best effort" is always available
    return AppConfig.freeTargetSizes.contains(targetBytes);
  }

  bool get allowsPageRangeSplit => isPremium;

  bool get allowsGrayscale => true;

  bool get adsEnabled => !isPremium && AppConfig.adsSupported;
}
