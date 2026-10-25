import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:in_app_purchase/in_app_purchase.dart';

import 'package:pdf_fit/core/config/app_config.dart';
import 'package:pdf_fit/core/entitlements/entitlement_service.dart';

/// Store products. A single non-consumable "premium unlock" per store keeps the
/// entitlement model simple and auditable.
class BillingProducts {
  /// Google Play product id (create in Play Console → Monetise → Products).
  static const String playPremium = 'pdf_fit_premium_unlock';

  /// Amazon Appstore SKU (create in the Amazon Developer Console). Amazon SKUs
  /// are store-specific; keep this identical to the console entry.
  static const String amazonPremium = 'pdf_fit_premium_unlock_amazon';

  static String get premiumId =>
      AppConfig.store == StoreFlavor.amazon ? amazonPremium : playPremium;

  /// Products this build is allowed to accept. Only the id for the current
  /// store is expected, but both are accepted so a restored purchase from the
  /// other store still unlocks (they are the same entitlement).
  static Set<String> get known => {premiumId};
}

enum BillingAvailability { unknown, available, unavailable }

/// Whether a purchase result is a real, store-confirmed entitlement.
enum PurchaseOutcome {
  /// Store confirmed and the entitlement was persisted.
  purchased,

  /// The user cancelled or the purchase is pending approval.
  pending,

  /// The store rejected the purchase.
  failed,

  /// The billing backend cannot be reached / the SKU is not configured.
  unavailable,

  /// A purchase was reported for an unknown product; premium is NOT granted.
  unverified,
}

class BillingResult {
  const BillingResult(this.outcome, this.message, {this.productId});
  final PurchaseOutcome outcome;
  final String message;
  final String? productId;

  bool get isSuccess => outcome == PurchaseOutcome.purchased;
}

/// Real in-app purchase integration via `in_app_purchase`.
///
/// Google Play and the Amazon Appstore are separate stores with separate SDKs.
/// The Flutter `in_app_purchase` plugin ships an Amazon Appstore implementation
/// on Android and selects the backend at runtime.
///
/// Honest limitations (see docs/STORE_SETUP.md):
///  * Google Play: the product must exist in Play Console and the app must be
///    signed with the upload key; purchases need a licence-tester account.
///  * Amazon: the SKU must exist in the Amazon Developer Console and the app must
///    be installed through the Amazon Appstore.
///  * Server-side receipt verification is NOT implemented (there is no backend in
///    a zero-budget setup). The app relies on the store's own receipt state via
///    the plugin plus `restorePurchases` for re-entitlement.
class BillingService {
  BillingService(this.entitlements, {InAppPurchase? iap})
      : _iap = iap ?? InAppPurchase.instance;

  final EntitlementService entitlements;
  final InAppPurchase _iap;

  StreamSubscription<List<PurchaseDetails>>? _subscription;
  BillingAvailability _availability = BillingAvailability.unknown;
  ProductDetails? _product;
  final _results = StreamController<BillingResult>.broadcast();

  /// Emits the outcome of purchase attempts for the UI to display.
  Stream<BillingResult> get results => _results.stream;
  BillingAvailability get availability => _availability;
  ProductDetails? get product => _product;

  /// Price string from the store, e.g. "Rs 350.00". Never hardcoded.
  String get priceLabel => _product?.price ?? 'Price unavailable';

  Future<void> initialize() async {
    _subscription = _iap.purchaseStream.listen(
      _handlePurchases,
      onError: (Object e) {
        _results.add(BillingResult(
          PurchaseOutcome.unavailable,
          'The store returned an error: $e',
        ));
      },
    );
    try {
      final available = await _iap.isAvailable();
      if (!available) {
        _availability = BillingAvailability.unavailable;
        return;
      }
      final response = await _iap.queryProductDetails(BillingProducts.known);
      if (response.productDetails.isNotEmpty) {
        _product = response.productDetails.first;
        _availability = BillingAvailability.available;
      } else {
        // Running, but the SKU is not configured in the store console.
        _availability = BillingAvailability.unavailable;
      }
    } catch (e) {
      _availability = BillingAvailability.unavailable;
      debugPrint('Billing init failed: $e');
    }
  }

  Future<BillingResult> buyPremium() async {
    if (_availability != BillingAvailability.available || _product == null) {
      return BillingResult(
        PurchaseOutcome.unavailable,
        'Purchases are not available right now. The store product '
        '"${BillingProducts.premiumId}" is not configured for this build, or the '
        'store is unreachable.',
      );
    }
    try {
      final param = PurchaseParam(productDetails: _product!);
      // Non-consumable unlock.
      final started = await _iap.buyNonConsumable(purchaseParam: param);
      if (!started) {
        return const BillingResult(
          PurchaseOutcome.failed,
          'The store did not start the purchase flow. Check your store account.',
        );
      }
      // The authoritative result arrives on purchaseStream.
      return const BillingResult(
        PurchaseOutcome.pending,
        'Waiting for the store to confirm the purchase…',
      );
    } catch (e) {
      return BillingResult(PurchaseOutcome.failed, 'Purchase failed: $e');
    }
  }

  /// Re-reads past purchases (required after a reinstall).
  Future<void> restore() async {
    try {
      await _iap.restorePurchases();
    } catch (e) {
      _results.add(BillingResult(PurchaseOutcome.unavailable, 'Restore failed: $e'));
    }
  }

  Future<void> _handlePurchases(List<PurchaseDetails> purchases) async {
    for (final purchase in purchases) {
      switch (purchase.status) {
        case PurchaseStatus.purchased:
        case PurchaseStatus.restored:
          // The plugin reports these only after the store itself validated the
          // receipt state. Grant, then finish the transaction.
          await _grant(purchase);
        case PurchaseStatus.pending:
          _results.add(const BillingResult(
            PurchaseOutcome.pending,
            'Purchase is pending store approval.',
          ));
        case PurchaseStatus.error:
          _results.add(BillingResult(
            PurchaseOutcome.failed,
            purchase.error?.message ?? 'The store reported a purchase error.',
          ));
          if (purchase.pendingCompletePurchase) {
            await _iap.completePurchase(purchase);
          }
        case PurchaseStatus.canceled:
          _results.add(const BillingResult(PurchaseOutcome.pending, 'Purchase cancelled.'));
      }
    }
  }

  Future<void> _grant(PurchaseDetails purchase) async {
    if (!BillingProducts.known.contains(purchase.productID)) {
      _results.add(BillingResult(
        PurchaseOutcome.unverified,
        'Unknown product "${purchase.productID}" was reported by the store.',
      ));
      return;
    }
    await entitlements.grantFromStore(productId: purchase.productID);
    if (purchase.pendingCompletePurchase) {
      await _iap.completePurchase(purchase);
    }
    _results.add(BillingResult(
      PurchaseOutcome.purchased,
      'Premium unlocked.',
      productId: purchase.productID,
    ));
  }

  Future<void> dispose() async {
    await _subscription?.cancel();
    await _results.close();
  }
}
