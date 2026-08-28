import 'dart:async';

import 'package:audio_service/audio_service.dart';
import 'package:audio_session/audio_session.dart';
import 'package:just_audio/just_audio.dart';

import '../core/constants/app_constants.dart';
import '../core/theme/player_themes.dart';
import '../core/utils/app_logger.dart';
import '../data/models/track.dart';

/// The app's media session: Spotify's 30-second previews, plus the lock-screen
/// and notification surface for playback happening elsewhere.
///
/// ## Two jobs, one session
///
/// **Local preview audio.** This plays exactly one thing: the MP3 at
/// `track.preview_url`, which Spotify publishes openly for many tracks. It
/// streams — nothing is written to disk, and there is no code path here that
/// could download, decrypt or cache Spotify's protected catalogue audio.
///
/// **Remote-control metadata.** When the audio is coming out of the Spotify app
/// (App Remote) or a Connect device, AURIX plays nothing itself but still owns
/// a media session, so the lock screen shows what is playing and its buttons
/// reach the right place. [remoteControlMode] switches between the two: with it
/// set, `just_audio` is silent and every transport override is forwarded to the
/// player controller instead of to the local player, and local playback events
/// stop overwriting the published state.
///
/// Under App Remote this means two notifications exist — Spotify's own and
/// AURIX's. That is inherent: Spotify's app posts its own session and no
/// third-party client can suppress or take it over.
class PreviewAudioHandler extends BaseAudioHandler with SeekHandler {
  /// How the OS notification presents itself.
  ///
  /// Set from the theme — see `outsidePlayerSyncProvider`. Mutable rather
  /// than constructor-injected because this handler is built during
  /// `bootstrap()`, before any theme has been read, and it outlives every
  /// theme change after that.
  ///
  /// Assigning re-publishes the current state, so a variant change lands on
  /// the notification immediately instead of at the next track.
  OutsidePlayerStyle get outsideStyle => _outsideStyle;
  OutsidePlayerStyle _outsideStyle = OutsidePlayerStyle.theme1;

  set outsideStyle(OutsidePlayerStyle value) {
    if (value == _outsideStyle) return;
    _outsideStyle = value;
    // Re-emit with the same playback facts and the new presentation.
    playbackState.add(
      playbackState.value.copyWith(
        androidCompactActionIndices: value.compactActions,
      ),
    );
  }

  /// The system actions a variant offers. Seek is always available — it is
  /// what the lock-screen scrubber uses, and removing it would freeze the
  /// timeline rather than tidy the controls.
  Set<MediaAction> get _systemActions => <MediaAction>{
    MediaAction.seek,
    if (_outsideStyle.showsSeekControls) ...<MediaAction>{
      MediaAction.seekForward,
      MediaAction.seekBackward,
    },
  };
  PreviewAudioHandler({AudioPlayer? player})
    : _player = player ?? AudioPlayer(handleInterruptions: true);

  final AudioPlayer _player;

  /// Called when a preview reaches its end, so the controller can advance the
  /// queue. The handler does not own the queue — the controller does.
  Future<void> Function()? onTrackCompleted;

  /// Called when the user presses next/previous on the lock screen.
  Future<void> Function()? onSkipNext;
  Future<void> Function()? onSkipPrevious;

  /// Lock-screen play/pause and scrub, while [remoteControlMode] is set.
  ///
  /// Only consulted in remote mode, which is what stops `play()` recursing:
  /// in preview mode the controller calls straight into this handler, so a
  /// hook that always fired would call the controller which would call the
  /// handler again.
  Future<void> Function()? onPlayRequested;
  Future<void> Function()? onPauseRequested;
  Future<void> Function(Duration position)? onSeekRequested;

  /// The user dismissed the media notification, or pressed its cancel button.
  ///
  /// Only consulted in remote mode, and it matters there in a way it does not
  /// for a preview: [stop] on its own tears down *AURIX's* session and leaves
  /// the Spotify app playing on, so the user's swipe would remove the controls
  /// while the music carried on with nothing to stop it. The controller's
  /// implementation pauses Spotify first and then clears the session, which is
  /// what "stop" means when the audio belongs to somebody else.
  Future<void> Function()? onStopRequested;

  /// True when the audio belongs to Spotify rather than to `just_audio`.
  bool _remoteControlMode = false;

  bool get remoteControlMode => _remoteControlMode;

