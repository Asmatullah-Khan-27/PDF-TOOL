import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import 'package:pdf_fit/core/ads/ad_service.dart';
import 'package:pdf_fit/core/config/app_config.dart';
import 'package:pdf_fit/core/entitlements/billing_service.dart';
import 'package:pdf_fit/core/entitlements/entitlement_service.dart';
import 'package:pdf_fit/core/files/file_service.dart';
import 'package:pdf_fit/core/state/app_state.dart';
import 'package:pdf_fit/ui/screens/premium_screen.dart';
import 'package:pdf_fit/ui/screens/privacy_screen.dart';
import 'package:pdf_fit/ui/widgets/common.dart';

class SettingsScreen extends StatelessWidget {
  const SettingsScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final app = context.watch<AppState>();
    final entitlements = context.watch<EntitlementService>();
    final ads = context.read<AdService>();
    final billing = context.read<BillingService>();
    final scheme = Theme.of(context).colorScheme;

    return Scaffold(
      appBar: AppBar(title: const Text('Settings')),
      body: SafeArea(
        child: ListView(
          padding: const EdgeInsets.all(16),
          children: [
            Card(
              child: ListTile(
                leading: CircleAvatar(
                  backgroundColor: scheme.primaryContainer,
                  child: Icon(Icons.person_outline, color: scheme.onPrimaryContainer),
                ),
                title: Text(
                  entitlements.planLabel,
                  style: const TextStyle(fontWeight: FontWeight.w700),
                ),
                subtitle: Text(
                  entitlements.state.isStoreVerified
                      ? 'Verified purchase · ${entitlements.state.productId ?? ""}'
                      : entitlements.isPremium
                          ? 'Development unlock (not a real purchase)'
                          : 'Basic plan · ${app.quota.label}',
                ),
                trailing: entitlements.isPremium
                    ? null
                    : FilledButton.tonal(
                        onPressed: () => Navigator.of(context).push(
                          MaterialPageRoute(builder: (_) => const PremiumScreen()),
                        ),
                        child: const Text('Upgrade'),
                      ),
              ),
            ),
            const SectionHeader(title: 'This month'),
            Card(
              child: Padding(
                padding: const EdgeInsets.all(14),
                child: Column(
                  children: [
                    InfoRow(label: 'Compressions used', value: '${app.quota.used}'),
                    InfoRow(
                      label: 'Limit',
                      value: app.quota.limit < 0 ? 'Unlimited (Premium)' : '${app.quota.limit}',
                    ),
                    InfoRow(label: 'Documents in history', value: '${app.history.length}'),
                    const SizedBox(height: 8),
                    LinearProgressIndicator(
                      value: app.quota.limit < 0
                          ? 0
                          : (app.quota.used / app.quota.limit).clamp(0.0, 1.0),
                    ),
                  ],
                ),
              ),
            ),
            const SectionHeader(title: 'Storage'),
            Card(
              child: Column(
                children: [
                  ListTile(
                    leading: const Icon(Icons.folder_outlined),
                    title: const Text('Saved documents'),
                    subtitle: const Text('Results are kept in app storage'),
                    trailing: const Icon(Icons.chevron_right),
                    onTap: () => _showStorageInfo(context),
                  ),
                  const Divider(height: 1),
                  ListTile(
                    leading: const Icon(Icons.delete_sweep_outlined),
                    title: const Text('Clear history'),
                    subtitle: Text(
                      app.isPremium
                          ? 'Remove all history entries'
                          : 'Basic keeps the last ${entitlements.historyLimit} entries',
                    ),
                    onTap: () => _confirmClearHistory(context, app),
                  ),
                ],
              ),
            ),
            const SectionHeader(title: 'About'),
            Card(
              child: Column(
                children: [
                  ListTile(
                    leading: const Icon(Icons.privacy_tip_outlined),
                    title: const Text('Privacy policy'),
                    trailing: const Icon(Icons.chevron_right),
                    onTap: () => Navigator.of(context).push(
                      MaterialPageRoute(builder: (_) => const PrivacyScreen()),
                    ),
                  ),
                  const Divider(height: 1),
                  ListTile(
                    leading: const Icon(Icons.restore),
                    title: const Text('Restore purchases'),
                    subtitle: Text('Use after reinstalling from ${AppConfig.storeLabel}'),
                    onTap: () async {
                      await billing.restore();
                      if (!context.mounted) return;
                      ScaffoldMessenger.of(context).showSnackBar(
                        const SnackBar(content: Text('Asked the store for previous purchases.')),
                      );
                    },
                  ),
                  const Divider(height: 1),
                  ListTile(
                    leading: const Icon(Icons.info_outline),
                    title: const Text('Version'),
                    subtitle: Text(
                      '${AppConfig.version} · ${AppConfig.storeLabel} build',
                    ),
                  ),
                ],
              ),
            ),
            const SectionHeader(title: 'Diagnostics'),
            Card(
              child: Padding(
                padding: const EdgeInsets.all(14),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    InfoRow(
                      label: 'Ads',
                      value: !AppConfig.adsSupported
                          ? 'Disabled for this store'
                          : entitlements.isPremium
                              ? 'Off (Premium)'
                              : ads.sdkReady
                                  ? 'Active'
                                  : 'SDK not ready',
                    ),
                    InfoRow(
                      label: 'Ad unit',
                      value: AppConfig.hasProductionAds ? 'Production' : 'Google test ads',
                    ),
                    if (ads.lastError != null)
                      InfoRow(label: 'Ad error', value: ads.lastError!),
                    InfoRow(
                      label: 'Billing',
                      value: switch (billing.availability) {
                        BillingAvailability.available => 'Store connected',
                        BillingAvailability.unavailable => 'Store unavailable',
                        BillingAvailability.unknown => 'Checking…',
                      },
                    ),
                    InfoRow(
                      label: 'Online processing',
                      value: 'None — everything runs on this device',
                    ),
                  ],
                ),
              ),
            ),
            const SizedBox(height: 20),
            Center(
              child: Text(
                'PDF Fit — ${AppConfig.tagline}',
                style: TextStyle(fontSize: 11.5, color: scheme.onSurfaceVariant),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _showStorageInfo(BuildContext context) async {
    final dir = await context.read<FileService>().outputDirectory();
    if (!context.mounted) return;
    showDialog<void>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Saved documents'),
        content: SelectableText(
          'Output files are stored in this app\'s private documents folder:\n\n$dir',
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context), child: const Text('Close')),
        ],
      ),
    );
  }

  Future<void> _confirmClearHistory(BuildContext context, AppState app) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Clear history?'),
        content: const Text('History entries are removed. Files you shared are not deleted.'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('Cancel')),
          FilledButton(onPressed: () => Navigator.pop(context, true), child: const Text('Clear')),
        ],
      ),
    );
    if (ok ?? false) await app.clearHistory();
  }
}
