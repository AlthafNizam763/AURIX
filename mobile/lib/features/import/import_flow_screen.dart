import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/theme/app_dimens.dart';
import '../../core/theme/app_typography.dart';
import '../../core/theme/aurix_palette.dart';
import '../../core/utils/responsive.dart';
import '../../data/import/imported_models.dart';
import '../../data/import/music_import_service.dart';
import '../../data/models/media_source.dart';
import '../../shared/widgets/feedback/state_views.dart';
import '../../shared/widgets/icons/aurix_glyphs.dart';
import '../../shared/widgets/icons/aurix_icon.dart';
import '../../shared/widgets/media/app_artwork.dart';
import 'providers/import_provider.dart';

/// One provider's import, start to finish.
///
/// Four states in one screen rather than four routes: connect → choose →
/// progress → summary. The user is inside a single operation the whole time,
/// and a route stack would let them press Back into the middle of a Firestore
/// write.
class ImportFlowScreen extends ConsumerWidget {
  const ImportFlowScreen({required this.source, super.key});

  final MediaSource source;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final state = ref.watch(importControllerProvider(source));
    final controller = ref.read(importControllerProvider(source).notifier);

    return PopScope(
      // Back is blocked only while Firestore is being written. An interrupted
      // write leaves a half-imported playlist, which is worse than waiting.
      canPop: state.stage != ImportStage.importing,
      child: Scaffold(
        backgroundColor: context.palette.ground,
        appBar: AppBar(
          leading: state.stage == ImportStage.importing
              ? null
              : IconButton(
                  onPressed: () => context.pop(),
                  icon: const AurixIcon(AurixGlyph.back),
                  tooltip: 'Back',
                ),
          title: Text('Import from ${source.label}'),
        ),
        body: ContentBounds(
          maxWidth: 560,
          child: switch (state.stage) {
            ImportStage.idle => _Intro(
              source: source,
              onConnect: controller.connect,
            ),
            ImportStage.authenticating => const _Busy(
              message: 'Waiting for you to sign in…',
            ),
            ImportStage.loadingPlaylists => const _Busy(
              message: 'Reading your playlists…',
            ),
            ImportStage.choosing => _Chooser(
              state: state,
              onToggle: controller.toggle,
              onSelectAll: controller.selectAll,
              onSelectNone: controller.selectNone,
              onImport: controller.importSelected,
            ),
            ImportStage.importing => _Progress(progress: state.progress),
            ImportStage.done => _Summary(
              source: source,
              summary: state.summary,
              onDone: () => context.pop(),
            ),
            ImportStage.failed => _Failed(
              message: state.error ?? 'The import did not finish.',
              onRetry: () {
                controller.reset();
                controller.connect();
              },
            ),
          },
        ),
      ),
    );
  }
}

class _Intro extends StatelessWidget {
  const _Intro({required this.source, required this.onConnect});

  final MediaSource source;
  final VoidCallback onConnect;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: EdgeInsets.symmetric(
        horizontal: context.pageGutter,
        vertical: AppSpacing.xl,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text('Connect to ${source.label}', style: AppTypography.headlineSmall),
          const SizedBox(height: AppSpacing.md),
          Text(
            'You will be asked to sign in to ${source.label}. AURIX reads your '
            'playlists once, copies them into your library, and then '
            'disconnects — it does not stay signed in.',
            style: AppTypography.bodyMedium.copyWith(height: 1.6),
          ),
          const SizedBox(height: AppSpacing.xl),
          const _Bullet(
            icon: AurixGlyph.playlist,
            text: 'Playlist names, artwork and track lists',
          ),
          const _Bullet(
            icon: AurixGlyph.lock,
            text: 'No audio is downloaded or stored anywhere',
          ),
          _Bullet(
            icon: AurixGlyph.close,
            text: 'Nothing is written back to your ${source.label} account',
          ),
          const Spacer(),
          FilledButton(
            onPressed: onConnect,
            style: FilledButton.styleFrom(minimumSize: const Size(0, 52)),
            child: Text('Continue with ${source.label}'),
          ),
          const SizedBox(height: AppSpacing.lg),
        ],
      ),
    );
  }
}

class _Bullet extends StatelessWidget {
  const _Bullet({required this.icon, required this.text});

