import 'package:flutter_test/flutter_test.dart';
import 'package:pdf_fit/core/entitlements/entitlement_service.dart';
import 'package:pdf_fit/core/pdf/pdf_operations.dart';
import 'package:pdf_fit/core/pdf/upload_rules.dart';

void main() {
  group('Entitlement gates', () {
    late EntitlementService service;

    setUp(() async {
      service = EntitlementService(store: MemoryEntitlementStore());
      await service.load();
    });

    test('starts on the Basic plan with free-plan limits', () {
      expect(service.isPremium, isFalse);
      expect(service.planLabel, 'Basic');
      expect(service.mergeFileLimit, 2);
      expect(service.imagesPerDocument, 5);
      expect(service.customPresetLimit, 1);
      expect(service.monthlyCompressionLimit, 20);
      expect(service.historyLimit, 25);
    });

    test('free plan only allows the listed target sizes', () {
      expect(service.allowsTargetSize(null), isTrue, reason: 'best effort is free');
      expect(service.allowsTargetSize(100 * 1024), isTrue);
      expect(service.allowsTargetSize(500 * 1024), isTrue);
      expect(service.allowsTargetSize(2 * 1024 * 1024), isTrue);
      expect(service.allowsTargetSize(5 * 1024 * 1024), isFalse);
      expect(service.allowsTargetSize(750 * 1024), isFalse);
    });

    test('store-verified grant removes all limits', () async {
      await service.grantFromStore(productId: 'pdf_fit_premium_unlock');
      expect(service.isPremium, isTrue);
      expect(service.state.isStoreVerified, isTrue);
      expect(service.state.isMock, isFalse);
      expect(service.mergeFileLimit, greaterThan(2));
      expect(service.monthlyCompressionLimit, -1);
      expect(service.allowsTargetSize(750 * 1024), isTrue);
      expect(service.adsEnabled, isFalse, reason: 'Premium users see no ads');
      expect(service.planLabel, 'Premium');
    });

    test('revoke returns to Basic', () async {
      await service.grantFromStore(productId: 'pdf_fit_premium_unlock');
      await service.revoke();
      expect(service.isPremium, isFalse);
      expect(service.planLabel, 'Basic');
    });

    test('mock unlock is refused unless explicitly enabled at compile time', () async {
      // This test binary is not built with PDFFIT_ALLOW_MOCK_PURCHASE, so the
      // service must refuse to fabricate an entitlement.
      expect(EntitlementService.mockPurchasesAllowed, isFalse);
      expect(() => service.grantMock(), throwsA(isA<StateError>()));
      expect(service.isPremium, isFalse);
    });

    test('a stored mock grant is ignored when mocks are not allowed', () async {
      final store = MemoryEntitlementStore();
      await store.write(source: 'mock', productId: 'dev.mock.premium');
      final service2 = EntitlementService(store: store);
      await service2.load();
      expect(service2.isPremium, isFalse,
          reason: 'debug-only grants must never leak into a normal build');
    });

    test('a stored store grant survives a restart', () async {
      final store = MemoryEntitlementStore();
      await EntitlementService(store: store).grantFromStore(productId: 'pdf_fit_premium_unlock');
      final service2 = EntitlementService(store: store);
      await service2.load();
      expect(service2.isPremium, isTrue);
      expect(service2.state.isStoreVerified, isTrue);
    });
  });

  group('Upload readiness rules', () {
    PdfInspection make({
      int pageCount = 3,
      int byteSize = 1024 * 1024,
      bool encrypted = false,
      bool hasText = true,
      int textChars = 500,
      double width = 595.28,
      double height = 841.89,
      bool annotations = false,
      bool mixed = false,
    }) =>
        PdfInspection(
          pageCount: pageCount,
          byteSize: byteSize,
          isEncrypted: encrypted,
          hasExtractableText: hasText,
          textCharacterCount: textChars,
          pageWidthPt: width,
          pageHeightPt: height,
          hasAnnotations: annotations,
          title: null,
          isLandscape: width > height,
          mixedPageSizes: mixed,
          imagesOnly: !hasText,
        );

    test('a compliant A4 text PDF passes the government profile', () {
      final results = evaluateUploadReadiness(
        UploadProfiles.byId('gov_aadhaar')!,
        make(),
      );
      expect(results.where((r) => r.isBlocking), isEmpty);
      expect(results.every((r) => r.status == RuleStatus.pass), isTrue);
      expect(overallStatus(results), RuleStatus.pass);
    });

    test('oversized file fails with the measured difference', () {
      final results = evaluateUploadReadiness(
        UploadProfiles.byId('gov_aadhaar')!,
        make(byteSize: 3 * 1024 * 1024),
      );
      final sizeResult = results.firstWhere((r) => r.rule.id == 'size');
      expect(sizeResult.status, RuleStatus.fail);
      expect(sizeResult.message, contains('exceeds'));
      expect(sizeResult.message, contains('MB'));
    });

    test('landscape pages fail the portrait rule', () {
      final results = evaluateUploadReadiness(
        UploadProfiles.byId('gov_aadhaar')!,
        make(width: 841.89, height: 595.28),
      );
      final orientation = results.firstWhere((r) => r.rule.id == 'orientation');
      expect(orientation.status, RuleStatus.fail);
    });

    test('non-A4 page size fails the A4 rule', () {
      final results = evaluateUploadReadiness(
        UploadProfiles.byId('gov_aadhaar')!,
        make(width: 612, height: 792), // US Letter
      );
      final size = results.firstWhere((r) => r.rule.id == 'size');
      expect(size.status, RuleStatus.fail);
      expect(size.message.toLowerCase(), contains('not accepted'));
    });

    test('mixed page sizes are flagged as an advisory warning', () {
      // "Uniform page size" is advisory: portals may reject mixed sizes, but it
      // is not a published hard requirement, so it must not block an upload.
      final results = evaluateUploadReadiness(
        UploadProfiles.byId('gov_aadhaar')!,
        make(mixed: true),
      );
      final uniform = results.firstWhere((r) => r.rule.id == 'uniform');
      expect(uniform.status, RuleStatus.warning);
      expect(uniform.isBlocking, isFalse);
    });

    test('scanned PDF fails a profile that requires a text layer', () {
      final results = evaluateUploadReadiness(
        UploadProfiles.byId('visa')!,
        make(hasText: false, textChars: 0, pageCount: 1),
      );
      final textRule = results.firstWhere((r) => r.rule.id == 'size');
      expect(textRule.status, RuleStatus.fail);
      expect(textRule.message, contains('no selectable text'));
    });

    test('password protection blocks every profile that requires it', () {
      final results = evaluateUploadReadiness(
        UploadProfiles.byId('email')!,
        make(encrypted: true),
      );
      expect(results.first.isBlocking, isTrue);
      expect(results.first.message, contains('password'));
    });

    test('too many pages fails with the page count', () {
      final results = evaluateUploadReadiness(
        UploadProfiles.byId('visa')!,
        make(pageCount: 4),
      );
      final rule = results.first;
      expect(rule.status, RuleStatus.fail);
      expect(rule.message, contains('4 pages'));
    });

    test('a profile reports the strictest size limit for suggestions', () {
      expect(UploadProfiles.byId('gov_aadhaar')!.maxBytes, 2 * 1024 * 1024);
      expect(UploadProfiles.byId('email')!.maxBytes, 25 * 1024 * 1024);
    });
  });
}
