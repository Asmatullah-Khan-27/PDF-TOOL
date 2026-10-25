# Signing and producing the Play release

Everything in this document is **your** step: it involves secrets that must
never be handled by anyone else, and a key that, if lost, permanently ends your
ability to update the app under the same identity.

There is deliberately **no keystore in this repository**. None was generated for
you, and none should be committed.

---

## 0. Why this matters (read once)

- Google Play will not accept an AAB signed with the Android **debug** key. That
  key ships with the SDK, is public, and is identical on every machine.
- Android identifies an app by `applicationId` **plus** signing key. If you lose
  the key, you cannot publish an update to the installed user base. You would
  have to ship a new app with a new package id and start with zero installs.
- Therefore: back up the keystore and its passwords **before** the first upload.

---

## 1. Create your upload keystore

Run this **on your own machine**, not in a shared or cloud sandbox. Use a
password manager–generated password; do not reuse a login password.

```bash
keytool -genkeypair -v \
  -keystore ~/keys/pdf-fit-upload.jks \
  -storetype JKS \
  -keyalg RSA -keysize 4096 -validity 10000 \
  -alias upload
```

What the flags mean:

| Flag | Meaning |
|---|---|
| `-storetype JKS` | Universally supported by `jarsigner`/Gradle. (PKCS12 also works.) |
| `-keysize 4096` | RSA 4096-bit; comfortable margin, no compatibility downside. |
| `-validity 10000` | ~27 years. Play requires the key to be valid past 2033. |
| `-alias upload` | The key alias; must match `keyAlias` below. |

You will be prompted for the store password and the key password. **Record both
immediately** in your password manager.

Verify what you created (prints the certificate, never the private key):

```bash
keytool -list -v -keystore ~/keys/pdf-fit-upload.jks -alias upload
```

### Back it up now

Copy `pdf-fit-upload.jks` to at least two offline/independent locations (e.g. an
encrypted archive in cloud storage **and** a USB drive kept separately). Store the
passwords in your password manager, not in a text file next to the keystore. A
lost keystore cannot be recovered by anyone, including Google.

> **Note on Play App Signing.** When you first upload, Play Console will offer
> (and for new apps require) *Play App Signing*. Google then holds the app-signing
> key and re-signs your uploads. Your keystore above becomes the **upload key**,
> which is replaceable through Play Console support if it is lost. This reduces
> the risk considerably — but still back the upload key up.

---

## 2. Point the build at it

```bash
cp android/key.properties.template android/key.properties
```

Edit `android/key.properties`:

```properties
storePassword=your-store-password
keyPassword=your-key-password
keyAlias=upload
storeFile=/absolute/path/to/pdf-fit-upload.jks
```

- `android/key.properties` is **git-ignored** (`android/.gitignore`).
- `*.jks` / `*.keystore` are **git-ignored** too.
- `storeFile` is resolved relative to `android/`, so use an absolute path if the
  keystore lives outside the project (recommended — keep keys out of the repo).

`android/app/build.gradle.kts` reads this file automatically. If it is absent,
release builds fall back to the debug key and print a warning — that is why the
artifact produced in this sandbox is installable but not uploadable.

Confirm the build is no longer using the debug key:

```bash
./tool/verify_signing.sh build/app/outputs/bundle/playRelease/app-play-release.aab
./tool/verify_signing.sh build/app/outputs/flutter-apk/app-play-release.apk
```

Both should print `OK: ... signed` and a certificate DN that is **not**
`CN=Android Debug`.

---

## 3. Build the release artifacts

```bash
flutter clean
flutter pub get

# Google Play upload artifact (this is the one you upload)
flutter build appbundle --release --flavor play \
  --dart-define=PDFFIT_STORE=play \
  --dart-define=ADMOB_APP_ID=ca-app-pub-XXXXXXXX~YYYYYYYY

# Optional: a signed APK for direct device testing / Amazon
flutter build apk --release --flavor play \
  --dart-define=PDFFIT_STORE=play

flutter build apk --release --flavor amazon \
  --dart-define=PDFFIT_STORE=amazon
```

Outputs:

| Artifact | Path |
|---|---|
| Play bundle | `build/app/outputs/bundle/playRelease/app-play-release.aab` |
| Play APK | `build/app/outputs/flutter-apk/app-play-release.apk` |
| Amazon APK | `build/app/outputs/flutter-apk/app-amazon-release.apk` |

### About `ADMOB_APP_ID`

The app ships with Google's public **test** app id and test ad units. That is
correct for development and review, and it earns nothing. Replace it with your
own AdMob app id (and the unit ids in `lib/core/config/app_config.dart`) when you
are ready to serve real ads. Serving real ads against test unit ids, or the
reverse, violates AdMob policy.

---

## 4. Before you upload — Play Console requirements

- [ ] `flutter build appbundle --release` produced the AAB and
      `tool/verify_signing.sh` reports a non-debug signature.
- [ ] `versionCode` incremented for every upload (`pubspec.yaml` → `version: 1.0.0+1`).
- [ ] **Data safety** form completed: PDF Fit collects nothing, transmits nothing,
      and has no account system. AdMob (Play build only) collects advertising
      identifiers — declare that accurately.
- [ ] **Privacy policy** hosted at a public URL (content in
      `docs/PRIVACY_POLICY.md`). Required because the app requests ad-related
      permissions.
- [ ] **Ads declaration**: "contains ads" = yes for the Play build.
- [ ] **Content rating** questionnaire completed.
- [ ] **Target audience**: not directed at children.
- [ ] Store listing, screenshots, feature graphic (see `docs/STORE_LISTING.md`).
- [ ] Billing product `pdf_fit_premium_unlock` created and **active**, and a
      licence-tester account added for purchase testing.
- [ ] App tested on a real device via internal testing track before production.

---

## 5. Honest status

At the time of writing, the artifact in `artifacts/` was built in a sandbox with
**no keystore**, so it is **debug-signed**. It installs and runs on a device; it
is **not uploadable**. Everything needed to produce an uploadable build is
configured and waiting for your keystore — see §1–2.
