import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:spotify_sdk/models/player_options.dart' as sdk;
import 'package:spotify_sdk/models/player_state.dart' as sdk;
import 'package:spotify_sdk/spotify_sdk.dart';

import '../../core/config/env.dart';
import '../../core/utils/app_logger.dart';
import '../models/playback.dart';

/// Why App Remote is not usable right now.
///
/// Each case has a different remedy, and conflating them is what produces the
/// "No Spotify device available" dead end: that message tells someone to open
/// Spotify on another device when the actual problem might be that Spotify is
/// not installed, or that they have never granted this app remote control.
enum AppRemoteFailure {
  /// The Spotify app is not on this device.
  notInstalled,

  /// The user has not granted `app-remote-control`, or the grant lapsed.
  notAuthorized,

  /// Spotify refused remote control for this account. In practice: not
  /// Premium, or the account is not on the app's Development Mode allowlist.
  notPermitted,

  /// The Spotify app is installed but the bind failed — it was force-stopped,
  /// is updating, or the connection dropped.
  connectionFailed,

  /// The URI handed to `play` was empty or not a Spotify URI.
  invalidUri,

  /// App Remote does not exist on this platform (web, desktop).
  unsupportedPlatform,
}

/// Where the App Remote binding stands, independent of the Web API.
///
/// `GET /me/player/devices` returning 200 proves the Web API is reachable and
/// nothing more — it does not mean `SpotifyAppRemote.connect()` succeeded, and
/// AURIX never appears in that device list at all. The two are reported
/// separately so the UI can stop blaming a missing Connect device for what is
/// actually an ungranted authorization.
enum AppRemoteConnectionState {
  /// Bound to the Spotify app; playback commands will reach it.
  connected,

  /// Could connect, but has not — either never tried, or the last attempt was
  /// refused for a reason the user can still clear (typically authorization).
  notConnected,

  /// Spotify is not installed, so there is nothing to bind to.
  noSpotifyApp,

  /// No App Remote SDK on this platform (web, desktop).
  unsupported,
}

/// Thrown by [SpotifyAppRemoteService] with a cause the UI can act on.
class AppRemoteException implements Exception {
  const AppRemoteException(this.failure, {this.debugDetail});

  final AppRemoteFailure failure;

  /// For logs only — never rendered.
  final String? debugDetail;

  /// Display-ready, and specific about the fix.
  String get message => switch (failure) {
    AppRemoteFailure.notInstalled =>
      'Spotify is not installed. Install Spotify to play this track.',
    AppRemoteFailure.notAuthorized =>
      'Spotify has not granted AURIX remote control. Connect to Spotify to '
          'allow it.',
    AppRemoteFailure.notPermitted =>
      'Spotify would not allow remote control for this account. Controlling '
          'playback requires Spotify Premium.',
    AppRemoteFailure.connectionFailed =>
      "Couldn't reach the Spotify app. Open Spotify once, then try again.",
    AppRemoteFailure.invalidUri => 'That track cannot be played on Spotify.',
    AppRemoteFailure.unsupportedPlatform =>
      'Spotify app playback is only available on Android and iOS.',
  };

  @override
  String toString() =>
      'AppRemoteException(${failure.name}${debugDetail == null ? '' : ': $debugDetail'})';
}

/// A snapshot of what the Spotify app is doing, normalised away from the SDK.
///
/// Keeping the SDK's `PlayerState` out of the rest of the app means the player
/// controller never imports `spotify_sdk`, and the web build never links it.
@immutable
class AppRemoteState {
  const AppRemoteState({
    required this.isPlaying,
    required this.position,
    this.trackUri,
    this.trackName,
    this.artistName,
    this.albumName,
    this.duration,
    this.imageUri,
    this.isShuffling = false,
    this.repeatMode = RepeatState.off,
  });

  final bool isPlaying;
  final Duration position;
  final String? trackUri;
  final String? trackName;
  final String? artistName;
  final String? albumName;
  final Duration? duration;

