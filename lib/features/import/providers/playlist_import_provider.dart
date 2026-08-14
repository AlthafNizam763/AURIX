import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/providers/app_providers.dart';
import '../../../core/utils/app_logger.dart';
import '../../../data/import/music_import_provider.dart';
import '../../../data/import/playlist_import_service.dart';
import '../../../data/import/playlist_url.dart';
import '../../../data/models/playlist.dart';
import '../../auth/providers/auth_provider.dart';
import '../../library/providers/library_provider.dart';

/// Where the paste-a-link import has got to.
enum LinkImportStage {
  /// Waiting for a link.
  idle,

  /// Working. [LinkImportState.step] says which phase.
  running,

  /// This playlist is already in the shared AURIX catalogue — imported by this
  /// user or by another one. Not an error: the UI offers "Open playlist" and
  /// "Sync".
  duplicate,

  /// Finished. [LinkImportState.outcome] says what happened.
  done,

  /// Stopped. [LinkImportState.error] says why, in words for a person.
  failed,
}

class LinkImportState {
  const LinkImportState({
    this.stage = LinkImportStage.idle,
    this.url = '',
    this.detected = PlaylistSource.unknown,
    this.linkProblem,
    this.step,
    this.outcome,
    this.duplicateOf,
    this.error,
  });

  final LinkImportStage stage;

  /// What is currently in the text field.
  final String url;

  /// The service the current text points at, updated as the user types. Drives
  /// the source badge beside the field.
  final PlaylistSource detected;

  /// Why the current text is not usable, or null when it is (or is empty).
  ///
  /// Shown as a hint under the field rather than as an error banner: the user
  /// is mid-paste, and a red box for a half-typed URL is noise.
  final PlaylistLinkProblem? linkProblem;

  final ImportStep? step;
  final ImportOutcome? outcome;

  /// The playlist already in the shared catalogue, when [stage] is
  /// [LinkImportStage.duplicate].
  ///
  /// It may have been imported by somebody else entirely — the catalogue is
  /// shared, so "already imported" is a fact about AURIX rather than about this
  /// account. Its `importedBy` is what the screen credits.
  final Playlist? duplicateOf;

  final String? error;

  bool get isBusy => stage == LinkImportStage.running;

  /// True when the button should be enabled.
  bool get canImport =>
      !isBusy && url.trim().isNotEmpty && linkProblem == null;

  LinkImportState copyWith({
    LinkImportStage? stage,
    String? url,
    PlaylistSource? detected,
    PlaylistLinkProblem? linkProblem,
    ImportStep? step,
    ImportOutcome? outcome,
    Playlist? duplicateOf,
    String? error,
    bool clearLinkProblem = false,
    bool clearError = false,
    bool clearStep = false,
    bool clearDuplicate = false,
  }) => LinkImportState(
    stage: stage ?? this.stage,
    url: url ?? this.url,
    detected: detected ?? this.detected,
    linkProblem: clearLinkProblem ? null : (linkProblem ?? this.linkProblem),
    step: clearStep ? null : (step ?? this.step),
    outcome: outcome ?? this.outcome,
    duplicateOf: clearDuplicate ? null : (duplicateOf ?? this.duplicateOf),
    error: clearError ? null : (error ?? this.error),
  );
}

/// Drives one paste-a-link import.
///
/// ## Where the work is, and where it is not
///
/// Nothing here fetches, normalises or writes. [PlaylistImportService] does all
/// of that; this holds the state a screen renders and translates one exception
/// type into one stage. The split is what lets the whole import pipeline be
/// tested without a widget, and the whole screen be tested without a network.
///
/// ## Validation as you type
///
/// [onUrlChanged] parses on every keystroke. That is cheap — the parser is
/// synchronous string work with no I/O — and it means the user learns that a
/// link is an album rather than a playlist before pressing a button, instead of
/// after a round trip.
class PlaylistLinkImportController extends Notifier<LinkImportState> {
  /// Set when Riverpod disposes this notifier.
  ///
  /// The import runs against Firestore and is unaffected by the screen closing,
  /// but its progress callback and its result would both try to write to a
  /// disposed notifier, which throws. Riverpod 2 exposes no `ref.mounted`, so
  /// the flag is kept by hand — the alternative is an exception on every import
  /// the user navigates away from, which is the common case rather than a rare
  /// one.
  bool _disposed = false;

  @override
  LinkImportState build() {
    ref.onDispose(() => _disposed = true);
    return const LinkImportState();
  }

