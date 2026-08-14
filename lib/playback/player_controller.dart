import 'dart:async';

import 'package:audio_service/audio_service.dart' show AudioProcessingState;
import 'package:equatable/equatable.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/network/api_exception.dart';
import '../core/providers/app_providers.dart';
import '../core/providers/app_visibility.dart';
import '../core/storage/preferences_store.dart';
import '../core/utils/app_logger.dart';
import '../data/models/album.dart';
import '../data/models/artist.dart';
import '../data/models/playback.dart';
import '../data/models/playlist.dart';
import '../data/models/track.dart';
import '../data/services/spotify_album_service.dart';
import '../data/services/spotify_app_remote_service.dart';
import '../data/services/spotify_player_service.dart';
import '../features/settings/providers/settings_provider.dart';
import 'media_permissions.dart';
import 'playback_mode.dart';
import 'playback_queue.dart';
import 'preview_audio_handler.dart';

/// Everything the player UI renders from.
class AurixPlaybackState extends Equatable {
  const AurixPlaybackState({
    this.queue = PlaybackQueue.empty,
    this.mode = PlaybackMode.idle,
    this.isPlaying = false,
    this.isBuffering = false,
    this.position = Duration.zero,
    this.duration = Duration.zero,
    this.limitation,
    this.connect = ConnectAvailabilitySnapshot.unknown,
    this.errorMessage,
    this.remoteTrack,
    this.positionUpdatedAt,
    this.remoteConnected = false,
  });

  final PlaybackQueue queue;
  final PlaybackMode mode;
  final bool isPlaying;
  final bool isBuffering;

  /// What Spotify says is playing, when that is *not* something AURIX queued.
  ///
  /// Spotify owns the playing context under App Remote: when a track ends it
  /// starts the next one from its own queue, the user can skip inside the
  /// Spotify app, and autoplay can wander off the album entirely. None of those
  /// tracks are in [queue], and matching by ID against it — which is all this
  /// used to do — silently left the previous track's title, artist and artwork
  /// on screen and in the notification.
  ///
  /// Set from the App Remote payload the moment Spotify reports a track AURIX
  /// does not know, then enriched with artwork from the Web API. Cleared as
  /// soon as playback returns to something in the queue.
  final Track? remoteTrack;

  /// When [position] was last taken from the player rather than interpolated.
  ///
  /// The anchor for the position ticker, and for the lock screen's own
  /// extrapolation. Null before anything has played.
  final DateTime? positionUpdatedAt;

  /// Whether the App Remote binding is currently live.
  ///
  /// Distinct from [isPlaying]: a dropped binding must stop the UI claiming
  /// playback it can no longer see.
  final bool remoteConnected;

  /// Current position. In [PlaybackMode.preview] this is real local playback
  /// position; in [PlaybackMode.connect] it is Spotify's reported progress,
  /// extrapolated between polls.
  final Duration position;

  /// Length of what is actually playing — 30 seconds for a preview, the full
  /// track over Connect. Never the full length while a preview is playing:
  /// that would make the scrubber lie.
  final Duration duration;

  final PlaybackLimitation? limitation;
  final ConnectAvailabilitySnapshot connect;
  final String? errorMessage;

  static const AurixPlaybackState initial = AurixPlaybackState();

  /// The track every surface renders: mini player, player screen, Dynamic
  /// Island and the media notification.
  ///
  /// Spotify's own report wins over AURIX's queue, because Spotify is the thing
  /// making sound. See [remoteTrack].
  Track? get track => remoteTrack ?? queue.current;

  bool get hasTrack => track != null;
  bool get isActive => mode.isPlayable && hasTrack;

  /// True when only a 30-second excerpt is available. The UI labels this
  /// everywhere it shows progress.
  bool get isPreviewOnly => mode == PlaybackMode.preview;

  double get progress {
    if (duration.inMilliseconds <= 0) return 0;
    return (position.inMilliseconds / duration.inMilliseconds).clamp(0.0, 1.0);
  }

  Duration get remaining {
    final left = duration - position;
    return left.isNegative ? Duration.zero : left;
  }

  bool get shuffled => queue.shuffled;
  RepeatState get repeatMode => queue.repeatMode;
  PlaybackContext get context => queue.context;
  SpotifyDevice? get activeDevice => connect.activeDevice;

  /// This state with the moving parts of the timeline removed.
  ///
  /// [position] advances twice a second for as long as anything is playing, and
  /// it is in [props] — so a widget that watches the whole state rebuilds twice
  /// a second whether or not it draws a scrubber. That is affordable for a row
  /// of text and ruinous for what AURIX actually puts on screen: a 24-sigma
  /// `BackdropFilter` in the mini player, a 60-sigma blur of the artwork behind
  /// the full player, a painted glass capsule in the island, and track lists
  /// that can hold thousands of rows.
  ///
  /// So the surfaces that do not scrub select *this* instead, and rebuild on
  /// track, transport and mode changes only. The two that genuinely do scrub —
  /// the full player's progress bar and the mini player's hairline — watch
  /// [playbackTimelineProvider] and [playbackProgressProvider], which are the
  /// only things left in the app that repaint at tick rate.
  ///
  /// [positionUpdatedAt] goes too: it moves on every anchor, which is every
  /// App Remote push and every five-second resync, and it exists purely to
  /// timestamp the position.
  AurixPlaybackState get timelineAgnostic =>
      (position == Duration.zero && positionUpdatedAt == null)
      ? this
      : AurixPlaybackState(
          queue: queue,
          mode: mode,
          isPlaying: isPlaying,
          isBuffering: isBuffering,
          duration: duration,
          limitation: limitation,
          connect: connect,
          errorMessage: errorMessage,
          remoteTrack: remoteTrack,
          remoteConnected: remoteConnected,
        );

  AurixPlaybackState copyWith({
    PlaybackQueue? queue,
    PlaybackMode? mode,
    bool? isPlaying,
    bool? isBuffering,
    Duration? position,
    Duration? duration,
    PlaybackLimitation? limitation,
    ConnectAvailabilitySnapshot? connect,
    String? errorMessage,
    Track? remoteTrack,
    DateTime? positionUpdatedAt,
    bool? remoteConnected,
    bool clearLimitation = false,
    bool clearError = false,
    bool clearRemoteTrack = false,
  }) => AurixPlaybackState(
    queue: queue ?? this.queue,
    mode: mode ?? this.mode,
    isPlaying: isPlaying ?? this.isPlaying,
    isBuffering: isBuffering ?? this.isBuffering,
    position: position ?? this.position,
    duration: duration ?? this.duration,
    limitation: clearLimitation ? null : (limitation ?? this.limitation),
    connect: connect ?? this.connect,
    errorMessage: clearError ? null : (errorMessage ?? this.errorMessage),
    remoteTrack: clearRemoteTrack ? null : (remoteTrack ?? this.remoteTrack),
    positionUpdatedAt: positionUpdatedAt ?? this.positionUpdatedAt,
    remoteConnected: remoteConnected ?? this.remoteConnected,
  );

  @override
  List<Object?> get props => [
    queue,
    mode,
    isPlaying,
    isBuffering,
    position,
    duration,
    limitation,
    connect,
    errorMessage,
    remoteTrack,
    positionUpdatedAt,
    remoteConnected,
  ];
}

/// Orchestrates playback across both authorised mechanisms.
///
/// ## Responsibilities
///
/// * Owns the queue (shuffle, repeat, reorder) regardless of mode.
/// * Picks a mode per track via [PlaybackResolver] and switches transparently:
///   a queue can mix Connect-playable tracks with preview-only ones.
/// * Mirrors remote state while on Connect, so the scrubber and play button
///   reflect what the Spotify device is really doing — including changes made
///   from that device.
/// * Refuses to fake it. When neither mechanism is available the state carries
///   a [PlaybackLimitation] and `isPlaying` stays false.
class PlayerController extends Notifier<AurixPlaybackState> {
  late final PreviewAudioHandler _audio;
  late final SpotifyPlayerService _connect;
  late final SpotifyAppRemoteService _appRemote;
  late final SpotifyAlbumService _catalogue;
  late final PreferencesStore _prefs;
  late final MediaPermissions _permissions;

  /// Whether the Spotify app on this phone is currently bound.
  ///
  /// Informational only — [_startCurrent] does **not** gate on it. An earlier
  /// version did, and that was the bug behind "press Play, nothing happens":
  /// the flag starts false, only a manual tap in the device picker set it, so
  /// Play never even attempted App Remote and fell through to the Connect
  /// path, which then reported "No Spotify device available" on a phone with
  /// Spotify sitting right there.
  bool _appRemoteConnected = false;

