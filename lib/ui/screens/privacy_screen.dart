import 'package:flutter/material.dart';

import 'package:pdf_fit/core/config/app_config.dart';

/// In-app privacy policy. Must stay in sync with docs/PRIVACY_POLICY.md and the
/// Play Console data-safety form.
class PrivacyScreen extends StatelessWidget {
  const PrivacyScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    Widget section(String title, String body) => Padding(
          padding: const EdgeInsets.only(bottom: 16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(title,
                  style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 14.5)),
              const SizedBox(height: 4),
              Text(body, style: const TextStyle(fontSize: 13, height: 1.5)),
            ],
          ),
        );

    return Scaffold(
      appBar: AppBar(title: const Text('Privacy')),
      body: SafeArea(
        child: ListView(
          padding: const EdgeInsets.all(16),
          children: [
            Card(
              color: scheme.secondaryContainer,
              child: Padding(
                padding: const EdgeInsets.all(14),
                child: Row(
                  children: [
                    Icon(Icons.shield_outlined, color: scheme.onSecondaryContainer),
                    const SizedBox(width: 10),
                    Expanded(
                      child: Text(
                        'Your documents are processed entirely on your device and are '
                        'never uploaded.',
                        style: TextStyle(
                          fontSize: 13,
                          fontWeight: FontWeight.w600,
                          color: scheme.onSecondaryContainer,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
            const SizedBox(height: 16),
            section(
              'What we process',
              'PDF Fit opens the PDF you choose, reads its structure, and writes a new '
              'file into this app\'s private storage. The original file is never '
              'modified.',
            ),
            section(
              'What leaves your device',
              'Nothing from your documents. Files leave the app only when you tap '
              'Share or Open, which hands the file to another app you choose. The app '
              'has no network permission for document content and no upload code.',
            ),
            section(
              'Advertising',
              AppConfig.store == StoreFlavor.amazon
                  ? 'The Amazon build shows no ads. Google AdMob is not used because '
                      'Fire OS devices typically ship without Google Play services.'
                  : 'The free (Basic) plan shows ads through Google AdMob. AdMob may '
                      'collect device identifiers and approximate location to serve ads, '
                      'as described in Google\'s advertising policies. Premium users see '
                      'no ads. Documents are never shared with the ad SDK.',
            ),
            section(
              'Purchases',
              'Secure in-app purchases are handled by ${AppConfig.storeLabel}. PDF Fit '
              'stores only a flag indicating that Premium is active, plus the product '
              'id, in this app\'s private storage. No payment details ever reach the '
              'app.',
            ),
            section(
              'Data stored on your device',
              'History entries (file names, sizes, page counts, timestamps), your saved '
              'presets, and a Premium flag. You can clear history at any time from the '
              'History tab; uninstalling the app removes everything.',
            ),
            section(
              'Permissions',
              'Storage access only when you pick files, so the app can read the document '
              'you selected and save results. The Amazon build declares no internet '
              'permission for documents.',
            ),
            section(
              'Children',
              'PDF Fit is a general-purpose document utility and is not directed at '
              'children under 13.',
            ),
            section(
              'Contact',
              'Questions about privacy: ${AppConfig.supportEmail}',
            ),
            Text(
              'Version ${AppConfig.version} · Store: ${AppConfig.storeLabel}',
              style: TextStyle(fontSize: 11, color: scheme.onSurfaceVariant),
            ),
          ],
        ),
      ),
    );
  }
}
