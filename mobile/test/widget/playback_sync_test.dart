import 'dart:async';

import 'package:audio_service/audio_service.dart';
import 'package:aurix/core/providers/app_providers.dart';
import 'package:aurix/core/providers/app_visibility.dart';
import 'package:aurix/data/models/album.dart';
import 'package:aurix/data/models/artist.dart';
import 'package:aurix/data/models/spotify_image.dart';
import 'package:aurix/data/models/track.dart';
import 'package:aurix/data/services/spotify_album_service.dart';
import 'package:aurix/data/services/spotify_app_remote_service.dart';
import 'package:aurix/data/services/spotify_player_service.dart';
import 'package:aurix/playback/playback_mode.dart';
import 'package:aurix/playback/player_controller.dart';
import 'package:aurix/playback/preview_audio_handler.dart';
import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import '../support/fixtures.dart';
import '../support/harness.dart';

/// A Spotify app under test control.
///
/// Subclasses the real service rather than reimplementing it, so the
/// normalisation and URI parsing under test are the shipping ones — only the
/// platform channel is replaced.
class _FakeAppRemote extends SpotifyAppRemoteService {
  final StreamController<AppRemoteState> _pushes =
      StreamController<AppRemoteState>.broadcast();

  AppRemoteState? nextCurrentState;
  int connects = 0;
  int seeks = 0;
  int resumes = 0;
  int pauses = 0;
  int skipNexts = 0;

  @override
  Stream<AppRemoteState> get states => _pushes.stream;

  @override
  bool get isConnected => true;

  /// Simulates Spotify pushing a player state, exactly as the SDK subscription
  /// would.
  void push(AppRemoteState state) {
    nextCurrentState = state;
    _pushes.add(state);
  }

  @override
  Future<void> connect() async => connects++;

  @override
  Future<void> play(String spotifyUri) async => connects++;

  @override
  Future<void> pause() async => pauses++;

  @override
  Future<void> resume() async => resumes++;

  @override
  Future<void> skipNext() async => skipNexts++;

  @override
  Future<void> skipPrevious() async {}

  @override
  Future<void> seek(Duration position) async => seeks++;

  @override
  Future<AppRemoteState?> currentState() async => nextCurrentState;

  @override
  Future<void> disconnect() async {}

  @override
  Future<void> dispose() async => _pushes.close();
}

/// Visibility under test control.
///
/// Overrides [AppVisibilityController.build] so no `AppLifecycleListener` is
/// registered — the real one answers to the platform, and these tests need to
/// say when AURIX left the screen rather than wait to be told.
class _TestVisibility extends AppVisibilityController {
  @override
  bool build() => true;

  void set({required bool visible}) => state = visible;
}

/// No Connect devices, so mode resolution lands on App Remote.
class _FakeConnect extends SpotifyPlayerService {
  _FakeConnect() : super(Dio());

  @override
  Future<ConnectAvailability> checkAvailability({CancelToken? cancelToken}) async =>
      const ConnectAvailability(status: ConnectStatus.noDevices, devices: []);
}

/// Stands in for `GET /tracks/{id}` — the artwork lookup for a track Spotify
/// moved to on its own.
class _FakeCatalogue extends SpotifyAlbumService {
  _FakeCatalogue() : super(Dio());

  int lookups = 0;
  Track? result;

  @override
  Future<Track?> track(String id, {CancelToken? cancelToken}) async {
    lookups++;
    return result;
  }
}

/// A track Spotify knows about but AURIX never queued.
Track _strangerTrack({String id = 'stranger', String name = 'Sunflower'}) => Track(
  id: id,
  name: name,
  artists: const <Artist>[Artist(id: 'a9', name: 'Post Malone')],
  durationMs: 158000,
  album: const Album(
    id: 'alb9',
    name: 'Spider-Verse',
    artists: <Artist>[Artist(id: 'a9', name: 'Post Malone')],
    images: <SpotifyImage>[
      SpotifyImage(url: 'https://cdn.example/sunflower.jpg', width: 640, height: 640),
    ],
  ),
);

AppRemoteState _remote({
  required String trackId,
  String name = 'Sunflower',
  String artist = 'Post Malone',
  bool playing = true,
  Duration position = Duration.zero,
  Duration duration = const Duration(seconds: 158),
}) => AppRemoteState(
  isPlaying: playing,
  position: position,
  trackUri: 'spotify:track:$trackId',
  trackName: name,
  artistName: artist,
  albumName: 'Spider-Verse',
  duration: duration,
);