  /// Set when App Remote cannot work on this device *at all* — Spotify is not
  /// installed, or the platform has no SDK.
  ///
  /// Deliberately not set for `notAuthorized`: that one is fixed by the user
  /// granting permission, so every Play must keep trying and keep offering the
  /// authorization screen. Only genuinely permanent failures stop the attempts,
  /// so a missing Spotify app does not cost a failed bind on every tap.
  bool _appRemoteUnavailable = false;

  /// True while it is still worth asking the Spotify app to play.
  bool get _shouldTryAppRemote =>
      SpotifyAppRemoteService.isSupportedPlatform && !_appRemoteUnavailable;

  /// Where the Spotify app on this phone stands, for the UI.
  ///
  /// Deliberately separate from anything derived from
  /// `GET /me/player/devices`: that endpoint returning 200 says only that the
  /// Web API is reachable, and says nothing about whether App Remote is bound.
  /// Conflating the two is what produced "No Spotify device available" while
  /// the real problem was an ungranted authorization.
  AppRemoteConnectionState get appRemoteState {
    if (!SpotifyAppRemoteService.isSupportedPlatform) {
      return AppRemoteConnectionState.unsupported;
    }
    if (_appRemoteConnected) return AppRemoteConnectionState.connected;
    if (_appRemoteUnavailable) return AppRemoteConnectionState.noSpotifyApp;
    return AppRemoteConnectionState.notConnected;
  }

  final List<StreamSubscription<Object?>> _subscriptions = [];

  /// The one playback timer in the app.
  ///
  /// It used to be two — a Connect poll and a Connect-only scrubber tick — and
  /// App Remote had neither, which is why the timeline sat frozen there: the
  /// Spotify app pushes its state on *change*, not on a clock, so between a
  /// play and the next skip nothing ever moved the position.
  ///
  /// Now one ticker serves every remote mode. Each tick interpolates the
  /// position from an anchor; every Nth tick reconciles that anchor against the
  /// real player, over IPC for App Remote and over the Web API for Connect.
  Timer? _ticker;

  /// Position last reported by the player, and when it was reported.
  ///
  /// Interpolating from an anchor rather than accumulating `position + tick`
  /// keeps the scrubber honest across a dropped frame, a paused isolate or a
  /// backgrounded app — an accumulator silently loses whatever time it was not
  /// scheduled for, and drifts further the longer a track runs.
  Duration _positionAnchor = Duration.zero;
  DateTime? _positionAnchoredAt;

  int _tickCount = 0;

  /// Guards against two `play` calls racing when a user taps twice.
  int _playGeneration = 0;

  /// Suppresses interpolation while a scrub is in flight, so the thumb does not
  /// snap back to the pre-seek position before the player confirms.
  bool _seeking = false;

  /// Whether AURIX's own UI is on screen. Mirrored from [appVisibilityProvider]
  /// so the ticker can read it without a provider lookup per tick.
  ///
  /// It governs the *cadence* of this controller and nothing else. No path in
  /// this file stops playback, disposes a session or clears a track because the
  /// app went away — the Spotify app keeps playing and the media service keeps
  /// its session whatever this says.
  bool _appVisible = true;

  /// How often the timeline is interpolated while someone is looking at it.
  static const Duration _foregroundTick = Duration(milliseconds: 500);

  /// How often anything happens at all while AURIX is backgrounded.
  ///
  /// Interpolation exists to move a scrubber smoothly, and a backgrounded app
  /// has no scrubber — Android advances the notification's own timeline from
  /// `PlaybackState.updateTime` and the floating island interpolates from its
  /// last anchor, both without help. So the fast tick is retired on the way out
  /// and what is left is the reconciliation the fast tick was carrying anyway:
  /// one App Remote read every five seconds, which is a local IPC call, not a
  /// network request.
  static const Duration _backgroundTick = Duration(seconds: 5);

  /// Ticks between reconciliations. App Remote is a cheap local IPC call, so it
  /// reconciles often; Connect is a Web API request and must not be.
  static const int _appRemoteResyncTicks = 10; // 5s
  static const int _connectResyncTicks = 8; // 4s

  /// Background ticks between Connect polls — 15 seconds, against 4 in the
  /// foreground.
  ///
  /// Connect is the one remote mode with no push channel, so it is the one that
  /// costs a Web API request to stay honest. Backgrounded there is nothing on
  /// screen to keep honest: the lock screen extrapolates its own timeline, and a
  /// track change still reaches the notification on the next poll. Polling at
  /// the foreground rate would be exactly the "duplicate API polling while
  /// minimised" this design is meant not to have.
  static const int _connectBackgroundResyncTicks = 3;

  /// Pressing "previous" past this point restarts the track instead.
  static const Duration _restartThreshold = Duration(seconds: 4);

  /// Tracks Spotify reported that AURIX had not queued, resolved to full
  /// metadata. Bounded — this only ever holds what one listening session
  /// wandered through.
  final Map<String, Track> _resolvedRemoteTracks = <String, Track>{};
  static const int _resolvedCacheLimit = 60;

  /// In-flight enrichment lookups, so a burst of state pushes for the same
  /// track does not fire the same request repeatedly.
  final Set<String> _enrichmentsInFlight = <String>{};

  @override
  AurixPlaybackState build() {
    _audio = ref.watch(audioHandlerProvider);
    _connect = ref.watch(spotifyPlayerServiceProvider);
    _appRemote = ref.watch(spotifyAppRemoteServiceProvider);
    _catalogue = ref.watch(spotifyAlbumServiceProvider);
    _prefs = ref.watch(preferencesStoreProvider);
    _permissions = ref.watch(mediaPermissionsProvider);

    // App Remote pushes state on every change inside the Spotify app, so this
    // replaces polling entirely while it is the active mode: a skip or pause
    // made in Spotify itself lands here within milliseconds.
    _subscriptions.add(
      _appRemote.states.listen(_onAppRemoteState),
    );

    // Every lock-screen and notification button lands here. In remote mode the
    // handler forwards rather than driving its own player, so these are the
    // route from a notification tap to a Spotify App Remote command.
    _audio.onTrackCompleted = _onPreviewCompleted;
    _audio.onSkipNext = () => next();
    _audio.onSkipPrevious = () => previous();
    _audio.onPlayRequested = () async {
      if (!state.isPlaying) await togglePlayPause();
    };
    _audio.onPauseRequested = () async {
      if (state.isPlaying) await togglePlayPause();
    };
    _audio.onSeekRequested = seek;
    _audio.onStopRequested = _onSessionStopRequested;

    _subscriptions.add(
      _audio.positionStream.listen((position) {
        if (state.mode != PlaybackMode.preview) return;
        state = state.copyWith(position: position);
      }),
    );

    _subscriptions.add(
      _audio.playbackState.listen((playback) {
        if (state.mode != PlaybackMode.preview) return;
        state = state.copyWith(
          isPlaying: playback.playing,
          isBuffering: playback.processingState == AudioProcessingState.buffering ||
              playback.processingState == AudioProcessingState.loading,
        );
      }),
    );

    // One shared answer to "is AURIX on screen", rather than an
    // `AppLifecycleListener` per interested party — see [AppVisibilityController].
    //
    // `listen`, not `watch`: watching would rebuild this notifier on every
    // background transition, which means a new queue, a new mode and a new
    // media session every time the user presses Home. That is the opposite of
    // what is wanted here.
    _appVisible = ref.read(appVisibilityProvider);
    ref.listen<bool>(appVisibilityProvider, (_, visible) {
      _appVisible = visible;
      _retimeTicker();
      if (visible) _onAppResumed();
    });

    ref.onDispose(_teardown);
    return AurixPlaybackState.initial;
  }

  /// Coming back to AURIX is the one moment a push could have been missed — the
  /// user may have skipped three tracks inside Spotify while AURIX was
  /// backgrounded. Re-read rather than trusting the last state seen.
  ///
  /// Deliberately a resynchronisation and nothing more: it does not restart
  /// playback, re-issue a play command or rebind anything that is still bound.
  void _onAppResumed() {
    if (!state.mode.isRemote) return;
    AppLogger.debug('Resumed — resynchronising with Spotify', scope: 'playback');

    // Forget what was last published to the OS, so the resync that follows
    // republishes the whole session rather than diffing against it.
    //
    // The diff in [_syncMediaSession] exists to avoid rewriting an unchanged
    // notification several times a second, and it assumes the OS still holds
    // what it was last handed. That assumption is exactly what a spell in the
    // background can break: Android is entitled to reclaim a media service, and
    // when it does, the Dart side still believes it published a track that no
    // longer exists anywhere — so every subsequent sync decides there is
    // nothing to do and the notification never comes back. Clearing the
    // snapshot costs one redundant write per foreground and removes that whole
    // class of "it worked until I left the app" failure.
    _forgetPublishedSession();

    if (state.mode == PlaybackMode.appRemote) {
      unawaited(resyncWithSpotify());
    }
    _syncMediaSession();
  }

