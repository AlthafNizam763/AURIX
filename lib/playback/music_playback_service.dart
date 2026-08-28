import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/providers/app_providers.dart';
import '../data/models/media_source.dart';
import '../data/models/track.dart';
import '../features/auth/providers/auth_provider.dart';
import 'audio_source_resolver.dart';
import 'playback_mode.dart';
import 'playback_queue.dart';
import 'player_controller.dart';

/// The one interface the UI uses to make sound happen.
///
/// ## Why this exists
///
/// Before the refactor, screens reached for `PlayerControllerProvider` and got
/// a class that knows about Spotify Connect devices, App Remote binding,
/// Spotify's 30-second preview URLs and Spotify's Premium requirement. The
/// coupling was invisible until you tried to change the playback source, at
/// which point every screen that touched playback was in scope.
///
/// This is the seam. The shape below is the whole vocabulary the UI needs —
/// play, pause, skip, seek, queue — and it names nothing Spotify-specific.
/// Behind it sits whichever provider is currently authorised to play the track
/// in hand.
///
/// ```
///        UI
///         ↓
///  MusicPlaybackService      ← this file
///         ↓
///  PlaybackProvider          ← Spotify App Remote / Connect / local preview
/// ```
///
/// ## What is behind it today, honestly
///
/// [PlayerController], unchanged. It is a large class that already implements
/// every method here and is the only thing in AURIX that can currently produce
/// audio, so wrapping it was the correct first move and rewriting it was not.
///
/// Its three mechanisms, in the order the resolver prefers them:
///
///  * **Spotify App Remote** — commands the Spotify app on this phone. Plays
///    the full track. Needs Spotify installed and authorised.
///  * **Spotify Connect** — commands a Spotify device elsewhere. Full track,
///    Premium only.
///  * **Local preview** — streams a 30-second preview URL where the source
///    publishes one, through `just_audio`. The only audio AURIX decodes itself.
///
/// A track AURIX owns that has no `spotifyId` and no preview URL cannot be
/// played by any of them, and [play] reports that rather than pretending. That
/// is not a bug in this layer — it is the honest state of a music app with no
/// licensed audio source of its own, and it is the thing a future provider
/// fixes.
///
/// ## What "swapping the provider" means with this in place
///
/// Implementing a new source means writing one class with these methods and
/// changing [musicPlaybackServiceProvider] to return it. No screen changes: the
/// mini player, the full player, the Dynamic Island, the lock-screen controls
/// and every play button already speak only this vocabulary.
abstract interface class MusicPlaybackService {
  /// Live playback state — what is playing, whether it is playing, where the
  /// position is, and why it cannot play if it cannot.
  AurixPlaybackState get state;

  /// Plays one track, replacing the queue.
  Future<void> play(Track track, {PlaybackContext? context});

  /// Replaces the queue and starts at [startIndex].
  Future<void> setQueue(
    List<Track> tracks, {
    int startIndex = 0,
    bool shuffle = false,
    PlaybackContext? context,
  });

  Future<void> pause();
  Future<void> resume();

  /// Pause if playing, resume if not. The single-button transport control.
  Future<void> togglePlayPause();

  Future<void> skipNext();
  Future<void> skipPrevious();
  Future<void> seek(Duration position);

  Future<void> toggleShuffle();
  Future<void> cycleRepeat();

  /// Puts [track] immediately after the current one.
  Future<void> playNext(Track track);

  /// Appends [track] to the queue.
  Future<void> addToQueue(Track track);

  void addAllToQueue(List<Track> tracks);

  /// True when the active provider is Spotify — App Remote or Connect.
  ///
  /// The one place the abstraction admits to knowing a provider's name, and it
  /// is here for a specific reason: the import flow must not revoke a Spotify
  /// authorization that is currently producing sound. See
  /// `ImportController._disconnectQuietly`.
  ///
  /// It is a question about the *provider*, not about the track, and it
  /// disappears with the coupling that needs it.
  bool get isUsingSpotify;

  /// Whether this service could play [track] right now.
  ///
  /// Lets a list grey out a row before the user taps it, rather than reporting
  /// the problem after.
  bool canPlay(Track track);
}

/// [MusicPlaybackService] over the existing [PlayerController].
///
/// A pure delegation layer: every method forwards, and none adds behaviour.
/// That is what makes it safe — this refactor moved no playback logic, so
/// background playback, the media notification, lock-screen controls, the
/// Dynamic Island and App Remote resynchronisation all behave exactly as they
/// did.
class PlayerControllerPlaybackService implements MusicPlaybackService {
  PlayerControllerPlaybackService(this._ref);

  final Ref _ref;

  PlayerController get _controller =>
      _ref.read(playerControllerProvider.notifier);

  @override
  AurixPlaybackState get state => _ref.read(playerControllerProvider);

  @override
  Future<void> play(Track track, {PlaybackContext? context}) =>
      _controller.playTrack(track, context: context);

  @override
  Future<void> setQueue(
    List<Track> tracks, {
    int startIndex = 0,
    bool shuffle = false,
    PlaybackContext? context,
  }) => _controller.playTracks(
    tracks,
    startIndex: startIndex,
    shuffle: shuffle,
    context: context ?? PlaybackContext.none,
  );