  set remoteControlMode(bool value) {
    if (_remoteControlMode == value) return;
    _remoteControlMode = value;
    AppLogger.debug(
      'Remote control mode: $value',
      scope: 'media_session',
    );
  }

  final List<StreamSubscription<Object?>> _subscriptions = [];
  bool _initialised = false;

  Stream<Duration> get positionStream => _player.positionStream;
  Duration get position => _player.position;
  Duration? get duration => _player.duration;
  bool get isPlaying => _player.playing;

  Future<void> init() async {
    if (_initialised) return;
    _initialised = true;

    // Declaring the session as music tells the OS to duck for navigation
    // prompts and pause for phone calls, rather than mixing over them.
    final session = await AudioSession.instance;
    await session.configure(const AudioSessionConfiguration.music());

    _subscriptions.add(
      _player.playbackEventStream.listen(
        _broadcastState,
        onError: (Object error, StackTrace stackTrace) {
          AppLogger.error(
            'Preview playback error',
            scope: 'audio',
            error: error,
            stackTrace: stackTrace,
          );
        },
      ),
    );

    _subscriptions.add(
      _player.processingStateStream.listen((state) {
        if (state != ProcessingState.completed) return;
        // just_audio parks at `completed` with `playing == true`; resetting is
        // what stops the notification showing a finished track as playing.
        unawaited(_handleCompletion());
      }),
    );
  }

  /// Loads and starts a preview.
  ///
  /// Returns false when the URL will not play, so the controller can fall back
  /// or report honestly rather than showing a stuck progress bar.
  Future<bool> playPreview(Track track, {String? artworkUrl}) async {
    final url = track.previewUrl;
    if (url == null || url.isEmpty) return false;

    await init();

    try {
      mediaItem.add(_mediaItemFor(track, artworkUrl: artworkUrl));
      await _player.setUrl(url);
      await _player.play();
      return true;
    } on PlayerException catch (error) {
      // A 404 on a preview URL is common — Spotify expires them.
      AppLogger.warn(
        'Preview rejected (${error.code}): ${error.message}',
        scope: 'audio',
      );
      return false;
    } on PlayerInterruptedException {
      // Superseded by a newer load; not an error.
      return false;
    } on Object catch (error, stackTrace) {
      AppLogger.error(
        'Preview load failed',
        scope: 'audio',
        error: error,
        stackTrace: stackTrace,
      );
      return false;
    }
  }

  // ---- Transport, as the lock screen and notification see it -------------
  // In remote mode these are the *only* route from a notification button to
  // Spotify, so each one forwards rather than touching the local player.

  @override
  Future<void> play() async {
    if (_remoteControlMode) {
      AppLogger.info('Lock-screen play', scope: 'media_session');
      return onPlayRequested?.call();
    }
    return _player.play();
  }

  @override
  Future<void> pause() async {
    if (_remoteControlMode) {
      AppLogger.info('Lock-screen pause', scope: 'media_session');
      return onPauseRequested?.call();
    }
    return _player.pause();
  }

  @override
  Future<void> stop() async {
    if (_remoteControlMode) {
      AppLogger.info('Media notification dismissed', scope: 'media_session');
      await onStopRequested?.call();
      return;
    }
    await _player.stop();
    mediaItem.add(null);
    playbackState.add(
      playbackState.value.copyWith(
        playing: false,
        processingState: AudioProcessingState.idle,
      ),
    );
  }

  @override
  Future<void> seek(Duration position) async {
    if (_remoteControlMode) {
      AppLogger.info('Lock-screen seek to $position', scope: 'media_session');
      return onSeekRequested?.call(position);
    }
    return _player.seek(position);
  }

  @override
  Future<void> skipToNext() async => onSkipNext?.call();

  @override
  Future<void> skipToPrevious() async => onSkipPrevious?.call();

  @override
  Future<void> setSpeed(double speed) => _player.setSpeed(speed);

  Future<void> setVolume(double volume) => _player.setVolume(volume.clamp(0, 1));

  Future<void> _handleCompletion() async {
    await _player.pause();
    await _player.seek(Duration.zero);
    await onTrackCompleted?.call();
  }

  // ---- Publishing remote playback to the OS ------------------------------