  final AurixGlyph icon;
  final String text;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: AppSpacing.md),
      child: Row(
        children: [
          AurixIcon(icon, size: 17, color: context.palette.accent),
          const SizedBox(width: AppSpacing.md),
          Expanded(
            child: Text(
              text,
              style: AppTypography.bodySmall.copyWith(
                color: context.palette.textSecondary,
                height: 1.4,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _Busy extends StatelessWidget {
  const _Busy({required this.message});

  final String message;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const CircularProgressIndicator(),
          const SizedBox(height: AppSpacing.xl),
          Text(message, style: AppTypography.bodyMedium),
        ],
      ),
    );
  }
}

class _Chooser extends StatelessWidget {
  const _Chooser({
    required this.state,
    required this.onToggle,
    required this.onSelectAll,
    required this.onSelectNone,
    required this.onImport,
  });

  final ImportState state;
  final void Function(String playlistId) onToggle;
  final VoidCallback onSelectAll;
  final VoidCallback onSelectNone;
  final VoidCallback onImport;

  @override
  Widget build(BuildContext context) {
    if (state.playlists.isEmpty) {
      return const EmptyView(
        icon: AurixGlyph.playlist,
        title: 'No playlists there',
        message: 'That account has no playlists to import.',
      );
    }

    final allSelected = state.selected.length == state.playlists.length;

    return Column(
      children: [
        Padding(
          padding: EdgeInsets.fromLTRB(
            context.pageGutter,
            AppSpacing.md,
            context.pageGutter,
            0,
          ),
          child: Row(
            children: [
              Expanded(
                child: Text(
                  '${state.playlists.length} playlists found',
                  style: AppTypography.bodySmall.copyWith(
                    color: context.palette.textSecondary,
                  ),
                ),
              ),
              TextButton(
                onPressed: allSelected ? onSelectNone : onSelectAll,
                child: Text(allSelected ? 'Select none' : 'Select all'),
              ),
            ],
          ),
        ),

        Expanded(
          child: ListView.builder(
            itemCount: state.playlists.length,
            itemBuilder: (context, index) {
              final playlist = state.playlists[index];
              return _PlaylistRow(
                playlist: playlist,
                selected: state.selected.contains(playlist.id),
                onChanged: () => onToggle(playlist.id),
              );
            },
          ),
        ),

        SafeArea(
          top: false,
          child: Padding(
            padding: EdgeInsets.all(context.pageGutter),
            child: SizedBox(
              width: double.infinity,
              child: FilledButton(
                onPressed: state.selected.isEmpty ? null : onImport,
                style: FilledButton.styleFrom(minimumSize: const Size(0, 52)),
                child: Text(
                  state.selected.isEmpty
                      ? 'Choose playlists to import'
                      : 'Import ${state.selected.length} '
                            '${state.selected.length == 1 ? 'playlist' : 'playlists'}',
                ),
              ),
            ),
          ),
        ),
      ],
    );
  }
}

class _PlaylistRow extends StatelessWidget {
  const _PlaylistRow({
    required this.playlist,
    required this.selected,
    required this.onChanged,
  });

  final ImportedPlaylist playlist;
  final bool selected;
  final VoidCallback onChanged;

  @override
  Widget build(BuildContext context) {
    return ListTile(
      onTap: onChanged,
      leading: AppArtwork(
        imageUrl: playlist.coverUrl,
        size: AppSizes.tileArtworkLarge,
        seed: playlist.id,
        fallbackIcon: AurixGlyph.playlist,
      ),
      title: Text(
        playlist.name,
        style: AppTypography.titleMedium,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
      ),
      subtitle: Text(
        <String>[
          '${playlist.trackCount} '
              '${playlist.trackCount == 1 ? 'song' : 'songs'}',
          if (playlist.ownerName != null) playlist.ownerName!,
        ].join(' · '),
        style: AppTypography.bodySmall,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
      ),
      trailing: Checkbox(
        value: selected,
        onChanged: (_) => onChanged(),
      ),
    );
  }
}

class _Progress extends StatelessWidget {
  const _Progress({required this.progress});

  final ImportProgress? progress;

  @override
  Widget build(BuildContext context) {
    final fraction = progress?.fraction;

    return Padding(
      padding: EdgeInsets.symmetric(horizontal: context.pageGutter),
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const Text(
            'Importing…',
            style: AppTypography.headlineSmall,
            textAlign: TextAlign.center,
          ),
          const SizedBox(height: AppSpacing.xl),
          ClipRRect(
            borderRadius: BorderRadius.circular(AppRadius.pill),
            child: LinearProgressIndicator(
              // Null while a playlist's total is unknown, which renders as the
              // indeterminate bar rather than as a bar stuck at zero.
              value: fraction,
              minHeight: 6,
              backgroundColor: context.palette.surfaceElevated,
            ),
          ),
          const SizedBox(height: AppSpacing.lg),
          if (progress != null)
            Text(
              '${progress!.playlistName}\n'
              'Playlist ${progress!.playlistIndex + 1} of '
              '${progress!.playlistTotal}'
              '${progress!.tracksTotal > 0 ? ' · ${progress!.tracksFetched} of ${progress!.tracksTotal} songs' : ''}',
              style: AppTypography.bodySmall.copyWith(
                color: context.palette.textSecondary,
                height: 1.6,
              ),
              textAlign: TextAlign.center,
            ),
          const SizedBox(height: AppSpacing.xxl),
          Text(
            'Keep AURIX open until this finishes.',
            style: AppTypography.bodySmall.copyWith(
              color: context.palette.textTertiary,
            ),
            textAlign: TextAlign.center,
          ),
        ],
      ),
    );
  }
}