  /// Spotify's own shuffle and repeat, which it owns while it is the player.
  ///
  /// Carried so AURIX's controls show what Spotify is actually doing rather
  /// than the last thing AURIX set — the two drift the moment the user touches
  /// the Spotify app.
  final bool isShuffling;
  final RepeatState repeatMode;

  /// Spotify's own image identifier. Resolving it to bytes needs
  /// `SpotifySdk.getImage`, which the UI does not currently use — AURIX
  /// already has artwork URLs from the Web API for anything it queued.
  final String? imageUri;

  /// The bare track ID, for matching against a Web API track.
  String? get trackId {
    final uri = trackUri;
    if (uri == null || uri.isEmpty) return null;
    final parts = uri.split(':');
    return parts.length == 3 && parts[1] == 'track' ? parts.last : null;
  }
}

/// Controls playback inside the user's own Spotify app, over App Remote.
///
/// ## Why this exists alongside the Web API
///
/// The Web API's `PUT /me/player/play` is Spotify **Connect**: it commands a
/// device that is already registered with Spotify's servers. A phone running
/// AURIX is not such a device — AURIX is not a Connect endpoint and never
/// appears in `GET /me/player/devices`. So on a phone with no *other* Spotify
/// device signed in, Connect has nothing to command and playback is
/// impossible, which is exactly the "No Spotify device available" dead end.
///
/// App Remote is the mechanism Spotify provides for that case: AURIX binds to
/// the Spotify app installed on the same phone and drives it directly. No
/// audio passes through AURIX, and nothing is decoded here — this is a remote
/// control, which is the only thing Spotify's terms allow a third-party client
/// to be.
///
/// The Web API stays exactly as it is for everything else: search, catalogue,
/// library, profile, and Connect control when a real Connect device exists.
///
/// ## Platform
///
/// Android and iOS only. Every method short-circuits on web with
/// [AppRemoteFailure.unsupportedPlatform] rather than calling into the plugin,
/// so the web build never exercises this path.
class SpotifyAppRemoteService {
  SpotifyAppRemoteService();

  bool _connected = false;
  StreamSubscription<sdk.PlayerState>? _stateSubscription;
  final StreamController<AppRemoteState> _states =
      StreamController<AppRemoteState>.broadcast();

  /// Player state pushed by the Spotify app.
  ///
  /// Unlike Connect — which AURIX has to poll every four seconds — App Remote
  /// pushes on every change, so the UI can follow a skip made inside Spotify
  /// itself without a polling loop.
  Stream<AppRemoteState> get states => _states.stream;

  bool get isConnected => _connected;

  /// False on web and desktop, where the native SDK does not exist.
  static bool get isSupportedPlatform =>
      !kIsWeb &&
      (defaultTargetPlatform == TargetPlatform.android ||
          defaultTargetPlatform == TargetPlatform.iOS);

