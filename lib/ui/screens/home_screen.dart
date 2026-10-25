import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import 'package:pdf_fit/core/state/app_state.dart';
import 'package:pdf_fit/ui/screens/compress_screen.dart';
import 'package:pdf_fit/ui/screens/image_to_pdf_screen.dart';
import 'package:pdf_fit/ui/screens/merge_screen.dart';
import 'package:pdf_fit/ui/screens/premium_screen.dart';
import 'package:pdf_fit/ui/screens/rotate_screen.dart';
import 'package:pdf_fit/ui/screens/split_screen.dart';
import 'package:pdf_fit/ui/screens/upload_check_screen.dart';
import 'package:pdf_fit/ui/widgets/banner_ad_slot.dart';
import 'package:pdf_fit/ui/widgets/common.dart';

class HomeScreen extends StatelessWidget {
  const HomeScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final app = context.watch<AppState>();
    final premium = app.isPremium;
    final scheme = Theme.of(context).colorScheme;

    return Scaffold(
      body: SafeArea(
        child: RefreshIndicator(
          onRefresh: app.refreshAll,
          child: ListView(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 24),
            children: [
              Row(
                children: [
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          'PDF Fit',
                          style: Theme.of(context).textTheme.headlineSmall?.copyWith(
                                fontWeight: FontWeight.w800,
                                color: scheme.primary,
                              ),
                        ),
                        Text(
                          'Compress, resize & prepare documents',
                          style: Theme.of(context).textTheme.bodySmall?.copyWith(
                                color: scheme.onSurfaceVariant,
                              ),
                        ),
                      ],
                    ),
                  ),
                  _PlanChip(label: app.isPremium ? 'Premium' : app.quota.label),
                ],
              ),
              const SizedBox(height: 14),

              // Primary action: compression is the core product.
              Card(
                color: scheme.primaryContainer,
                child: InkWell(
                  borderRadius: BorderRadius.circular(18),
                  onTap: () => _open(context, const CompressScreen()),
                  child: Padding(
                    padding: const EdgeInsets.all(18),
                    child: Row(
                      children: [
                        Icon(Icons.compress, size: 34, color: scheme.onPrimaryContainer),
                        const SizedBox(width: 14),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                'Compress to a target size',
                                style: TextStyle(
                                  fontSize: 17,
                                  fontWeight: FontWeight.w800,
                                  color: scheme.onPrimaryContainer,
                                ),
                              ),
                              const SizedBox(height: 2),
                              Text(
                                premium
                                    ? 'Any target size, unlimited runs'
                                    : '${app.quota.remaining >= 0 ? app.quota.remaining : "Unlimited"} compressions left this month',
                                style: TextStyle(
                                  fontSize: 12.5,
                                  color: scheme.onPrimaryContainer.withValues(alpha: 0.85),
                                ),
                              ),
                            ],
                          ),
                        ),
                        Icon(Icons.arrow_forward, color: scheme.onPrimaryContainer),
                      ],
                    ),
                  ),
                ),
              ),

              const SectionHeader(title: 'Prepare for upload'),
              ToolCard(
                title: 'Upload readiness check',
                subtitle: 'Verify size, pages, A4, text and protection before you submit',
                icon: Icons.fact_check_outlined,
                onTap: () => _open(context, const UploadCheckScreen()),
              ),

              const SectionHeader(title: 'Document tools'),
              ToolCard(
                title: 'Merge PDFs',
                subtitle: premium
                    ? 'Combine any number of documents, in order'
                    : 'Combine up to 2 documents (Basic)',
                icon: Icons.merge_type,
                onTap: () => _open(context, const MergeScreen()),
              ),
              const SizedBox(height: 10),
              ToolCard(
                title: 'Split & extract pages',
                subtitle: premium
                    ? 'Page ranges, every N pages, or single pages'
                    : 'Even/odd and every N pages (Basic)',
                icon: Icons.content_cut,
                onTap: () => _open(context, const SplitScreen()),
              ),
              const SizedBox(height: 10),
              ToolCard(
                title: 'Rotate pages',
                subtitle: 'Fix sideways or upside-down scans',
                icon: Icons.rotate_right,
                onTap: () => _open(context, const RotateScreen()),
              ),
              const SizedBox(height: 10),
              ToolCard(
                title: 'Images to PDF',
                subtitle: premium
                    ? 'Unlimited photos and scans per document'
                    : 'Up to 5 images per document (Basic)',
                icon: Icons.photo_library_outlined,
                onTap: () => _open(context, const ImageToPdfScreen()),
              ),

              if (!premium) ...[
                const SectionHeader(title: 'Upgrade'),
                Card(
                  child: Padding(
                    padding: const EdgeInsets.all(16),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Row(
                          children: [
                            Icon(Icons.workspace_premium, color: scheme.tertiary),
                            const SizedBox(width: 8),
                            Text(
                              'PDF Fit Premium',
                              style: Theme.of(context).textTheme.titleMedium?.copyWith(
                                    fontWeight: FontWeight.w700,
                                  ),
                            ),
                          ],
                        ),
                        const SizedBox(height: 8),
                        const Text(
                          '• Custom target sizes and unlimited compression\n'
                          '• Merge unlimited documents and page-range splitting\n'
                          '• Unlimited images per PDF, unlimited presets\n'
                          '• No ads, full history',
                          style: TextStyle(fontSize: 13, height: 1.5),
                        ),
                        const SizedBox(height: 12),
                        FilledButton.tonalIcon(
                          onPressed: () => _open(context, const PremiumScreen()),
                          icon: const Icon(Icons.arrow_upward),
                          label: const Text('See Premium'),
                        ),
                      ],
                    ),
                  ),
                ),
              ],

              const SizedBox(height: 16),
              // Banner ad: only for Basic users on stores where AdMob works.
              const BannerAdSlot(),
              const SizedBox(height: 8),
              Text(
                'All processing happens on your device. Files never leave your phone.',
                textAlign: TextAlign.center,
                style: Theme.of(context).textTheme.bodySmall?.copyWith(
                      color: scheme.onSurfaceVariant,
                    ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  void _open(BuildContext context, Widget screen) {
    Navigator.of(context).push(MaterialPageRoute(builder: (_) => screen));
  }
}

class _PlanChip extends StatelessWidget {
  const _PlanChip({required this.label});

  final String label;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
      decoration: BoxDecoration(
        color: scheme.secondaryContainer,
        borderRadius: BorderRadius.circular(20),
      ),
      child: Text(
        label,
        style: TextStyle(
          fontSize: 11,
          fontWeight: FontWeight.w700,
          color: scheme.onSecondaryContainer,
        ),
      ),
    );
  }
}