class _Summary extends StatelessWidget {
  const _Summary({
    required this.source,
    required this.summary,
    required this.onDone,
  });

  final MediaSource source;
  final ImportSummary? summary;
  final VoidCallback onDone;

  @override
  Widget build(BuildContext context) {
    final results = summary;
    final succeeded = results?.succeeded ?? const <PlaylistImportResult>[];
    final failed = results?.failed ?? const <PlaylistImportResult>[];

    return Padding(
      padding: EdgeInsets.symmetric(
        horizontal: context.pageGutter,
        vertical: AppSpacing.xl,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          AurixIcon(
            AurixGlyph.checkCircle,
            size: 48,
            color: context.palette.accent,
          ),
          const SizedBox(height: AppSpacing.lg),
          Text(
            succeeded.isEmpty ? 'Nothing imported' : 'Import complete',
            style: AppTypography.headlineSmall,
            textAlign: TextAlign.center,
          ),
          const SizedBox(height: AppSpacing.sm),
          Text(
            succeeded.isEmpty
                ? 'None of the selected playlists could be imported.'
                : '${succeeded.length} '
                      '${succeeded.length == 1 ? 'playlist' : 'playlists'} and '
                      '${results?.trackCount ?? 0} songs are now in your '
                      'library.',
            style: AppTypography.bodyMedium,
            textAlign: TextAlign.center,
          ),

          if (failed.isNotEmpty) ...[
            const SizedBox(height: AppSpacing.lg),
            Container(
              padding: const EdgeInsets.all(AppSpacing.lg),
              decoration: BoxDecoration(
                color: context.palette.surface,
                borderRadius: AppRadius.card,
                border: Border.all(color: context.palette.hairline),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    '${failed.length} could not be imported',
                    style: AppTypography.titleMedium,
                  ),
                  const SizedBox(height: AppSpacing.sm),
                  // Named individually rather than counted. "3 failed" tells
                  // the user nothing they can act on; the names tell them
                  // which ones to try again.
                  for (final result in failed)
                    Padding(
                      padding: const EdgeInsets.only(bottom: 4),
                      child: Text(
                        '${result.name} — ${result.error}',
                        style: AppTypography.bodySmall,
                      ),
                    ),
                ],
              ),
            ),
          ],

          const SizedBox(height: AppSpacing.xl),

          Container(
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
                  AurixGlyph.lock,
                  size: 17,
                  color: context.palette.textTertiary,
                ),
                const SizedBox(width: AppSpacing.md),
                Expanded(
                  child: Text(
                    '${source.label} has been disconnected. Your imported '
                    'playlists are yours now — rename them, reorder them, add '
                    'to them. AURIX will not sign in to ${source.label} again '
                    'unless you import from it.',
                    style: AppTypography.bodySmall.copyWith(height: 1.6),
                  ),
                ),
              ],
            ),
          ),

          const Spacer(),

          FilledButton(
            onPressed: onDone,
            style: FilledButton.styleFrom(minimumSize: const Size(0, 52)),
            child: const Text('Done'),
          ),
        ],
      ),
    );
  }
}

class _Failed extends StatelessWidget {
  const _Failed({required this.message, required this.onRetry});

  final String message;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    return EmptyView(
      icon: AurixGlyph.warning,
      title: 'Import failed',
      message: message,
      actionLabel: 'Try again',
      onAction: onRetry,
    );
  }
}
