# PDF Fit — release status

_Last updated: 25 October 2026_

This file is the honest accounting of what is finished, what is verified, and
what still requires action from you (accounts, keys, devices). It is updated
whenever the state changes.

---

## Verified in the build sandbox

| Item | Evidence |
|---|---|
| Flutter project compiles | `flutter analyze` → **0 errors** |
| Automated tests | `flutter test` → **74/74 passing** (60 + 9 compression-size + 5 file-workflow) |
| 200 KB target uses real bytes | 9,446,634 B → **179,235 B on disk** (limit 204,800), measured with `File.length()` after writing |
| Real PDF compression | 14.17 MB → 4.73 MB, met a 4.96 MB target, output re-opened and page count confirmed |
| Output reopen + re-process | Compressed file reopened from disk, page count confirmed, then compressed again successfully |
| Corrupted PDF handling | Truncated/junk input rejected with a typed message; asserted **no output file is created** |
| Split / merge / rotate | Output page counts and page **order** verified by extracting text from the produced files |
| Non-PDF input rejected | Test asserts a thrown `PdfOperationException`, no corrupt output |
| Upload readiness engine | 21 tests across pass / fail / warning / notApplicable / mixed |
| Basic vs Premium gating | 16 tests; mock unlocks refused in normal builds |
| **AAB built** | `artifacts/app-play-release.aab`, **32.4 MB** (32,362,027 B), valid bundle: `BundleConfig.pb`, 5 dex, arm64-only libs incl. `libpdfium.so` |
| Release APK built | `app-play-release.apk`, **37.0 MB**, `com.pdffit.pdf_fit` v1.0.0, targetSdk 36, **not debuggable** |
| APK signature | `apksigner verify` → **valid** (`CN=Android Debug` — see below) |
| Single ABI | `native-code: 'arm64-v8a'` only; `armeabi-v7a`/`x86_64` libs pruned |
| PDF engine present in APK | `lib/arm64-v8a/libpdfium.so` (6,386,696 B) confirmed inside the APK |
| Amazon flavour separation | merged Amazon manifest has **no `AD_ID`, no ads-service permissions, no `MobileAdsInitProvider`**, while keeping `INTERNET` + `BILLING` |
| Permission hygiene | `READ_MEDIA_IMAGES/VIDEO/AUDIO` removed from the Play build (a PDF tool has no need for them) |

---

## Not verified here (requires hardware, accounts or money)

These are **not claimed to work**. The code paths exist and are wired to the
standard plugins, but they have not been exercised against a live service.

1. **Installing and running the app on a device.** Verified impossibility:
   `/proc/cpuinfo` exposes neither `vmx` nor `svm`, `/dev/kvm` is absent, the
   machine is itself a guest (`hypervisor` flag), the `emulator` package and
   system images are not installed, `flutter emulators` reports none, and
   `adb devices` lists nothing. Software-only emulation of a modern Android
   image is not viable on 2 vCPUs / 1.9 GB RAM. Use the checklist in
   `docs/MANUAL_TEST_CHECKLIST.md` on a real phone. Run
   `adb install build/app/outputs/flutter-apk/app-play-debug.apk` on a phone and
   walk through: pick PDF → compress to 200 KB → open → share → check the
   before/after sizes.
2. **Signing with your upload key.** No keystore was created (deliberately).
   Both artifacts here are debug-signed: `tool/verify_signing.sh` reports
   `FAIL: signed with the Android DEBUG key` for each, and `jarsigner -verify`
   shows `CN=Android Debug`. They install on a device; **neither can be uploaded**.
   Follow `docs/SIGNING_AND_RELEASE.md` §1-3 to create and use your own key.
3. **Google Play purchases.** Needs a Play Console product
   `pdf_fit_premium_unlock`, an uploaded build and a licence-tester account.
4. **Amazon purchases.** Needs the Amazon Developer Console SKU
   `pdf_fit_premium_unlock_amazon` and the app installed through the Amazon
   Appstore.
5. **Live AdMob fill.** The Play build ships with Google's public **test** ad
   units. Inject production ids to earn revenue (`docs/STORE_SETUP.md` §3).
   The Amazon build intentionally has no ads and no INTERNET permission.
6. **Store approval.** Nobody can guarantee this. Nothing in the app conflicts
   with published policy as far as it can be assessed from source, but review is
   a human process.

---

## Feature completeness

### Implemented and exercised with real files
- Targeted compression with a measured search loop and a full attempt log
- Upload readiness checker (size, pages, A4, portrait, uniform size, text layer,
  annotations, encryption)
- Merge, split (every N / per page / odd-even / exact ranges), rotate,
  images → PDF
- In-app PDF preview (pdfrx/PDFium rendering)
- Presets (SQLite, seeded + user-created) and history (SQLite) with real
  before/after sizes, open/share/delete
- Basic/Premium entitlements with store-verified vs development-mock separation
- AdMob banner + interstitial for the Basic tier on the Play build only
- `in_app_purchase` for Play and Amazon, with restore support
- Privacy policy in-app and in `docs/PRIVACY_POLICY.md`

### Known functional gaps (deliberate, documented)
1. **OCR is not implemented.** The upload checker correctly detects scanned
   PDFs and tells the user a text layer is missing, but PDF Fit cannot add one.
   Adding OCR requires ML Kit/Tesseract, which is a separate dependency decision.
2. **No server-side receipt validation.** Entitlements rely on the store's own
   receipt state via the plugin plus restore. A determined user could tamper with
   local state; a backend would be needed to harden this. Documented in
   `BillingService`.
3. **Compressed pages lose selectable text.** This is inherent to raster
   compression; the app states it in the UI and keeps the original untouched.
4. **History trimming deletes list rows only** — files the user already shared or
   saved elsewhere are never touched.

---

## Immediate next steps (in order)

1. Run the APK on a real phone and complete the manual pass above.
2. Create the upload keystore and produce a signed release APK/AAB.
3. Configure AdMob units and the store products, inject ids at build time.
4. Test a purchase with a licence-tester account on Google Play.
5. Capture store screenshots and publish the privacy policy at a public URL.
