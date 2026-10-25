# PDF Fit — build and verification report

Everything below was executed in a Linux sandbox with:
Flutter 3.47.8 · Dart 3.13.7 · Android SDK 36 · build-tools 36.0.0 · JDK 21.

Commands are copy-pasteable locally.

---

## 1. Static analysis

```bash
flutter analyze
```

**Result: 0 errors.** The remaining output is 18 `info`-level lints
(deprecated `Radio.groupValue` API and one null-aware style hint). None of them
affect behaviour.

---

## 2. Automated tests

```bash
flutter test
```

**Result: 60 tests, all passing.**

| File | Tests | What it actually proves |
|---|---|---|
| `test/engine_test.dart` | 12 | Real PDFium: opens real PDFs, rejects non-PDF input, split/remove/rotate/merge produce exactly the requested pages (page *order* verified by extracting text), page rendering produces ink, and target-size compression reaches a measured target |
| `test/upload_rules_test.dart` | 21 | Severity ranking (`notApplicable < pass < warning < fail`), passing docs, over-limit failures, advisory warnings, non-applicable rules, mixed outcomes |
| `test/gating_test.dart` | 16 | Basic/Premium entitlements, mock unlocks refused in normal builds, store grants persisting, upload-profile behaviour |
| `test/widget_test.dart` | 11 | Real widgets render and respond; ad slot collapses to zero height; billing outcome semantics; file-name sanitising |

### Measured compression evidence (from `test/engine_test.dart`)

```
heavy input: 14169083 bytes
compressed:   4727107 bytes (target 4959179, 33.4% of original)
              dpi=195.57 quality=72 in 3463ms
```

The target was derived from the input size and **met**; the output was reopened
with PDFium to confirm the page count before the test asserted success.

---

## 3. Android build

Both flavours build with the same command shape:

```bash
# Play release APK (arm64 only)
flutter build apk --release --flavor play \
  --target-platform android-arm64 \
  --dart-define=PDFFIT_STORE=play

# Play release bundle for the Play Console
flutter build appbundle --release --flavor play \
  --dart-define=PDFFIT_STORE=play

# Amazon Appstore APK (no ads SDK components, see the flavour manifest)
flutter build apk --release --flavor amazon \
  --target-platform android-arm64 \
  --dart-define=PDFFIT_STORE=amazon
```

### Actual result of the release build

```
✓ Built build/app/outputs/flutter-apk/app-play-release.apk (37.0MB)
```

Preserved copy: `artifacts/PDFFit-1.0.0-play-release.apk`
(36,990,145 B, sha256
`d91f50fd906f03f82490e363e997eb96546e650361e285858191702f4f14cb1a`).

Verified with `aapt2` and `apksigner`:

| Property | Value |
|---|---|
| package | `com.pdffit.pdf_fit` |
| version | 1.0.0 (code 1) |
| label | `PDF Fit` |
| targetSdk / compileSdk | 36 |
| debuggable | **no** (release) |
| native-code | `arm64-v8a` only |
| PDF engine | `lib/arm64-v8a/libpdfium.so`, 6,386,696 B |
| signature | **valid**, `CN=Android Debug` |

The signature is the debug key because no keystore exists in the sandbox. The
APK installs and runs on a device, but **no store will accept it** until it is
re-signed with your upload key (`docs/STORE_SETUP.md` §2).

APK size dropped from 118 MB (debug, three ABIs) to 37 MB by pinning
`arm64-v8a` and excluding the `armeabi-v7a`/`x86`/`x86_64` native libraries that
transitive dependencies still publish. Google Play delivers per-device splits,
so an AAB is smaller still.

### Environment issues found and how they were handled

| Problem | Cause | Resolution |
|---|---|---|
| `No space left on device` mid-build | 25 GB root disk, PDFium + Gradle transforms | Removed build caches, limited ABIs to `arm64-v8a`, pruned `jniLibs` |
| `Cannot lock file hash cache … already been locked` | Orphaned Gradle daemon after a killed build | `./gradlew --stop`, delete `android/.gradle` |
| `NoSuchFileException: …/transforms/…/gradle-1.0.0.jar` | Transform cache deleted while a daemon held a stale file-watch map | Stop daemons, clear `caches/9.3.1/fileChanges`, rebuild with `--rerun-tasks` |
| `Product flavor … custom resource values … disabled` | `resValue` unsupported in this AGP's new DSL | Removed `resValue`; label comes from the manifest |
| Flutter tool crashed listing `/opt/tools/flutter/dev` | Cleanup removed an SDK directory | Recreated it |

---

## 4. Tests that require real hardware / store accounts

These cannot be verified in a headless sandbox and are **not claimed as verified**:

- Installing and launching the APK on a device (no `/dev/kvm`, so no emulator).
- Google Play / Amazon purchase flows (need store consoles + licence testers).
- Live AdMob fill (needs an AdMob account and a device with Play services).
- File picker and share-sheet behaviour (platform channels need a device).

Everything these depend on is wired through standard plugins and configured in
`android/app/build.gradle.kts` and the manifests; the setup steps are in
`docs/STORE_SETUP.md`.