  /// Binds to the Spotify app, if it is not already bound.
  ///
  /// Returns normally when connected. Throws [AppRemoteException] otherwise —
  /// the caller needs the *reason* to choose between "install Spotify",
  /// "connect to Spotify" and "this needs Premium".
  Future<void> connect() async {
    if (!isSupportedPlatform) {
      throw const AppRemoteException(AppRemoteFailure.unsupportedPlatform);
    }
    if (_connected) return;

    if (!Env.isConfigured) {
      throw const AppRemoteException(
        AppRemoteFailure.notAuthorized,
        debugDetail: 'No Spotify client ID configured',
      );
    }

    AppLogger.info('Starting App Remote connection', scope: 'appremote');

    try {
      // `spotify_sdk` builds ConnectionParams with `.showAuthView(true)`
      // already (SpotifySdkPlugin.kt:217-220), so this call *is* the
      // authorization flow: when the user has not yet granted remote control,
      // Spotify shows its own consent screen before completing the bind.
      //
      // When it still throws UserNotAuthorized despite that, the cause is
      // outside the app — the package name and signing certificate SHA-1 are
      // not registered in the Spotify dashboard, so Spotify cannot verify the
      // caller and refuses without ever showing the screen. No amount of Dart
      // or a hand-written native bridge changes that; see the README.
      //
      // The redirect URL is App Remote's own registered entry, kept separate
      // from the PKCE callback so the two auth flows cannot collide.
      final connected = await SpotifySdk.connectToSpotifyRemote(
        clientId: Env.spotifyClientId,
        redirectUrl: Env.appRemoteRedirectUri,
        playerName: 'AURIX',
      );

      if (!connected) {
        throw const AppRemoteException(
          AppRemoteFailure.connectionFailed,
          debugDetail: 'connectToSpotifyRemote returned false',
        );
      }

      _connected = true;
      _listenToPlayerState();
      // Reaching here means the bind completed, which — when showAuthView is
      // on — implies the user either had already authorised AURIX or has just
      // done so on Spotify's consent screen.
      AppLogger.info('Spotify installed: true', scope: 'appremote');
      AppLogger.info('Authorization completed', scope: 'appremote');
      AppLogger.info('Connected successfully', scope: 'appremote');
    } on AppRemoteException {
      rethrow;
    } on PlatformException catch (error) {
      _connected = false;
      final failure = _classify(error);

      // Spotify's own error distinguishes "app missing" from "app present but
      // not authorised", so it is the only reliable installed-check available:
      // spotify_sdk 3.0.1 removed `isSpotifyAppActive`, and probing package
      // visibility separately would answer a different question.
      AppLogger.info(
        'Spotify installed: ${failure != AppRemoteFailure.notInstalled}',
        scope: 'appremote',
      );

      if (failure == AppRemoteFailure.notAuthorized) {
        // Spotify refused to authorise the caller. Said plainly, because the
        // fix is in the dashboard rather than in the app, and the previous
        // wording sent people looking for a missing Spotify Connect device.
        AppLogger.warn(
          'Authorization required — Spotify did not grant remote control. '
          'Check that package com.aurix.app and this build\'s signing SHA-1 '
          'are registered under Android Packages in the Spotify dashboard, '
          'and that ${Env.appRemoteRedirectUri} is a registered Redirect URI.',
          scope: 'appremote',
        );
      }

      AppLogger.warn(
        'Connection failed: ${failure.name}',
        scope: 'appremote',
        error: error.message,
      );
      throw AppRemoteException(
        failure,
        debugDetail: '${error.code}: ${error.message}',
      );
    } on MissingPluginException catch (error) {
      _connected = false;
      throw AppRemoteException(
        AppRemoteFailure.unsupportedPlatform,
        debugDetail: error.message,
      );
    }
  }

  /// Maps the plugin's platform errors onto something the UI can act on.
  ///
  /// The Android SDK reports its failures as `PlatformException` codes and
  /// messages rather than typed errors, so this matches on both. The strings
  /// come from `com.spotify.android.appremote.api.error` — `CouldNotFindSpotifyApp`
  /// when Spotify is absent, `NotLoggedIn` when no account is signed in,
  /// `UserNotAuthorized` when remote control was never granted.
  static AppRemoteFailure _classify(PlatformException error) {
    final haystack = '${error.code} ${error.message ?? ''}'.toLowerCase();

    if (haystack.contains('couldnotfindspotifyapp') ||
        haystack.contains('not installed') ||
        haystack.contains('spotifynotinstalled')) {
      return AppRemoteFailure.notInstalled;
    }
    if (haystack.contains('usernotauthorized') ||
        haystack.contains('notloggedin') ||
        haystack.contains('authentication')) {
      return AppRemoteFailure.notAuthorized;
    }
    if (haystack.contains('premium') || haystack.contains('forbidden')) {
      return AppRemoteFailure.notPermitted;
    }
    return AppRemoteFailure.connectionFailed;
  }

  void _listenToPlayerState() {
    _stateSubscription?.cancel();
    try {
      _stateSubscription = SpotifySdk.subscribePlayerState().listen(
        (state) => _states.add(_normalise(state)),
        // A failed or closed stream means the binding is gone — Spotify was
        // force-stopped, updated, or dropped the connection. Clearing the flag
        // is what lets the next command rebind instead of firing into a dead
        // channel and looking like a playback failure.
        onError: (Object error) {
          AppLogger.warn(
            'App Remote player state stream failed',
            scope: 'appremote',
            error: error,
          );
          _connected = false;
        },
        onDone: () {
          AppLogger.info('App Remote player state stream closed', scope: 'appremote');
          _connected = false;
        },
      );
    } on Object catch (error) {
      AppLogger.warn(
        'Could not subscribe to App Remote player state',
        scope: 'appremote',
        error: error,
      );
    }
  }

