import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/providers/app_providers.dart';
import '../../../core/utils/app_logger.dart';
import '../../../data/import/imported_models.dart';
import '../../../data/import/music_import_provider.dart';
import '../../../data/import/music_import_service.dart';
import '../../../data/import/providers/spotify_import_provider.dart';
import '../../../data/import/providers/youtube_import_provider.dart';
import '../../../data/models/media_source.dart';
import '../../../playback/music_playback_service.dart';
import '../../auth/providers/auth_provider.dart';
import '../../library/providers/library_provider.dart';

/// Every import source AURIX knows about.
///
/// The registry a new provider is added to, and the only place the app names
/// its providers. The import screen renders this list, so a provider appears in
/// the UI by being here — there is no second registration step.
///
/// Order is the order they are offered.
final importProvidersProvider = Provider<List<MusicImportProvider>>((ref) {
  return <MusicImportProvider>[
    SpotifyImportProvider(
      authService: ref.watch(spotifyAuthServiceProvider),
      playlistService: ref.watch(spotifyPlaylistServiceProvider),
    ),
    const YouTubeImportProvider(),
  ];
});

MusicImportProvider? _findProvider(Ref ref, MediaSource source) {
  for (final provider in ref.read(importProvidersProvider)) {
    if (provider.source == source) return provider;
  }
  return null;
}

final importServiceProvider = Provider<MusicImportService>(
  (ref) => MusicImportService(
    library: ref.watch(libraryRepositoryProvider),
    // Both import paths publish to the catalogue, so a song is globally
    // searchable regardless of which one brought it in.
    catalog: ref.watch(catalogRepositoryProvider),
  ),
);

/// Where an import has got to.
enum ImportStage {
  /// Nothing has happened yet.
  idle,

  /// Waiting on the provider's sign-in.
  authenticating,

  /// Reading the account's playlists.
  loadingPlaylists,

  /// The user is choosing what to bring in.
  choosing,

  /// Writing to Firestore.
  importing,

  /// Finished. [ImportState.summary] says what happened.
  done,

  /// Stopped. [ImportState.error] says why.
  failed,
}

class ImportState {
  const ImportState({
    this.stage = ImportStage.idle,
    this.playlists = const [],
    this.selected = const {},
    this.progress,
    this.summary,
    this.error,
  });

  final ImportStage stage;

  /// What the provider offered.
  final List<ImportedPlaylist> playlists;

  /// Source-side ids of the playlists the user has ticked.
  final Set<String> selected;

  final ImportProgress? progress;
  final ImportSummary? summary;
  final String? error;

  bool get isBusy =>
      stage == ImportStage.authenticating ||
      stage == ImportStage.loadingPlaylists ||
      stage == ImportStage.importing;

  ImportState copyWith({
    ImportStage? stage,
    List<ImportedPlaylist>? playlists,
    Set<String>? selected,
    ImportProgress? progress,
    ImportSummary? summary,
    String? error,
    bool clearError = false,
    bool clearProgress = false,
  }) => ImportState(
    stage: stage ?? this.stage,
    playlists: playlists ?? this.playlists,
    selected: selected ?? this.selected,
    progress: clearProgress ? null : (progress ?? this.progress),
    summary: summary ?? this.summary,
    error: clearError ? null : (error ?? this.error),
  );
}

/// Drives one import, from sign-in to summary.
///
/// Keyed by [MediaSource], so two providers cannot share a controller and an
/// abandoned Spotify import cannot leave state in front of a YouTube one.
class ImportController extends FamilyNotifier<ImportState, MediaSource> {
  MusicImportProvider? _provider;

  @override
  ImportState build(MediaSource arg) {
    _provider = _findProvider(ref, arg);

    // Disconnected when the screen goes away, whatever route it took to get
    // there — finished, failed, or the user pressing Back mid-import. An
    // import that leaves a live provider session behind has quietly turned
    // into a connected account, which is exactly what this architecture is
    // arranged to avoid.
    ref.onDispose(() => unawaited(_disconnectQuietly()));

    return const ImportState();
  }

