import 'package:aurix/core/providers/app_providers.dart';
import 'package:aurix/core/providers/app_visibility.dart';
import 'package:aurix/core/storage/preferences_store.dart';
import 'package:aurix/features/dynamic_island/providers/dynamic_island_controller.dart';
import 'package:aurix/features/settings/providers/settings_provider.dart';
import 'package:aurix/playback/background_island_channel.dart';
import 'package:aurix/playback/playback_mode.dart';
import 'package:aurix/playback/playback_queue.dart';
import 'package:aurix/playback/player_controller.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../support/fixtures.dart';

/// The Dynamic Island's background half, exercised against a fake platform.
///
/// The native surface is a `MethodChannel`, so a mock handler is the whole test
/// double needed — no window, no permission and no Android. What is being
/// verified is the decision layer: *when* AURIX asks for a floating surface,
/// *what* it publishes, and — mostly — the long list of situations in which it
/// must ask for nothing at all.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const channel = MethodChannel('com.aurix.app/dynamic_island');

  late _FakeIslandPlatform platform;

  setUp(() {
    platform = _FakeIslandPlatform();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, platform.handle);
  });

  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null);
  });

  /// A container with the island's dependencies stubbed and its settings
  /// seeded, ready for the controller to be read into existence.
  Future<ProviderContainer> boot({
    bool island = false,
    bool overlay = false,
    AurixPlaybackState? playback,
    required _Visibility visibility,
    required _StubPlayer player,
  }) async {
    SharedPreferences.setMockInitialValues(<String, Object>{
      PrefKeys.dynamicIsland: island,
      PrefKeys.dynamicIslandOverlay: overlay,
    });
    final preferences = await PreferencesStore.open();

    final container = ProviderContainer(
      overrides: <Override>[
        preferencesStoreProvider.overrideWithValue(preferences),
        appVisibilityProvider.overrideWith(() => visibility),
        playerControllerProvider.overrideWith(() => player),
      ],
    );
    addTearDown(container.dispose);
    return container;
  }

  test('a fresh install asks the platform for nothing beyond its capability', () async {
    final container = await boot(
      visibility: _Visibility(),
      player: _StubPlayer(_playing()),
    );

    container.read(dynamicIslandControllerProvider);
    await pumpEventQueue();

    expect(
      platform.calls,
      <String>['capability'],
      reason: 'the island is off by default, so nothing may be drawn',
    );
  });

  test('enabling the island alone does not draw outside the app', () async {
    final visibility = _Visibility();
    final container = await boot(
      island: true,
      visibility: visibility,
      player: _StubPlayer(_playing()),
    );

    container.read(dynamicIslandControllerProvider);
    await pumpEventQueue();

    visibility.set(false);
    await pumpEventQueue();

    expect(
      platform.calls.contains('show'),
      isFalse,
      reason: 'the outside-the-app consent is separate and has not been given',
    );
  });

  test('backgrounding shows the island, foregrounding takes it down', () async {
    final visibility = _Visibility();
    final container = await boot(
      island: true,
      overlay: true,
      visibility: visibility,
      player: _StubPlayer(_playing()),
    );

    container.read(dynamicIslandControllerProvider);
    await pumpEventQueue();

    // On screen: the in-app pill is the island, so nothing floats.
    expect(platform.calls.contains('show'), isFalse);

    visibility.set(false);
    await pumpEventQueue();

    expect(platform.calls.contains('show'), isTrue);
    expect(container.read(dynamicIslandControllerProvider).floatingVisible, isTrue);
    expect(platform.lastFrame?['title'], 'Track 0');

    visibility.set(true);
    await pumpEventQueue();

    expect(platform.calls.last, 'hide');
    expect(container.read(dynamicIslandControllerProvider).floatingVisible, isFalse);
  });

  test('a track change republishes metadata rather than leaving the old song', () async {
    final visibility = _Visibility();
    final player = _StubPlayer(_playing());
    final container = await boot(
      island: true,
      overlay: true,
      visibility: visibility,
      player: player,
    );

    container.read(dynamicIslandControllerProvider);
    visibility.set(false);
    await pumpEventQueue();
    expect(platform.lastFrame?['title'], 'Track 0');

    player.moveTo(1);
    await pumpEventQueue();

    expect(platform.calls.last, 'update');
    expect(platform.lastFrame?['title'], 'Track 1');
    expect(platform.lastFrame?['trackId'], 'track_1');
  });

  test('an interpolated position tick publishes nothing', () async {
    final visibility = _Visibility();
    final player = _StubPlayer(_playing());
    final container = await boot(
      island: true,
      overlay: true,
      visibility: visibility,
      player: player,
    );

    container.read(dynamicIslandControllerProvider);
    visibility.set(false);
    await pumpEventQueue();

    final before = platform.calls.length;
    // What the ticker does between anchors: moves the position and nothing
    // else. The native surface interpolates this for itself.
    player.interpolate(const Duration(seconds: 12));
    await pumpEventQueue();

    expect(platform.calls.length, before);
  });

  test('a real position anchor re-syncs the timeline without republishing metadata', () async {
    final visibility = _Visibility();
    final player = _StubPlayer(_playing());
    final container = await boot(
      island: true,
      overlay: true,
      visibility: visibility,
      player: player,
    );

    container.read(dynamicIslandControllerProvider);
    visibility.set(false);
    await pumpEventQueue();

    player.anchor(const Duration(seconds: 42));
    await pumpEventQueue();

    expect(platform.calls.last, 'syncPosition');
    expect(platform.lastArguments?['positionMs'], 42000);
  });

  test('switching the island off takes the surface down and touches nothing else', () async {
    final visibility = _Visibility();
    final container = await boot(
      island: true,
      overlay: true,
      visibility: visibility,
      player: _StubPlayer(_playing()),
    );

    container.read(dynamicIslandControllerProvider);
    visibility.set(false);
    await pumpEventQueue();
    expect(container.read(dynamicIslandControllerProvider).floatingVisible, isTrue);

    await container.read(settingsProvider.notifier).setDynamicIsland(false);
    await pumpEventQueue();

    expect(platform.calls.last, 'hide');
    expect(container.read(dynamicIslandControllerProvider).floatingVisible, isFalse);
    // The player is untouched: no stop, no pause, no mode change.
    expect(container.read(playerControllerProvider).isPlaying, isTrue);
    expect(container.read(playerControllerProvider).mode, PlaybackMode.appRemote);
  });

  test('a press on the floating surface runs through the one player', () async {
    final visibility = _Visibility();
    final player = _StubPlayer(_playing());
    final container = await boot(
      island: true,
      overlay: true,
      visibility: visibility,
      player: player,
    );

    container.read(dynamicIslandControllerProvider);
    visibility.set(false);
    await pumpEventQueue();

    await platform.press(channel, 'pause');
    await pumpEventQueue();
    expect(player.toggles, 1);

    await platform.press(channel, 'next');
    await pumpEventQueue();
    expect(player.skips, 1);

    await platform.press(channel, 'previous');
    await pumpEventQueue();
    expect(player.rewinds, 1);
  });

  test('an ungranted permission stops the island asking again and again', () async {
    platform.granted = false;
    final visibility = _Visibility();
    final container = await boot(
      island: true,
      overlay: true,
      visibility: visibility,
      player: _StubPlayer(_playing()),
    );

    container.read(dynamicIslandControllerProvider);
    visibility.set(false);
    await pumpEventQueue();

    expect(platform.calls.contains('show'), isFalse);
    expect(
      container.read(islandCapabilityProvider).reason,
      IslandUnavailableReason.overlayPermissionMissing,
    );
  });
}

