import 'package:pdf_fit/core/pdf/pdf_operations.dart';

/// A single upload-portal requirement.
class UploadRule {
  const UploadRule({
    required this.id,
    required this.label,
    this.maxBytes,
    this.maxPages,
    this.maxWidthPt,
    this.maxHeightPt,
    this.requirePortrait = false,
    this.requireSinglePageSize = false,
    this.requireText = false,
    this.forbidAnnotations = false,
    this.requireUnencrypted = false,
    this.allowedPageSizes = const [],
    this.advisory = false,
  });

  final String id;
  final String label;
  final int? maxBytes;
  final int? maxPages;
  final double? maxWidthPt;
  final double? maxHeightPt;
  final bool requirePortrait;
  final bool requireSinglePageSize;
  final bool requireText;
  final bool forbidAnnotations;
  final bool requireUnencrypted;

  /// Acceptable page sizes in points (width, height), orientation-agnostic.
  /// Empty means "any size".
  final List<({double width, double height})> allowedPageSizes;

  /// Advisory rules never block an upload: a failure becomes a warning. Use this
  /// for guidance that "may" cause rejection rather than a hard requirement.
  final bool advisory;
}

enum RuleStatus { pass, fail, warning, notApplicable }

/// Explicit severity ordering. The higher the rank, the more serious the result.
///
/// Keeping this in one place means "worst outcome wins" is decided by a single
/// function instead of by comparing enum indices, which used to be wrong because
/// the declaration order (`pass, fail, warning, notApplicable`) is not a severity
/// order.
int severityRank(RuleStatus status) => switch (status) {
      RuleStatus.notApplicable => 0,
      RuleStatus.pass => 1,
      RuleStatus.warning => 2,
      RuleStatus.fail => 3,
    };

/// Combines several outcomes, returning the most severe one.
///
/// Returns [RuleStatus.notApplicable] only when every input is notApplicable
/// (i.e. nothing was actually evaluated).
RuleStatus worstStatus(Iterable<RuleStatus> statuses) {
  var worst = RuleStatus.notApplicable;
  var any = false;
  for (final status in statuses) {
    any = true;
    if (severityRank(status) > severityRank(worst)) worst = status;
  }
  return any ? worst : RuleStatus.notApplicable;
}

class RuleResult {
  const RuleResult({
    required this.rule,
    required this.status,
    required this.message,
  });

  final UploadRule rule;
  final RuleStatus status;
  final String message;

  bool get isBlocking => status == RuleStatus.fail;
}

/// A named bundle of rules for a real-world upload target.
class UploadProfile {
  const UploadProfile({
    required this.id,
    required this.name,
    required this.description,
    required this.rules,
  });

  final String id;
  final String name;
  final String description;
  final List<UploadRule> rules;

  /// The strictest size rule, used to suggest a compression target.
  int? get maxBytes {
    final sizes = rules.map((r) => r.maxBytes).whereType<int>().toList()..sort();
    return sizes.isEmpty ? null : sizes.first;
  }
}

/// Built-in profiles. The values are conservative, published-style limits used
/// by common Indian government / job / visa portals and email providers. They are
/// editable in the UI, and every check reports the exact measured value, so a
/// mismatch is never hidden.
class UploadProfiles {
  UploadProfiles._();

  static const a4 = (width: 595.28, height: 841.89);

  static const List<UploadProfile> all = [
    UploadProfile(
      id: 'email',
      name: 'Email attachment',
      description: 'Most providers accept up to 25 MB per message.',
      rules: [
        UploadRule(
          id: 'size',
          label: 'Total file size',
          maxBytes: 25 * 1024 * 1024,
          maxPages: 100,
          requireUnencrypted: true,
        ),
      ],
    ),
    UploadProfile(
      id: 'job',
      name: 'Job application portal',
      description: 'Common resume/CV upload limits.',
      rules: [
        UploadRule(
          id: 'size',
          label: 'File size',
          maxBytes: 2 * 1024 * 1024,
          maxPages: 10,
          requireUnencrypted: true,
          allowedPageSizes: [a4],
        ),
      ],
    ),
    UploadProfile(
      id: 'gov_aadhaar',
      name: 'Government form (India, A4)',
      description: 'A4 pages, small size, scanned copies accepted.',
      rules: [
        UploadRule(
          id: 'size',
          label: 'File size',
          maxBytes: 2 * 1024 * 1024,
          maxPages: 20,
          requireUnencrypted: true,
          allowedPageSizes: [a4],
        ),
        UploadRule(
          id: 'orientation',
          label: 'Portrait pages',
          requirePortrait: true,
        ),
        UploadRule(
          id: 'uniform',
          label: 'Uniform page size (advisory)',
          requireSinglePageSize: true,
          // Portals "may" reject mixed sizes; it is not a published hard
          // requirement, so this is a warning rather than a blocker.
          advisory: true,
        ),
      ],
    ),
    UploadProfile(
      id: 'visa',
      name: 'Visa / passport application',
      description: 'Single-page, text-based PDFs are usually required.',
      rules: [
        UploadRule(
          id: 'size',
          label: 'File size',
          maxBytes: 5 * 1024 * 1024,
          maxPages: 1,
          requireText: true,
          requireUnencrypted: true,
          forbidAnnotations: true,
        ),
      ],
    ),
    UploadProfile(
      id: 'scholarship',
      name: 'Scholarship / admission portal',
      description: 'Multi-page documents with a modest size cap.',
      rules: [
        UploadRule(
          id: 'size',
          label: 'File size',
          maxBytes: 10 * 1024 * 1024,
          maxPages: 30,
          requireUnencrypted: true,
          allowedPageSizes: [a4],
        ),
      ],
    ),
  ];