  void _teardown() {
    _stopTicker();
    for (final subscription in _subscriptions) {
      unawaited(subscription.cancel());
    }
    _subscriptions.clear();
    _audio.onTrackCompleted = null;
    _audio.onSkipNext = null;
    _audio.onSkipPrevious = null;
    _audio.onPlayRequested = null;
    _audio.onPauseRequested = null;
    _audio.onSeekRequested = null;
    _audio.onStopRequested = null;
    _audio.remoteControlMode = false;
  }

  /// The user dismissed AURIX's media notification.
  ///
  /// In a remote mode that is not the same request as "stop the app's own
  /// player", because AURIX has no player running — the sound is coming out of
  /// the Spotify app. Removing only the session would leave the music playing
  /// with the controls for it gone, so the pause goes to Spotify first and the
  /// session comes down after it.
  ///
  /// The queue is deliberately left intact: the mini player stays populated and
  /// paused, exactly as it would be after a pause from anywhere else.
  Future<void> _onSessionStopRequested() async {
    AppLogger.info('Session dismissed — pausing Spotify', scope: 'playback');

    if (state.isPlaying) {
      switch (state.mode) {
        case PlaybackMode.appRemote:
          await _runAppRemoteCommand(_appRemote.pause);
        case PlaybackMode.connect:
          await _runConnectCommand(
            () => _connect.pause(deviceId: state.connect.activeDevice?.id),
            silent: true,
          );
        case PlaybackMode.preview:
        case PlaybackMode.idle:
        case PlaybackMode.unavailable:
          break;
      }
    }

    _stopTicker();
    _clearMediaSession();
    state = state.copyWith(isPlaying: false, isBuffering: false);
  }

  // -----------------------------------------------------------------------
  // Starting playback
  // -----------------------------------------------------------------------

  /// Plays [tracks] starting at [startIndex].
  Future<void> playTracks(
    List<Track> tracks, {
    int startIndex = 0,
    PlaybackContext context = PlaybackContext.none,
    bool shuffle = false,
  }) async {
    final playable = tracks.where((t) => !t.isLocal).toList(growable: false);
    if (playable.isEmpty) {
      state = state.copyWith(
        mode: PlaybackMode.unavailable,
        limitation: PlaybackLimitation.localFile,
        isPlaying: false,
      );
      return;
    }

    // startIndex refers to the caller's list; local files may have been
    // filtered out, so re-resolve it against the filtered list by identity.
    var resolvedStart = startIndex;
    if (playable.length != tracks.length &&
        startIndex >= 0 &&
        startIndex < tracks.length) {
      final target = tracks[startIndex];
      final found = playable.indexWhere((t) => t.id == target.id);
      resolvedStart = found >= 0 ? found : 0;
    }

    state = state.copyWith(
      queue: PlaybackQueue.from(
        playable,
        startIndex: resolvedStart,
        shuffle: shuffle,
        repeatMode: state.queue.repeatMode,
        context: context,
      ),
      clearError: true,
    );

    await _startCurrent();
  }

  Future<void> playAlbum(Album album, {int startIndex = 0, bool shuffle = false}) {
    final tracks = album.tracks?.items ?? const <Track>[];
    return playTracks(
      tracks.map((t) => t.withAlbum(album)).toList(growable: false),
      startIndex: startIndex,
      shuffle: shuffle,
      context: PlaybackContext(
        title: album.name,
        subtitle: album.artistNames,
        uri: album.spotifyUri,
        imageUrl: album.imageUrl,
      ),
    );
  }

  Future<void> playPlaylist(
    Playlist playlist, {
    int startIndex = 0,
    bool shuffle = false,
  }) => playTracks(
    playlist.playableTracks,
    startIndex: startIndex,
    shuffle: shuffle,
    context: PlaybackContext(
      title: playlist.name,
      subtitle: playlist.ownerName,
      uri: playlist.spotifyUri,
      imageUrl: playlist.imageUrl,
    ),
  );

  /// Plays a single track with no surrounding context — a search result tap.
  Future<void> playTrack(Track track, {PlaybackContext? context}) =>
      playTracks(<Track>[track], context: context ?? PlaybackContext.none);

  // -----------------------------------------------------------------------
  // Transport
  // -----------------------------------------------------------------------

  Future<void> togglePlayPause() async {
    if (!state.hasTrack) return;

    switch (state.mode) {
      case PlaybackMode.preview:
        if (state.isPlaying) {
          await _audio.pause();
        } else {
          await _audio.play();
        }
      case PlaybackMode.connect:
        await _runConnectCommand(() async {
          if (state.isPlaying) {
            await _connect.pause(deviceId: state.connect.activeDevice?.id);
          } else {
            await _connect.play(deviceId: state.connect.activeDevice?.id);
          }
        });
        // Optimistic flip, corrected by the next poll if the device disagrees.
        // Connect has no push channel, so waiting for confirmation would leave
        // the button visibly unresponsive for up to a poll interval.
        state = state.copyWith(isPlaying: !state.isPlaying);
        _anchorPosition(state.position);
        _syncMediaSession();
      case PlaybackMode.appRemote:
        // No optimistic flip: App Remote pushes its state back within
        // milliseconds, so guessing here would only produce a visible bounce
        // if the Spotify app disagreed.
        await _runAppRemoteCommand(
          () => state.isPlaying ? _appRemote.pause() : _appRemote.resume(),
        );
      case PlaybackMode.idle:
      case PlaybackMode.unavailable:
        await _startCurrent();
    }
  }

  Future<void> next({bool manual = true}) async {
    // Under App Remote, hand the skip to Spotify rather than re-issuing a
    // fresh play for the next queue entry. Spotify owns the playing context,
    // so its own "next" respects shuffle and the rest of the album/playlist —
    // and the state push that follows moves AURIX's queue to match.
    if (state.mode == PlaybackMode.appRemote && manual) {
      await _runAppRemoteCommand(_appRemote.skipNext);
      return;
    }

    final advanced = state.queue.next(manual: manual);
    if (advanced == null) {
      await _stopPlayback();
      return;
    }
    if (identical(advanced, state.queue) && state.queue.repeatMode == RepeatState.track) {
      await seek(Duration.zero);
      if (!state.isPlaying) await togglePlayPause();
      return;
    }
    state = state.copyWith(queue: advanced);
    await _startCurrent();
  }

  Future<void> previous() async {
    // Standard behaviour: restart the track unless we are near its start.
    final atStart = state.position <= _restartThreshold;
    if (!atStart) {
      await seek(Duration.zero);
      return;
    }

    // As with next(): Spotify owns the context under App Remote, and its
    // skipPrevious already implements the same restart-vs-step rule against
    // the real playback position.
    if (state.mode == PlaybackMode.appRemote) {
      await _runAppRemoteCommand(_appRemote.skipPrevious);
      return;
    }

    final stepped = state.queue.previous();
    if (stepped == null) {
      await seek(Duration.zero);
      return;
    }
    state = state.copyWith(queue: stepped);
    await _startCurrent();
  }

  Future<void> seek(Duration position) async {
    final clamped = Duration(
      milliseconds: position.inMilliseconds.clamp(
        0,
        state.duration.inMilliseconds == 0 ? 0 : state.duration.inMilliseconds,
      ),
    );

    switch (state.mode) {
      case PlaybackMode.preview:
        await _audio.seek(clamped);
        state = state.copyWith(position: clamped);

      case PlaybackMode.connect:
      case PlaybackMode.appRemote:
        // Show the requested position at once, then hold it against incoming
        // pushes until the command lands. Without the guard the next state
        // push — which is still carrying the pre-seek position, because the
        // player has not moved yet — drags the thumb back to where it was.
        _seeking = true;
        try {
          _anchorPosition(clamped);
          _pushMediaSessionPosition();

          if (state.mode == PlaybackMode.appRemote) {
            await _runAppRemoteCommand(() => _appRemote.seek(clamped));
          } else {
            await _runConnectCommand(
              () => _connect.seek(clamped, deviceId: state.connect.activeDevice?.id),
            );
          }
        } finally {
          // A stuck guard would freeze the scrubber for the rest of the
          // session, so it is released even if the command threw something the
          // command runners do not catch.
          _seeking = false;
        }
        // Re-read rather than trusting the request: the player may have
        // clamped it, and this is the resynchronisation point.
        if (state.mode == PlaybackMode.appRemote) {
          unawaited(resyncWithSpotify());
        }

      case PlaybackMode.idle:
      case PlaybackMode.unavailable:
        break;
    }
  }

