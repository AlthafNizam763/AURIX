import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/router/navigation.dart';
import '../../core/router/route_names.dart';
import '../../core/theme/app_dimens.dart';
import '../../core/theme/app_typography.dart';
import '../../core/theme/aurix_palette.dart';
import '../../core/utils/responsive.dart';
import '../../data/import/music_import_provider.dart';
import '../../shared/widgets/icons/aurix_glyphs.dart';
import '../../shared/widgets/icons/aurix_icon.dart';
import 'providers/import_provider.dart';

/// Settings → Import Music.
///
/// Lists every registered [MusicImportProvider]. A provider appears here by
/// being in `importProvidersProvider` and nowhere else — adding YouTube's
/// implementation puts it on this screen with no change to this file.
///
/// Unavailable providers are listed and disabled rather than hidden. A missing
/// option is a mystery; a greyed-out one with a reason underneath is an
/// instruction.
class ImportMusicScreen extends ConsumerWidget {
  const ImportMusicScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final providers = ref.watch(importProvidersProvider);

    return Scaffold(
      backgroundColor: context.palette.ground,
      appBar: AppBar(
        leading: IconButton(
          onPressed: () => context.pop(),
          icon: const AurixIcon(AurixGlyph.back),
          tooltip: 'Back',
        ),
        title: const Text('Import music'),
      ),
      body: ContentBounds(
        maxWidth: 560,
        child: ListView(
          padding: EdgeInsets.symmetric(
            horizontal: context.pageGutter,
            vertical: AppSpacing.lg,
          ),
          children: [
            const Text(
              'Bring playlists you already have into AURIX. They become your '
              'own playlists here — you can rename them, reorder them and add '
              'to them.',
              style: AppTypography.bodyMedium,
            ),

            const SizedBox(height: AppSpacing.xl),

            for (final provider in providers) ...[
              _ProviderCard(
                provider: provider,
                onTap: () => context.pushDistinct(
                  RouteNames.importProvider,
                  pathParameters: {'provider': provider.source.wireValue},
                ),
              ),
              const SizedBox(height: AppSpacing.md),
            ],

            const SizedBox(height: AppSpacing.lg),

            const _LegalNote(),
          ],
        ),
      ),
    );
  }
}

class _ProviderCard extends StatelessWidget {
  const _ProviderCard({required this.provider, required this.onTap});

  final MusicImportProvider provider;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final available = provider.isAvailable;
    final palette = context.palette;

    return Opacity(
      opacity: available ? 1 : 0.55,
      child: Material(
        color: palette.surface,
        borderRadius: AppRadius.card,
        child: InkWell(
          onTap: available ? onTap : null,
          borderRadius: AppRadius.card,
          child: Container(
            padding: const EdgeInsets.all(AppSpacing.lg),
            decoration: BoxDecoration(
              borderRadius: AppRadius.card,
              border: Border.all(color: palette.hairline),
            ),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Container(
                  width: 44,
                  height: 44,
                  decoration: BoxDecoration(
                    color: palette.accentSoft,
                    borderRadius: AppRadius.artwork,
                  ),
                  child: AurixIcon(
                    AurixGlyph.musicNote,
                    size: 22,
                    color: palette.accent,
                  ),
                ),
                const SizedBox(width: AppSpacing.lg),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        children: [
                          Text(
                            provider.displayName,
                            style: AppTypography.titleMedium,
                          ),
                          if (!available) ...[
                            const SizedBox(width: AppSpacing.sm),
                            Container(
                              padding: const EdgeInsets.symmetric(
                                horizontal: AppSpacing.sm,
                                vertical: 2,
                              ),
                              decoration: BoxDecoration(
                                color: palette.surfaceElevated,
                                borderRadius: BorderRadius.circular(
                                  AppRadius.pill,
                                ),
                              ),
                              child: Text(
                                'Coming soon',
                                style: AppTypography.labelMedium.copyWith(
                                  fontSize: 10,
                                  color: palette.textTertiary,
                                ),
                              ),
                            ),
                          ],
                        ],
                      ),
                      const SizedBox(height: AppSpacing.xs),
                      Text(
                        available
                            ? provider.description
                            : provider.unavailableReason ?? provider.description,
                        style: AppTypography.bodySmall.copyWith(height: 1.5),
                      ),
                    ],
                  ),
                ),
                if (available) ...[
                  const SizedBox(width: AppSpacing.sm),
                  AurixIcon(
                    AurixGlyph.chevronRight,
                    size: 18,
                    color: palette.textTertiary,
                  ),
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// What importing does and does not do.
///
/// On screen rather than only in the code, because it is the answer to the
/// question a user actually has — "does this download my music?" — and because
/// the answer is a commitment rather than an implementation detail.
class _LegalNote extends StatelessWidget {
  const _LegalNote();

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(AppSpacing.lg),
      decoration: BoxDecoration(
        color: context.palette.surface,
        borderRadius: AppRadius.card,
        border: Border.all(color: context.palette.hairline),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          AurixIcon(
            AurixGlyph.info,
            size: 18,
            color: context.palette.textTertiary,
          ),
          const SizedBox(width: AppSpacing.md),
          Expanded(
            child: Text(
              'Importing copies playlist details — titles, artists, artwork '
              'links and track references. No audio is downloaded or stored. '
              'Imported tracks play through the service they came from, and '
              'AURIX is not affiliated with any of them.',
              style: AppTypography.bodySmall.copyWith(
                height: 1.6,
                color: context.palette.textSecondary,
              ),
            ),
          ),
        ],
      ),
    );
  }
}