  /// Signs in and loads the account's playlists.
  Future<void> connect() async {
    final provider = _provider;
    if (provider == null) return;

    state = state.copyWith(
      stage: ImportStage.authenticating,
      clearError: true,
    );

    try {
      await provider.authenticate();
    } on ImportFailure catch (failure) {
      // Cancelling is not a failure — the user changed their mind, and an error
      // banner for that is noise.
      state = failure.kind == ImportFailureKind.cancelled
          ? state.copyWith(stage: ImportStage.idle)
          : state.copyWith(stage: ImportStage.failed, error: failure.message);
      return;
    }

    state = state.copyWith(stage: ImportStage.loadingPlaylists);

    try {
      final playlists = await provider.getPlaylists();
      state = state.copyWith(
        stage: ImportStage.choosing,
        playlists: playlists,
        // Nothing pre-selected. Ticking twelve playlists by default and letting
        // the user untick is how someone ends up importing a library they did
        // not want.
        selected: const <String>{},
      );
    } on ImportFailure catch (failure) {
      state = state.copyWith(stage: ImportStage.failed, error: failure.message);
    } on Object catch (error, stackTrace) {
      AppLogger.error(
        'Loading playlists failed',
        scope: 'import',
        error: error,
        stackTrace: stackTrace,
      );
      state = state.copyWith(
        stage: ImportStage.failed,
        error: 'Could not read that account\'s playlists.',
      );
    }
  }

  void toggle(String playlistId) {
    final next = <String>{...state.selected};
    if (!next.remove(playlistId)) next.add(playlistId);
    state = state.copyWith(selected: next);
  }

  void selectAll() => state = state.copyWith(
    selected: state.playlists.map((p) => p.id).toSet(),
  );

  void selectNone() => state = state.copyWith(selected: const <String>{});

  /// Imports the ticked playlists.
  Future<void> importSelected() async {
    final provider = _provider;
    final uid = ref.read(currentUserIdProvider);
    if (provider == null || uid == null || state.selected.isEmpty) return;

    final chosen = state.playlists
        .where((playlist) => state.selected.contains(playlist.id))
        .toList(growable: false);

    state = state.copyWith(stage: ImportStage.importing, clearError: true);

    try {
      final summary = await ref.read(importServiceProvider).importPlaylists(
        uid: uid,
        provider: provider,
        playlists: chosen,
        onProgress: (progress) => state = state.copyWith(progress: progress),
      );

      state = state.copyWith(
        stage: ImportStage.done,
        summary: summary,
        clearProgress: true,
      );

      // The library streams are already live and will carry the new playlists
      // in on their own. Invalidated anyway so a screen that was disposed while
      // the import ran re-subscribes on its next build rather than showing a
      // snapshot from before.
      ref.invalidate(userPlaylistsProvider);

      // Disconnected on success, here rather than only in `onDispose`, so the
      // summary screen is already showing a disconnected state when the user
      // reads "Spotify has been disconnected".
      await _disconnectQuietly();
    } on Object catch (error, stackTrace) {
      AppLogger.error(
        'Import failed',
        scope: 'import',
        error: error,
        stackTrace: stackTrace,
      );
      state = state.copyWith(
        stage: ImportStage.failed,
        error: error is ImportFailure
            ? error.message
            : 'The import did not finish.',
        clearProgress: true,
      );
    }
  }

  /// Starts over, keeping the provider session so the user does not have to
  /// authorize twice.
  void reset() => state = const ImportState();

  /// Ends the provider session.
  ///
  /// ## The one exception, and why it is here
  ///
  /// Spotify is currently AURIX's playback provider for full tracks: App Remote
  /// and Spotify Connect both require a live Spotify authorization. Clearing it
  /// while a song is playing would stop the music, from a screen about
  /// importing — which would read as a bug rather than as a security measure.
  ///
  /// So a Spotify import session is left in place while Spotify playback is
  /// active. This is the last coupling between the import path and the playback
  /// path, and it disappears the moment playback moves to a provider that is
  /// not Spotify: `MusicPlaybackService` is the seam that makes that a change
  /// to one file.
  Future<void> _disconnectQuietly() async {
    final provider = _provider;
    if (provider == null) return;

    if (provider.source == MediaSource.spotify && _spotifyIsPlaying) {
      AppLogger.info(
        'Keeping the Spotify session: it is the active playback provider. '
        'It will end when playback moves to another provider or the app '
        'restarts.',
        scope: 'import',
      );
      return;
    }

    try {
      await provider.disconnect();
    } on Object catch (error) {
      // Best effort. A failure to revoke is worth a log and nothing more —
      // there is no user action that would help, and the token expires anyway.
      AppLogger.warn('Disconnect failed', scope: 'import', error: error);
    }
  }

  bool get _spotifyIsPlaying {
    try {
      return ref.read(musicPlaybackServiceProvider).isUsingSpotify;
    } on Object {
      // The playback layer may not be constructed at all — on web, in a test.
      // Treated as "not playing", which makes the disconnect happen.
      return false;
    }
  }
}

final importControllerProvider =
    NotifierProvider.family<ImportController, ImportState, MediaSource>(
      ImportController.new,
    );