  Future<void> toggleShuffle() async {
    final next = !state.queue.shuffled;
    state = state.copyWith(queue: state.queue.setShuffle(next));
    if (state.mode == PlaybackMode.connect) {
      await _runConnectCommand(
        () => _connect.setShuffle(next, deviceId: state.connect.activeDevice?.id),
        silent: true,
      );
    }
  }

  Future<void> cycleRepeat() async {
    final next = state.queue.repeatMode.next;
    state = state.copyWith(queue: state.queue.setRepeat(next));
    if (state.mode == PlaybackMode.connect) {
      await _runConnectCommand(
        () => _connect.setRepeat(next, deviceId: state.connect.activeDevice?.id),
        silent: true,
      );
    }
  }

  // -----------------------------------------------------------------------
  // Queue editing
  // -----------------------------------------------------------------------

  Future<void> playNextInQueue(Track track) async {
    state = state.copyWith(queue: state.queue.playNext(track));
    // Mirrored onto the Connect device only when there is a Spotify track
    // behind this row. An AURIX-native track has nothing to send, and the
    // local queue above is the real one either way.
    final uri = track.spotifyUri;
    if (state.mode == PlaybackMode.connect && uri != null) {
      await _runConnectCommand(
        () => _connect.addToQueue(uri, deviceId: state.connect.activeDevice?.id),
        silent: true,
      );
    }
  }

  Future<void> addToQueue(Track track) async {
    if (state.queue.isEmpty) {
      await playTrack(track);
      return;
    }
    state = state.copyWith(queue: state.queue.addToQueue(track));
    final uri = track.spotifyUri;
    if (state.mode == PlaybackMode.connect && uri != null) {
      await _runConnectCommand(
        () => _connect.addToQueue(uri, deviceId: state.connect.activeDevice?.id),
        silent: true,
      );
    }
  }

  void addAllToQueue(List<Track> tracks) {
    state = state.copyWith(queue: state.queue.addAllToQueue(tracks));
  }

  void removeFromQueue(int upNextIndex) {
    final orderIndex = state.queue.cursor + 1 + upNextIndex;
    state = state.copyWith(queue: state.queue.removeAt(orderIndex));
  }

  void reorderQueue(int from, int to) {
    state = state.copyWith(queue: state.queue.reorderUpNext(from, to));
  }

  void clearUpNext() {
    state = state.copyWith(queue: state.queue.clearUpNext());
  }

  /// Jumps to a queue entry the user tapped in the Queue screen.
  Future<void> jumpToQueueIndex(int upNextIndex) async {
    final orderIndex = state.queue.cursor + 1 + upNextIndex;
    state = state.copyWith(queue: state.queue.jumpToOrderIndex(orderIndex));
    await _startCurrent();
  }

  // -----------------------------------------------------------------------
  // Devices
  // -----------------------------------------------------------------------

  /// Re-reads Connect availability. Cheap enough to call when the player
  /// opens, and necessary because devices come and go.
  Future<ConnectAvailabilitySnapshot> refreshDevices({bool force = false}) async {
    if (!force && !state.connect.isStale) return state.connect;

    if (ref.read(isOfflineProvider)) {
      final snapshot = ConnectAvailabilitySnapshot(
        status: ConnectStatus.unavailable,
        checkedAt: DateTime.now(),
      );
      state = state.copyWith(connect: snapshot);
      return snapshot;
    }

    final availability = await _connect.checkAvailability();
    final snapshot = ConnectAvailabilitySnapshot(
      status: availability.status,
      activeDevice: availability.activeDevice,
      devices: availability.devices,
      checkedAt: DateTime.now(),
    );
    state = state.copyWith(connect: snapshot);
    return snapshot;
  }

  /// Moves playback to another Spotify device.
  Future<bool> selectDevice(SpotifyDevice device) async {
    final id = device.id;
    if (id == null) return false;

    try {
      await _connect.transferPlayback(id, startPlaying: state.isPlaying);
      final snapshot = await refreshDevices(force: true);

      // If a preview was playing locally, hand over cleanly rather than
      // letting both sources play at once.
      if (state.mode == PlaybackMode.preview) {
        await _audio.stop();
      }

      if (snapshot.canPlay && state.hasTrack) {
        await _startCurrent();
      }
      return true;
    } on ApiException catch (error) {
      state = state.copyWith(errorMessage: error.message);
      return false;
    }
  }

  // -----------------------------------------------------------------------
  // Mode resolution and starting the current track
  // -----------------------------------------------------------------------

  Future<void> _startCurrent() async {
    final track = state.queue.current;
    if (track == null) {
      await _stopPlayback();
      return;
    }

    final generation = ++_playGeneration;

    // The one place the notification permission is asked for, and the right
    // one: a dialog at launch asks for something the user has no context for,
    // whereas the same dialog as a song starts explains itself. Fire-and-forget
    // — a refusal costs AURIX its own notification and costs playback nothing,
    // so nothing below waits on the answer or branches on it.
    unawaited(_permissions.ensureNotificationPermission());

    state = state.copyWith(
      isBuffering: true,
      position: Duration.zero,
      clearError: true,
      clearLimitation: true,
    );

    final preference = ref.read(settingsProvider).playbackPreference;
    final connect = await refreshDevices();
    if (generation != _playGeneration) return;

    final resolution = PlaybackResolver.resolve(
      track: track,
      preference: preference,
      connect: connect,
      isOffline: ref.read(isOfflineProvider),
      // Attempt whenever the platform can support it — not only after a
      // successful bind. Binding is what `_startAppRemote` does, and its
      // failure carries the reason the user needs ("Connect to Spotify",
      // "Install Spotify"). Gating on a prior success meant Play silently
      // skipped App Remote and blamed the Connect device list instead.
      appRemoteAvailable: _shouldTryAppRemote,
    );

    switch (resolution.mode) {
      case PlaybackMode.preview:
        await _startPreview(track, resolution, generation);
      case PlaybackMode.connect:
        await _startConnect(track, resolution, generation);
      case PlaybackMode.appRemote:
        await _startAppRemote(track, resolution, generation);
      case PlaybackMode.idle:
      case PlaybackMode.unavailable:
        await _reportUnplayable(resolution);
    }

    unawaited(_persistLastPlayed(track));
  }

  Future<void> _startPreview(
    Track track,
    PlaybackResolution resolution,
    int generation,
  ) async {
    _stopTicker();
    // Hand the media session back to the local player: it publishes a real
    // position and buffering state from `just_audio`, which the remote mirror
    // could only approximate.
    _audio.remoteControlMode = false;
    _sessionTrackId = null;
    state = state.copyWith(clearRemoteTrack: true);

    final started = await _audio.playPreview(track);
    if (generation != _playGeneration) return;

    if (!started) {
      // The preview URL was advertised but did not play — expired, or a
      // network failure. Try Connect before giving up.
      if (state.connect.canPlay && track.isConnectPlayable) {
        await _startConnect(track, const PlaybackResolution(mode: PlaybackMode.connect), generation);
        return;
      }
      await _reportUnplayable(
        const PlaybackResolution(
          mode: PlaybackMode.unavailable,
          limitation: PlaybackLimitation.noSource,
        ),
      );
      return;
    }

    state = state.copyWith(
      mode: PlaybackMode.preview,
      isPlaying: true,
      isBuffering: false,
      // A preview is 30 seconds — not the track's real duration.
      duration: const Duration(seconds: 30),
      limitation: resolution.limitation,
      clearLimitation: resolution.limitation == null,
    );
  }

