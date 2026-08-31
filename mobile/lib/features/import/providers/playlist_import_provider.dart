import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/network/api_exception.dart';
import '../../../core/providers/app_providers.dart';
import '../../../core/utils/app_logger.dart';
import '../../../data/import/playlist_url.dart';
import '../../../data/models/media_source.dart';
import '../../../data/models/playlist.dart';
import '../../../data/services/api/api_music_service.dart';
import '../../auth/providers/auth_provider.dart';
import '../../library/providers/library_provider.dart';

/// Where the paste-a-link import has got to.
enum LinkImportStage {
  /// Waiting for a link.
  idle,

  /// Working.
  running,

  /// The provider needs connecting before this link can be read.
  ///
  /// **Not an error stage**, and that is the point of it existing. The user has
  /// done nothing wrong and there is nothing to fix — there is a button to
  /// press. The screen renders "Connect Spotify" rather than a red banner, and
  /// the import resumes by itself once the connection lands.
  needsConnection,

  /// Finished.
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
    this.outcome,
    this.error,
    this.problem,
    this.connectProvider,
    this.connecting = false,
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

  /// What the import produced, when [stage] is [LinkImportStage.done].
  final ImportedPlaylistResult? outcome;

  /// The sentence to show, when [stage] is [LinkImportStage.failed].
  ///
  /// Written by the API, which writes its messages to be read by a person —
  /// including the one that matters most here, the explanation that a Spotify
  /// playlist belongs to somebody else's account.
  final String? error;

  /// What went wrong, as something to branch on.
  final ImportProblem? problem;

  /// Which provider to offer a Connect button for, when [stage] is
  /// [LinkImportStage.needsConnection].
  final MediaSource? connectProvider;

  /// True while the consent browser is open.
  final bool connecting;

  bool get isBusy => stage == LinkImportStage.running || connecting;

  /// True when the button should be enabled.
  bool get canImport => !isBusy && url.trim().isNotEmpty && linkProblem == null;

  /// True when the failure is worth offering a plain "Try again" for.
  ///
  /// Deliberately false for [ImportProblem.forbidden]: a Spotify playlist that
  /// belongs to another account will refuse every retry for ever, and a button
  /// that cannot work is worse than no button.
  bool get canRetry =>
      stage == LinkImportStage.failed &&
      problem != ImportProblem.forbidden &&
      problem != ImportProblem.badLink &&
      problem != ImportProblem.notConfigured;

  LinkImportState copyWith({
    LinkImportStage? stage,
    String? url,
    PlaylistSource? detected,
    PlaylistLinkProblem? linkProblem,
    ImportedPlaylistResult? outcome,
    String? error,
    ImportProblem? problem,
    MediaSource? connectProvider,
    bool? connecting,
    bool clearLinkProblem = false,
    bool clearError = false,
    bool clearOutcome = false,
  }) => LinkImportState(
    stage: stage ?? this.stage,
    url: url ?? this.url,
    detected: detected ?? this.detected,
    linkProblem: clearLinkProblem ? null : (linkProblem ?? this.linkProblem),
    outcome: clearOutcome ? null : (outcome ?? this.outcome),
    error: clearError ? null : (error ?? this.error),
    problem: clearError ? null : (problem ?? this.problem),
    connectProvider: connectProvider ?? this.connectProvider,
    connecting: connecting ?? this.connecting,
  );
}

