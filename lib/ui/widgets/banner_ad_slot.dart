import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:google_mobile_ads/google_mobile_ads.dart';
import 'package:provider/provider.dart';

import 'package:pdf_fit/core/ads/ad_service.dart';
import 'package:pdf_fit/core/config/app_config.dart';

/// A real AdMob banner.
///
/// Renders nothing at all when ads are disallowed (Premium/Amazon) or when the
/// SDK could not initialise, so the layout never contains a blank box. When the
/// SDK is ready but the ad fails to fill, the failure reason is shown in debug
/// builds only — a "working" banner is never faked.
class BannerAdSlot extends StatefulWidget {
  const BannerAdSlot({super.key});

  @override
  State<BannerAdSlot> createState() => _BannerAdSlotState();
}

class _BannerAdSlotState extends State<BannerAdSlot> {
  BannerAd? _ad;
  bool _loaded = false;
  String? _error;
  bool _requested = false;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final ads = context.read<AdService>();
    if (!_requested && ads.adsAllowed && ads.sdkReady) {
      _requested = true;
      _load(ads);
    }
  }

  void _load(AdService ads) {
    final ad = BannerAd(
      adUnitId: AppConfig.admobBannerUnitId,
      size: AdSize.banner,
      request: const AdRequest(),
      listener: BannerAdListener(
        onAdLoaded: (_) {
          if (!mounted) return;
          setState(() {
            _loaded = true;
            _error = null;
          });
        },
        onAdFailedToLoad: (ad, error) {
          ad.dispose();
          if (!mounted) return;
          setState(() {
            _loaded = false;
            _error = '${error.code}: ${error.message}';
          });
        },
      ),
    );
    ad.load().then((_) {
      if (mounted) setState(() => _ad = ad);
    });
    _ad = ad;
  }

  @override
  void dispose() {
    _ad?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final ads = context.watch<AdService>();
    if (!ads.adsAllowed || !ads.sdkReady) return const SizedBox.shrink();

    // Wait for the ad object to exist before rendering the container.
    final ad = _ad;
    if (_loaded && ad != null) {
      return SizedBox(
        width: ad.size.width.toDouble(),
        height: ad.size.height.toDouble(),
        child: AdWidget(ad: ad),
      );
    }
    if (_error != null && kDebugMode) {
      return Padding(
        padding: const EdgeInsets.symmetric(vertical: 6),
        child: Text(
          'Ad unavailable ($_error)',
          textAlign: TextAlign.center,
          style: Theme.of(context).textTheme.bodySmall?.copyWith(
                color: Theme.of(context).colorScheme.onSurfaceVariant,
              ),
        ),
      );
    }
    return const SizedBox.shrink();
  }
}