  Future<void> _startConnect(
    Track track,
    PlaybackResolution resolution,
    int generation,
  ) async {
    // Local audio must stop first, or a preview and the Connect device play
    // over each other.
    if (_audio.isPlaying) await _audio.stop();

    final deviceId = state.connect.activeDevice?.id ??
        state.connect.controllableDevices.firstOrNull?.id;

    try {
      if (state.connect.needsTransfer && deviceId != null) {
        await _connect.transferPlayback(deviceId);
      }

      // Playing the surrounding context (album/playlist) rather than a bare
      // URI is what makes Spotify's own "next track" match AURIX's queue.
      final contextUri = state.queue.context.uri;
      if (contextUri != null) {
        final indexInContext = state.queue.tracks.indexWhere((t) => t.id == track.id);
        await _connect.play(
          contextUri: contextUri,
          offsetPosition: indexInContext >= 0 ? indexInContext : null,
          deviceId: deviceId,
        );
      } else {
        // Non-null by construction: `PlaybackResolver` only chooses
        // `PlaybackMode.connect` for a track whose `isConnectPlayable` is
        // true, and that now requires a Spotify id. The fallback keeps the
        // invariant from becoming a crash if that ever stops holding.
        final uri = track.spotifyUri;
        if (uri == null) {
          await _reportUnplayable(
            const PlaybackResolution(
              mode: PlaybackMode.unavailable,
              limitation: PlaybackLimitation.noSource,
            ),
          );
          return;
        }
        await _connect.play(trackUris: <String>[uri], deviceId: deviceId);
      }
    } on ApiException catch (error) {
      if (generation != _playGeneration) return;
      await _handleConnectFailure(track, error, generation);
      return;
    }

    if (generation != _playGeneration) return;

    _audio.remoteControlMode = true;
    _anchorPosition(Duration.zero, publish: false);
    state = state.copyWith(
      mode: PlaybackMode.connect,
      isPlaying: true,
      isBuffering: false,
      position: Duration.zero,
      positionUpdatedAt: _positionAnchoredAt,
      duration: track.duration,
      limitation: resolution.limitation,
      clearLimitation: resolution.limitation == null,
      clearRemoteTrack: true,
    );

    _syncMediaSession();
    _startTicker();
  }

  /// Connect refused. Fall back to a preview if one exists, otherwise explain.
  Future<void> _handleConnectFailure(
    Track track,
    ApiException error,
    int generation,
  ) async {
    AppLogger.info('Connect play failed: ${error.reason ?? error.kind.name}', scope: 'player');

    if (error.requiresActiveDevice) {
      await refreshDevices(force: true);
    }

    if (track.hasPreview) {
      await _startPreview(
        track,
        PlaybackResolution(
          mode: PlaybackMode.preview,
          limitation: error.requiresPremium
              ? PlaybackLimitation.premiumRequired
              : PlaybackLimitation.previewOnly,
        ),
        generation,
      );
      return;
    }

    await _reportUnplayable(
      PlaybackResolution(
        mode: PlaybackMode.unavailable,
        limitation: error.requiresPremium
            ? PlaybackLimitation.premiumRequired
            : PlaybackLimitation.noDevice,
      ),
    );
  }

  /// The one place that puts the player into a non-playing state with a
  /// reason. There is deliberately no path that sets `isPlaying: true`
  /// without a real audio source behind it.
  /// Connects to the Spotify app and starts the current track in it.
  ///
  /// Returns null on success, or the failure so the caller can choose a
  /// remedy — "install Spotify" and "this needs Premium" lead to different
  /// places, and the device picker sends the user to each.
  Future<AppRemoteException?> connectSpotifyApp() async {
    try {
      await _appRemote.connect();
      _appRemoteConnected = true;
      _appRemoteUnavailable = false;
    } on AppRemoteException catch (error) {
      _appRemoteConnected = false;
      _appRemoteUnavailable = _isPermanent(error.failure);
      return error;
    }

    // Connecting alone plays nothing. If a track is already loaded, move it to
    // the Spotify app so the button does what its label implies.
    if (state.hasTrack) await _startCurrent();
    return null;
  }

  /// Plays [track] through the Spotify app on this phone.
  ///
  /// Mirrors [_startConnect] in shape, and differs in two ways that matter:
  /// there is no device to transfer to (the target is the app next door), and
  /// no polling loop — App Remote pushes its state, so [_onAppRemoteState]
  /// takes over from here.
  Future<void> _startAppRemote(
    Track track,
    PlaybackResolution resolution,
    int generation,
  ) async {
    // Local preview audio and the Spotify app must never play at once.
    if (_audio.isPlaying) await _audio.stop();
    _stopTicker();
    // From here the notification is AURIX's window onto Spotify, not onto
    // `just_audio`. Set before the play call so a state push arriving during it
    // is published rather than dropped.
    _audio.remoteControlMode = true;

    // The URI Spotify is asked to play is the selected track's own — built
    // from its `uri` field when Spotify supplied one, or `spotify:track:<id>`
    // otherwise. Never a placeholder, never "something from this album".
    //
    // Null when the track is AURIX's own and was never matched to a Spotify
    // catalogue entry. `PlaybackResolver` will not choose App Remote for such a
    // track, so reaching here with null means the invariant broke — report it
    // as unplayable rather than handing Spotify a URI it cannot parse.
    final uri = track.spotifyUri;
    if (uri == null) {
      _audio.remoteControlMode = false;
      await _reportUnplayable(
        const PlaybackResolution(
          mode: PlaybackMode.unavailable,
          limitation: PlaybackLimitation.noSource,
        ),
      );
      return;
    }

    AppLogger.info('Play requested', scope: 'player');
    AppLogger.info('URI: $uri', scope: 'player');

    try {
      await _appRemote.play(uri);
    } on AppRemoteException catch (error) {
      _appRemoteConnected = false;
      _appRemoteUnavailable = _isPermanent(error.failure);
      if (generation != _playGeneration) return;
      await _handleAppRemoteFailure(track, error);
      return;
    }

    if (generation != _playGeneration) return;

    _appRemoteConnected = true;

    // The command was *accepted*, which is not the same as audio playing.
    // Report buffering, not playing: claiming playback here would light up the
    // pause button and start the scrubber over silence if Spotify then refused
    // the track (region-locked, unavailable, or a non-Premium account that
    // accepts the bind but not the command).
    _anchorPosition(Duration.zero, publish: false);
    state = state.copyWith(
      mode: PlaybackMode.appRemote,
      isPlaying: false,
      isBuffering: true,
      position: Duration.zero,
      positionUpdatedAt: _positionAnchoredAt,
      duration: track.duration,
      clearLimitation: true,
      // The queue entry the user tapped is authoritative until Spotify says
      // otherwise; anything left over from a previous remote track would show
      // the wrong song for the moment before the first push arrives.
      clearRemoteTrack: true,
      remoteConnected: true,
    );

    // Publish immediately: a track started from AURIX has full Web API artwork
    // in hand, so the notification can be correct before Spotify reports back.
    _syncMediaSession();
    _startTicker();

    // Ask Spotify what it is actually doing. The subscription pushes this too,
    // but a single explicit read closes the window where a refused command
    // would otherwise leave the UI buffering indefinitely.
    final confirmed = await _appRemote.currentState();
    if (generation != _playGeneration) return;

    if (confirmed == null) {
      // No answer. Leave buffering off and say nothing false; the push
      // subscription still corrects this the moment Spotify reports.
      state = state.copyWith(isBuffering: false);
      return;
    }

    _onAppRemoteState(confirmed);
  }

  /// Applies a state push from the Spotify app. **The source of truth.**
  ///
  /// Ignored unless App Remote is the active mode: the stream stays subscribed
  /// for the life of the controller, and the Spotify app keeps reporting even
  /// when AURIX has moved on to a preview.
  ///
  /// Every field the UI and the notification render comes from here, including
  /// on tracks AURIX never queued. The previous version matched the reported
  /// track ID against the queue and *dropped the payload when it did not
  /// match* — so when Spotify rolled on to its own next track, AURIX kept
  /// showing the previous title, artist and artwork indefinitely. That was the
  /// stale-metadata bug.
  void _onAppRemoteState(AppRemoteState remote) {
    if (state.mode != PlaybackMode.appRemote) return;

    if (remote.isPlaying && !state.isPlaying) {
      AppLogger.info('Playback started', scope: 'player');
    }

    final remoteId = remote.trackId;
    final changed = remoteId != null && remoteId != state.track?.id;

    if (changed) {
      _adoptRemoteTrack(remoteId, remote);
    }

    // Spotify owns shuffle and repeat while it is the player, so the controls
    // follow it. Applied only on a real change: `setShuffle` rebuilds the play
    // order, and doing that on every push would reshuffle Up Next continuously.
    if (remote.isShuffling != state.queue.shuffled) {
      state = state.copyWith(queue: state.queue.setShuffle(remote.isShuffling));
    }
    if (remote.repeatMode != state.queue.repeatMode) {
      state = state.copyWith(queue: state.queue.setRepeat(remote.repeatMode));
    }

    // A seek in flight owns the position until it lands; a push carrying the
    // pre-seek position would otherwise yank the thumb backwards.
    if (!_seeking) {
      _anchorPosition(remote.position, publish: false);
    }

    state = state.copyWith(
      isPlaying: remote.isPlaying,
      position: _seeking ? state.position : remote.position,
      positionUpdatedAt: _positionAnchoredAt,
      duration: remote.duration ?? state.duration,
      isBuffering: false,
      remoteConnected: true,
    );

    if (changed) _logTrackChange(state.track);

    AppLogger.debug(
      'State received — playing=${remote.isPlaying} '
      '${state.position}/${state.duration}',
      scope: 'playback',
    );

    _syncMediaSession();
  }

