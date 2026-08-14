import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/router/route_names.dart';
import '../../core/theme/app_dimens.dart';
import '../../core/theme/app_typography.dart';
import '../../core/theme/aurix_palette.dart';
import '../../core/utils/responsive.dart';
import '../../data/import/playlist_import_service.dart';
import '../../data/import/playlist_url.dart';
import '../../shared/widgets/icons/aurix_glyphs.dart';
import '../../shared/widgets/icons/aurix_icon.dart';
import '../../shared/widgets/media/app_artwork.dart';
import 'providers/playlist_import_provider.dart';

/// AURIX → Import Playlist.
///
/// One screen, four states — paste, working, already-imported, done — rather
/// than four routes. The user is inside a single operation the whole time, and
/// a route stack would let them press Back into the middle of a Firestore
/// write.
class ImportPlaylistScreen extends ConsumerStatefulWidget {
  const ImportPlaylistScreen({super.key});

  @override
  ConsumerState<ImportPlaylistScreen> createState() =>
      _ImportPlaylistScreenState();
}

class _ImportPlaylistScreenState extends ConsumerState<ImportPlaylistScreen> {
  late final TextEditingController _field;

  @override
  void initState() {
    super.initState();
    _field = TextEditingController(
      text: ref.read(playlistLinkImportControllerProvider).url,
    );
  }

  @override
  void dispose() {
    _field.dispose();
    super.dispose();
  }

  /// Fills the field from the clipboard.
  ///
  /// Worth a button: the user arrives here having *just* copied a link, and
  /// pasting into a text field on a phone is a long-press and a popup menu.
  Future<void> _pasteFromClipboard() async {
    final data = await Clipboard.getData(Clipboard.kTextPlain);
    final text = data?.text?.trim();
    if (text == null || text.isEmpty) return;
    _field.text = text;
    ref.read(playlistLinkImportControllerProvider.notifier).onUrlChanged(text);
  }

  @override
  Widget build(BuildContext context) {
    final state = ref.watch(playlistLinkImportControllerProvider);
    final controller =
        ref.read(playlistLinkImportControllerProvider.notifier);

    return PopScope(
      // Back is blocked only while Firestore is being written. An interrupted
      // write leaves a half-imported playlist, which is worse than waiting.
      canPop: !state.isBusy,
      child: Scaffold(
        backgroundColor: context.palette.ground,
        appBar: AppBar(
          leading: state.isBusy
              ? null
              : IconButton(
                  onPressed: () => context.pop(),
                  icon: const AurixIcon(AurixGlyph.back),
                  tooltip: 'Back',
                ),
          title: const Text('Import playlist'),
        ),
        body: ContentBounds(
          maxWidth: 560,
          child: switch (state.stage) {
            LinkImportStage.running => _Working(step: state.step),
            LinkImportStage.done => _Done(
              outcome: state.outcome!,
              onOpen: () => _openPlaylist(state.outcome!.playlistId),
              onImportAnother: () {
                _field.clear();
                controller.reset();
              },
            ),
            LinkImportStage.duplicate => _AlreadyImported(
              name: state.duplicateOf?.name ?? 'That playlist',
              onOpen: () => _openPlaylist(state.duplicateOf!.id),
              onResync: controller.resync,
            ),
            LinkImportStage.idle || LinkImportStage.failed => _PasteForm(
              state: state,
              field: _field,
              onChanged: controller.onUrlChanged,
              onPaste: _pasteFromClipboard,
              onImport: controller.import,
            ),
          },
        ),
      ),
    );
  }

  void _openPlaylist(String playlistId) {
    // `pushReplacement` rather than `push`: the import screen has done its job,
    // and leaving it on the stack means Back from the playlist returns to a
    // success card for an import that is over.
    context.pushReplacementNamed(
      RouteNames.playlist,
      pathParameters: <String, String>{'id': playlistId},
    );
  }
}

// ---------------------------------------------------------------------------
// Paste
// ---------------------------------------------------------------------------

class _PasteForm extends StatelessWidget {
  const _PasteForm({
    required this.state,
    required this.field,
    required this.onChanged,
    required this.onPaste,
    required this.onImport,
  });

  final LinkImportState state;
  final TextEditingController field;
  final ValueChanged<String> onChanged;
  final Future<void> Function() onPaste;
  final VoidCallback onImport;

