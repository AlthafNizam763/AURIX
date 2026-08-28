import 'dart:async';

import 'package:flutter/foundation.dart';

import '../../../core/utils/app_logger.dart';

/// What replaced Firestore's snapshot listeners.
///
/// ## The problem
///
/// Every read in AURIX was a `Stream` — `watchPlaylists`, `watchLikedTracks`,
/// `watchTracks` — and the screens above them are `StreamProvider`s that rebuild
/// when a document changes. Firestore supplied that for free: a write echoed
/// back into every listener on the device before it even reached the server.
///
/// An HTTP API supplies nothing of the kind. Rewriting every screen to a
/// request/response model would have meant touching the whole feature layer and
/// losing the property that makes the app feel immediate — that liking a song on
/// the player updates the heart on the library screen behind it.
///
/// So the streams stay, and this is what feeds them.
///
/// ## How it works
///
/// A [watch] call is keyed by a string. It fetches once, emits, and then emits
/// again whenever something [invalidate]s a key that matches. Every write in
/// every API service invalidates the keys it affected, so a local change
/// propagates to every listener on the device exactly as a Firestore write did
/// — one fetch per affected query rather than a push, which is the real
/// difference and is invisible at this scale.
///
/// Keys are hierarchical and invalidation is by prefix:
///
/// ```
/// library:<uid>:liked          invalidated by  library:<uid>  or  library:
/// playlists:<uid>:<id>:tracks  invalidated by  playlists:<uid>:<id>
/// ```
///
/// That is what lets a write say "the playlist changed" without enumerating the
/// four queries that read part of it.
///
/// ## What this deliberately does not do
///
/// **It is not real-time across devices.** Firestore pushed another device's
/// write to this one within a second; nothing here does. [pollInterval] narrows
/// the gap for the queries where staleness is actually visible, and the honest
/// summary is that a change made on a phone shows up on a tablet within that
/// interval rather than instantly. Genuine cross-device push needs a WebSocket
/// or SSE channel on the API, which is a worthwhile addition and is not
/// pretended to exist here.
///
/// **It does not cache across subscriptions.** Two screens watching the same key
/// each fetch. That is one extra request on a screen transition, and the
/// alternative — a shared result cache with its own invalidation — is a second
/// source of truth to keep in step for a saving that does not show up in use.
class LiveQueries {
  LiveQueries({this.pollInterval = const Duration(minutes: 2)});

  /// How often a watched query re-fetches with nothing having changed locally.
  ///
  /// The only thing that closes the cross-device gap, so it is a real
  /// trade-off rather than a tuning constant: shorter means fresher and more
  /// requests per idle minute, longer means an edit made elsewhere lingers.
  /// Two minutes is chosen for a music library, where the common case is one
  /// person on one device and a stale playlist name costs nothing.
  ///
  /// Set to null to disable polling entirely — which is what tests do, so a
  /// widget test does not fire timers it never pumps.
  final Duration? pollInterval;

  final StreamController<String> _signals = StreamController<String>.broadcast();

  /// Announces that everything under [key] may have changed.
  ///
  /// Called by every write path. Cheap: it is one event on a broadcast stream,
  /// and only the streams whose key matches do any work.
  void invalidate(String key) {
    if (_signals.isClosed) return;
    _signals.add(key);
  }

  /// Announces that *everything* changed. Used on sign-in and sign-out.
  void invalidateAll() => invalidate('');

  /// A stream that re-fetches on invalidation and on the poll interval.
  ///
  /// [fetch] failures are logged and swallowed rather than closing the stream.
  /// That is the same contract the Firestore version had — `handleError` on
  /// every snapshot stream — and it exists because a transient failure must not
  /// permanently break a screen that would work on the next attempt. The stream
  /// simply does not emit, and the screen keeps showing what it had.
  ///
  /// The *first* fetch is the exception: if it fails the error is forwarded, so
  /// a screen with nothing to show can display why rather than an empty state
  /// that looks like an empty library.
  Stream<T> watch<T>(String key, Future<T> Function() fetch) {
    late StreamController<T> controller;
    StreamSubscription<String>? signals;
    Timer? poll;
    var closed = false;
    var isFirst = true;

    // Guards against a re-entrant fetch: an invalidation arriving while a
    // fetch is in flight must not start a second one, or a burst of writes
    // produces a burst of overlapping requests that can resolve out of order
    // and emit stale data last.
    var inFlight = false;
    var pending = false;

    Future<void> run() async {
      if (closed) return;
      if (inFlight) {
        pending = true;
        return;
      }
      inFlight = true;

      try {
        final value = await fetch();
        if (!closed) controller.add(value);
        isFirst = false;
      } on Object catch (error, stackTrace) {
        if (closed) return;
        if (isFirst) {
          isFirst = false;
          controller.addError(error, stackTrace);
        } else {
          AppLogger.debug('Live query "$key" failed to refresh: $error', scope: 'live');
        }
      } finally {
        inFlight = false;
        if (pending && !closed) {
          pending = false;
          unawaited(run());
        }
      }
    }

    controller = StreamController<T>(
      onListen: () {
        unawaited(run());

        signals = _signals.stream.listen((signal) {
          // Prefix matching, so `playlists:<uid>` refreshes
          // `playlists:<uid>:<id>:tracks` without naming it.
          if (signal.isEmpty || key.startsWith(signal)) unawaited(run());
        });

        final interval = pollInterval;
        if (interval != null) {
          poll = Timer.periodic(interval, (_) => unawaited(run()));
        }
      },
      onCancel: () async {
        // Order matters: `closed` first, so a fetch already in flight sees it
        // and drops its result instead of adding to a controller that is on
        // its way out.
        closed = true;
        poll?.cancel();
        await signals?.cancel();
        await controller.close();
      },
    );

    return controller.stream;
  }

  @visibleForTesting
  bool get hasListeners => _signals.hasListener;

  void dispose() {
    unawaited(_signals.close());
  }
}

/// The invalidation keys, spelled once.
///
/// The counterpart of `FirestorePaths` for the *notification* side: a key typed
/// by hand at a write site is a key no read subscribes to, and the failure mode
/// is a screen that shows stale data until it is navigated away from and back.
/// That is exactly the kind of bug that survives a code review and is reported
/// as "sometimes it doesn't update".
abstract final class LiveKeys {
  static String user(String uid) => 'user:$uid';

  static String library(String uid) => 'library:$uid';
  static String liked(String uid) => 'library:$uid:liked';
  static String history(String uid) => 'library:$uid:history';

  static String playlists(String uid) => 'playlists:$uid';
  static String playlist(String uid, String playlistId) => 'playlists:$uid:$playlistId';
  static String playlistTracks(String uid, String playlistId) =>
      'playlists:$uid:$playlistId:tracks';

  static const String sharedPlaylists = 'shared';
  static String sharedPlaylist(String playlistId) => 'shared:$playlistId';
  static String sharedPlaylistTracks(String playlistId) => 'shared:$playlistId:tracks';

  static const String catalog = 'catalog';
  static const String theme = 'theme';
}
