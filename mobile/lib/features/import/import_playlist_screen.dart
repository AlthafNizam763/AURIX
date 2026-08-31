import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/providers/app_providers.dart';
import '../../core/router/route_names.dart';
import '../../core/theme/app_dimens.dart';
import '../../core/theme/app_typography.dart';
import '../../core/theme/aurix_palette.dart';
import '../../core/utils/responsive.dart';
import '../../data/import/playlist_url.dart';
import '../../data/models/media_source.dart';
import '../../data/services/api/api_music_service.dart';
import '../../shared/widgets/icons/aurix_glyphs.dart';
import '../../shared/widgets/icons/aurix_icon.dart';
import '../../shared/widgets/media/app_artwork.dart';
import 'providers/playlist_import_provider.dart';

/// AURIX → Import Playlist.
///
/// One screen, four states — paste, working, connect, done — rather than four
/// routes. The user is inside a single operation the whole time, and a route
/// stack would let them press Back into the middle of it.
///
/// ## The connect state is not an error state
///
/// The screen a user reaches when Spotify is not connected shows the provider,
/// a sentence, and a button. It does not show a red banner, because nothing has
/// gone wrong: the import needs a permission it does not have yet, and pressing
/// the button both grants it and finishes the import. That is the difference
/// §10 asks for between "Contents unavailable" and "Spotify authorization is
/// required. [ Connect Spotify ]".
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
    final controller = ref.read(playlistLinkImportControllerProvider.notifier);

    return PopScope(
      // Back is blocked only while the import is in flight. The write happens
      // on the server and would finish regardless, but leaving mid-import and
      // arriving back at a screen with no result is worse than waiting.
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
            LinkImportStage.running => const _Working(),
            LinkImportStage.needsConnection => _NeedsConnection(
              state: state,
              onConnect: controller.connectAndRetry,
              onCancel: controller.reset,
            ),
            LinkImportStage.done => _Done(
              result: state.outcome!,
              onOpen: () => _openPlaylist(state.outcome!.playlistId),
              onImportAnother: () {
                _field.clear();
                controller.reset();
              },
            ),
            LinkImportStage.idle || LinkImportStage.failed => _PasteForm(
              state: state,
              field: _field,
              onChanged: controller.onUrlChanged,
              onPaste: _pasteFromClipboard,
              onImport: controller.import,
              onRetry: controller.retry,
              onConnect: controller.connect,
              onDisconnect: controller.disconnect,
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

class _PasteForm extends ConsumerWidget {
  const _PasteForm({
    required this.state,
    required this.field,
    required this.onChanged,
    required this.onPaste,
    required this.onImport,
    required this.onRetry,
    required this.onConnect,
    required this.onDisconnect,
  });

  final LinkImportState state;
  final TextEditingController field;
  final ValueChanged<String> onChanged;
  final Future<void> Function() onPaste;
  final VoidCallback onImport;
  final VoidCallback onRetry;
  final void Function(MediaSource) onConnect;
  final void Function(MediaSource) onDisconnect;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final palette = context.palette;
    final connections = ref.watch(musicConnectionsProvider);

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

        // The connection rows, above the field.
        //
        // Above rather than below because they are a precondition for what the
        // field does, and because a user who knows they need to connect should
        // not have to fail an import to discover the button. A user who does
        // not need to connect can ignore them entirely — nothing here blocks
        // the field.
        connections.when(
          loading: () => const _ConnectionsPlaceholder(),
          // A failure to read connection status must not stop an import. The
          // server decides whether a connection is needed, and it will say so.
          error: (_, _) => const SizedBox.shrink(),
          data: (rows) => Column(
            children: [
              for (final row in rows)
                Padding(
                  padding: const EdgeInsets.only(bottom: AppSpacing.sm),
                  child: _ConnectionRow(
                    connection: row,
                    busy: state.connecting,
                    onConnect: () => onConnect(row.provider),
                    onDisconnect: () => onDisconnect(row.provider),
                  ),
                ),
            ],
          ),
        ),

        const SizedBox(height: AppSpacing.lg),

        TextField(
          controller: field,
          onChanged: onChanged,
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
              icon: const AurixIcon(AurixGlyph.copy, size: 18),
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

        // A real failure — the import ran and did not finish — gets the full
        // treatment, and the message is the server's own words.
        if (state.stage == LinkImportStage.failed && state.error != null) ...[
          const SizedBox(height: AppSpacing.lg),
          _ErrorCard(
            message: state.error!,
            onRetry: state.canRetry ? onRetry : null,
          ),
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

// ---------------------------------------------------------------------------
// Connection rows
// ---------------------------------------------------------------------------

/// One provider's connection state, with the button that changes it.
///
/// ```
/// Spotify           ✓ Connected as althaf     [ Disconnect ]
/// YouTube Music     Connect for private…      [ Connect ]
/// ```
class _ConnectionRow extends StatelessWidget {
  const _ConnectionRow({
    required this.connection,
    required this.busy,
    required this.onConnect,
    required this.onDisconnect,
  });

  final MusicConnection connection;
  final bool busy;
  final VoidCallback onConnect;
  final VoidCallback onDisconnect;

  @override
  Widget build(BuildContext context) {
    final palette = context.palette;
    final connected = connection.connected;

    return Container(
      padding: const EdgeInsets.symmetric(
        horizontal: AppSpacing.lg,
        vertical: AppSpacing.md,
      ),
      decoration: BoxDecoration(
        color: palette.surface,
        borderRadius: AppRadius.card,
        border: Border.all(color: palette.hairline),
      ),
      child: Row(
        children: [
          AurixIcon(
            connected ? AurixGlyph.checkCircle : AurixGlyph.musicNote,
            size: 20,
            color: connected ? palette.accent : palette.textTertiary,
          ),
          const SizedBox(width: AppSpacing.md),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  connection.provider.label,
                  style: AppTypography.titleSmall,
                ),
                const SizedBox(height: 2),
                Text(
                  connection.subtitle,
                  style: AppTypography.bodySmall.copyWith(
                    color: connected ? palette.accent : palette.textSecondary,
                  ),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ],
            ),
          ),
          const SizedBox(width: AppSpacing.sm),

          // A provider this deployment holds no credentials for gets no button
          // at all. Offering one that opens a browser and fails is worse than
          // saying plainly that it is unavailable here.
          if (!connection.configured)
            const SizedBox.shrink()
          else if (connected)
            TextButton(
              onPressed: busy ? null : onDisconnect,
              child: const Text('Disconnect'),
            )
          else
            OutlinedButton(
              onPressed: busy ? null : onConnect,
              child: Text('Connect ${connection.provider.label.split(' ').first}'),
            ),
        ],
      ),
    );
  }
}

/// Placeholder while connection status loads.
///
/// Two rows the size of the real ones, so the field does not jump down the
/// screen the moment they arrive under the user's thumb.
class _ConnectionsPlaceholder extends StatelessWidget {
  const _ConnectionsPlaceholder();

  @override
  Widget build(BuildContext context) {
    final palette = context.palette;
    return Column(
      children: [
        for (var i = 0; i < 2; i++)
          Container(
            height: 64,
            margin: const EdgeInsets.only(bottom: AppSpacing.sm),
            decoration: BoxDecoration(
              color: palette.surface,
              borderRadius: AppRadius.card,
              border: Border.all(color: palette.hairline),
            ),
          ),
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
          const SizedBox(height: AppSpacing.sm),
          // Said here because it is the single most common way an import fails,
          // and finding out afterwards is a wasted round trip and a confusing
          // refusal. Spotify serves a playlist's songs only to its owner or a
          // collaborator; nothing AURIX can do changes that.
          Text(
            'A Spotify playlist can only be imported by the account that owns '
            'it or collaborates on it — that is Spotify’s rule, not AURIX’s.',
            style: AppTypography.bodySmall.copyWith(
              color: palette.textTertiary,
              height: 1.5,
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
  const _Working();

  @override
  Widget build(BuildContext context) {
    final palette = context.palette;

    return Padding(
      padding: EdgeInsets.symmetric(horizontal: context.pageGutter),
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const Text(
            'Importing playlist…',
            style: AppTypography.headlineSmall,
            textAlign: TextAlign.center,
          ),

          const SizedBox(height: AppSpacing.xl),

          ClipRRect(
            borderRadius: BorderRadius.circular(AppRadius.pill),
            child: LinearProgressIndicator(
              // Indeterminate, and honestly so. The paging now happens on the
              // server, inside one request, so the app has nothing to report a
              // fraction from. A bar that invented one would be a lie, and a
              // bar stuck at zero reads as a hang.
              minHeight: 6,
              backgroundColor: palette.surfaceElevated,
            ),
          ),

          const SizedBox(height: AppSpacing.xxl),

          Text(
            'Reading the playlist and matching songs. A large playlist can '
            'take a few moments.',
            style: AppTypography.bodySmall.copyWith(
              color: palette.textTertiary,
              height: 1.5,
            ),
            textAlign: TextAlign.center,
          ),
        ],
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Connect
// ---------------------------------------------------------------------------

/// The state §10 exists for.
///
/// The import stopped because a provider is not connected. There is no red
/// banner and no apology — there is the provider's name, the server's own
/// explanation, and one button that both connects and finishes the import.
class _NeedsConnection extends StatelessWidget {
  const _NeedsConnection({
    required this.state,
    required this.onConnect,
    required this.onCancel,
  });

  final LinkImportState state;
  final VoidCallback onConnect;
  final VoidCallback onCancel;

  @override
  Widget build(BuildContext context) {
    final palette = context.palette;
    final provider = state.connectProvider ?? MediaSource.spotify;
    final name = provider.label;

    return Padding(
      padding: EdgeInsets.symmetric(
        horizontal: context.pageGutter,
        vertical: AppSpacing.xl,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const Spacer(),

          AurixIcon(AurixGlyph.lock, size: 40, color: palette.accent),
          const SizedBox(height: AppSpacing.lg),

          Text(
            state.problem == ImportProblem.reconnectRequired
                ? 'Reconnect $name'
                : '$name authorization is required',
            style: AppTypography.headlineSmall,
            textAlign: TextAlign.center,
          ),

          const SizedBox(height: AppSpacing.md),

          Text(
            state.error ??
                'AURIX needs your permission to read this playlist from $name.',
            style: AppTypography.bodyMedium.copyWith(height: 1.6),
            textAlign: TextAlign.center,
          ),

          const SizedBox(height: AppSpacing.lg),

          Text(
            'You will sign in on $name’s own page. AURIX never sees your '
            '$name password, and reads playlists only.',
            style: AppTypography.bodySmall.copyWith(
              color: palette.textTertiary,
              height: 1.5,
            ),
            textAlign: TextAlign.center,
          ),

          const Spacer(),

          FilledButton(
            onPressed: state.connecting ? null : onConnect,
            style: FilledButton.styleFrom(minimumSize: const Size(0, 52)),
            child: state.connecting
                ? const SizedBox(
                    height: 20,
                    width: 20,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : Text(
                    state.problem == ImportProblem.reconnectRequired
                        ? 'Reconnect ${name.split(' ').first}'
                        : 'Connect ${name.split(' ').first}',
                  ),
          ),
          const SizedBox(height: AppSpacing.sm),
          TextButton(
            onPressed: state.connecting ? null : onCancel,
            child: const Text('Cancel'),
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
    required this.result,
    required this.onOpen,
    required this.onImportAnother,
  });

  final ImportedPlaylistResult result;
  final VoidCallback onOpen;
  final VoidCallback onImportAnother;

  @override
  Widget build(BuildContext context) {
    final palette = context.palette;
    final caveat = result.caveat;

    return Padding(
      padding: EdgeInsets.symmetric(
        horizontal: context.pageGutter,
        vertical: AppSpacing.xl,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          AurixIcon(AurixGlyph.checkCircle, size: 48, color: palette.accent),
          const SizedBox(height: AppSpacing.lg),
          Text(
            // A second import of the same playlist is an *update*, not a
            // duplicate — the document id is derived from the source, so there
            // is exactly one of it either way. Saying "updated" is what makes
            // that legible rather than surprising.
            result.created ? 'Playlist imported successfully' : 'Playlist updated',
            style: AppTypography.headlineSmall,
            textAlign: TextAlign.center,
          ),

          const SizedBox(height: AppSpacing.xl),

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
                  imageUrl: result.coverUrl,
                  size: 64,
                  seed: result.playlistId,
                  fallbackIcon: AurixGlyph.playlist,
                ),
                const SizedBox(width: AppSpacing.lg),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(
                        result.name,
                        style: AppTypography.titleMedium,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                      ),
                      const SizedBox(height: AppSpacing.xs),
                      Text(
                        '${result.trackCount} '
                        '${result.trackCount == 1 ? 'song' : 'songs'}',
                        style: AppTypography.bodySmall.copyWith(
                          color: palette.textSecondary,
                        ),
                      ),
                      if (result.songsCreated > 0) ...[
                        const SizedBox(height: 2),
                        Text(
                          '${result.songsCreated} new to AURIX',
                          style: AppTypography.bodySmall.copyWith(
                            color: palette.accent,
                          ),
                        ),
                      ],
                    ],
                  ),
                ),
              ],
            ),
          ),

          // Said out loud rather than swallowed. A playlist of 40 that imported
          // 37 must say so — silently producing 37 is how a library drifts out
          // of agreement with its source without anyone noticing.
          if (caveat != null) ...[
            const SizedBox(height: AppSpacing.md),
            Text(
              caveat,
              style: AppTypography.bodySmall.copyWith(
                color: palette.textSecondary,
                height: 1.5,
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
// Shared pieces
// ---------------------------------------------------------------------------

class _ErrorCard extends StatelessWidget {
  const _ErrorCard({required this.message, this.onRetry});

  final String message;

  /// Null when retrying cannot help.
  ///
  /// The case that matters: a Spotify playlist owned by another account will
  /// refuse every retry for ever, so offering the button would be a lie about
  /// what the user can do.
  final VoidCallback? onRetry;

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
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              AurixIcon(
                AurixGlyph.warning,
                size: 18,
                color: palette.textSecondary,
              ),
              const SizedBox(width: AppSpacing.md),
              Expanded(
                child: Text(
                  message,
                  style: AppTypography.bodySmall.copyWith(height: 1.6),
                ),
              ),
            ],
          ),
          if (onRetry != null) ...[
            const SizedBox(height: AppSpacing.sm),
            Align(
              alignment: Alignment.centerRight,
              child: TextButton(
                onPressed: onRetry,
                child: const Text('Try again'),
              ),
            ),
          ],
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