  @override
  Widget build(BuildContext context) {
    final palette = context.palette;

    return ListView(
      padding: EdgeInsets.symmetric(
        horizontal: context.pageGutter,
        vertical: AppSpacing.xl,
      ),
      children: [
        const Text('Import Playlist', style: AppTypography.headlineSmall),
        const SizedBox(height: AppSpacing.sm),
        Text(
          'Paste a Spotify or YouTube Music playlist link',
          style: AppTypography.bodyMedium.copyWith(
            color: palette.textSecondary,
            height: 1.5,
          ),
        ),

        const SizedBox(height: AppSpacing.xl),

        TextField(
          controller: field,
          onChanged: onChanged,
          autofocus: true,
          autocorrect: false,
          enableSuggestions: false,
          keyboardType: TextInputType.url,
          textInputAction: TextInputAction.go,
          onSubmitted: (_) {
            if (state.canImport) onImport();
          },
          style: AppTypography.bodyMedium,
          decoration: InputDecoration(
            hintText: 'Paste playlist URL',
            filled: true,
            fillColor: palette.surface,
            prefixIcon: _SourceBadge(source: state.detected),
            suffixIcon: IconButton(
              onPressed: onPaste,
              icon: const AurixIcon(AurixGlyph.add, size: 18),
              tooltip: 'Paste from clipboard',
            ),
            border: OutlineInputBorder(
              borderRadius: AppRadius.card,
              borderSide: BorderSide(color: palette.hairline),
            ),
            enabledBorder: OutlineInputBorder(
              borderRadius: AppRadius.card,
              borderSide: BorderSide(color: palette.hairline),
            ),
            focusedBorder: OutlineInputBorder(
              borderRadius: AppRadius.card,
              borderSide: BorderSide(color: palette.accent),
            ),
          ),
        ),

        // The link hint sits under the field and is deliberately not styled as
        // an error: the user is mid-paste, and a red box for a half-typed URL
        // is noise rather than help.
        if (state.linkProblem != null) ...[
          const SizedBox(height: AppSpacing.sm),
          Text(
            state.linkProblem!.message,
            style: AppTypography.bodySmall.copyWith(
              color: palette.textSecondary,
              height: 1.5,
            ),
          ),
        ],

        // A real failure — the import ran and did not finish — does get the
        // full treatment.
        if (state.error != null) ...[
          const SizedBox(height: AppSpacing.lg),
          _ErrorCard(message: state.error!),
        ],

        const SizedBox(height: AppSpacing.xl),

        FilledButton(
          onPressed: state.canImport ? onImport : null,
          style: FilledButton.styleFrom(minimumSize: const Size(0, 52)),
          child: const Text('Import Playlist'),
        ),

        const SizedBox(height: AppSpacing.xxl),

        const _ExampleLinks(),

        const SizedBox(height: AppSpacing.lg),

        const _LegalNote(),
      ],
    );
  }
}

/// The detected-source chip inside the text field.
class _SourceBadge extends StatelessWidget {
  const _SourceBadge({required this.source});

  final PlaylistSource source;

  @override
  Widget build(BuildContext context) {
    final palette = context.palette;
    final known = source != PlaylistSource.unknown;

    return Padding(
      padding: const EdgeInsets.only(left: AppSpacing.md, right: AppSpacing.sm),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          AurixIcon(
            known ? AurixGlyph.musicNote : AurixGlyph.search,
            size: 18,
            color: known ? palette.accent : palette.textTertiary,
          ),
          if (known) ...[
            const SizedBox(width: AppSpacing.xs),
            Text(
              source.label,
              style: AppTypography.labelMedium.copyWith(
                color: palette.accent,
                fontSize: 11,
              ),
            ),
          ],
        ],
      ),
    );
  }
}

class _ExampleLinks extends StatelessWidget {
  const _ExampleLinks();

