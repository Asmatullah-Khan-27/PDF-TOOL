import 'dart:async';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import 'package:pdf_fit/core/config/app_config.dart';
import 'package:pdf_fit/core/entitlements/billing_service.dart';
import 'package:pdf_fit/core/entitlements/entitlement_service.dart';
import 'package:pdf_fit/ui/screens/privacy_screen.dart';
import 'package:pdf_fit/ui/widgets/common.dart';

/// Premium upgrade screen.
///
/// Pricing always comes from the store (`ProductDetails.price`); nothing is
/// hardcoded. When the store cannot be reached, the screen says so plainly and
/// never pretends a purchase succeeded.
class PremiumScreen extends StatefulWidget {
  const PremiumScreen({super.key});

  @override
  State<PremiumScreen> createState() => _PremiumScreenState();
}

class _PremiumScreenState extends State<PremiumScreen> {
  StreamSubscription<BillingResult>? _sub;
  bool _busy = false;
  String? _message;
  bool _messageIsError = false;

  @override
  void initState() {
    super.initState();
    final billing = context.read<BillingService>();
    _sub = billing.results.listen((result) {
      if (!mounted) return;
      setState(() {
        _busy = result.outcome == PurchaseOutcome.pending && false;
        _message = result.message;
        _messageIsError = !result.isSuccess && result.outcome != PurchaseOutcome.pending;
      });
    });
  }

  @override
  void dispose() {
    _sub?.cancel();
    super.dispose();
  }

  Future<void> _buy() async {
    setState(() {
      _busy = true;
      _message = null;
    });
    final result = await context.read<BillingService>().buyPremium();
    if (!mounted) return;
    setState(() {
      _busy = false;
      _message = result.message;
      _messageIsError = result.outcome == PurchaseOutcome.failed ||
          result.outcome == PurchaseOutcome.unavailable;
    });
  }

  Future<void> _restore() async {
    setState(() {
      _busy = true;
      _message = 'Checking the store for previous purchases…';
      _messageIsError = false;
    });
    await context.read<BillingService>().restore();
    if (!mounted) return;
    setState(() => _busy = false);
  }