  static AppRemoteState _normalise(sdk.PlayerState state) {
    final track = state.track;
    return AppRemoteState(
      // The SDK reports pause, not play — inverting it here keeps the rest of
      // the app speaking in one direction.
      isPlaying: !state.isPaused,
      position: Duration(milliseconds: state.playbackPosition),
      trackUri: track?.uri,
      trackName: track?.name,
      artistName: track?.artist.name,
      albumName: track?.album.name,
      duration: track == null ? null : Duration(milliseconds: track.duration),
      imageUri: track?.imageUri.raw,
      isShuffling: state.playbackOptions.isShuffling,
      repeatMode: _repeatFrom(state.playbackOptions.repeatMode),
    );
  }

  static RepeatState _repeatFrom(sdk.RepeatMode mode) => switch (mode) {
    sdk.RepeatMode.track => RepeatState.track,
    sdk.RepeatMode.context => RepeatState.context,
    sdk.RepeatMode.off => RepeatState.off,
  };

  /// Starts [spotifyUri] in the Spotify app, connecting first if needed.
  Future<void> play(String spotifyUri) async {
    if (spotifyUri.isEmpty || !spotifyUri.startsWith('spotify:')) {
      throw AppRemoteException(
        AppRemoteFailure.invalidUri,
        debugDetail: 'Not a Spotify URI: "$spotifyUri"',
      );
    }
    await connect();
    await _guard(() => SpotifySdk.play(spotifyUri: spotifyUri), 'play');
  }

  Future<void> pause() => _requireConnected(
    () => _guard(SpotifySdk.pause, 'pause'),
  );

  Future<void> resume() => _requireConnected(
    () => _guard(SpotifySdk.resume, 'resume'),
  );

  Future<void> skipNext() => _requireConnected(
    () => _guard(SpotifySdk.skipNext, 'skipNext'),
  );

  Future<void> skipPrevious() => _requireConnected(
    () => _guard(SpotifySdk.skipPrevious, 'skipPrevious'),
  );

  Future<void> seek(Duration position) => _requireConnected(
    () => _guard(
      () => SpotifySdk.seekTo(positionedMilliseconds: position.inMilliseconds),
      'seekTo',
    ),
  );

  /// Reads the current state once, for reconciling after a resume.
  Future<AppRemoteState?> currentState() async {
    if (!isSupportedPlatform || !_connected) return null;
    try {
      final state = await SpotifySdk.getPlayerState();
      return state == null ? null : _normalise(state);
    } on Object {
      return null;
    }
  }

  Future<T> _requireConnected<T>(Future<T> Function() action) async {
    await connect();
    return action();
  }

  /// Runs a transport command, translating plugin errors and treating a
  /// dropped binding as "no longer connected" so the next call reconnects.
  Future<void> _guard(Future<void> Function() action, String name) async {
    try {
      await action();
      AppLogger.info('Playback command sent ($name)', scope: 'appremote');
    } on PlatformException catch (error) {
      final failure = _classify(error);
      if (failure == AppRemoteFailure.connectionFailed) _connected = false;
      AppLogger.warn(
        'Playback command failed ($name): ${failure.name}',
        scope: 'appremote',
        error: error.message,
      );
      throw AppRemoteException(
        failure,
        debugDetail: '${error.code}: ${error.message}',
      );
    }
  }

  Future<void> disconnect() async {
    await _stateSubscription?.cancel();
    _stateSubscription = null;
    if (!_connected) return;
    _connected = false;
    try {
      await SpotifySdk.disconnect();
    } on Object catch (error) {
      AppLogger.debug('App Remote disconnect failed: $error', scope: 'appremote');
    }
  }

  Future<void> dispose() async {
    await disconnect();
    await _states.close();
  }
}
