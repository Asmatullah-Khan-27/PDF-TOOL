/// Which store build this binary was compiled for.
///
/// Set at build time:
///   flutter build apk --flavor play   --dart-define=PDFFIT_STORE=play
///   flutter build apk --flavor amazon --dart-define=PDFFIT_STORE=amazon
enum StoreFlavor { play, amazon, unknown }

class AppConfig {
  AppConfig._();

  static const String appName = 'PDF Fit';
  static const String tagline = 'Compress, Resize & Prepare';
  static const String supportEmail = 'support@pdffit.app';
  static const String privacyPolicyUrl = 'https://pdffit.app/privacy';

  static const String _storeDefine = String.fromEnvironment('PDFFIT_STORE', defaultValue: '');

  static StoreFlavor get store => switch (_storeDefine) {
        'play' => StoreFlavor.play,
        'amazon' => StoreFlavor.amazon,
        _ => StoreFlavor.unknown,
      };

  static String get storeLabel => switch (store) {
        StoreFlavor.play => 'Google Play',
        StoreFlavor.amazon => 'Amazon Appstore',
        StoreFlavor.unknown => 'Development',
      };

  // ---------------------------------------------------------------------------
  // Advertising
  // ---------------------------------------------------------------------------
  // Google's published *test* ids are used unless production ids are supplied at
  // build time. They never generate revenue and MUST be replaced before release.
  static const String _admobTestAppId = 'ca-app-pub-3940256099942544~3347511713';
  static const String _admobTestBannerId = 'ca-app-pub-3940256099942544/6300978111';
  static const String _admobTestInterstitialId = 'ca-app-pub-3940256099942544/1033173712';

  static const String _admobAppIdDefine = String.fromEnvironment('ADMOB_APP_ID');
  static const String _admobBannerDefine = String.fromEnvironment('ADMOB_BANNER_ID');
  static const String _admobInterstitialDefine = String.fromEnvironment('ADMOB_INTERSTITIAL_ID');

  /// True when real (revenue-generating) ad units are configured.
  static bool get hasProductionAds =>
      _admobAppIdDefine.isNotEmpty &&
      _admobBannerDefine.isNotEmpty &&
      !_admobAppIdDefine.contains('3940256099942544');

  static String get admobAppId =>
      _admobAppIdDefine.isNotEmpty ? _admobAppIdDefine : _admobTestAppId;

  static String get admobBannerUnitId =>
      _admobBannerDefine.isNotEmpty ? _admobBannerDefine : _admobTestBannerId;

  static String get admobInterstitialUnitId => _admobInterstitialDefine.isNotEmpty
      ? _admobInterstitialDefine
      : _admobTestInterstitialId;

  /// Amazon Fire OS devices usually ship without Google Play services, so AdMob
  /// cannot serve there. Ads are disabled for the Amazon flavour instead of
  /// showing a permanently blank banner or crashing.
  static const bool _amazonHasPlayServices =
      bool.fromEnvironment('AMAZON_HAS_PLAY_SERVICES', defaultValue: false);

  static bool get adsSupported => store != StoreFlavor.amazon || _amazonHasPlayServices;

  // ---------------------------------------------------------------------------
  // Basic (free) plan limits. Premium removes all of these.
  // ---------------------------------------------------------------------------
  static const int freeHistoryLimit = 25;
  static const int freeMergeFileLimit = 2;
  static const int freeImagesPerDocument = 5;
  static const int freeCustomPresets = 1;
  static const int freeMonthlyCompressions = 20;

  static const List<int> freeTargetSizes = [
    100 * 1024,
    200 * 1024,
    500 * 1024,
    1024 * 1024,
    2 * 1024 * 1024,
  ];

  static const String version = '1.0.0';
}