  Future<void> _mockUnlock() async {
    try {
      await context.read<EntitlementService>().grantMock();
      if (!mounted) return;
      setState(() {
        _message = 'Development mock unlocked. This is NOT a real purchase.';
        _messageIsError = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _message = e.toString();
        _messageIsError = true;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final entitlements = context.watch<EntitlementService>();
    final billing = context.read<BillingService>();
    final scheme = Theme.of(context).colorScheme;
    final isPremium = entitlements.isPremium;

    return Scaffold(
      appBar: AppBar(title: const Text('PDF Fit Premium')),
      body: SafeArea(
        child: ListView(
          padding: const EdgeInsets.all(16),
          children: [
            Card(
              color: scheme.primaryContainer,
              child: Padding(
                padding: const EdgeInsets.all(18),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Icon(Icons.workspace_premium, color: scheme.onPrimaryContainer),
                        const SizedBox(width: 8),
                        Expanded(
                          child: Text(
                            isPremium ? 'Premium is active' : 'Everything, unlocked',
                            style: TextStyle(
                              fontSize: 18,
                              fontWeight: FontWeight.w800,
                              color: scheme.onPrimaryContainer,
                            ),
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 8),
                    Text(
                      isPremium
                          ? 'Thank you for supporting PDF Fit. Ads are off and all limits are removed.'
                          : 'One purchase, no subscription. Yours on this store account.',
                      style: TextStyle(fontSize: 13, color: scheme.onPrimaryContainer),
                    ),
                    if (entitlements.state.isMock) ...[
                      const SizedBox(height: 10),
                      Container(
                        padding: const EdgeInsets.all(10),
                        decoration: BoxDecoration(
                          color: scheme.errorContainer,
                          borderRadius: BorderRadius.circular(10),
                        ),
                        child: Row(
                          children: [
                            Icon(Icons.science_outlined, color: scheme.onErrorContainer, size: 18),
                            const SizedBox(width: 8),
                            Expanded(
                              child: Text(
                                'Development mock entitlement — not a real purchase. '
                                'This unlock disappears in release builds.',
                                style: TextStyle(fontSize: 11.5, color: scheme.onErrorContainer),
                              ),
                            ),
                          ],
                        ),
                      ),
                    ],
                  ],
                ),
              ),
            ),
            const SectionHeader(title: 'What you get'),
            for (final feature in const [
              ('Custom target sizes', 'Compress to any size, from 20 KB upwards'),
              ('Unlimited compression', 'No monthly cap'),
              ('Merge without limits', 'Combine any number of documents'),
              ('Page-range splitting', 'Extract exact pages: 1-3, 7, 9-'),
              ('Unlimited images per PDF', 'Basic is capped at 5'),
              ('Unlimited presets', 'Basic keeps 1 custom preset'),
              ('No ads', 'Clean, quiet interface'),
              ('Full history', 'Basic keeps the last 25 entries'),
            ])
              Padding(
                padding: const EdgeInsets.only(bottom: 10),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Icon(Icons.check_circle, size: 18, color: scheme.primary),
                    const SizedBox(width: 10),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(feature.$1,
                              style: const TextStyle(fontWeight: FontWeight.w600, fontSize: 13.5)),
                          Text(feature.$2,
                              style: TextStyle(fontSize: 12, color: scheme.onSurfaceVariant)),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
            const SizedBox(height: 8),
            if (_message != null)
              Padding(
                padding: const EdgeInsets.only(bottom: 12),
                child: Text(
                  _message!,
                  style: TextStyle(
                    color: _messageIsError ? scheme.error : scheme.onSurfaceVariant,
                    fontSize: 12.5,
                  ),
                ),
              ),
            if (!isPremium) ...[
              FilledButton.icon(
                onPressed: _busy ? null : _buy,
                icon: _busy
                    ? const SizedBox(
                        width: 18,
                        height: 18,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : const Icon(Icons.lock_open),
                label: Text(
                  billing.availability == BillingAvailability.available
                      ? 'Unlock for ${billing.priceLabel}'
                      : 'Unlock Premium',
                ),
              ),
              const SizedBox(height: 8),
              OutlinedButton.icon(
                onPressed: _busy ? null : _restore,
                icon: const Icon(Icons.restore),
                label: const Text('Restore purchase'),
              ),
              const SizedBox(height: 10),
              if (billing.availability != BillingAvailability.available)
                Card(
                  child: Padding(
                    padding: const EdgeInsets.all(12),
                    child: Text(
                      'The store is not reachable from this build. Purchases require '
                      'the app to be installed from ${AppConfig.storeLabel} with the '
                      'product "${BillingProducts.premiumId}" configured. See '
                      'docs/STORE_SETUP.md.',
                      style: TextStyle(fontSize: 11.5, color: scheme.onSurfaceVariant),
                    ),
                  ),
                ),
              if (EntitlementService.mockPurchasesAllowed) ...[
                const SizedBox(height: 10),
                TextButton.icon(
                  onPressed: _mockUnlock,
                  icon: const Icon(Icons.science_outlined, size: 18),
                  label: const Text('Development: simulate unlock'),
                ),
              ],
            ],
            const SizedBox(height: 16),
            TextButton(
              onPressed: () => Navigator.of(context).push(
                MaterialPageRoute(builder: (_) => const PrivacyScreen()),
              ),
              child: const Text('Privacy policy'),
            ),
            Text(
              'Payment is handled entirely by ${AppConfig.storeLabel}. PDF Fit never '
              'sees your payment details.',
              textAlign: TextAlign.center,
              style: TextStyle(fontSize: 11, color: scheme.onSurfaceVariant),
            ),
          ],
        ),
      ),
    );
  }
}