  /// Publishes the metadata for a track AURIX is not playing itself.
  ///
  /// Called on every track change, which is the whole fix for the stale
  /// notification: previously `mediaItem` was written only by [playPreview], so
  /// under App Remote it kept whatever the last preview had put there — for the
  /// rest of the process.
  void publishRemoteMediaItem({
    required String id,
    required String title,
    required String artist,
    String? album,
    String? artworkUrl,
    required Duration duration,
    String? spotifyUri,
  }) {
    // `artUri` is what Android renders on the lock screen, and audio_service
    // keys its artwork cache on this URI — so a per-track URL is what makes the
    // image change with the song. A constant key here would pin the first
    // artwork permanently.
    final art = (artworkUrl == null || artworkUrl.isEmpty)
        ? null
        : Uri.tryParse(artworkUrl);

    mediaItem.add(
      MediaItem(
        id: id,
        title: title,
        artist: artist,
        album: album,
        duration: duration,
        artUri: art,
        extras: <String, dynamic>{
          'spotify_uri': ?spotifyUri,
          'is_preview': false,
        },
      ),
    );

    AppLogger.info('Metadata updated', scope: 'notification');
    AppLogger.info('Artwork updated: ${art ?? 'none'}', scope: 'notification');
  }

  /// Publishes transport state for playback happening elsewhere.
  ///
  /// [position] must be accurate *at the moment of the call*: `PlaybackState`
  /// stamps `updateTime` with now, and Android extrapolates the lock-screen
  /// scrubber from that anchor and [speed]. That is why this does not need
  /// calling on a timer — pushing it on every real change is enough for the
  /// lock-screen timeline to run smoothly on its own.
  void publishRemotePlaybackState({
    required bool playing,
    required Duration position,
    required bool buffering,
    bool canSkipNext = true,
    bool canSkipPrevious = true,
  }) {
    playbackState.add(
      PlaybackState(
        controls: <MediaControl>[
          MediaControl.skipToPrevious,
          if (playing) MediaControl.pause else MediaControl.play,
          MediaControl.skipToNext,
        ],
        systemActions: _systemActions,
        androidCompactActionIndices: _outsideStyle.compactActions,
        processingState: buffering
            ? AudioProcessingState.buffering
            : AudioProcessingState.ready,
        playing: playing,
        updatePosition: position,
        bufferedPosition: position,
        // Spotify plays at normal speed; a zero here would freeze the
        // lock-screen scrubber even while audio was running.
        speed: playing ? 1 : 0,
      ),
    );

    AppLogger.debug(
      'Playback state updated: playing=$playing position=$position',
      scope: 'media_session',
    );
  }

  /// Tears the session down when nothing is playing anywhere.
  void clearSession() {
    mediaItem.add(null);
    playbackState.add(
      playbackState.value.copyWith(
        playing: false,
        processingState: AudioProcessingState.idle,
        controls: const <MediaControl>[],
      ),
    );
  }

  /// Publishes state to the OS so the notification and lock screen stay in
  /// sync with the actual player.
  void _broadcastState(PlaybackEvent event) {
    // In remote mode the local player is stopped and its events are noise;
    // letting them through would overwrite Spotify's real state with
    // "idle, position zero" and blank the notification mid-song.
    if (_remoteControlMode) return;

    final playing = _player.playing;
    playbackState.add(
      playbackState.value.copyWith(
        controls: <MediaControl>[
          MediaControl.skipToPrevious,
          if (playing) MediaControl.pause else MediaControl.play,
          MediaControl.skipToNext,
          MediaControl.stop,
        ],
        systemActions: _systemActions,
        // Compact view shows three buttons at most; the indices point into
        // `controls` above and come from the configured variant.
        androidCompactActionIndices: _outsideStyle.compactActions,
        processingState: _mapProcessingState(_player.processingState),
        playing: playing,
        updatePosition: _player.position,
        bufferedPosition: _player.bufferedPosition,
        speed: _player.speed,
        queueIndex: event.currentIndex,
      ),
    );
  }

  AudioProcessingState _mapProcessingState(ProcessingState state) {
    switch (state) {
      case ProcessingState.idle:
        return AudioProcessingState.idle;
      case ProcessingState.loading:
        return AudioProcessingState.loading;
      case ProcessingState.buffering:
        return AudioProcessingState.buffering;
      case ProcessingState.ready:
        return AudioProcessingState.ready;
      case ProcessingState.completed:
        return AudioProcessingState.completed;
    }
  }

