# PDF Fit — Store setup and release guide

This document lists **everything that cannot be done from source code**: accounts,
keys, console configuration, and the exact commands to produce release artifacts.

Nothing in this file has been verified against a live store from the build
sandbox (there is no store account available there). Everything that *can* be
verified — compilation, analysis, real PDF processing, unit tests, APK assembly —
was run and is reported in `docs/BUILD_AND_TEST.md`.

---

## 1. Application identity

| Item | Value |
|---|---|
| Application id | `com.pdffit.pdf_fit` |
| Debug suffix | `.debug` (so debug and release can coexist) |
| App name | PDF Fit |
| minSdk | 23 (Android 6.0) |
| targetSdk / compileSdk | 36 |
| Flavours | `play`, `amazon` |

If you want a different application id, change **all** of:

- `android/app/build.gradle.kts` → `defaultConfig.applicationId`
- `android/app/src/main/kotlin/com/pdffit/pdf_fit/MainActivity.kt` package
  (directory must match)
- `BillingProducts` product ids (section 4)

---

## 2. Signing key (both stores)

Stores reject builds signed with the Flutter debug key. Create an upload keystore
once and keep it safe — losing it means you cannot ship updates to Google Play.

```bash
keytool -genkeypair -v \
  -keystore ~/pdf-fit-upload.jks \
  -keyalg RSA -keysize 2048 -validity 10000 \
  -alias pdf-fit-upload \
  -dname "CN=PDF Fit, OU=Mobile, O=PDF Fit, L=Karachi, S=Sindh, C=PK"
```

Then create `android/key.properties` (already git-ignored):

```properties
storePassword=YOUR_STORE_PASSWORD
keyPassword=YOUR_KEY_PASSWORD
keyAlias=pdf-fit-upload
storeFile=/absolute/path/to/pdf-fit-upload.jks
```

The Gradle file reads this automatically. Without it, release builds fall back to
debug signing and print a warning — such a build **cannot** be uploaded.

> Also enable **Play App Signing** in the Play Console. Google then holds the app
> signing key and you keep the upload key above.

---

## 3. Google Play

1. Create the app in the Play Console (one-time US$25 registration).
2. **Store listing**: use `docs/STORE_LISTING.md` (short/full description, assets
   checklist).
3. **Data safety form**: answers are in `docs/PRIVACY_POLICY.md` §6.
   Short version: no document data is collected or shared; ads (free tier) use
   Google AdMob, which collects device/advertising identifiers.
4. **Content rating**: complete the questionnaire (Utility category, no user
   content, no data sharing).
5. **Ads declaration**: app contains ads (free tier).
6. **Target audience**: 13+ / general utility.
7. **Privacy policy URL**: required because the app requests AD_ID via AdMob.
   Host `docs/PRIVACY_POLICY.md` publicly and also set
   `AppConfig.privacyPolicyUrl` in `lib/core/config/app_config.dart`.

### AdMob (Play build)

AdMob is **required** to monetise the free tier and is **test-only until you
configure real units**.

1. Create an AdMob account, add the app, and create one **Banner** and one
   **Interstitial** unit.
2. Build with the real ids (never commit them):

```bash
flutter build appbundle --release --flavor play \
  --dart-define=PDFFIT_STORE=play \
  --dart-define=ADMOB_APP_ID=ca-app-pub-XXXXXXXX~YYYYYYYY \
  --dart-define=ADMOB_BANNER_ID=ca-app-pub-XXXXXXXX/1111111111 \
  --dart-define=ADMOB_INTERSTITIAL_ID=ca-app-pub-XXXXXXXX/2222222222
```

Without these defines the app ships with Google's public test units, which
**never earn revenue**. `Settings → Diagnostics` shows whether test or production
units are in use.

3. Play policy: AdMob requires the app to comply with the Families policy if you
   target children — PDF Fit does not, so keep the target audience at 13+.

### Play Billing