void main() {
  // The controller registers an `AppLifecycleListener` so it can resynchronise
  // with Spotify on resume, and that needs a binding.
  TestWidgetsFlutterBinding.ensureInitialized();

  // App Remote only resolves on a mobile platform, and mode resolution reads
  // the ambient platform statically.
  setUp(() => debugDefaultTargetPlatformOverride = TargetPlatform.android);
  tearDown(() => debugDefaultTargetPlatformOverride = null);

  late _FakeAppRemote appRemote;
  late _FakeCatalogue catalogue;
  late PreviewAudioHandler audio;

  Future<ProviderContainer> boot() async {
    appRemote = _FakeAppRemote();
    catalogue = _FakeCatalogue();
    audio = buildTestAudioHandler();

    final base = await baseOverrides();
    final container = ProviderContainer(
      overrides: [
        ...base,
        audioHandlerProvider.overrideWithValue(audio),
        spotifyAppRemoteServiceProvider.overrideWithValue(appRemote),
        spotifyPlayerServiceProvider.overrideWithValue(_FakeConnect()),
        spotifyAlbumServiceProvider.overrideWithValue(catalogue),
        appVisibilityProvider.overrideWith(_TestVisibility.new),
      ],
    );
    addTearDown(container.dispose);
    addTearDown(appRemote.dispose);
    return container;
  }

  /// Gets playback running through App Remote on a known queue.
  Future<PlayerController> playing(ProviderContainer container) async {
    final controller = container.read(playerControllerProvider.notifier);
    final tracks = Fixtures.tracks(3);
    appRemote.nextCurrentState = _remote(trackId: tracks.first.id, name: 'Track 0');
    await controller.playTracks(tracks);
    return controller;
  }

  group('App Remote is the source of truth for metadata', () {
    test('a track AURIX queued plays with its own Web API metadata', () async {
      final container = await boot();
      await playing(container);

      final state = container.read(playerControllerProvider);
      expect(state.mode, PlaybackMode.appRemote);
      expect(state.track?.name, 'Track 0');
      expect(state.remoteTrack, isNull, reason: 'queued tracks need no stand-in');
    });

    test('Spotify rolling on to an unqueued track replaces the metadata',
        () async {
      // The stale-first-song bug. Spotify finishes the queue and starts
      // something of its own; the previous version matched the reported ID
      // against the queue, found nothing, and left the old song on screen.
      final container = await boot();
      final controller = await playing(container);
      catalogue.result = _strangerTrack();

      appRemote.push(_remote(trackId: 'stranger'));
      await Future<void>.delayed(Duration.zero);

      final state = container.read(playerControllerProvider);
      expect(state.track?.id, 'stranger');
      expect(state.track?.name, 'Sunflower');
      expect(state.track?.artistNames, 'Post Malone');
      expect(state.duration, const Duration(seconds: 158));
      expect(controller.state.track?.name, isNot('Track 0'));
    });

    test('artwork is filled in from the Web API and reaches the notification',
        () async {
      // App Remote reports only a `spotify:image:` identifier, which is not a
      // URL — so the cover has to be resolved separately or the lock screen
      // keeps the previous track's image.
      final container = await boot();
      await playing(container);
      catalogue.result = _strangerTrack();

      final items = <MediaItem?>[];
      final sub = audio.mediaItem.listen(items.add);
      addTearDown(sub.cancel);

      appRemote.push(_remote(trackId: 'stranger'));
      await Future<void>.delayed(const Duration(milliseconds: 10));

      final state = container.read(playerControllerProvider);
      expect(catalogue.lookups, 1);
      expect(state.track?.artworkUrl, 'https://cdn.example/sunflower.jpg');

      final published = items.whereType<MediaItem>().toList();
      expect(published.last.title, 'Sunflower');
      expect(
        published.last.artUri.toString(),
        'https://cdn.example/sunflower.jpg',
        reason: 'artUri keys the OS artwork cache; a stale one pins the image',
      );
    });

    test('the same unqueued track is only looked up once', () async {
      final container = await boot();
      await playing(container);
      catalogue.result = _strangerTrack();

      for (var i = 0; i < 4; i++) {
        appRemote.push(_remote(trackId: 'stranger', position: Duration(seconds: i)));
        await Future<void>.delayed(const Duration(milliseconds: 5));
      }

      expect(catalogue.lookups, 1);
    });

    test('returning to a queued track drops the stand-in', () async {
      final container = await boot();
      await playing(container);
      catalogue.result = _strangerTrack();

      appRemote.push(_remote(trackId: 'stranger'));
      await Future<void>.delayed(const Duration(milliseconds: 10));
      expect(container.read(playerControllerProvider).remoteTrack, isNotNull);

      appRemote.push(_remote(trackId: 'track_1', name: 'Track 1'));
      await Future<void>.delayed(const Duration(milliseconds: 10));

      final state = container.read(playerControllerProvider);
      expect(state.remoteTrack, isNull);
      expect(state.track?.id, 'track_1');
    });

    test('play/pause follows Spotify rather than flipping locally', () async {
      // AURIX must never show "playing" for a command Spotify refused.
      final container = await boot();
      final controller = await playing(container);

      appRemote.push(_remote(trackId: 'track_0', playing: true));
      await Future<void>.delayed(Duration.zero);
      expect(container.read(playerControllerProvider).isPlaying, isTrue);

      await controller.togglePlayPause();
      expect(appRemote.pauses, 1);
      // Still playing: Spotify has not confirmed yet, and guessing is what
      // produces a pause button over audio that never stopped.
      expect(container.read(playerControllerProvider).isPlaying, isTrue);

      appRemote.push(_remote(trackId: 'track_0', playing: false));
      await Future<void>.delayed(Duration.zero);
      expect(container.read(playerControllerProvider).isPlaying, isFalse);
    });
  });

  group('the timeline follows Spotify', () {
    test('position advances while playing', () async {
      final container = await boot();
      await playing(container);

      appRemote.push(
        _remote(trackId: 'track_0', playing: true, position: const Duration(seconds: 10)),
      );
      await Future<void>.delayed(Duration.zero);
      expect(container.read(playerControllerProvider).position,
          const Duration(seconds: 10));

      // The one ticker interpolates from Spotify's anchor. Real elapsed time,
      // because the anchor is a wall clock rather than an accumulator.
      await Future<void>.delayed(const Duration(milliseconds: 1200));

      final advanced = container.read(playerControllerProvider).position;
      expect(advanced, greaterThan(const Duration(seconds: 10)));
      expect(advanced, lessThan(const Duration(seconds: 12)));
    });

    test('position holds still while paused', () async {
      final container = await boot();
      await playing(container);

      appRemote.push(
        _remote(trackId: 'track_0', playing: false, position: const Duration(seconds: 30)),
      );
      await Future<void>.delayed(const Duration(milliseconds: 1200));

      expect(container.read(playerControllerProvider).position,
          const Duration(seconds: 30));
    });

    test('position never runs past the duration', () async {
      // At the end of a track the scrubber must park and wait for Spotify to
      // report the next one, not sail on into a song that has not started.
      final container = await boot();
      await playing(container);

      appRemote.push(
        _remote(
          trackId: 'track_0',
          playing: true,
          position: const Duration(seconds: 9, milliseconds: 500),
          duration: const Duration(seconds: 10),
        ),
      );
      await Future<void>.delayed(const Duration(milliseconds: 1500));

      final state = container.read(playerControllerProvider);
      expect(state.position, state.duration);
    });

    test('a track change resets the position to what Spotify reports', () async {
      final container = await boot();
      await playing(container);
      catalogue.result = _strangerTrack();

      appRemote.push(
        _remote(trackId: 'track_0', position: const Duration(seconds: 45)),
      );
      await Future<void>.delayed(Duration.zero);

      appRemote.push(
        _remote(trackId: 'stranger', position: const Duration(seconds: 2)),
      );
      await Future<void>.delayed(Duration.zero);

      expect(container.read(playerControllerProvider).position,
          const Duration(seconds: 2));
    });

    test('seeking holds the requested position instead of snapping back',
        () async {
      final container = await boot();
      final controller = await playing(container);

      appRemote.push(
        _remote(trackId: 'track_0', position: const Duration(seconds: 5)),
      );
      await Future<void>.delayed(Duration.zero);

      // Spotify keeps reporting the old position until the seek lands.
      appRemote.nextCurrentState =
          _remote(trackId: 'track_0', position: const Duration(seconds: 90));
      await controller.seek(const Duration(seconds: 90));

      expect(appRemote.seeks, 1);
      expect(container.read(playerControllerProvider).position,
          const Duration(seconds: 90));
    });

    test('skip hands the command to Spotify and waits for its answer', () async {
      final container = await boot();
      final controller = await playing(container);

      await controller.next();
      expect(appRemote.skipNexts, 1);

      catalogue.result = _strangerTrack(id: 'after', name: 'After');
      appRemote.push(_remote(trackId: 'after', name: 'After'));
      await Future<void>.delayed(const Duration(milliseconds: 10));

      expect(container.read(playerControllerProvider).track?.name, 'After');
    });
  });

  group('media session', () {
    test('remote mode forwards lock-screen transport to the controller',
        () async {
      final container = await boot();
      await playing(container);

      expect(audio.remoteControlMode, isTrue);

      appRemote.push(_remote(trackId: 'track_0', playing: true));
      await Future<void>.delayed(Duration.zero);

      // What Android calls when the notification's pause button is tapped.
      await audio.pause();
      expect(appRemote.pauses, 1,
          reason: 'the lock screen must reach Spotify, not just_audio');

      await audio.seek(const Duration(seconds: 20));
      expect(appRemote.seeks, 1);
    });

    test('local playback events cannot overwrite remote state', () async {
      // just_audio is stopped in remote mode, and its idle events would blank
      // the notification mid-song if they were allowed through.
      final container = await boot();
      await playing(container);

      appRemote.push(
        _remote(trackId: 'track_0', playing: true, position: const Duration(seconds: 40)),
      );
      await Future<void>.delayed(Duration.zero);

      final published = audio.playbackState.value;
      expect(published.playing, isTrue);
      expect(published.updatePosition, const Duration(seconds: 40));
      expect(published.speed, 1.0,
          reason: 'a zero speed freezes the lock-screen scrubber');
    });

    test('the published duration is the real track length', () async {
      final container = await boot();
      await playing(container);
      catalogue.result = _strangerTrack();

      appRemote.push(_remote(trackId: 'stranger'));
      await Future<void>.delayed(const Duration(milliseconds: 10));

      expect(audio.mediaItem.value?.duration, const Duration(seconds: 158));
    });
  });

  group('resilience', () {
    test('a silent App Remote stops AURIX claiming playback', () async {
      final container = await boot();
      await playing(container);

      appRemote.push(_remote(trackId: 'track_0', playing: true));
      await Future<void>.delayed(Duration.zero);
      expect(container.read(playerControllerProvider).remoteConnected, isTrue);

      // The binding drops: `getPlayerState` starts answering null.
      appRemote.nextCurrentState = null;
      await container.read(playerControllerProvider.notifier).resyncWithSpotify();

      expect(container.read(playerControllerProvider).remoteConnected, isFalse);
    });

    test('disposing the controller stops the ticker', () async {
      final container = await boot();
      await playing(container);

      appRemote.push(_remote(trackId: 'track_0', playing: true));
      await Future<void>.delayed(Duration.zero);

      container.dispose();
      // A leaked periodic timer would keep firing against disposed state and
      // throw; reaching the end of the test quietly is the assertion.
      await Future<void>.delayed(const Duration(milliseconds: 1200));
    });
  });

  group('a position tick wakes only the surfaces that draw one', () {
    /// Watches every playback subscription and counts what each one is told.
    ///
    /// These providers recompute lazily, so a notification count on its own can
    /// pass for the wrong reason — nothing read them, so nothing fired. Every
    /// helper below reads all four after each push, which forces the
    /// recomputation and makes a count of zero mean "recomputed and found
    /// unchanged" rather than "never asked".
    ({int Function() full, int Function() agnostic, int Function() badge,
      int Function() timeline, void Function() flush, void Function() reset})
    watchAll(ProviderContainer container) {
      var full = 0;
      var agnostic = 0;
      var badge = 0;
      var timeline = 0;

      container.listen(playerControllerProvider, (_, _) => full++,
          fireImmediately: true);
      container.listen(playbackStateProvider, (_, _) => agnostic++,
          fireImmediately: true);
      container.listen(playbackBadgeProvider, (_, _) => badge++,
          fireImmediately: true);
      container.listen(playbackTimelineProvider, (_, _) => timeline++,
          fireImmediately: true);

      void flush() {
        container
          ..read(playerControllerProvider)
          ..read(playbackStateProvider)
          ..read(playbackBadgeProvider)
          ..read(playbackTimelineProvider);
      }

      void reset() {
        flush();
        full = 0;
        agnostic = 0;
        badge = 0;
        timeline = 0;
      }

      return (
        full: () => full,
        agnostic: () => agnostic,
        badge: () => badge,
        timeline: () => timeline,
        flush: flush,
        reset: reset,
      );
    }

    test('the timeline-agnostic view and the badge stay asleep', () async {
      // The whole performance fix, expressed as an assertion. Every one of
      // these surfaces used to watch the full state, so a tick rebuilt a
      // 24-sigma `BackdropFilter`, a 60-sigma full-screen blur, a painted glass
      // capsule and every row of a track list — twice a second, for as long as
      // anything played.
      final container = await boot();
      await playing(container);
      await Future<void>.delayed(Duration.zero);

      final seen = watchAll(container)..reset();

      // Three pushes that move only the position — exactly what the ticker does
      // between one Spotify state change and the next.
      for (var second = 1; second <= 3; second++) {
        appRemote.push(
          _remote(
            trackId: 'track_0',
            name: 'Track 0',
            position: Duration(seconds: second),
          ),
        );
        await Future<void>.delayed(Duration.zero);
        seen.flush();
      }

      expect(
        seen.full(),
        greaterThan(0),
        reason: 'the controller itself must still publish every tick',
      );
      expect(
        seen.timeline(),
        greaterThan(0),
        reason: 'the scrubber is the thing that is meant to move',
      );
      expect(
        seen.agnostic(),
        0,
        reason: 'mini player, full player, island, queue and device picker',
      );
      expect(
        seen.badge(),
        0,
        reason: 'Liked Songs, Playlist, Album and Artist track lists',
      );
    });

    test('a real track change still reaches every surface', () async {
      // The other half of the guarantee: sleeping through ticks must not mean
      // sleeping through the thing the whole brief is about.
      final container = await boot();
      await playing(container);
      await Future<void>.delayed(Duration.zero);
      catalogue.result = _strangerTrack();

      final seen = watchAll(container)..reset();

      appRemote.push(_remote(trackId: 'stranger'));
      await Future<void>.delayed(Duration.zero);
      seen.flush();

      expect(seen.agnostic(), greaterThan(0));
      expect(seen.badge(), greaterThan(0));
      expect(container.read(playbackBadgeProvider).trackId, 'stranger');
      expect(container.read(playbackStateProvider).track?.name, 'Sunflower');
    });
  });

  group('The media notification is a remote control, not a second player', () {
    test('dismissing it pauses Spotify rather than orphaning the session',
        () async {
      // Swiping AURIX's notification away used to reach `BaseAudioHandler.stop`,
      // which stops the *local* player — and under App Remote there is no local
      // player. The controls vanished and the music carried on with nothing on
      // screen able to stop it.
      final container = await boot();
      await playing(container);
      await Future<void>.delayed(Duration.zero);
      expect(container.read(playerControllerProvider).isPlaying, isTrue);

      await audio.stop();
      await Future<void>.delayed(Duration.zero);

      expect(appRemote.pauses, 1, reason: 'the pause has to reach Spotify');
      expect(container.read(playerControllerProvider).isPlaying, isFalse);
      expect(
        container.read(playerControllerProvider).hasTrack,
        isTrue,
        reason: 'the queue survives — the mini player stays populated',
      );
    });

    test('lock-screen next and previous drive Spotify, not the queue', () async {
      final container = await boot();
      await playing(container);
      await Future<void>.delayed(Duration.zero);

      await audio.skipToNext();
      await Future<void>.delayed(Duration.zero);

      expect(
        appRemote.skipNexts,
        1,
        reason: 'Spotify owns the playing context under App Remote',
      );
    });

    test('coming back to the foreground republishes the whole session',
        () async {
      // Android is entitled to reclaim a media service while AURIX is away.
      // The publish path diffs against what it last sent, so without forgetting
      // that snapshot on resume it would decide there was nothing to do and the
      // notification would never come back.
      final container = await boot();
      final controller = await playing(container);
      await Future<void>.delayed(Duration.zero);

      final published = <MediaItem?>[];
      final subscription = audio.mediaItem.listen(published.add);
      addTearDown(subscription.cancel);
      await Future<void>.delayed(Duration.zero);
      published.clear();

      // Nothing about playback has changed — only that AURIX is being looked
      // at again.
      final visibility =
          container.read(appVisibilityProvider.notifier) as _TestVisibility;
      visibility.set(visible: false);
      visibility.set(visible: true);
      await Future<void>.delayed(Duration.zero);
      await controller.resyncWithSpotify();
      await Future<void>.delayed(Duration.zero);

      expect(
        published,
        isNotEmpty,
        reason: 'the metadata must be re-sent even though the track is the same',
      );
      expect(published.last?.title, 'Track 0');
    });
  });
}
