# PDF Fit — architecture

## What this app is

An offline Android document utility: compress a PDF to a target size, resize it
to a required page format, check it against an upload rule, and do the usual
merge/split/rotate/image-to-PDF jobs. Everything runs on the device. There is no
backend, no account, and no upload code path.

---

## Layers

```
lib/
  main.dart                     app bootstrap, providers, AppShell (3 tabs)
  core/
    config/app_config.dart      store flavour, ad flags, AdMob ids, limits
    pdf/pdfium_engine.dart      PDFium via pdfrx FFI, inside a worker isolate
    pdf/pdf_operations.dart     compress / merge / split / rotate / images
    pdf/upload_rules.dart       rule profiles + severity aggregation
    files/file_service.dart     pick, save, write, share, open
    storage/app_database.dart   SQLite: history + presets
    entitlements/               entitlement_service, billing_service
    ads/ad_service.dart         AdMob banner + interstitial
    state/app_state.dart        ChangeNotifier: quota, settings, premium
  ui/
    screens/                    12 screens
    widgets/                    shared widgets (loading, empty, error, banner)
```

### State flow

`Provider`/`ChangeNotifier`, no third-party state framework.

- `main()` initialises `pdfrxInitialize()`, then `EntitlementService`,
  `BillingService`, `AdService` and `AppState` (in that order — the first three
  are dependencies of the last two).
- `AppShell` holds an `IndexedStack` behind a `NavigationBar`, so switching tabs
  preserves each screen's state. `PopScope` sends the back gesture to the Home
  tab before it can exit the app.
- Screens call into `core/` directly; they never own processing logic.

---

## PDF processing

`pdfium_engine.dart` wraps PDFium through `pdfrx`'s FFI bindings. PDFium is not
thread-safe and pdfrx only permits FFI access inside its worker isolate, so the
engine opens a document, performs the operation, and returns results across the
isolate boundary — there is no document handle shared with the UI.

`pdf_operations.dart` exposes five operations. Each one:

1. validates the input (real header/parse check, not a file extension test),
2. writes to a **new** file in `outputDirectory()`, never to the input,
3. re-opens the produced file and verifies it (page count, and page order for
   split/rotate),
4. returns the measured byte size, not an estimate.

### Targeted compression

`compress()` is a **search**, not a fixed setting:

1. Parse the document, read the current page count and dimensions.
2. Pick an initial DPI and JPEG quality from the requested target and the
   document's current density.
3. Render pages to images at that setting, rebuild the PDF, measure the real
   output size.
4. Adjust (binary-style step down/up) and repeat while the output is over the
   target and attempts remain — up to a hard cap.
5. Keep the result closest to but not exceeding the target; return the attempt
   log so the UI can show what was tried.

Measured reference run: 14,169,083 B → 4,727,107 B against a 4,959,179 B target
(33.4 %, dpi 195.57, q72, 3463 ms). Because it is raster-based, a compressed
document loses its selectable text layer; the UI says so and the original file
is left untouched.

---

## Upload readiness rules

`upload_rules.dart` holds the profiles (`email`, `job`, `gov_aadhaar`, `visa`,
`scholarship`) as data: a rule id, a human label, the constraints it checks, and
an `advisory` flag.

Aggregation is explicit rather than implicit:

```
severityRank:  notApplicable=0 < pass=1 < warning=2 < fail=3
worstStatus(iterable) -> highest-ranked member;
                         notApplicable only when every input is notApplicable
overallStatus(results) -> the same, over a whole report
```

A rule's own outcome is the worst of its checks. A failed check becomes `fail`
unless the rule is `advisory`, in which case it degrades to `warning` — that is
how "uniform page size" can warn without blocking. A document that fails
`requireUnencrypted` short-circuits to `fail` regardless of advisories.
`notApplicable` appears only when no applicable constraint was evaluated at all.

---

## Entitlements and billing

Two separate concerns, deliberately kept apart:

- `EntitlementService` — the local truth: is this user Premium, how many free
  operations are left. Exposes `isMock` / `isStoreVerified`.
- `BillingService` — talks to `in_app_purchase`, which resolves to Play Billing
  or the Amazon Appstore depending on the installed store. Product ids are
  per-store (`pdf_fit_premium_unlock` / `pdf_fit_premium_unlock_amazon`).

`BillingResult.isSuccess` is true only for a `purchased` state. A development
mock unlock requires `mockPurchasesAllowed` and is labelled as a mock everywhere
it surfaces — a test unlock can never masquerade as a paid one. There is no
server-side receipt validation; the store's own receipt state plus restore is the
source of truth.

---

## Ads

AdMob is initialised by `AdService` only when `AppConfig.adsSupported` is true
and the user is not Premium. Placements are a home-screen banner and an
interstitial after a successful multi-file operation.

The Play build ships Google's public **test** ids unless production ids are
injected at build time. The Amazon build removes the ads SDK's startup provider,
its application-id meta-data and all ad-tracking permissions from the merged
manifest, so a Fire OS device sees no ads and grants no ad permissions. The app
also sets `ads.initialization_delay=true`, so the SDK never auto-initialises.

---

## Storage

SQLite via `sqflite`, two tables: `history` (file name, input/output bytes, time,
operation, output path) and `presets` (name, settings, seeded defaults plus
user-created). History keeps real measured sizes so the UI can show before/after.
Trimming history deletes rows only — files the user saved or shared are already
outside the app's control and are never touched.

---

## Failure handling

Every operation returns a typed result or throws `PdfOperationException` with a
user-facing message. Screens show three states: in-progress (with real progress
where available), error (with the actual reason and a retry), and empty. There
is no optimistic success — a run is reported as succeeded only after the output
file has been re-opened and verified.