  /// Called on every keystroke and on paste.
  void onUrlChanged(String raw) {
    final trimmed = raw.trim();

    if (trimmed.isEmpty) {
      state = state.copyWith(
        url: '',
        detected: PlaylistSource.unknown,
        clearLinkProblem: true,
        clearError: true,
      );
      return;
    }

    final result = PlaylistUrlParser.parse(trimmed);

    state = state.copyWith(
      url: raw,
      detected: PlaylistUrlParser.detect(trimmed),
      linkProblem: result is PlaylistLinkRejected ? result.problem : null,
      clearLinkProblem: result is PlaylistLinkParsed,
      clearError: true,
      // A new link clears the previous result, so the screen cannot show last
      // import's success card above this import's field.
      stage: LinkImportStage.idle,
      clearDuplicate: true,
      clearStep: true,
    );
  }

  /// Runs the import for whatever is in the field.
  Future<void> import({bool allowResync = false}) async {
    final uid = ref.read(currentUserIdProvider);
    if (uid == null) {
      state = state.copyWith(
        stage: LinkImportStage.failed,
        error: 'Sign in to import a playlist.',
      );
      return;
    }

    // Denormalised onto the shared playlist document so a search result can
    // credit the importer without a profile read per row — and so it still
    // renders for users who cannot read this account's profile, which is all of
    // them: profiles are private.
    final importedBy = ref.read(currentUserProvider)?.displayName;

    if (!state.canImport && !allowResync) return;

    state = state.copyWith(
      stage: LinkImportStage.running,
      clearError: true,
      clearDuplicate: true,
      step: const ImportStep(phase: ImportPhase.detecting),
    );

    try {
      final outcome = await ref
          .read(playlistImportServiceProvider)
          .importFromUrl(
            uid: uid,
            url: state.url,
            importedBy: importedBy,
            allowResync: allowResync,
            onProgress: (step) {
              // The controller can outlive the screen if the user navigates
              // away mid-import; Riverpod disposes it, and writing to a
              // disposed notifier throws. The import itself is unaffected —
              // it is already running against Firestore.
              if (_disposed) return;
              state = state.copyWith(step: step);
            },
          );

      if (_disposed) return;

      state = state.copyWith(
        stage: LinkImportStage.done,
        outcome: outcome,
        clearStep: true,
      );

      // The library streams are live and will carry the new playlist in on
      // their own. Invalidated anyway so a screen disposed while the import ran
      // re-subscribes on its next build rather than showing a stale snapshot.
      ref.invalidate(userPlaylistsProvider);
    } on DuplicatePlaylist catch (duplicate) {
      if (_disposed) return;
      // Deliberately not an error stage: the user is offered a choice rather
      // than told off.
      state = state.copyWith(
        stage: LinkImportStage.duplicate,
        duplicateOf: duplicate.existing,
        clearStep: true,
      );
    } on ImportFailure catch (failure) {
      if (_disposed) return;
      state = failure.kind == ImportFailureKind.cancelled
          // Backing out of the Spotify consent screen is a decision, not a
          // failure. An error banner for it would be noise.
          ? state.copyWith(stage: LinkImportStage.idle, clearStep: true)
          : state.copyWith(
              stage: LinkImportStage.failed,
              error: failure.message,
              clearStep: true,
            );
    } on Object catch (error, stackTrace) {
      if (_disposed) return;
      AppLogger.error(
        'Link import failed',
        scope: 'import',
        error: error,
        stackTrace: stackTrace,
      );
      // The last line of defence for requirement "never show raw exceptions".
      // Anything that reaches here is a bug, and the user gets a sentence
      // rather than a stack trace.
      state = state.copyWith(
        stage: LinkImportStage.failed,
        error: 'The import did not finish. Please try again.',
        clearStep: true,
      );
    }
  }

  /// Re-runs the import for a playlist already in the library.
  Future<void> resync() => import(allowResync: true);

  /// Clears everything back to an empty field.
  void reset() => state = const LinkImportState();
}

final playlistLinkImportControllerProvider =
    NotifierProvider<PlaylistLinkImportController, LinkImportState>(
      PlaylistLinkImportController.new,
    );

/// Re-syncs a playlist opened from the library, rather than from a pasted link.
///
/// Separate from the controller above because it starts from a [Playlist]
/// record instead of from text, and because it is invoked from the playlist
/// screen's overflow menu where there is no field to validate.
final resyncPlaylistProvider =
    Provider<Future<ImportOutcome> Function(Playlist)>((ref) {
  return (playlist) async {
    final uid = ref.read(currentUserIdProvider);
    if (uid == null) {
      throw const ImportFailure(ImportFailureKind.authFailed);
    }
    final outcome = await ref
        .read(playlistImportServiceProvider)
        .resync(
          uid: uid,
          playlist: playlist,
          // Only used if the catalogue entry has gone and the sync recreates
          // it. A sync of an existing entry never rewrites its provenance.
          importedBy: ref.read(currentUserProvider)?.displayName,
        );
    ref.invalidate(userPlaylistsProvider);
    return outcome;
  };
});
