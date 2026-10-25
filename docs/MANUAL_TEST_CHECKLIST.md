# Manual test checklist — physical Android phone

This is the part that cannot be done in a sandbox. Nothing in this document has
been executed yet: the build environment has no `/dev/kvm`, no CPU
virtualisation flags (`vmx`/`svm`) and therefore cannot run an emulator, and no
physical device is attached. The automated tests cover the PDF engine, the size
maths and the file-writing path; **this checklist covers what tests cannot** —
the picker, the OS share sheet, the external PDF viewer, real storage, and
battery/memory behaviour on a real device.

Record what you actually observe. If something fails, note the step number and
the exact on-screen message.

---

## 0. Install the build

```bash
# Debug build: installable, debuggable, fine for this checklist
flutter build apk --debug --flavor play --target-platform android-arm64 \
  --dart-define=PDFFIT_STORE=play
adb install -r build/app/outputs/flutter-apk/app-play-debug.apk

# or, for a release-speed check
adb install -r build/app/outputs/flutter-apk/app-play-release.apk
```

| # | Check | Expected |
|---|---|---|
| 0.1 | `adb install` completes | `Success` |
| 0.2 | App icon appears labelled **PDF Fit** | Yes |
| 0.3 | Launches without crash; three tabs visible | Home / Tools / Settings (or as built) |
| 0.4 | Android Settings → Apps → PDF Fit → Permissions | No media/audio/video permissions requested *(release build)* |

**Prepare test files** (put in device Download folder):

- `scanned_5mb.pdf` — a real scan, 3–6 MB is ideal
- `text_200kb.pdf` — a normal digital PDF
- `large_20mb.pdf` — something heavy, if you have it
- `protected.pdf` — a password-protected PDF
- `not_a_pdf.pdf` — any non-PDF file renamed to `.pdf`

---

## 1. Compression to an exact target size — the core claim

The UI preset **200 KB** means 200 × 1024 = **204,800 bytes**, and the limit is
applied to the **actual output file size in bytes**, measured after the file is
written.

| # | Step | Expected result |
|---|---|---|
| 1.1 | Home → Compress → pick `scanned_5mb.pdf` | File name and size shown; size matches the real file |
| 1.2 | Choose preset **200 KB** → Compress | Progress shown; no fabricated instant success |
| 1.3 | Result screen | Shows before size, after size, saved %, and whether the target was met |
| 1.4 | Tap the result's **Open** | External PDF viewer opens the file; pages render |
| 1.5 | **Verify the size independently** (see below) | ≤ 204,800 bytes |
| 1.6 | Return to History | The same entry shows the same after-size |

**Independently verify the byte count** — do not trust the app's own figure:

```bash
adb shell run-as com.pdffit.pdf_fit.debug \
  ls -l "/data/data/com.pdffit.pdf_fit.debug/app_flutter/PDF Fit/output"
# or pull it and check on your machine:
adb shell "run-as com.pdffit.pdf_fit.debug cat '/data/data/com.pdffit.pdf_fit.debug/app_flutter/PDF Fit/output/<name>.pdf'" > /tmp/out.pdf
ls -l /tmp/out.pdf          # must be <= 204800
```

| # | Check | Expected |
|---|---|---|
| 1.7 | File size in bytes | **≤ 204,800** |
| 1.8 | Open the pulled file on a desktop PDF reader | Opens, all pages present, text is an image (expected after resampling) |
| 1.9 | Original `scanned_5mb.pdf` unchanged | Same byte size and checksum as before |

Sanity reference from the automated suite: a 9,446,634-byte scanned PDF
compressed to a 200 KB target produced **179,235 bytes on disk** — comfortably
under 204,800. A much heavier document will land closer to the limit, and a very
small or already-optimal one will report "already fits" instead of shrinking.

---

## 2. Unreachable target — must fail honestly, never fake success

| # | Step | Expected |
|---|---|---|
| 2.1 | Compress a 1-page scan with custom target **20 KB** | Reports the target was **not** met; saves the smallest achievable file |
| 2.2 | Message wording | Explicitly says the target could not be reached — no "Done!" |
| 2.3 | Resulting file | Still a valid, openable PDF (not truncated/corrupt) |
| 2.4 | Reported size | Matches the real file on disk |