  /// Makes Spotify's reported track the current one.
  ///
  /// Two paths, and the difference is artwork. A track AURIX queued already
  /// carries its Web API album images. A track Spotify moved to on its own does
  /// not — App Remote reports only a `spotify:image:` identifier, which is not
  /// a URL and cannot be handed to an `Image.network` or to a MediaSession — so
  /// it is adopted immediately from the App Remote payload (correct title and
  /// artist, no artwork) and the cover is filled in a moment later by
  /// [_enrichRemoteTrack]. Showing the right title instantly beats showing the
  /// wrong song until a request completes.
  void _adoptRemoteTrack(String remoteId, AppRemoteState remote) {
    final synced = state.queue.jumpToTrackId(remoteId);
    if (synced.current?.id == remoteId) {
      state = state.copyWith(queue: synced, clearRemoteTrack: true);
      return;
    }

    final cached = _resolvedRemoteTracks[remoteId];
    if (cached != null) {
      state = state.copyWith(remoteTrack: cached);
      return;
    }

    state = state.copyWith(remoteTrack: _trackFromRemote(remoteId, remote));
    unawaited(_enrichRemoteTrack(remoteId));
  }

  /// Builds a Track from what App Remote reported, with no album artwork.
  static Track _trackFromRemote(String id, AppRemoteState remote) => Track(
    id: id,
    name: remote.trackName ?? 'Unknown track',
    artists: <Artist>[
      Artist(id: '', name: remote.artistName ?? 'Unknown artist'),
    ],
    durationMs: remote.duration?.inMilliseconds ?? 0,
    uri: remote.trackUri,
  );

  /// Fills in artwork for a track Spotify moved to on its own.
  ///
  /// One `GET /tracks/{id}` per unrecognised track — metadata, not a playback
  /// poll. Results are cached, so a queue Spotify loops through costs one
  /// request per distinct track for the session.
  Future<void> _enrichRemoteTrack(String id) async {
    if (id.isEmpty || !_enrichmentsInFlight.add(id)) return;
    try {
      final full = await _catalogue.track(id);
      if (full == null) return;

      if (_resolvedRemoteTracks.length >= _resolvedCacheLimit) {
        _resolvedRemoteTracks.remove(_resolvedRemoteTracks.keys.first);
      }
      _resolvedRemoteTracks[id] = full;

      // Only adopt it if Spotify is still on this track — a slow request must
      // not overwrite the metadata of a song the user has already skipped to.
      if (state.remoteTrack?.id != id) return;
      state = state.copyWith(remoteTrack: full);
      AppLogger.info('artwork=${full.artworkUrl}', scope: 'playback');
      _syncMediaSession();
    } on Object catch (error) {
      // Artwork is a nicety; the title and artist are already right.
      AppLogger.debug('Could not resolve track $id: $error', scope: 'playback');
    } finally {
      _enrichmentsInFlight.remove(id);
    }
  }

  // -----------------------------------------------------------------------
  // Media session — lock screen and notification
  // -----------------------------------------------------------------------

  /// The last values published to the OS, so nothing is republished unchanged.
  String? _sessionTrackId;
  String? _sessionArtworkUrl;
  bool? _sessionPlaying;
  bool? _sessionBuffering;
  Duration? _sessionPosition;
  DateTime? _sessionPositionAt;

  /// How far the OS's own extrapolation may drift before it is worth a push.
  static const Duration _sessionDriftTolerance = Duration(seconds: 2);

  /// Whether the lock screen's projected position has diverged from the truth.
  ///
  /// Android does not need a position on every tick — it advances its own
  /// scrubber from the last `updatePosition` plus elapsed time at `speed`. That
  /// projection stays right on its own through ordinary playback, and wrong the
  /// moment the position jumps for a reason the OS cannot see: a scrub inside
  /// the Spotify app, a resume that did not land where it paused. Pushing only
  /// on real divergence keeps the notification honest without a per-tick write.
  bool get _sessionPositionDiverged {
    final anchor = _sessionPosition;
    final at = _sessionPositionAt;
    if (anchor == null || at == null) return true;

    final projected = (_sessionPlaying ?? false)
        ? anchor + DateTime.now().difference(at)
        : anchor;
    final delta = state.position - projected;
    return delta.abs() > _sessionDriftTolerance;
  }

  /// Mirrors the global state onto the Android media session.
  ///
  /// Only for the remote modes. Preview playback already publishes through
  /// `just_audio`'s event stream, which carries a real position and buffering
  /// state that this could only approximate.
  ///
  /// Metadata is pushed on track change, transport state on any change that
  /// alters what the lock screen shows. Position is deliberately *not* pushed
  /// every tick: `PlaybackState` carries `updateTime` and `speed`, and Android
  /// advances its own scrubber from that anchor.
  void _syncMediaSession() {
    if (!state.mode.isRemote) return;

    final track = state.track;
    if (track == null) return;

    final artworkUrl = track.artworkUrl;
    if (track.id != _sessionTrackId || artworkUrl != _sessionArtworkUrl) {
      _sessionTrackId = track.id;
      _sessionArtworkUrl = artworkUrl;
      _audio.publishRemoteMediaItem(
        id: track.id.isEmpty ? track.documentId : track.id,
        title: track.name,
        artist: track.artistNames,
        album: track.album?.name,
        artworkUrl: artworkUrl,
        // The real track length. A remote mode plays the whole song, so the
        // 30-second preview duration would make the lock-screen scrubber lie.
        duration: state.duration > Duration.zero ? state.duration : track.duration,
        spotifyUri: track.spotifyUri,
      );
      // Force the transport push too: a new track resets the position anchor,
      // and Android would otherwise keep extrapolating from the old one.
      _sessionPlaying = null;
    }

    if (state.isPlaying != _sessionPlaying ||
        state.isBuffering != _sessionBuffering ||
        _sessionPositionDiverged) {
      _pushMediaSessionState();
    }
  }

  /// Pushes transport state unconditionally — after a seek, where the position
  /// moved but nothing else did.
  void _pushMediaSessionPosition() {
    if (!state.mode.isRemote) return;
    _pushMediaSessionState();
  }

  void _pushMediaSessionState() {
    _sessionPlaying = state.isPlaying;
    _sessionBuffering = state.isBuffering;
    _sessionPosition = state.position;
    _sessionPositionAt = DateTime.now();
    _audio.publishRemotePlaybackState(
      playing: state.isPlaying,
      position: state.position,
      buffering: state.isBuffering,
    );
  }

  /// Drops the record of what was last published, without touching the session
  /// itself.
  ///
  /// The difference from [_clearMediaSession] is the whole point: that one
  /// tells the OS to take the session down, this one only makes the next
  /// [_syncMediaSession] behave as though nothing had ever been published. Used
  /// where the OS may have discarded the session behind AURIX's back.
  void _forgetPublishedSession() {
    _sessionTrackId = null;
    _sessionArtworkUrl = null;
    _sessionPlaying = null;
    _sessionBuffering = null;
    _sessionPosition = null;
    _sessionPositionAt = null;
  }

  void _clearMediaSession() {
    _forgetPublishedSession();
    _audio.clearSession();
  }

  void _logTrackChange(Track? track) {
    if (track == null) return;
    AppLogger.info('Track changed', scope: 'playback');
    AppLogger.info('id=${track.id}', scope: 'playback');
    AppLogger.info('title=${track.name}', scope: 'playback');
    AppLogger.info('artist=${track.artistNames}', scope: 'playback');
    AppLogger.info('artwork=${track.artworkUrl ?? 'pending'}', scope: 'playback');
    AppLogger.info('duration=${track.duration}', scope: 'playback');
  }

  /// Runs a transport command against the Spotify app, surfacing a failure as
  /// a limitation rather than an exception.
  Future<void> _runAppRemoteCommand(Future<void> Function() command) async {
    try {
      await command();
    } on AppRemoteException catch (error) {
      _appRemoteConnected = false;
      _appRemoteUnavailable = _isPermanent(error.failure);
      AppLogger.warn(
        'App Remote command failed',
        scope: 'player',
        error: error.debugDetail,
      );
      state = state.copyWith(
        isPlaying: false,
        limitation: _limitationFor(error),
        remoteConnected: false,
      );
      _syncMediaSession();
      unawaited(_reconnectAppRemote());
    }
  }