  @override
  Widget build(BuildContext context) {
    final palette = context.palette;

    return Container(
      padding: const EdgeInsets.all(AppSpacing.lg),
      decoration: BoxDecoration(
        color: palette.surface,
        borderRadius: AppRadius.card,
        border: Border.all(color: palette.hairline),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text('Links that work', style: AppTypography.titleMedium),
          const SizedBox(height: AppSpacing.md),
          for (final example in const <String>[
            'open.spotify.com/playlist/…',
            'music.youtube.com/playlist?list=…',
            'youtube.com/playlist?list=…',
          ])
            Padding(
              padding: const EdgeInsets.only(bottom: 6),
              child: Text(
                example,
                style: AppTypography.bodySmall.copyWith(
                  color: palette.textSecondary,
                  fontFamily: 'monospace',
                ),
              ),
            ),
        ],
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Working
// ---------------------------------------------------------------------------

class _Working extends StatelessWidget {
  const _Working({required this.step});

  final ImportStep? step;

  @override
  Widget build(BuildContext context) {
    final palette = context.palette;
    final current = step;

    return Padding(
      padding: EdgeInsets.symmetric(horizontal: context.pageGutter),
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(
            current?.message ?? ImportPhase.detecting.message,
            style: AppTypography.headlineSmall,
            textAlign: TextAlign.center,
          ),

          const SizedBox(height: AppSpacing.xl),

          ClipRRect(
            borderRadius: BorderRadius.circular(AppRadius.pill),
            child: LinearProgressIndicator(
              // Null renders the indeterminate bar, which is the honest thing
              // to show while the total is unknown — a bar stuck at zero reads
              // as a hang.
              value: current?.fraction,
              minHeight: 6,
              backgroundColor: palette.surfaceElevated,
            ),
          ),

          if (current != null && current.total > 0) ...[
            const SizedBox(height: AppSpacing.lg),
            Text(
              '${current.fetched} of ${current.total} songs',
              style: AppTypography.bodySmall.copyWith(
                color: palette.textSecondary,
              ),
              textAlign: TextAlign.center,
            ),
          ],

          const SizedBox(height: AppSpacing.xxl),

          Text(
            'Keep AURIX open until this finishes.',
            style: AppTypography.bodySmall.copyWith(
              color: palette.textTertiary,
            ),
            textAlign: TextAlign.center,
          ),
        ],
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Done
// ---------------------------------------------------------------------------

class _Done extends StatelessWidget {
  const _Done({
    required this.outcome,
    required this.onOpen,
    required this.onImportAnother,
  });

  final ImportOutcome outcome;
  final VoidCallback onOpen;
  final VoidCallback onImportAnother;

  @override
  Widget build(BuildContext context) {
    final palette = context.palette;

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
            color: palette.accent,
          ),
          const SizedBox(height: AppSpacing.lg),
          Text(
            outcome.wasResync
                ? 'Playlist synced'
                : 'Playlist imported successfully',
            style: AppTypography.headlineSmall,
            textAlign: TextAlign.center,
          ),

          const SizedBox(height: AppSpacing.xl),

          // The summary card: cover, name, count, source — what the user needs
          // to confirm the right playlist arrived.
          Container(
            padding: const EdgeInsets.all(AppSpacing.lg),
            decoration: BoxDecoration(
              color: palette.surface,
              borderRadius: AppRadius.card,
              border: Border.all(color: palette.hairline),
            ),
            child: Row(
              children: [
                AppArtwork(
                  imageUrl: outcome.coverUrl,
                  size: 64,
                  seed: outcome.playlistId,
                  fallbackIcon: AurixGlyph.playlist,
                ),
                const SizedBox(width: AppSpacing.lg),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(
                        outcome.name,
                        style: AppTypography.titleMedium,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                      ),
                      const SizedBox(height: AppSpacing.xs),
                      Text(
                        outcome.source.label,
                        style: AppTypography.bodySmall.copyWith(
                          color: palette.accent,
                        ),
                      ),
                      const SizedBox(height: 2),
                      Text(
                        '${outcome.songCount} '
                        '${outcome.songCount == 1 ? 'song' : 'songs'}',
                        style: AppTypography.bodySmall.copyWith(
                          color: palette.textSecondary,
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),

          // Only on a re-sync, and only when something actually changed —
          // "0 added, 0 removed" is noise on a playlist that has not moved.
          if (outcome.wasResync &&
              (outcome.addedCount > 0 || outcome.removedCount > 0)) ...[
            const SizedBox(height: AppSpacing.md),
            Text(
              <String>[
                if (outcome.addedCount > 0) '${outcome.addedCount} added',
                if (outcome.removedCount > 0) '${outcome.removedCount} removed',
              ].join(' · '),
              style: AppTypography.bodySmall.copyWith(
                color: palette.textSecondary,
              ),
              textAlign: TextAlign.center,
            ),
          ],

          const SizedBox(height: AppSpacing.lg),

          Text(
            'These songs are now searchable across AURIX.',
            style: AppTypography.bodySmall.copyWith(
              color: palette.textTertiary,
              height: 1.5,
            ),
            textAlign: TextAlign.center,
          ),

          const Spacer(),

          FilledButton(
            onPressed: onOpen,
            style: FilledButton.styleFrom(minimumSize: const Size(0, 52)),
            child: const Text('Open Playlist'),
          ),
          const SizedBox(height: AppSpacing.sm),
          TextButton(
            onPressed: onImportAnother,
            child: const Text('Import another'),
          ),
        ],
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Already imported
// ---------------------------------------------------------------------------

/// Shown when this user has imported this playlist before.
///
/// Deliberately not an error screen. Re-pasting a link is a reasonable thing to
/// do — usually because the source has changed and the user wants the update —
/// so the two things they might have meant are both offered.
class _AlreadyImported extends StatelessWidget {
  const _AlreadyImported({
    required this.name,
    required this.onOpen,
    required this.onResync,
  });

  final String name;
  final VoidCallback onOpen;
  final VoidCallback onResync;

  @override
  Widget build(BuildContext context) {
    final palette = context.palette;

    return Padding(
      padding: EdgeInsets.symmetric(
        horizontal: context.pageGutter,
        vertical: AppSpacing.xl,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          AurixIcon(AurixGlyph.info, size: 40, color: palette.textSecondary),
          const SizedBox(height: AppSpacing.lg),
          const Text(
            'This playlist is already imported.',
            style: AppTypography.headlineSmall,
            textAlign: TextAlign.center,
          ),
          const SizedBox(height: AppSpacing.md),
          Text(
            '"$name" is already in your library. Sync it to pull in anything '
            'that has changed at the source.',
            style: AppTypography.bodyMedium.copyWith(height: 1.6),
            textAlign: TextAlign.center,
          ),

          const Spacer(),

          FilledButton(
            onPressed: onOpen,
            style: FilledButton.styleFrom(minimumSize: const Size(0, 52)),
            child: const Text('Open Playlist'),
          ),
          const SizedBox(height: AppSpacing.sm),
          OutlinedButton(
            onPressed: onResync,
            style: OutlinedButton.styleFrom(minimumSize: const Size(0, 52)),
            child: const Text('Re-sync Playlist'),
          ),
        ],
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Shared pieces
// ---------------------------------------------------------------------------

class _ErrorCard extends StatelessWidget {
  const _ErrorCard({required this.message});

  final String message;

  @override
  Widget build(BuildContext context) {
    final palette = context.palette;

    return Container(
      padding: const EdgeInsets.all(AppSpacing.lg),
      decoration: BoxDecoration(
        color: palette.surface,
        borderRadius: AppRadius.card,
        border: Border.all(color: palette.hairline),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          AurixIcon(AurixGlyph.warning, size: 18, color: palette.textSecondary),
          const SizedBox(width: AppSpacing.md),
          Expanded(
            child: Text(
              message,
              style: AppTypography.bodySmall.copyWith(height: 1.6),
            ),
          ),
        ],
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
    final palette = context.palette;

    return Container(
      padding: const EdgeInsets.all(AppSpacing.lg),
      decoration: BoxDecoration(
        color: palette.surface,
        borderRadius: AppRadius.card,
        border: Border.all(color: palette.hairline),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          AurixIcon(AurixGlyph.lock, size: 18, color: palette.textTertiary),
          const SizedBox(width: AppSpacing.md),
          Expanded(
            child: Text(
              'Importing copies playlist details — titles, artists, artwork '
              'links and track references. No audio is downloaded or stored. '
              'Imported songs play through an authorised source, and AURIX is '
              'not affiliated with Spotify or YouTube.',
              style: AppTypography.bodySmall.copyWith(
                height: 1.6,
                color: palette.textSecondary,
              ),
            ),
          ),
        ],
      ),
    );
  }
}