---

## 3. Sharing and opening

| # | Step | Expected |
|---|---|---|
| 3.1 | Result → **Share** | Android share sheet appears with the PDF attached |
| 3.2 | Share to Gmail/Drive/Files | Target app receives a real, openable PDF with the same size |
| 3.3 | Share a file, then delete it from History, then share again from a stale link | Clear "file no longer exists" style message — no silent failure |
| 3.4 | Open with **no** PDF viewer installed (if you can test this) | Clear message naming the problem |

---

## 4. Corrupted / invalid input

| # | Step | Expected |
|---|---|---|
| 4.1 | Pick `not_a_pdf.pdf` | Rejected with a readable reason; **no output file created** |
| 4.2 | Truncate a real PDF (`head -c 5000 scan.pdf > broken.pdf`) and pick it | Rejected; message says damaged/unsupported, not a raw stack trace |
| 4.3 | Pick `protected.pdf` | Password message, or a password prompt; never a crash |
| 4.4 | After 4.1–4.3, check the output folder | Contains no partial or zero-byte files |

---

## 5. Other operations (regression pass)

| # | Step | Expected |
|---|---|---|
| 5.1 | Merge two PDFs | Output page count = sum; pages in the order picked |
| 5.2 | Split "every 2 pages" a 5-page PDF | 3 outputs: 2 + 2 + 1 pages |
| 5.3 | Split exact ranges, e.g. `1-2,4` | Output has exactly those pages |
| 5.4 | Rotate 90° and reopen | Rotation visibly persisted in the saved file |
| 5.5 | Images → PDF with 3 photos | 3-page PDF, images upright |
| 5.6 | Upload check with an over-size file | Blocking verdict with the real limit stated |
| 5.7 | Upload check on a scanned (no text layer) PDF | Warns that no text layer was found |

---

## 6. Premium / ads / billing

| # | Step | Expected |
|---|---|---|
| 6.1 | Free-tier operation counted, then limit reached | Premium prompt appears; counting is visible |
| 6.2 | Tap unlock on a Play build **not** installed from Play | Clear failure message — no fake success |
| 6.3 | Purchase with a licence-tester account | Store sheet appears; success reflects the **verified** store receipt |
| 6.4 | Reinstall, then Restore | Premium state restored without paying twice |
| 6.5 | Banner shown on Home for free tier | Banner renders (test ad unit unless you injected production ids) |
| 6.6 | Premium user | **No** ads anywhere |
| 6.7 | Amazon build on a Fire device | No ads, no crash at startup (ads SDK components are removed) |

---

## 7. Privacy and security spot-checks

| # | Step | Expected |
|---|---|---|
| 7.1 | Enable airplane mode, then compress | Works fully offline |
| 7.2 | Read `docs/PRIVACY_POLICY.md` in Settings | Opens and is readable |
| 7.3 | Delete history entry | Row removed; files you already shared elsewhere are untouched |
| 7.4 | Check app storage after several runs | Outputs accumulate as expected; no unbounded temp growth |

---

## 8. Accessibility and robustness

| # | Step | Expected |
|---|---|---|
| 8.1 | Enable TalkBack | Every control has a meaningful label; screens traversable |
| 8.2 | System font size → largest | No clipped or overlapping text |
| 8.3 | Enable dark mode | All screens legible |
| 8.4 | Rotate the device mid-operation | No crash; operation completes |
| 8.5 | Kill the app mid-compression, relaunch | No corrupt output left behind; app starts cleanly |
| 8.6 | Compress a 50 MB+ file | Completes without OOM on a mid-range device; note the time |

---

## Sign-off

| Area | Pass / Fail | Notes |
|---|---|---|
| 1. Exact 200 KB target (≤ 204,800 B, verified with `ls -l`) | | |
| 2. Unreachable target reported honestly | | |
| 3. Open + share | | |
| 4. Corrupted input handling | | |
| 5. Merge / split / rotate / images | | |
| 6. Premium, restore, ads | | |
| 7. Privacy, offline, storage | | |
| 8. Accessibility, robustness | | |

**Do not treat the app as publication-ready until this table is filled in.**
The automated suite cannot see the share sheet, the external viewer, or a real
device's memory limits.