  /// Falls back when the Spotify app cannot play the track.
  ///
  /// A preview is still better than silence, so it is tried first when one
  /// exists — but the reason App Remote failed is kept on screen either way,
  /// because "install Spotify" and "this needs Premium" are different actions.
  Future<void> _handleAppRemoteFailure(
    Track track,
    AppRemoteException error,
  ) async {
    AppLogger.warn(
      'App Remote playback failed (${error.failure.name})',
      scope: 'player',
      error: error.debugDetail,
    );

    // The Spotify app is out of the picture, so the media session goes back to
    // the local player — leaving it in remote mode would silence the very
    // events that keep the notification honest during a preview.
    _stopTicker();
    _audio.remoteControlMode = false;
    _sessionTrackId = null;

    if (track.hasPreview && await _audio.playPreview(track)) {
      state = state.copyWith(
        mode: PlaybackMode.preview,
        isPlaying: true,
        isBuffering: false,
        position: Duration.zero,
        duration: const Duration(seconds: 30),
        limitation: _limitationFor(error).copyAsNonBlocking(),
        clearRemoteTrack: true,
        remoteConnected: false,
      );
      return;
    }

    _clearMediaSession();
    state = state.copyWith(
      mode: PlaybackMode.unavailable,
      isPlaying: false,
      isBuffering: false,
      position: Duration.zero,
      duration: track.duration,
      limitation: _limitationFor(error),
      clearRemoteTrack: true,
      remoteConnected: false,
    );
  }

  /// Whether a failure means "stop trying" rather than "try again".
  ///
  /// Only two are permanent for the life of the process: no Spotify app, and
  /// no SDK for this platform. `notAuthorized` is emphatically **not** — it is
  /// the one the user can clear by granting permission, so every subsequent
  /// Play must attempt the bind again and re-offer the authorization screen.
  /// Treating it as permanent is what turns a one-tap fix into a dead app.
  static bool _isPermanent(AppRemoteFailure failure) =>
      failure == AppRemoteFailure.notInstalled ||
      failure == AppRemoteFailure.unsupportedPlatform;

  static PlaybackLimitation _limitationFor(AppRemoteException error) =>
      PlaybackLimitation(
        headline: switch (error.failure) {
          AppRemoteFailure.notInstalled => 'Spotify is not installed',
          AppRemoteFailure.notAuthorized => 'Connect to Spotify',
          AppRemoteFailure.notPermitted => 'Spotify Premium required',
          AppRemoteFailure.invalidUri => 'This track cannot be played',
          AppRemoteFailure.unsupportedPlatform => 'Not available here',
          AppRemoteFailure.connectionFailed => "Couldn't reach Spotify",
        },
        detail: error.message,
        action: switch (error.failure) {
          AppRemoteFailure.notInstalled => PlaybackRemedy.installSpotify,
          AppRemoteFailure.notPermitted => PlaybackRemedy.learnAboutPremium,
          _ => PlaybackRemedy.retry,
        },
      );

  Future<void> _reportUnplayable(PlaybackResolution resolution) async {
    _stopTicker();
    if (_audio.isPlaying) await _audio.stop();
    _audio.remoteControlMode = false;
    _clearMediaSession();

    state = state.copyWith(
      mode: PlaybackMode.unavailable,
      isPlaying: false,
      isBuffering: false,
      position: Duration.zero,
      duration: state.track?.duration ?? Duration.zero,
      limitation: resolution.limitation ?? PlaybackLimitation.noSource,
      clearRemoteTrack: true,
    );
  }

  Future<void> _stopPlayback() async {
    _stopTicker();
    await _audio.stop();
    _audio.remoteControlMode = false;
    _clearMediaSession();
    state = state.copyWith(
      mode: PlaybackMode.idle,
      isPlaying: false,
      isBuffering: false,
      position: Duration.zero,
      clearRemoteTrack: true,
    );
  }

  Future<void> _onPreviewCompleted() async {
    if (state.mode != PlaybackMode.preview) return;
    await next(manual: false);
  }

  // -----------------------------------------------------------------------
  // Remote mirroring — the single playback ticker
  // -----------------------------------------------------------------------

  /// Anchors the position so the ticker can interpolate from it.
  ///
  /// Call this — never `copyWith(position:)` directly — wherever a *real*
  /// position arrives: an App Remote push, a Connect poll, a seek. Writing the
  /// position without moving the anchor leaves the ticker interpolating from a
  /// stale reference and the scrubber jumps back on the next tick.
  void _anchorPosition(Duration position, {bool publish = true}) {
    _positionAnchor = position;
    _positionAnchoredAt = DateTime.now();
    if (publish) {
      state = state.copyWith(
        position: position,
        positionUpdatedAt: _positionAnchoredAt,
      );
    }
  }

  /// Starts the one timer that drives every remote mode.
  ///
  /// Idempotent: a second call while it is already running is a no-op rather
  /// than a second timer. That matters because both `_startConnect` and
  /// `_startAppRemote` reach it, and a track change calls them again.
  void _startTicker() {
    if (_ticker != null) return;
    _tickCount = 0;
    _ticker = Timer.periodic(
      _appVisible ? _foregroundTick : _backgroundTick,
      (_) => _onTick(),
    );
  }

  void _stopTicker() {
    _ticker?.cancel();
    _ticker = null;
  }

  /// Swaps the ticker between its foreground and background cadences.
  ///
  /// Still one timer — it is cancelled and recreated at the other interval,
  /// never run alongside itself. Doing this on the visibility edge rather than
  /// checking the clock inside [_onTick] is what actually saves the work: a
  /// 500ms timer that returns early ten times a second is still a 500ms timer
  /// waking the isolate.
  void _retimeTicker() {
    if (_ticker == null) return;
    _stopTicker();
    _startTicker();
  }

  void _onTick() {
    final mode = state.mode;
    if (!mode.isRemote) {
      // Preview audio has its own position stream, and idle needs no clock.
      _stopTicker();
      return;
    }

    _tickCount++;

    // Reconcile against the real player. App Remote is a local IPC round trip,
    // so it can afford to be frequent; Connect is a Web API request and is
    // deliberately not.
    //
    // Backgrounded the tick itself is already five seconds, so App Remote
    // reconciles once per tick and lands on the same five-second cadence it has
    // in the foreground — the interpolation between those reads is what was
    // dropped, not the reads.
    if (mode == PlaybackMode.appRemote) {
      final every = _appVisible ? _appRemoteResyncTicks : 1;
      if (_tickCount % every == 0) unawaited(resyncWithSpotify());
    } else {
      final every = _appVisible
          ? _connectResyncTicks
          : _connectBackgroundResyncTicks;
      if (_tickCount % every == 0) unawaited(_pollRemote());
    }

    // Nothing is watching the scrubber, and the surfaces that are still on
    // screen — the notification, the lock screen, the floating island — run
    // their own extrapolation from the last anchor. Interpolating here would
    // rebuild the timeline providers behind an invisible widget tree.
    if (!_appVisible) return;

    if (!state.isPlaying || _seeking) return;

    final anchoredAt = _positionAnchoredAt;
    if (anchoredAt == null) return;

    // Interpolated from the anchor rather than accumulated, so a skipped tick
    // costs nothing and a long background pause does not desynchronise.
    final elapsed = DateTime.now().difference(anchoredAt);
    final projected = _positionAnchor + elapsed;
    final duration = state.duration;

    // Never run past the end. When a track finishes, Spotify starts the next
    // one and pushes its state — parking here until it does is what stops the
    // scrubber sailing past the duration into a track that has not started.
    if (duration > Duration.zero && projected >= duration) {
      if (state.position != duration) {
        state = state.copyWith(position: duration);
      }
      return;
    }

    state = state.copyWith(position: projected);
  }

  /// Re-reads the Spotify app's own player state and reconciles.
  ///
  /// Cheap: App Remote is an IPC call to the app next door, not a network
  /// request. This is the safety net for the case the push subscription cannot
  /// cover — a state change that arrived while AURIX was backgrounded, or a
  /// dropped binding that silently stopped delivering.
  ///
  /// Public because it is a legitimate operation for any surface that has just
  /// become visible, not only for the ticker: the ticker calls it on a cadence,
  /// the lifecycle listener calls it on resume, and the player screen can call
  /// it when it opens.
  Future<void> resyncWithSpotify() async {
    if (state.mode != PlaybackMode.appRemote) return;

    final remote = await _appRemote.currentState();
    if (remote == null) {
      // No answer means the binding is gone. Say so rather than leaving a
      // scrubber advancing over audio AURIX can no longer see.
      if (state.remoteConnected) {
        AppLogger.warn('App Remote went quiet; reconnecting', scope: 'playback');
        state = state.copyWith(remoteConnected: false);
        unawaited(_reconnectAppRemote());
      }
      return;
    }
    _onAppRemoteState(remote);
  }