  static UploadProfile? byId(String id) {
    for (final profile in all) {
      if (profile.id == id) return profile;
    }
    return null;
  }
}

/// Runs every rule in [profile] against a real inspection of [inspection].
///
/// Nothing is assumed: page sizes, text presence, annotations and encryption are
/// all read from PDFium. Rules that cannot be evaluated are reported as
/// [RuleStatus.warning] rather than silently passing.
List<RuleResult> evaluateUploadReadiness(UploadProfile profile, PdfInspection inspection) {
  final results = <RuleResult>[];
  for (final rule in profile.rules) {
    results.add(_evaluate(rule, inspection));
  }
  return results;
}

RuleResult _evaluate(UploadRule rule, PdfInspection pdf) {
  // Encryption blocks any portal that needs to parse the file. This is a hard
  // failure regardless of the advisory flag: an unreadable file is unusable.
  if (rule.requireUnencrypted && pdf.isEncrypted) {
    return RuleResult(
      rule: rule,
      status: RuleStatus.fail,
      message: 'The PDF is password/owner protected. Remove protection before '
          'uploading (the portal cannot read it).',
    );
  }

  final messages = <String>[];
  final outcomes = <RuleStatus>[];

  // Every check records its own outcome; the rule's outcome is the most severe
  // of them (see [worstStatus]).
  void record(bool ok, String message) {
    outcomes.add(ok ? RuleStatus.pass : RuleStatus.warning);
    messages.add(message);
  }

  if (rule.maxBytes != null) {
    final ok = pdf.byteSize <= rule.maxBytes!;
    record(
      ok,
      ok
          ? 'Size ${_bytes(pdf.byteSize)} is within ${_bytes(rule.maxBytes!)}.'
          : 'Size ${_bytes(pdf.byteSize)} exceeds ${_bytes(rule.maxBytes!)} '
              'by ${_bytes(pdf.byteSize - rule.maxBytes!)}.',
    );
  }

  if (rule.maxPages != null) {
    final ok = pdf.pageCount <= rule.maxPages!;
    record(
      ok,
      ok
          ? '${pdf.pageCount} pages (limit ${rule.maxPages}).'
          : '${pdf.pageCount} pages exceeds the ${rule.maxPages}-page limit.',
    );
  }

  if (rule.allowedPageSizes.isNotEmpty) {
    bool matches(double w, double h) => rule.allowedPageSizes.any(
          (s) => ((s.width - w).abs() < 4 && (s.height - h).abs() < 4),
        );
    final ok = matches(pdf.pageWidthPt, pdf.pageHeightPt);
    record(
      ok,
      ok
          ? 'Page size ${pdf.pageSizeLabel} is accepted.'
          : 'Page size ${pdf.pageSizeLabel} is not accepted. Resize to A4 first.',
    );
  }

  if (rule.maxWidthPt != null || rule.maxHeightPt != null) {
    final tooWide = rule.maxWidthPt != null && pdf.pageWidthPt > rule.maxWidthPt!;
    final tooTall = rule.maxHeightPt != null && pdf.pageHeightPt > rule.maxHeightPt!;
    record(
      !(tooWide || tooTall),
      (tooWide || tooTall)
          ? 'Page is ${pdf.pageWidthPt.round()}x${pdf.pageHeightPt.round()} pt, larger '
              'than the allowed ${rule.maxWidthPt?.round() ?? '-'}x'
              '${rule.maxHeightPt?.round() ?? '-'} pt.'
          : 'Page dimensions are within limits.',
    );
  }

  if (rule.requirePortrait) {
    record(
      !pdf.isLandscape,
      pdf.isLandscape ? 'Pages are landscape. Rotate to portrait first.' : 'Pages are portrait.',
    );
  }

  if (rule.requireSinglePageSize) {
    record(
      !pdf.mixedPageSizes,
      pdf.mixedPageSizes
          ? 'Pages have different sizes. Portals that require a uniform document '
              'may reject this file.'
          : 'All sampled pages share the same size.',
    );
  }

  if (rule.requireText) {
    record(
      pdf.hasExtractableText,
      pdf.hasExtractableText
          ? 'Selectable text found (${pdf.textCharacterCount} characters sampled).'
          : 'This looks like a scan: no selectable text was found. Some portals '
              'require a text-based PDF (OCR is not included in this app).',
    );
  }

  if (rule.forbidAnnotations) {
    record(
      !pdf.hasAnnotations,
      pdf.hasAnnotations
          ? 'Annotations/comments are present; flatten or remove them first.'
          : 'No annotations found.',
    );
  }

  // No applicable constraint on this rule: nothing was evaluated.
  if (outcomes.isEmpty) {
    return RuleResult(
      rule: rule,
      status: RuleStatus.notApplicable,
      message: 'This rule does not apply to the selected profile.',
    );
  }

  final combined = worstStatus(outcomes);
  // A failed check is only a hard failure when the rule is not advisory.
  final status = combined == RuleStatus.warning && !rule.advisory
      ? RuleStatus.fail
      : combined;

  return RuleResult(
    rule: rule,
    status: status,
    message: messages.join(' '),
  );
}

/// Aggregated outcome for a whole report.
///
/// * [RuleStatus.fail] if any rule failed,
/// * else [RuleStatus.warning] if any rule warned,
/// * else [RuleStatus.pass] if at least one rule passed,
/// * else [RuleStatus.notApplicable].
RuleStatus overallStatus(List<RuleResult> results) =>
    worstStatus(results.map((r) => r.status));

String _bytes(int bytes) {
  if (bytes < 1024) return '$bytes B';
  if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(0)} KB';
  return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';
}