// ---------------------------------------------------------------------------
// Doubles
// ---------------------------------------------------------------------------

/// Stands in for Android's overlay window, recording what it was asked to do.
class _FakeIslandPlatform {
  final List<String> calls = <String>[];
  Map<Object?, Object?>? lastArguments;
  bool granted = true;
  bool visible = false;

  Map<Object?, Object?>? get lastFrame =>
      lastArguments != null && lastArguments!.containsKey('title')
          ? lastArguments
          : null;

  Future<Object?> handle(MethodCall call) async {
    calls.add(call.method);
    lastArguments = call.arguments as Map<Object?, Object?>?;

    switch (call.method) {
      case 'capability':
      case 'requestPermission':
        return <String, Object?>{
          'surface': 'overlayWindow',
          'reason': granted ? 'none' : 'overlayPermissionMissing',
          'granted': granted,
        };
      case 'show':
        visible = granted;
        return granted;
      case 'hide':
        visible = false;
        return null;
      default:
        return null;
    }
  }

  /// Delivers a transport press the way the native side does.
  Future<void> press(MethodChannel channel, String command) {
    return TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .handlePlatformMessage(
          channel.name,
          channel.codec.encodeMethodCall(
            MethodCall('command', <String, Object?>{'command': command}),
          ),
          (_) {},
        );
  }
}

/// Visibility without a real `AppLifecycleListener`, so a test can put AURIX in
/// the background without driving platform lifecycle messages.
class _Visibility extends AppVisibilityController {
  @override
  bool build() => true;

  void set(bool value) => state = value;
}

/// A player that holds a fixed state and counts what was asked of it.
///
/// The point of the island's design is that it can only ever ask; this is what
/// makes "no second playback engine" testable rather than merely asserted.
class _StubPlayer extends PlayerController {
  _StubPlayer(this.initial);

  final AurixPlaybackState initial;
  int toggles = 0;
  int skips = 0;
  int rewinds = 0;

  @override
  AurixPlaybackState build() => initial;

  @override
  Future<void> togglePlayPause() async {
    toggles++;
    state = state.copyWith(isPlaying: !state.isPlaying);
  }

  @override
  Future<void> next({bool manual = true}) async => skips++;

  @override
  Future<void> previous() async => rewinds++;

  void moveTo(int index) {
    state = state.copyWith(queue: state.queue.jumpToOrderIndex(index));
  }

  /// A ticker pass: the position moves, the anchor does not.
  void interpolate(Duration position) {
    state = state.copyWith(position: position);
  }

  /// A real report from Spotify: position and anchor together.
  void anchor(Duration position) {
    state = state.copyWith(position: position, positionUpdatedAt: DateTime.now());
  }
}

AurixPlaybackState _playing() => AurixPlaybackState(
  queue: PlaybackQueue.from(Fixtures.tracks(3)),
  mode: PlaybackMode.appRemote,
  isPlaying: true,
  duration: const Duration(minutes: 3),
  remoteConnected: true,
);