1. **Monetise → Products → In-app products** → create a **non-consumable**
   product with id `pdf_fit_premium_unlock` (must match
   `BillingProducts.playPremium`).
2. Set a price; the app displays the price string the store returns (never a
   hardcoded price).
3. Add your test account under **Setup → License testing** — purchases only work
   for licence testers on debug/sideloaded builds.
4. **Upload the signed AAB to a testing track before testing purchases.** Play
   billing does not work for an app that has never been uploaded.

Release command:

```bash
flutter build appbundle --release --flavor play \
  --dart-define=PDFFIT_STORE=play \
  --dart-define=ADMOB_APP_ID=... --dart-define=ADMOB_BANNER_ID=... \
  --dart-define=ADMOB_INTERSTITIAL_ID=...
# artifact: build/app/outputs/bundle/playRelease/app-play-release.aab
```

---

## 4. Amazon Appstore

Amazon is a separate store with a separate SDK and separate SKU ids.

1. Register at the Amazon Developer Console (free) and create the app.
2. **SKU**: create an in-app product with id `pdf_fit_premium_unlock_amazon`
   (matches `BillingProducts.amazonPremium`). The `in_app_purchase` plugin routes
   to Amazon's Appstore SDK on devices where the Amazon store is installed.
3. **No AdMob in the Amazon build.** Fire OS devices normally have no Google Play
   services, so the `amazon` flavour removes the AdMob application id and the
   INTERNET permission, and the app shows no ads (`AppConfig.adsSupported`).
   Revenue on Amazon therefore comes from the Premium unlock only.
4. Build:

```bash
flutter build apk --release --flavor amazon \
  --dart-define=PDFFIT_STORE=amazon
# artifact: build/app/outputs/flutter-apk/app-amazon-release.apk
```

Amazon requires an APK (not an AAB). Upload it in the Amazon console, fill in the
listing, content rating and privacy questionnaire (same answers as Play, minus
ads: the Amazon build shows no ads).

### Honest limitations for Amazon

- Amazon IAP has **not** been tested against a live Amazon account here. The code
  path is the same `in_app_purchase` integration, but Amazon requires the app to
  be installed **through the Amazon Appstore** for entitlement checks to succeed.
- Amazon device testing needs a Fire tablet or an Android device with the Amazon
  Appstore installed. Neither was available in the build environment.

---

## 5. What the sandbox could not do

| Task | Status |
|---|---|
| Compile, analyse, test the Dart/Flutter code | ✅ done here |
| Build a real Android APK | ✅ done here (debug; see BUILD_AND_TEST.md) |
| Release APK/AAB with a real keystore | ⚠️ requires your keystore |
| Run on a physical device / emulator | ❌ no `/dev/kvm` in the sandbox, so no emulator |
| Live AdMob fill | ❌ needs an AdMob account + real device |
| Live Play/Amazon purchase | ❌ needs store accounts and console products |
| Store review/approval | ❌ cannot be guaranteed by anyone |

---

## 6. Pre-submission checklist

- [ ] Upload keystore created, `android/key.properties` present, backup stored
- [ ] `versionCode` / `versionName` bumped in `pubspec.yaml`
- [ ] Release build signed with the upload key (not debug)
- [ ] AdMob production ids injected; test ads disabled
- [ ] `pdf_fit_premium_unlock` created in Play Console (and `_amazon` in Amazon)
- [ ] Product tested with a licence tester account
- [ ] Privacy policy hosted publicly; URL reachable
- [ ] Data safety / privacy questionnaire completed consistently with
      `docs/PRIVACY_POLICY.md`
- [ ] Store listing assets: icon 512×512, feature graphic 1024×500, ≥2 phone
      screenshots (see `docs/STORE_LISTING.md`)
- [ ] Content rating questionnaire completed
- [ ] Tested on a real device: pick a PDF, compress to a target, open, share
- [ ] Amazon build installed from the Amazon Appstore and Premium tested
