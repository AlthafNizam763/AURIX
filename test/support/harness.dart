import 'dart:async';

import 'package:aurix/core/network/connectivity_service.dart';
import 'package:aurix/core/providers/app_providers.dart';
import 'package:aurix/core/storage/preferences_store.dart';
import 'package:aurix/core/storage/secure_store.dart';
import 'package:aurix/core/theme/app_theme.dart';
import 'package:aurix/data/models/models.dart';
import 'package:aurix/data/repositories/auth_repository.dart';
import 'package:aurix/features/auth/providers/auth_provider.dart';
import 'package:aurix/features/library/providers/library_provider.dart';
import 'package:aurix/playback/preview_audio_handler.dart';
import 'package:aurix/shared/widgets/icons/aurix_glyphs.dart';
import 'package:aurix/shared/widgets/icons/aurix_icon.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:just_audio/just_audio.dart';
import 'package:mocktail/mocktail.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'fixtures.dart';

/// Test double for `just_audio`.
///
/// The real `AudioPlayer` reaches for a platform channel the moment it is
/// asked to load anything, so widget tests get this instead. Its streams are
/// controllable, which is what lets a test drive the player's position without
/// any audio existing.
class MockAudioPlayer extends Mock implements AudioPlayer {}

class MockConnectivityService extends Mock implements ConnectivityService {}

/// Builds a [PreviewAudioHandler] backed by a mock player.
///
/// Pass [positions] to drive the position stream from a test; the caller owns
/// that controller and is responsible for closing it. Without one, an empty
/// stream is used, so nothing needs closing.
// ignore: close_sinks — the optional controller is owned by the caller.
PreviewAudioHandler buildTestAudioHandler({
  StreamController<Duration>? positions,
}) {
  final player = MockAudioPlayer();

  when(() => player.positionStream).thenAnswer(
    (_) => positions?.stream ?? const Stream<Duration>.empty(),
  );
  when(() => player.playbackEventStream)
      .thenAnswer((_) => const Stream<PlaybackEvent>.empty());
  when(() => player.processingStateStream)
      .thenAnswer((_) => const Stream<ProcessingState>.empty());
  when(() => player.position).thenReturn(Duration.zero);
  when(() => player.bufferedPosition).thenReturn(Duration.zero);
  when(() => player.duration).thenReturn(null);
  when(() => player.playing).thenReturn(false);
  when(() => player.speed).thenReturn(1);
  when(() => player.processingState).thenReturn(ProcessingState.idle);
  when(player.play).thenAnswer((_) async {});
  when(player.pause).thenAnswer((_) async {});
  when(player.stop).thenAnswer((_) async {});
  when(player.dispose).thenAnswer((_) async {});
  when(() => player.seek(any())).thenAnswer((_) async {});
  when(() => player.setUrl(any())).thenAnswer((_) async => null);
  when(() => player.setVolume(any())).thenAnswer((_) async {});

  return PreviewAudioHandler(player: player);
}

ConnectivityService buildTestConnectivity({bool offline = false}) {
  final service = MockConnectivityService();
  when(() => service.isOffline).thenReturn(offline);
  when(() => service.status)
      .thenReturn(offline ? NetworkStatus.offline : NetworkStatus.online);
  when(() => service.onStatusChanged)
      .thenAnswer((_) => const Stream<NetworkStatus>.empty());
  when(service.refresh).thenAnswer(
    (_) async => offline ? NetworkStatus.offline : NetworkStatus.online,
  );
  return service;
}

/// The overrides every widget test needs: real storage backed by mocks, a
/// non-platform audio handler and a controllable network status.
///
/// Individual tests append their own overrides for the providers under test.
Future<List<Override>> baseOverrides({
  bool offline = false,
  Map<String, Object> initialPreferences = const {},
}) async {
  SharedPreferences.setMockInitialValues(initialPreferences);
  final preferences = await PreferencesStore.open();

  return <Override>[
    preferencesStoreProvider.overrideWithValue(preferences),
    secureStoreProvider.overrideWithValue(InMemorySecureStore()),
    connectivityServiceProvider
        .overrideWithValue(buildTestConnectivity(offline: offline)),
    audioHandlerProvider.overrideWithValue(buildTestAudioHandler()),
  ];
}

/// An [AuthController] that reports a fixed state and talks to no Firebase.
///
/// The real controller subscribes to `authStateChanges` in `build`, which
/// needs an initialised Firebase app — something a widget test has no business
/// providing. Overriding the notifier rather than mocking Firebase keeps the
/// test's dependency on identity down to one value: who is signed in.
class _StaticAuthController extends AuthController {
  _StaticAuthController(this._state);

