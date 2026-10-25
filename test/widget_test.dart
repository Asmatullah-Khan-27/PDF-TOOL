import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';

import 'package:pdf_fit/core/ads/ad_service.dart';
import 'package:pdf_fit/core/entitlements/billing_service.dart';
import 'package:pdf_fit/core/entitlements/entitlement_service.dart';
import 'package:pdf_fit/core/files/file_service.dart';
import 'package:pdf_fit/core/state/app_state.dart';
import 'package:pdf_fit/ui/screens/privacy_screen.dart';
import 'package:pdf_fit/ui/theme/app_theme.dart';
import 'package:pdf_fit/ui/widgets/banner_ad_slot.dart';
import 'package:pdf_fit/ui/widgets/common.dart';

/// Widget tests for the real UI components.
///
/// These render actual widgets (not mocks of them) and assert on visible text
/// and behaviour. Store/network-backed services are not exercised here; they are
/// covered by the platform integrations and documented as device-only checks.
void main() {
  Widget wrap(Widget child) => MaterialApp(
        theme: AppTheme.light(),
        home: Scaffold(body: child),
      );

  group('shared widgets', () {
    testWidgets('ToolCard renders title, subtitle and reacts to taps', (tester) async {
      var tapped = 0;
      await tester.pumpWidget(wrap(ToolCard(
        title: 'Merge PDFs',
        subtitle: 'Combine documents',
        icon: Icons.merge_type,
        onTap: () => tapped++,
      )));

      expect(find.text('Merge PDFs'), findsOneWidget);
      expect(find.text('Combine documents'), findsOneWidget);
      await tester.tap(find.text('Merge PDFs'));
      expect(tapped, 1);
    });

    testWidgets('disabled ToolCard ignores taps', (tester) async {
      var tapped = 0;
      await tester.pumpWidget(wrap(ToolCard(
        title: 'Locked',
        subtitle: 'Premium only',
        icon: Icons.lock,
        enabled: false,
        onTap: () => tapped++,
      )));
      await tester.tap(find.text('Locked'));
      expect(tapped, 0);
    });

    testWidgets('ErrorCard shows the message and a retry action', (tester) async {
      var retried = 0;
      await tester.pumpWidget(wrap(ErrorCard(
        message: 'The file is not a valid PDF.',
        onRetry: () => retried++,
      )));
      expect(find.text('The file is not a valid PDF.'), findsOneWidget);
      await tester.tap(find.text('Try again'));
      expect(retried, 1);
    });

    testWidgets('EmptyState renders its guidance', (tester) async {
      await tester.pumpWidget(wrap(const EmptyState(
        icon: Icons.history,
        title: 'Nothing here yet',
        message: 'Documents you compress appear here.',
      )));
      expect(find.text('Nothing here yet'), findsOneWidget);
      expect(find.text('Documents you compress appear here.'), findsOneWidget);
    });

    testWidgets('InfoRow shows label and value', (tester) async {
      await tester.pumpWidget(wrap(const InfoRow(label: 'Original', value: '14.17 MB')));
      expect(find.text('Original'), findsOneWidget);
      expect(find.text('14.17 MB'), findsOneWidget);
    });
  });

  group('banner ad slot', () {
    testWidgets('renders nothing when ads are disabled', (tester) async {
      // Ads are gated on the entitlement service; with no Premium unlock and no
      // initialised AdMob SDK the slot must collapse to zero height.
      final entitlements = EntitlementService(store: MemoryEntitlementStore());
      await entitlements.load();
      final ads = AdService(entitlements);
      expect(ads.sdkReady, isFalse);
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Provider<AdService>.value(value: ads, child: const BannerAdSlot()),
          ),
        ),
      );
      expect(tester.getSize(find.byType(BannerAdSlot)).height, 0);
    });

    testWidgets('takes up no space when the SDK is not ready', (tester) async {
      final entitlements = EntitlementService(store: MemoryEntitlementStore());
      final ads = AdService(entitlements);
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Provider<AdService>.value(
              value: ads,
              child: const BannerAdSlot(),
            ),
          ),
        ),
      );
      // No AdWidget, no placeholder text: the layout must not contain a blank box.
      expect(find.textContaining('Ad unavailable'), findsNothing);
      expect(tester.getSize(find.byType(BannerAdSlot)).height, 0);
    });
  });

  group('privacy screen', () {
    testWidgets('states that documents never leave the device', (tester) async {
      await tester.pumpWidget(MaterialApp(
        theme: AppTheme.light(),
        home: const PrivacyScreen(),
      ));
      expect(
        find.textContaining('never uploaded'),
        findsWidgets,
      );
    });
  });

  group('quota state used by the home screen', () {
    test('reports remaining compressions and exhaustion accurately', () {
      const fresh = QuotaState(used: 0, limit: 20, isPremium: false);
      expect(fresh.remaining, 20);
      expect(fresh.exhausted, isFalse);
      expect(fresh.label, '20 of 20 left');

      const spent = QuotaState(used: 20, limit: 20, isPremium: false);
      expect(spent.remaining, 0);
      expect(spent.exhausted, isTrue);

      const premium = QuotaState(used: 500, limit: -1, isPremium: true);
      expect(premium.remaining, -1);
      expect(premium.exhausted, isFalse);
      expect(premium.label, 'Unlimited');
    });
  });

  group('billing result semantics', () {
    test('only a purchased outcome counts as success', () {
      expect(
        const BillingResult(PurchaseOutcome.purchased, 'ok').isSuccess,
        isTrue,
      );
      for (final outcome in [
        PurchaseOutcome.pending,
        PurchaseOutcome.failed,
        PurchaseOutcome.unavailable,
        PurchaseOutcome.unverified,
      ]) {
        expect(BillingResult(outcome, 'x').isSuccess, isFalse, reason: outcome.name);
      }
    });
  });

  group('file naming', () {
    test('sanitizes unsafe characters and keeps names usable', () {
      expect(sanitizeFileName('My Report: 2026/final?.pdf'), 'My Report_ 2026_final_');
      expect(sanitizeFileName('   '), 'document');
      expect(sanitizeFileName('a' * 200).length, 80);
    });
  });
}
