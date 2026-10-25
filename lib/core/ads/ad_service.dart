import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:google_mobile_ads/google_mobile_ads.dart';

import 'package:pdf_fit/core/config/app_config.dart';
import 'package:pdf_fit/core/entitlements/entitlement_service.dart';

/// Ad state exposed to widgets.
///
/// Ads are limited to non-intrusive placements: a banner on the home screen and
/// an interstitial after a *successful* multi-file operation. Premium users and
/// the Amazon flavour never see them.
class AdService {
  AdService(this.entitlements);

  final EntitlementService entitlements;

  InterstitialAd? _interstitial;
  bool _initialised = false;
  bool _sdkFailed = false;

  /// Last error reported by the Ads SDK, surfaced in diagnostics so a blank
  /// banner is never mistaken for a working one.
  String? lastError;

  /// True when ads may be requested right now.
  bool get adsAllowed => entitlements.adsEnabled;

  bool get usingTestAds => !AppConfig.hasProductionAds;
  bool get sdkReady => _initialised && !_sdkFailed;

  Future<void> initialize() async {
    if (!adsAllowed) return;
    try {
      // The SDK reads the app id from AndroidManifest
      // (com.google.android.gms.ads.APPLICATION_ID).
      final status = await MobileAds.instance.initialize();
      _initialised = true;
      debugPrint('AdMob initialised: ${status.adapterStatuses.keys.join(', ')}');
    } catch (e) {
      // Fire OS devices without Google Play services land here; the UI shows no
      // banner rather than crashing or leaving a blank box.
      _sdkFailed = true;
      lastError = e.toString();
      debugPrint('AdMob init failed: $e');
    }
  }

  /// Loads an interstitial ahead of time (call after a successful operation).
  Future<void> preloadInterstitial() async {
    if (!adsAllowed || !sdkReady || _interstitial != null) return;
    await InterstitialAd.load(
      adUnitId: AppConfig.admobInterstitialUnitId,
      request: const AdRequest(),
      adLoadCallback: InterstitialAdLoadCallback(
        onAdLoaded: (ad) => _interstitial = ad,
        onAdFailedToLoad: (error) {
          lastError = 'Interstitial load failed: ${error.code} ${error.message}';
          _interstitial = null;
        },
      ),
    );
  }

  /// Shows a loaded interstitial. Returns false when none was ready, so callers
  /// never block the user on an ad that cannot display.
  Future<bool> showInterstitial() async {
    final ad = _interstitial;
    if (!adsAllowed || ad == null) return false;
    _interstitial = null;
    final completer = Completer<bool>();
    ad.fullScreenContentCallback = FullScreenContentCallback(
      onAdDismissedFullScreenContent: (ad) {
        ad.dispose();
        if (!completer.isCompleted) completer.complete(true);
      },
      onAdFailedToShowFullScreenContent: (ad, error) {
        lastError = 'Interstitial show failed: ${error.message}';
        ad.dispose();
        if (!completer.isCompleted) completer.complete(false);
      },
    );
    await ad.show();
    return completer.future.timeout(const Duration(seconds: 30), onTimeout: () => false);
  }

  void dispose() {
    _interstitial?.dispose();
    _interstitial = null;
  }
}