/// Drives one paste-a-link import.
///
/// ## What this used to do, and does not any more
///
/// It used to orchestrate the whole import: run a Spotify PKCE flow, page the
/// Web API, normalise the results and write them. All of that is now one
/// `POST /music/import`, and this holds the state a screen renders and turns one
/// error code into one stage.
///
/// The reason is requirement §11 — no client secret and no provider token in
/// the app — but the effect worth noting is on *errors*. The server knows why a
/// playlist could not be read, and writes a sentence saying so. This class no
/// longer guesses.
///
/// ## Connect, then continue
///
/// [import] arriving at `provider_auth_required` does not fail. It moves to
/// [LinkImportStage.needsConnection] with the provider to connect, and
/// [connectAndRetry] runs the consent flow and re-runs the import. From the
/// user's side that is: paste, press Import, approve, done — the flow §2 asks
/// for, with no "authorize first" step for a link that may not have needed one.
class PlaylistLinkImportController extends Notifier<LinkImportState> {
  /// Set when Riverpod disposes this notifier.
  ///
  /// The import runs on the server and is unaffected by the screen closing, but
  /// its result would try to write to a disposed notifier, which throws.
  /// Riverpod 2 exposes no `ref.mounted`, so the flag is kept by hand.
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
        stage: LinkImportStage.idle,
        clearLinkProblem: true,
        clearError: true,
        clearOutcome: true,
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
      // A new link clears the previous result, so the screen cannot show the
      // last import's success card above this import's field.
      stage: LinkImportStage.idle,
      clearOutcome: true,
    );
  }

  /// Runs the import for whatever is in the field.
  Future<void> import() async {
    if (ref.read(currentUserIdProvider) == null) {
      state = state.copyWith(
        stage: LinkImportStage.failed,
        error: 'Sign in to import a playlist.',
        problem: ImportProblem.unknown,
      );
      return;
    }

    if (!state.canImport) return;

    state = state.copyWith(
      stage: LinkImportStage.running,
      clearError: true,
      clearOutcome: true,
    );

    await _run();
  }

  /// Connects the provider the last attempt asked for, then imports again.
  ///
  /// One press. The user asked to import a playlist, not to manage an OAuth
  /// connection, so the connection is a step inside that request rather than a
  /// separate errand they have to remember to come back from.
  Future<void> connectAndRetry() async {
    final provider = state.connectProvider;
    if (provider == null) return;

    state = state.copyWith(connecting: true, clearError: true);

    try {
      await ref.read(apiMusicServiceProvider).connect(provider);
    } on MusicConnectCancelled {
      // Backing out of a consent screen is a decision, not a failure. Back to
      // the same offer, with nothing to apologise for.
      if (_disposed) return;
      state = state.copyWith(connecting: false, stage: LinkImportStage.needsConnection);
      return;
    } on MusicConnectFailed catch (failure) {
      if (_disposed) return;
      state = state.copyWith(
        connecting: false,
        stage: LinkImportStage.failed,
        error: failure.message,
        problem: ImportProblem.unknown,
      );
      return;
    } on ApiException catch (error) {
      if (_disposed) return;
      state = state.copyWith(
        connecting: false,
        stage: LinkImportStage.failed,
        error: error.message,
        problem: ImportProblem.of(error),
      );
      return;
    }

    if (_disposed) return;

    // The row above the field says "Connected" from here on.
    ref.invalidate(musicConnectionsProvider);

    state = state.copyWith(connecting: false, stage: LinkImportStage.running);
    await _run();
  }

  /// Connects a provider from the row, outside an import.
  ///
  /// For the user who opens the screen and connects Spotify before pasting
  /// anything — which is the other half of §9, and the reason the rows carry
  /// their own buttons rather than only appearing after a failure.
  Future<void> connect(MediaSource provider) async {
    state = state.copyWith(connecting: true, clearError: true);
    try {
      await ref.read(apiMusicServiceProvider).connect(provider);
      ref.invalidate(musicConnectionsProvider);
      if (!_disposed) state = state.copyWith(connecting: false);
    } on MusicConnectCancelled {
      if (!_disposed) state = state.copyWith(connecting: false);
    } on Object catch (error) {
      if (_disposed) return;
      state = state.copyWith(
        connecting: false,
        stage: LinkImportStage.failed,
        error: error is MusicConnectFailed
            ? error.message
            : error is ApiException
            ? error.message
            : 'That connection did not complete. Please try again.',
        problem: ImportProblem.unknown,
      );
    }
  }

  /// Forgets a provider connection.
  Future<void> disconnect(MediaSource provider) async {
    try {
      await ref.read(apiMusicServiceProvider).disconnect(provider);
    } on ApiException catch (error) {
      AppLogger.warn('Could not disconnect ${provider.label}: ${error.message}',
          scope: 'import');
    }
    ref.invalidate(musicConnectionsProvider);
  }

  /// Retries the last import.
  Future<void> retry() => import();

  /// Clears everything back to an empty field.
  void reset() => state = const LinkImportState();

  // ---- The call itself ---------------------------------------------------

  Future<void> _run() async {
    try {
      final result = await ref
          .read(apiMusicServiceProvider)
          .importFromUrl(state.url);

      if (_disposed) return;

      state = state.copyWith(stage: LinkImportStage.done, outcome: result);

      // The library streams carry the new playlist in on their own. Invalidated
      // anyway so a screen disposed while the import ran re-subscribes on its
      // next build rather than showing a stale snapshot.
      ref.invalidate(userPlaylistsProvider);
    } on ApiException catch (error) {
      if (_disposed) return;

      final problem = ImportProblem.of(error);

      if (problem.needsConnection) {
        // Not a failure. The remedy is a button, and the import resumes on its
        // own once it is pressed.
        state = state.copyWith(
          stage: LinkImportStage.needsConnection,
          connectProvider: _providerFor(state.detected),
          error: error.message,
          problem: problem,
        );
        return;
      }

      state = state.copyWith(
        stage: LinkImportStage.failed,
        // The API writes its messages for a person to read; using them as-is is
        // the contract. This is where "Spotify only lets an application read the
        // songs in a playlist its own user owns" reaches the screen.
        error: error.message,
        problem: problem,
      );
    } on Object catch (error, stackTrace) {
      if (_disposed) return;
      AppLogger.error(
        'Link import failed',
        scope: 'import',
        error: error,
        stackTrace: stackTrace,
      );
      // The last line of defence for "never show a raw exception". Anything
      // reaching here is a bug, and the user gets a sentence.
      state = state.copyWith(
        stage: LinkImportStage.failed,
        error: 'The import did not finish. Please try again.',
        problem: ImportProblem.unknown,
      );
    }
  }

  /// The provider a detected link belongs to.
  ///
  /// Falls back to Spotify only when the link parsed as nothing, which cannot
  /// reach an authorization failure — a link the server could not attribute is
  /// refused before any connection is consulted.
  static MediaSource _providerFor(PlaylistSource source) => switch (source) {
    PlaylistSource.youtube => MediaSource.youtube,
    _ => MediaSource.spotify,
  };
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
///
/// ## A sync and an import are the same operation
///
/// `POST /music/import` is idempotent by construction: the document id is
/// derived from (provider, provider playlist id), so a second import of the
/// same link updates the playlist rather than creating a second one. It adds
/// what the source added, drops what the source no longer lists, and rewrites
/// the order from the source. That *is* a sync, so this posts the playlist's
/// stored `sourceUrl` and there is no second code path to keep in step.
final resyncPlaylistProvider =
    Provider<Future<ImportedPlaylistResult> Function(Playlist)>((ref) {
  return (playlist) async {
    final url = playlist.sourceUrl?.trim();
    if (url == null || url.isEmpty) {
      // A playlist built in AURIX has no source to sync from. Reached only if
      // the menu item is offered where it should not be, so it names the reason
      // rather than failing obscurely.
      throw const ResyncUnavailable(
        'This playlist was created in AURIX, so there is nothing to sync it '
        'against.',
      );
    }

    final result = await ref.read(apiMusicServiceProvider).importFromUrl(url);
    ref.invalidate(userPlaylistsProvider);
    return result;
  };
});

/// A sync that could not be attempted.
class ResyncUnavailable implements Exception {
  const ResyncUnavailable(this.message);

  final String message;

  @override
  String toString() => message;
}