  /// Rebinds after a dropped connection and re-reads the truth.
  Future<void> _reconnectAppRemote() async {
    if (!_shouldTryAppRemote) return;
    try {
      await _appRemote.connect();
    } on AppRemoteException catch (error) {
      _appRemoteConnected = false;
      _appRemoteUnavailable = _isPermanent(error.failure);
      AppLogger.warn(
        'App Remote reconnect failed (${error.failure.name})',
        scope: 'playback',
      );
      // Stop claiming playback that is no longer observable.
      state = state.copyWith(isPlaying: false, isBuffering: false);
      _syncMediaSession();
      return;
    }

    _appRemoteConnected = true;
    AppLogger.info('App Remote reconnected', scope: 'playback');

    final remote = await _appRemote.currentState();
    if (remote != null) _onAppRemoteState(remote);
  }

  Future<void> _pollRemote() async {
    if (state.mode != PlaybackMode.connect) return;

    try {
      final remote = await _connect.playbackState();

      if (remote.isIdle) {
        // The device went away or playback ended remotely.
        state = state.copyWith(isPlaying: false);
        _syncMediaSession();
        return;
      }

      final remoteTrack = remote.track;

      // The user skipped on the Spotify device. Follow them rather than
      // fighting over what should be playing. Unlike App Remote, Connect
      // returns a full Web API track, so its artwork is already present.
      if (remoteTrack != null && remoteTrack.id != state.track?.id) {
        final synced = state.queue.jumpToTrackId(remoteTrack.id);
        final inQueue = synced.current?.id == remoteTrack.id;
        state = state.copyWith(
          queue: synced,
          duration: remoteTrack.duration,
          remoteTrack: inQueue ? null : remoteTrack,
          clearRemoteTrack: inQueue,
        );
        _logTrackChange(state.track);
      }

      _anchorPosition(remote.progressAt(DateTime.now()));
      state = state.copyWith(
        isPlaying: remote.isPlaying,
        duration: remoteTrack?.duration ?? state.duration,
        connect: state.connect.copyWithDevice(remote.device),
      );
      _syncMediaSession();
    } on ApiException catch (error) {
      // Polling failures are not worth interrupting the user for; the next
      // tick will try again. A 403/404 means Connect is gone, though.
      if (error.kind == ApiFailureKind.forbidden ||
          error.kind == ApiFailureKind.notFound) {
        _stopTicker();
        state = state.copyWith(isPlaying: false);
        _syncMediaSession();
      }
    }
  }

  /// Runs a Connect command and surfaces capability failures without throwing
  /// into the widget tree.
  Future<void> _runConnectCommand(
    Future<void> Function() command, {
    bool silent = false,
  }) async {
    try {
      await command();
    } on ApiException catch (error) {
      AppLogger.info('Connect command failed: ${error.message}', scope: 'player');
      if (silent) return;
      state = state.copyWith(errorMessage: error.message);
      if (error.requiresActiveDevice) await refreshDevices(force: true);
    }
  }

  // -----------------------------------------------------------------------
  // Persistence
  // -----------------------------------------------------------------------

  /// Remembers the last track so the mini player can be restored on relaunch.
  /// Metadata only — no audio, and nothing that could reconstruct one.
  Future<void> _persistLastPlayed(Track track) =>
      _prefs.setJson(PrefKeys.lastPlayedTrack, track.toJson());

  /// Restores the last track into the queue *paused*, so relaunching shows a
  /// populated mini player without unexpectedly making noise.
  Future<void> restoreLastPlayed() async {
    if (state.hasTrack) return;
    final json = _prefs.getJson(PrefKeys.lastPlayedTrack);
    if (json == null) return;
    try {
      final track = Track.fromJson(json);
      state = state.copyWith(
        queue: PlaybackQueue.from(<Track>[track]),
        mode: PlaybackMode.idle,
        isPlaying: false,
        duration: track.duration,
      );
    } on Object catch (error) {
      AppLogger.debug('Could not restore last track: $error', scope: 'player');
    }
  }

  void dismissError() => state = state.copyWith(clearError: true);
  void dismissLimitation() => state = state.copyWith(clearLimitation: true);
}

extension on ConnectAvailabilitySnapshot {
  ConnectAvailabilitySnapshot copyWithDevice(SpotifyDevice? device) {
    if (device == null) return this;
    return ConnectAvailabilitySnapshot(
      status: status,
      activeDevice: device,
      devices: devices,
      checkedAt: checkedAt,
    );
  }
}

final playerControllerProvider =
    NotifierProvider<PlayerController, AurixPlaybackState>(PlayerController.new);

/// Narrow selectors, so a widget that only cares about the play/pause icon does
/// not rebuild on every position tick.
final currentTrackProvider = Provider<Track?>(
  (ref) => ref.watch(playerControllerProvider.select((s) => s.track)),
);

final isPlayingProvider = Provider<bool>(
  (ref) => ref.watch(playerControllerProvider.select((s) => s.isPlaying)),
);

final playbackPositionProvider = Provider<Duration>(
  (ref) => ref.watch(playerControllerProvider.select((s) => s.position)),
);

final hasActivePlaybackProvider = Provider<bool>(
  (ref) => ref.watch(playerControllerProvider.select((s) => s.hasTrack)),
);

/// The whole state minus the moving timeline — see
/// [AurixPlaybackState.timelineAgnostic].
///
/// The default subscription for any surface that renders playback but draws no
/// scrubber. Same single source of truth, sampled at the rate that surface
/// actually changes at.
final playbackStateProvider = Provider<AurixPlaybackState>(
  (ref) => ref.watch(playerControllerProvider.select((s) => s.timelineAgnostic)),
);

/// True only when the active playback provider has positively reported that
/// this account cannot control remote playback.
///
/// ## Where this moved from, and why
///
/// It used to read `profile.product` off Spotify's `GET /me` — a *user*
/// property, watched from the auth layer. That reading is gone with the Spotify
/// profile, and its replacement is better than a like-for-like port: this is
/// derived from what the playback provider actually answered when asked to
/// play, which is the question the UI is really asking.
///
/// Use this — not `!hasPremium` — to decide whether to tell the user that a
/// subscription is the obstacle. The distinction is the same one the old
/// provider existed for: "the provider said no" and "the provider has not been
/// asked" are different states, and only the first justifies naming a cause.
/// Saying "Premium required" on the second tells subscribers something false
/// while hiding the guidance that would have worked.
final knownNonPremiumProvider = Provider<bool>(
  (ref) => ref.watch(
    playerControllerProvider.select(
      (s) => s.connect.status == ConnectStatus.premiumRequired,
    ),
  ),
);

/// Exactly what a content list needs to mark its rows.
///
/// A record rather than a class so equality is structural for free, and small
/// enough that `select` can compare it on every tick without allocating
/// anything that matters. Liked Songs, Playlist, Album and Artist all render
/// from this: which collection is playing, which row is the current track,
/// whether it is playing, and whether shuffle is on. No position, so a list of
/// three thousand rows stops rebuilding twice a second.
typedef PlaybackBadge = ({
  String? contextUri,
  String? trackId,
  bool isPlaying,
  bool hasTrack,
  bool shuffled,
});

final playbackBadgeProvider = Provider<PlaybackBadge>(
  (ref) => ref.watch(
    playerControllerProvider.select(
      (s) => (
        contextUri: s.context.uri,
        trackId: s.track?.id,
        isPlaying: s.isPlaying,
        hasTrack: s.hasTrack,
        shuffled: s.shuffled,
      ),
    ),
  ),
);

/// Position and duration together, for the one scrubber that needs both.
///
/// Deliberately paired: a bar fed position and duration from two subscriptions
/// can render a frame where they disagree, which shows up as the thumb jumping
/// on a track change.
typedef PlaybackTimeline = ({Duration position, Duration duration});

final playbackTimelineProvider = Provider<PlaybackTimeline>(
  (ref) => ref.watch(
    playerControllerProvider.select(
      (s) => (position: s.position, duration: s.duration),
    ),
  ),
);

/// Fractional progress, for the mini player's 2px hairline.
final playbackProgressProvider = Provider<double>(
  (ref) => ref.watch(playerControllerProvider.select((s) => s.progress)),
);