  final AuthState _state;

  /// Avatar ids this controller was asked to save, in order.
  ///
  /// The assertion the avatar tests used to make against `SharedPreferences`.
  /// The choice is a Firestore write now, so what a widget test can honestly
  /// check is that the write was *requested* with the right value — the write
  /// itself is `FirestoreProfileService`'s to get right, and is covered by the
  /// rules rather than by a widget.
  final List<String> savedAvatarIds = <String>[];

  @override
  AuthState build() => _state;

  /// Records the request and echoes it into state.
  ///
  /// Overridden rather than inherited because the real implementation reaches
  /// for the repository that [build] would have created — and this controller
  /// deliberately never runs the real `build`.
  @override
  Future<void> setAvatar(String avatarId) async {
    savedAvatarIds.add(avatarId);
    final user = state.user;
    if (user != null) {
      state = state.copyWith(user: user.copyWith(avatarId: avatarId));
    }
  }

  @override
  Future<void> updateName(String name) async {
    final user = state.user;
    if (user != null) state = state.copyWith(user: user.copyWith(name: name));
  }
}

/// Reads back what [signedInOverrides] recorded.
///
/// The controller is private, so this is how a test asks "did the app try to
/// save that avatar?" without the harness leaking its type.
List<String> savedAvatarIds(ProviderContainer container) {
  final controller = container.read(authControllerProvider.notifier);
  return controller is _StaticAuthController
      ? controller.savedAvatarIds
      : const <String>[];
}

/// Everything a screen needs to render as if a user were signed in with a
/// library.
///
/// The three collection providers are overridden with plain streams rather
/// than with a fake Firestore, because that is the seam the screens actually
/// depend on: they watch `likedTracksProvider`, `userPlaylistsProvider` and
/// `recentlyPlayedProvider`, and what fills those is not their concern.
///
/// Append to [baseOverrides], not instead of it — the preferences store and
/// audio handler are still required.
List<Override> signedInOverrides({
  AurixUser? user,
  List<Track> likedTracks = const [],
  List<Playlist> playlists = const [],
  List<PlayHistoryEntry> recentlyPlayed = const [],
}) {
  final account = user ?? Fixtures.aurixUser;
  return <Override>[
    authControllerProvider.overrideWith(
      () => _StaticAuthController(
        AuthState(status: AuthStatus.signedIn, user: account),
      ),
    ),
    likedTracksProvider.overrideWith((ref) => Stream.value(likedTracks)),
    userPlaylistsProvider.overrideWith((ref) => Stream.value(playlists)),
    recentlyPlayedProvider.overrideWith((ref) => Stream.value(recentlyPlayed)),
  ];
}

/// The signed-out equivalent.
List<Override> signedOutOverrides() => <Override>[
  authControllerProvider.overrideWith(
    () => _StaticAuthController(AuthState.signedOut),
  ),
];

/// Wraps a widget in the app's theme and a [ProviderScope].
///
/// Uses the real [AppTheme] rather than a bare MaterialApp so tests exercise
/// the same text styles and colours the app ships — a widget that only renders
/// correctly under a default theme is not actually verified.
Widget wrapForTest(
  Widget child, {
  List<Override> overrides = const [],
  NavigatorObserver? navigatorObserver,
}) {
  return ProviderScope(
    overrides: overrides,
    child: MaterialApp(
      theme: AppTheme.dark(),
      debugShowCheckedModeBanner: false,
      navigatorObservers: navigatorObserver == null ? const [] : [navigatorObserver],
      home: Scaffold(body: child),
    ),
  );
}

/// Finds an [AurixIcon] drawing a particular glyph.
///
/// The replacement for `find.byIcon`, which only works on Material's font
/// glyphs. AURIX icons are painted, so there is no `IconData` to match on —
/// the glyph enum is the identity.
Finder findGlyph(AurixGlyph glyph) => find.byWidgetPredicate(
  (widget) => widget is AurixIcon && widget.glyph == glyph,
  description: 'AurixIcon(${glyph.name})',
);

/// Wraps a widget that is itself a full screen (provides its own Scaffold).
Widget wrapScreenForTest(
  Widget child, {
  List<Override> overrides = const [],
}) {
  return ProviderScope(
    overrides: overrides,
    child: MaterialApp(
      theme: AppTheme.dark(),
      debugShowCheckedModeBanner: false,
      home: child,
    ),
  );
}
