import 'package:flutter_test/flutter_test.dart';
import 'package:pdf_fit/core/pdf/pdf_operations.dart';
import 'package:pdf_fit/core/pdf/upload_rules.dart';

/// Regression tests for the upload-readiness rule engine.
///
/// These lock in the explicit severity ranking (pass < warning < fail, with
/// notApplicable meaning "nothing evaluated"), because the original
/// implementation compared raw enum indices and therefore reported warnings
/// where it should have reported passes and failures.
void main() {
  PdfInspection pdf({
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

  /// A rule with no constraints at all: nothing can be evaluated.
  const inertRule = UploadRule(id: 'inert', label: 'Nothing to check');

  const sizeRule = UploadRule(id: 'size', label: 'File size', maxBytes: 1000);
  const pageRule = UploadRule(id: 'pages', label: 'Page count', maxPages: 2);
  const advisoryRule = UploadRule(
    id: 'uniform',
    label: 'Uniform page size',
    requireSinglePageSize: true,
    advisory: true,
  );

  group('severityRank ordering', () {
    test('orders notApplicable < pass < warning < fail', () {
      expect(severityRank(RuleStatus.notApplicable), 0);
      expect(
        severityRank(RuleStatus.notApplicable),
        lessThan(severityRank(RuleStatus.pass)),
      );
      expect(severityRank(RuleStatus.pass), lessThan(severityRank(RuleStatus.warning)));
      expect(severityRank(RuleStatus.warning), lessThan(severityRank(RuleStatus.fail)));
    });

    test('worstStatus picks the most severe outcome', () {
      expect(
        worstStatus([RuleStatus.pass, RuleStatus.warning, RuleStatus.pass]),
        RuleStatus.warning,
      );
      expect(
        worstStatus([RuleStatus.pass, RuleStatus.fail, RuleStatus.warning]),
        RuleStatus.fail,
      );
      expect(worstStatus([RuleStatus.pass]), RuleStatus.pass);
    });

    test('worstStatus returns notApplicable only when nothing was evaluated', () {
      expect(worstStatus(const []), RuleStatus.notApplicable);
      expect(
        worstStatus(const [RuleStatus.notApplicable, RuleStatus.notApplicable]),
        RuleStatus.notApplicable,
      );
      // A single real result outranks notApplicable.
      expect(
        worstStatus(const [RuleStatus.notApplicable, RuleStatus.pass]),
        RuleStatus.pass,
      );
    });
  });

  group('passing documents', () {
    test('compliant A4 text PDF passes every gov_aadhaar rule', () {
      final results = evaluateUploadReadiness(
        UploadProfiles.byId('gov_aadhaar')!,
        pdf(),
      );
      expect(results, isNotEmpty);
      expect(results.any((r) => r.isBlocking), isFalse);
      expect(overallStatus(results), RuleStatus.pass);
      expect(
        results.every((r) => r.status == RuleStatus.pass),
        isTrue,
        reason: 'no rule should report a warning for a fully valid document',
      );
      // Rule ids and profile behaviour must not change.
      expect(
        results.map((r) => r.rule.id).toList(),
        containsAll(<String>['size', 'orientation', 'uniform']),
      );
    });

    test('small single-page email attachment passes', () {
      final results = evaluateUploadReadiness(
        UploadProfiles.byId('email')!,
        pdf(pageCount: 2, byteSize: 500 * 1024),
      );
      expect(overallStatus(results), RuleStatus.pass);
    });
  });

  group('failing documents', () {
    test('oversized file fails with the measured difference', () {
      final results = evaluateUploadReadiness(
        UploadProfiles.byId('gov_aadhaar')!,
        pdf(byteSize: 3 * 1024 * 1024),
      );
      final size = results.firstWhere((r) => r.rule.id == 'size');
      expect(size.status, RuleStatus.fail);
      expect(size.isBlocking, isTrue);
      expect(size.message, contains('exceeds'));
      expect(overallStatus(results), RuleStatus.fail);
    });

    test('a failing single-constraint rule reports fail, never warning', () {
      final result = evaluateUploadReadiness(
        const UploadProfile(id: 'x', name: 'x', description: 'x', rules: [sizeRule]),
        pdf(byteSize: 5000),
      ).single;
      expect(result.status, RuleStatus.fail);
    });

    test('too many pages fails with the page count', () {
      final results = evaluateUploadReadiness(
        const UploadProfile(id: 'x', name: 'x', description: 'x', rules: [pageRule]),
        pdf(pageCount: 9),
      );
      expect(results.single.status, RuleStatus.fail);
      expect(results.single.message, contains('9 pages'));
    });

    test('landscape pages fail the gov_aadhaar orientation rule', () {
      final results = evaluateUploadReadiness(
        UploadProfiles.byId('gov_aadhaar')!,
        pdf(width: 841.89, height: 595.28),
      );
      final orientation = results.firstWhere((r) => r.rule.id == 'orientation');
      expect(orientation.status, RuleStatus.fail);
    });

    test('password-protected files block the upload outright', () {
      final results = evaluateUploadReadiness(
        UploadProfiles.byId('email')!,
        pdf(encrypted: true),
      );
      expect(results.single.status, RuleStatus.fail);
      expect(results.single.message.toLowerCase(), contains('password'));
    });
  });

  group('warning conditions', () {
    test('an advisory rule failure is a warning, not a blocker', () {
      final result = evaluateUploadReadiness(
        const UploadProfile(id: 'x', name: 'x', description: 'x', rules: [advisoryRule]),
        pdf(mixed: true),
      ).single;
      expect(result.status, RuleStatus.warning);
      expect(result.isBlocking, isFalse);
    });

    test('mixed page sizes warn under gov_aadhaar but do not block', () {
      final results = evaluateUploadReadiness(
        UploadProfiles.byId('gov_aadhaar')!,
        pdf(mixed: true),
      );
      final uniform = results.firstWhere((r) => r.rule.id == 'uniform');
      expect(uniform.status, RuleStatus.warning);
      expect(uniform.rule.advisory, isTrue);
      // Everything else still passes, so the document is usable.
      expect(results.where((r) => r.isBlocking), isEmpty);
      expect(overallStatus(results), RuleStatus.warning);
    });
  });

  group('rules that do not apply', () {
    test('a rule with no constraints is notApplicable, not a pass', () {
      final result = evaluateUploadReadiness(
        const UploadProfile(id: 'x', name: 'x', description: 'x', rules: [inertRule]),
        pdf(),
      ).single;
      expect(result.status, RuleStatus.notApplicable);
      expect(result.isBlocking, isFalse);
    });

    test('a profile made only of inert rules aggregates to notApplicable', () {
      final results = evaluateUploadReadiness(
        const UploadProfile(id: 'x', name: 'x', description: 'x', rules: [inertRule, inertRule]),
        pdf(),
      );
      expect(results.every((r) => r.status == RuleStatus.notApplicable), isTrue);
      expect(overallStatus(results), RuleStatus.notApplicable);
    });

    test('an empty profile aggregates to notApplicable', () {
      final results = evaluateUploadReadiness(
        const UploadProfile(id: 'x', name: 'x', description: 'x', rules: []),
        pdf(),
      );
      expect(results, isEmpty);
      expect(overallStatus(results), RuleStatus.notApplicable);
    });

    test('notApplicable never masks a real result', () {
      final results = evaluateUploadReadiness(
        const UploadProfile(id: 'x', name: 'x', description: 'x', rules: [inertRule, sizeRule]),
        pdf(byteSize: 10),
      );
      expect(results.first.status, RuleStatus.notApplicable);
      expect(results.last.status, RuleStatus.pass);
      expect(overallStatus(results), RuleStatus.pass);
    });
  });

  group('mixed outcomes', () {
    test('worst rule decides the overall verdict across several rules', () {
      final results = evaluateUploadReadiness(
        const UploadProfile(
          id: 'x',
          name: 'x',
          description: 'x',
          rules: [sizeRule, pageRule, advisoryRule],
        ),
        pdf(byteSize: 10, pageCount: 5, mixed: true),
      );
      expect(results[0].status, RuleStatus.pass); // size fine
      expect(results[1].status, RuleStatus.fail); // too many pages
      expect(results[2].status, RuleStatus.warning); // advisory
      expect(overallStatus(results), RuleStatus.fail);
    });

    test('a rule that checks several constraints reports all of them', () {
      // gov_aadhaar's `size` rule also enforces the accepted page size, so one
      // failing rule carries both messages. That is intentional: the rule is the
      // unit the UI lists, and the user must see every reason it failed.
      final results = evaluateUploadReadiness(
        UploadProfiles.byId('gov_aadhaar')!,
        pdf(byteSize: 9 * 1024 * 1024, width: 612, height: 792),
      );
      final sizeResult = results.firstWhere((r) => r.rule.id == 'size');
      expect(sizeResult.status, RuleStatus.fail);
      expect(sizeResult.message, contains('exceeds'));
      expect(sizeResult.message, contains('not accepted'));
      expect(results.firstWhere((r) => r.rule.id == 'orientation').status, RuleStatus.pass);
      expect(overallStatus(results), RuleStatus.fail);
    });

    test('two separate failing rules are both reported as blockers', () {
      final results = evaluateUploadReadiness(
        const UploadProfile(
          id: 'x',
          name: 'x',
          description: 'x',
          rules: [sizeRule, pageRule],
        ),
        pdf(byteSize: 5000, pageCount: 9),
      );
      final failures = results.where((r) => r.isBlocking).toList();
      expect(failures.length, 2);
      expect(failures.map((f) => f.rule.id), containsAll(<String>['size', 'pages']));
      expect(overallStatus(results), RuleStatus.fail);
    });
  });

  group('profile definitions are unchanged', () {
    test('gov_aadhaar keeps its three rules in order', () {
      final profile = UploadProfiles.byId('gov_aadhaar')!;
      expect(profile.rules.map((r) => r.id).toList(), ['size', 'orientation', 'uniform']);
      expect(profile.maxBytes, 2 * 1024 * 1024);
    });

    test('every built-in profile evaluates without throwing', () {
      for (final profile in UploadProfiles.all) {
        final results = evaluateUploadReadiness(profile, pdf());
        expect(results.length, profile.rules.length, reason: profile.id);
        for (final result in results) {
          expect(
            result.status,
            isNot(RuleStatus.notApplicable),
            reason: '${profile.id}/${result.rule.id} should be evaluable',
          );
        }
      }
    });
  });
}
