# PDF Fit — Privacy Policy

**Last updated:** 25 October 2026
**App:** PDF Fit — Compress, Resize & Prepare (`com.pdffit.pdf_fit`)
**Contact:** support@pdffit.app

This policy must be published at a public URL and kept identical to the in-app
policy (`lib/ui/screens/privacy_screen.dart`).

---

## 1. Summary

**Your documents never leave your device.** PDF Fit opens, compresses, splits,
merges, rotates and converts files entirely on your phone using an embedded PDF
engine (PDFium). There is no document upload, no cloud service and no account.

## 2. What the app processes

- The PDF or image files **you explicitly select** through the system file picker.
- File metadata needed to show the result: page count, page size, file size,
  whether the document contains selectable text, annotations, or encryption.

Processing happens in the app's own memory and sandbox. The original file is
never modified; results are written as **new files** into the app's private
storage.

## 3. Data stored on your device

| Data | Purpose | Where |
|---|---|---|
| History entries (operation, file names, sizes, page counts, timestamps, output path) | So you can reopen or share results | Local SQLite database |
| Presets (name, target size, grayscale flag) | Re-apply your usual settings | Local SQLite database |
| Premium flag + product id | Remember an unlocked purchase | SharedPreferences |

You can delete history at any time (History → clear, or Settings → Clear
history). Uninstalling the app removes all of it.

## 4. Data we never collect

- Document contents or thumbnails
- Names, emails, phone numbers, contacts
- Precise location
- Analytics or crash reports tied to you (the app contains no analytics SDK)

## 5. Advertising (Basic plan only)

The **Amazon Appstore build shows no ads** and requests no INTERNET permission.

The **Google Play build** may show ads to users on the free (Basic) plan via
Google AdMob. AdMob may collect:

- Advertising ID and similar device identifiers
- IP address and coarse location derived from it
- Ad interaction data (impressions, clicks)

This is used by Google to serve and measure ads, as described in Google's
[Advertising Policies](https://policies.google.com/technologies/ads). PDF Fit
never passes document content, file names or file paths to the ads SDK.
**Premium users see no ads.** You can reset or delete your advertising ID in
Android Settings → Privacy → Ads.

## 6. Purchases

Purchases are handled by the store you installed from (Google Play or Amazon
Appstore). PDF Fit receives only the confirmation that a purchase succeeded and
the product id. Payment details are never available to the app.

## 7. Permissions and why they are needed

| Permission | Why |
|---|---|
| Storage / media read (via system picker) | To read the file you select |
| `INTERNET` (Play build only) | Required by Google Mobile Ads and Play Billing. Not used for documents. |
| `com.android.vending.BILLING` | Premium purchase |

## 8. Children

PDF Fit is a general-purpose utility not directed at children under 13. It does
not knowingly collect personal data from anyone, including children.

## 9. Data safety form answers (Google Play)

- Does your app collect or share any of the required user data types? **Yes — only
  for advertising (device or other IDs), and only in the free tier of the Play
  build.**
- Is all of the user data encrypted in transit? **Yes** (AdMob/billing use HTTPS).
- Can users request that their data be deleted? **Yes** — uninstalling removes all
  app data; history can be cleared in-app.
- Data types: **Device or other IDs** (advertising), collected by the AdMob SDK,
  used for advertising/marketing, not linked to identity.
- Files and docs: **not collected, not shared.**

If you ship the Amazon-only build as a separate listing, its answer is **"No data
collected"** because it contains no ads SDK and no network permission.

## 10. Changes

Material changes to this policy will be reflected in an app update and in the
"Last updated" date above.

## 11. Contact

support@pdffit.app