  @override
  Future<void> pause() async {
    if (state.isPlaying) await _controller.togglePlayPause();
  }

  @override
  Future<void> resume() async {
    if (!state.isPlaying) await _controller.togglePlayPause();
  }

  @override
  Future<void> togglePlayPause() => _controller.togglePlayPause();

  @override
  Future<void> skipNext() => _controller.next();

  @override
  Future<void> skipPrevious() => _controller.previous();

  @override
  Future<void> seek(Duration position) => _controller.seek(position);

  @override
  Future<void> toggleShuffle() => _controller.toggleShuffle();

  @override
  Future<void> cycleRepeat() => _controller.cycleRepeat();

  @override
  Future<void> playNext(Track track) => _controller.playNextInQueue(track);

  @override
  Future<void> addToQueue(Track track) => _controller.addToQueue(track);

  @override
  void addAllToQueue(List<Track> tracks) => _controller.addAllToQueue(tracks);

  @override
  bool get isUsingSpotify => state.mode.isRemote;

  /// Delegated to [AudioSourceResolver] rather than answered here.
  ///
  /// The logic is identical to what this method used to inline — a Spotify id
  /// or a preview URL, and never a local file — but asking the resolver is what
  /// makes it *replaceable*. When AURIX gains a licensed catalogue, the new
  /// source becomes playable everywhere at once because every "can this play"
  /// question in the app funnels through here and then through one interface.
  @override
  bool canPlay(Track track) => _ref.read(audioSourceResolverProvider).canPlay(track);
}

/// Which authorised sources can play a track.
///
/// **A swap point, alongside [musicPlaybackServiceProvider].** That one decides
/// *how* audio is produced; this decides *whether AURIX is allowed to produce
/// it at all, and from where*. Adding a licensed catalogue means returning a
/// resolver that knows about it here.
final audioSourceResolverProvider = Provider<AudioSourceResolver>((ref) {
  return DefaultAudioSourceResolver(
    // Read lazily, so constructing the resolver subscribes to nothing and it
    // stays a pure function of its inputs at call time.
    isSpotifyAvailable: () {
      try {
        return ref.read(playerControllerProvider).mode != PlaybackMode.unavailable;
      } on Object {
        // The playback layer may not exist at all — on web, in a widget test.
        // Treated as available, which preserves the previous behaviour of
        // judging a track solely on what it carries.
        return true;
      }
    },
  );
});

/// The playback service the app uses.
///
/// **This line is the swap point.** Replacing the playback source is a change
/// to the class constructed here and to nothing else in `lib/features`.
final musicPlaybackServiceProvider = Provider<MusicPlaybackService>(
  (ref) => PlayerControllerPlaybackService(ref),
);

/// Records plays into the user's Firestore history.
///
/// Wired as a listener rather than a call inside [PlayerController], and that
/// separation is the point: the player has no business knowing that AURIX has
/// a database, and history is not worth a failure path in the play button.
/// See `ApiLibraryService.recordPlay`, which swallows its own failures
/// for the same reason.
class PlayHistoryRecorder {
  PlayHistoryRecorder({required this.onPlay});

  /// Called with each track as it starts.
  final Future<void> Function(Track track) onPlay;

  String? _lastRecorded;

  /// Feeds a state change in. Records a play when the track changes to
  /// something that is actually playing.
  ///
  /// The de-duplication matters: the player emits many states per second, and
  /// a pause and resume of the same song is one play, not two.
  void observe(AurixPlaybackState state) {
    final track = state.track;
    if (track == null || !state.isPlaying) return;
    if (state.mode == PlaybackMode.unavailable) return;

    final id = track.documentId;
    if (id == _lastRecorded) return;
    _lastRecorded = id;

    unawaited(onPlay(track));
  }

  /// Forgets the last recorded track, so replaying it counts again.
  void reset() => _lastRecorded = null;
}

/// Keeps `/users/{uid}/recentlyPlayed` in step with what is playing.
///
/// A provider that exists for its subscription rather than its value: nothing
/// reads the recorder, and it is kept alive by being watched once from the app
/// shell.
///
/// Wired here rather than inside [PlayerController] because history is not the
/// player's concern. The player must keep working with no network and no
/// signed-in user; giving it a Firestore dependency would put a failure path
/// through the play button for the sake of a shelf on the home screen.
final playHistoryRecorderProvider = Provider<PlayHistoryRecorder>((ref) {
  final recorder = PlayHistoryRecorder(
    onPlay: (track) async {
      final uid = ref.read(currentUserIdProvider);
      if (uid == null) return;
      await ref.read(libraryRepositoryProvider).recordPlay(uid, track);
    },
  );

  ref.listen<AurixPlaybackState>(
    playerControllerProvider,
    (_, next) => recorder.observe(next),
  );

  // A new signed-in user starts a fresh history.
  ref.listen<String?>(currentUserIdProvider, (_, _) => recorder.reset());

  return recorder;
});

/// Named for the source a track can be played from, for diagnostics.
extension TrackPlayability on Track {
  MediaSource? get playableBy {
    if (hasSpotifyId) return MediaSource.spotify;
    if (youtubeVideoId != null) return MediaSource.youtube;
    return null;
  }
}