  MediaItem _mediaItemFor(Track track, {String? artworkUrl}) {
    final art = artworkUrl ?? track.artworkUrl;
    return MediaItem(
      id: track.id.isEmpty ? track.documentId : track.id,
      title: track.name,
      artist: track.artistNames,
      album: track.album?.name,
      // The *preview* is 30 seconds, not the track's real length. Reporting
      // the full duration here would make the lock-screen scrubber lie.
      duration: const Duration(seconds: 30),
      artUri: art == null ? null : Uri.tryParse(art),
      extras: <String, dynamic>{
        'spotify_uri': track.spotifyUri,
        'is_preview': true,
        'full_duration_ms': track.durationMs,
      },
    );
  }

  Future<void> dispose() async {
    for (final subscription in _subscriptions) {
      await subscription.cancel();
    }
    _subscriptions.clear();
    await _player.dispose();
  }
}

/// Boots `audio_service` and returns the handler.
///
/// Must be called once, after `WidgetsFlutterBinding.ensureInitialized()` and
/// before any playback. Calling it twice throws inside audio_service.
Future<PreviewAudioHandler> initAudioService() async {
  // Everything the platform side rejects arrives here and nowhere else.
  //
  // `audio_service` publishes metadata and transport over a method channel and
  // routes any failure into this stream rather than throwing into the caller —
  // which is correct (a lock screen must not be able to crash a music app) and
  // is also why a broken media session is invisible without this line. A
  // notification that will not post, a foreground service Android refuses to
  // start, a malformed small icon: all of them land here, and none of them land
  // anywhere else.
  AudioService.asyncError.listen((Object error) {
    AppLogger.error(
      'Media session rejected an update',
      scope: 'media_session',
      error: error,
    );
  });

  final handler = await AudioService.init<PreviewAudioHandler>(
    builder: PreviewAudioHandler.new,
    config: const AudioServiceConfig(
      androidNotificationChannelId: AppConstants.audioNotificationChannelId,
      androidNotificationChannelName: AppConstants.audioNotificationChannelName,
      androidNotificationChannelDescription:
          AppConstants.audioNotificationChannelDescription,

      // The service stays in the foreground across a pause. This is the whole
      // reason the notification survives being backgrounded.
      //
      // With the opposite setting — which is `audio_service`'s default, and
      // what AURIX had — pausing calls `stopForeground()`, and the next resume
      // has to call `startForegroundService()` again. From Android 12 that call
      // throws `ForegroundServiceStartNotAllowedException` when the app is in
      // the background, and AURIX is *always* in the background at that moment:
      // the resume came from the lock screen, or from a state push after the
      // user pressed play inside the Spotify app. The exception is swallowed by
      // the platform channel, so the visible symptom is simply that the
      // notification never comes back — for the rest of the session.
      //
      // Keeping the service foreground makes pause and resume pure state
      // updates with no service transition to lose. The cost is a partial wake
      // lock (CPU only, screen unaffected) held while paused, which is released
      // when the session ends: playback stopping, the App Remote binding going
      // away, or the user dismissing the notification — see `stop` above.
      androidStopForegroundOnPause: false,

      // Must be false whenever the above is false; `audio_service` asserts it.
      // No loss: an ongoing notification is one the user cannot swipe away, and
      // AURIX is not the thing making the sound. Being able to dismiss AURIX's
      // controls — which pauses Spotify and ends the session, rather than
      // orphaning it — is the right affordance here.
      androidNotificationOngoing: false,

      // A white-on-transparent mark, not the launcher icon.
      //
      // Android renders a small icon from its *alpha channel* only. The
      // launcher icon is opaque, so taking `audio_service`'s default of
      // `mipmap/ic_launcher` draws a solid white square in the status bar. See
      // the note in android/.../drawable/ic_stat_aurix.xml.
      androidNotificationIcon: 'drawable/ic_stat_aurix',

      // Tapping the notification brings AURIX forward; `MediaNotificationTaps`
      // is what then puts the player screen under the user.
      androidNotificationClickStartsActivity: true,

      // Spotify serves 640px covers. The notification and lock screen never
      // draw one larger than a few hundred pixels, and every one of them is
      // held as a decoded bitmap for the life of the session.
      artDownscaleWidth: 512,
      artDownscaleHeight: 512,

      fastForwardInterval: Duration(seconds: 10),
      rewindInterval: Duration(seconds: 10),
    ),
  );
  await handler.init();
  return handler;
}
