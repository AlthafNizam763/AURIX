import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import '../core/utils/app_logger.dart';

/// What this platform can actually do with a floating playback surface.
///
/// Reported by the native side rather than guessed from
/// `defaultTargetPlatform`, because the answer is not a property of the OS
/// family: on Android it depends on an overlay grant the user controls in
/// system settings, and on iOS it depends on whether this build ships a Live
/// Activity extension. A Dart-side `Platform.isAndroid` check would be a guess,
/// and a wrong one is what produces a Settings switch that turns on a feature
/// that never appears.
enum IslandSurface {
  /// A floating window that can be drawn over other apps. Android, and only
  /// once `SYSTEM_ALERT_WINDOW` has been granted.
  overlayWindow,

  /// An OS-owned Live Activity — the real iOS Dynamic Island. Requires a
  /// widget extension target in the Xcode project; see ios/LiveActivity.
  liveActivity,

  /// Nothing beyond the media notification and lock screen. The honest answer
  /// on iOS builds with no extension, on desktop, and on the web.
  none,
}

/// Why the floating surface is unavailable, when it is.
///
/// Separate from [IslandSurface] because the remedies differ completely: a
/// missing grant is one tap away in Settings, a missing Live Activity extension
/// is a build-time change, and an unsupported platform is neither. The Settings
/// screen renders a different row for each, and none of them auto-requests
/// anything.
enum IslandUnavailableReason {
  /// The surface is available. No remedy needed.
  none,

  /// Android: the user has not granted "Display over other apps".
  overlayPermissionMissing,

  /// iOS: this build has no Live Activity extension linked, so ActivityKit has
  /// no UI to render. See ios/LiveActivity/README.md.
  liveActivityExtensionMissing,

  /// iOS: the user has switched Live Activities off for AURIX in Settings.
  liveActivityDisabledByUser,

  /// Web, desktop, or an Android version below the overlay API.
  unsupportedPlatform,
}

/// What the native side reports about the floating surface.
@immutable
class IslandCapability {
  const IslandCapability({
    required this.surface,
    required this.reason,
    this.granted = false,
  });

  /// The honest default before the platform has answered, and the permanent
  /// answer on web and desktop.
  static const IslandCapability unsupported = IslandCapability(
    surface: IslandSurface.none,
    reason: IslandUnavailableReason.unsupportedPlatform,
  );

  final IslandSurface surface;
  final IslandUnavailableReason reason;

  /// Whether the surface can be shown *right now* — the permission is granted
  /// (Android) or the extension is present and enabled (iOS).
  final bool granted;

  /// True when asking the user for a permission would actually achieve
  /// something. False for a missing extension, which no dialog can fix.
  bool get isRequestable =>
      reason == IslandUnavailableReason.overlayPermissionMissing;

  /// True when the platform has a floating surface at all, granted or not.
  bool get exists => surface != IslandSurface.none;

  /// True when a floating surface can be put on screen this second.
  bool get isUsable => exists && granted;

  static IslandCapability _parse(Map<Object?, Object?>? raw) {
    if (raw == null) return unsupported;
    return IslandCapability(
      surface: switch (raw['surface']) {
        'overlayWindow' => IslandSurface.overlayWindow,
        'liveActivity' => IslandSurface.liveActivity,
        _ => IslandSurface.none,
      },
      reason: switch (raw['reason']) {
        'overlayPermissionMissing' =>
          IslandUnavailableReason.overlayPermissionMissing,
        'liveActivityExtensionMissing' =>
          IslandUnavailableReason.liveActivityExtensionMissing,
        'liveActivityDisabledByUser' =>
          IslandUnavailableReason.liveActivityDisabledByUser,
        'unsupportedPlatform' => IslandUnavailableReason.unsupportedPlatform,
        _ => IslandUnavailableReason.none,
      },
      granted: raw['granted'] == true,
    );
  }

  @override
  bool operator ==(Object other) =>
      other is IslandCapability &&
      other.surface == surface &&
      other.reason == reason &&
      other.granted == granted;

  @override
  int get hashCode => Object.hash(surface, reason, granted);

  @override
  String toString() =>
      'IslandCapability(${surface.name}, ${reason.name}, granted: $granted)';
}

/// A transport button pressed on the floating surface.
///
/// The surface owns no player. Every press comes back here and is executed by
/// the one [PlayerController] the rest of the app uses, which is what stops the
/// island becoming a second playback engine.
enum IslandCommand { play, pause, next, previous, open, dismiss }

/// One frame of playback, as the floating surface needs it.
///
/// Deliberately a value object rather than a pile of channel arguments: the
/// bridge suppresses republishing an unchanged frame, and that check is only
/// honest if the whole payload compares by value.
@immutable
class IslandFrame {
  const IslandFrame({
    required this.trackId,
    required this.title,
    required this.artist,
    required this.playing,
    required this.position,
    required this.duration,
    this.album,
    this.artworkUrl,
  });

  final String trackId;
  final String title;
  final String artist;
  final String? album;
  final String? artworkUrl;
  final bool playing;

  /// Spotify's own reported position, as of [IslandFrame] construction.
  ///
  /// The native surface extrapolates from this anchor exactly as Android's
  /// `PlaybackState` does — it never runs a clock of its own that could
  /// disagree with the player.
  final Duration position;

  final Duration duration;

  Map<String, Object?> toMap() => <String, Object?>{
    'trackId': trackId,
    'title': title,
    'artist': artist,
    'album': album,
    'artworkUrl': artworkUrl,
    'playing': playing,
    'positionMs': position.inMilliseconds,
    'durationMs': duration.inMilliseconds,
  };

  /// Everything except the position, which moves continuously.
  ///
  /// Two frames that differ only in position do not need republishing: the
  /// native side is already interpolating, and a push per tick would be the
  /// duplicate-timer traffic this design exists to avoid. The position is
  /// pushed on divergence instead — see `DynamicIslandController`.
  bool sameContentAs(IslandFrame other) =>
      other.trackId == trackId &&
      other.title == title &&
      other.artist == artist &&
      other.album == album &&
      other.artworkUrl == artworkUrl &&
      other.playing == playing &&
      other.duration == duration;

  @override
  bool operator ==(Object other) =>
      other is IslandFrame && sameContentAs(other) && other.position == position;

  @override
  int get hashCode => Object.hash(
    trackId,
    title,
    artist,
    album,
    artworkUrl,
    playing,
    position,
    duration,
  );
}

/// The one route between AURIX's playback state and a floating surface owned by
/// the OS.
///
/// ## What this is not
///
/// It is not a player. It holds no Spotify connection, no queue and no timer of
/// its own, and it cannot start or stop audio. Every method here either pushes
/// what the [PlayerController] already knows onto a native surface, or carries
/// a button press back the other way. That is the whole contract, and it is why
/// enabling the island cannot produce a second playback engine, a second App
/// Remote binding or a second poll.
///
/// ## Failure is normal
///
/// The channel does not exist on web, on desktop, or in a widget test, and the
/// Android side answers `none` until an overlay grant arrives. Every call
/// therefore swallows [MissingPluginException] and returns the safe answer
/// rather than throwing into the provider graph.
class BackgroundIslandChannel {
  BackgroundIslandChannel({MethodChannel? channel})
    : _channel = channel ?? const MethodChannel(_name) {
    _channel.setMethodCallHandler(_onNativeCall);
  }

  static const String _name = 'com.aurix.app/dynamic_island';

  final MethodChannel _channel;

  final StreamController<IslandCommand> _commands =
      StreamController<IslandCommand>.broadcast();

  /// Transport presses made on the floating surface.
  Stream<IslandCommand> get commands => _commands.stream;

  Future<void> _onNativeCall(MethodCall call) async {
    if (call.method != 'command') return;
    final name = call.arguments is Map
        ? (call.arguments as Map)['command']
        : call.arguments;
    final command = switch (name) {
      'play' => IslandCommand.play,
      'pause' => IslandCommand.pause,
      'next' => IslandCommand.next,
      'previous' => IslandCommand.previous,
      'open' => IslandCommand.open,
      'dismiss' => IslandCommand.dismiss,
      _ => null,
    };
    if (command == null) return;
    AppLogger.debug('Island command: ${command.name}', scope: 'island');
    _commands.add(command);
  }

  /// Asks the platform what it can do. Never throws.
  Future<IslandCapability> capability() async {
    final raw = await _invoke<Map<Object?, Object?>>('capability');
    return IslandCapability._parse(raw);
  }

  /// Sends the user to the system screen where the overlay grant lives.
  ///
  /// **Only ever called from an explicit tap** on the Settings row that
  /// explains what the permission is for. There is deliberately no path that
  /// reaches this from app start, from enabling the in-app island, or from
  /// playback beginning — see the note on `setOverlayEnabled` in
  /// `SettingsController`.
  ///
  /// Returns the capability as it stands after the user comes back.
  Future<IslandCapability> requestPermission() async {
    final raw = await _invoke<Map<Object?, Object?>>('requestPermission');
    return IslandCapability._parse(raw);
  }

  /// Puts the surface on screen and publishes [frame] in one call, so it never
  /// appears empty for a frame.
  ///
  /// Returns whether the surface is actually up. This is the one call whose
  /// failure must be visible to the caller: a grant revoked while AURIX was not
  /// looking, or an OEM refusing the window type, both fail here — and a
  /// controller that assumed success would mark the island shown, stop calling
  /// `show`, and route every later update into a window that does not exist.
  Future<bool> show(IslandFrame frame) async =>
      await _invoke<bool>('show', frame.toMap()) ?? false;

  /// Republishes metadata and transport state.
  Future<void> update(IslandFrame frame) =>
      _invoke<void>('update', frame.toMap());

  /// Re-anchors the timeline without touching metadata.
  ///
  /// The counterpart of Android's `PlaybackState.updatePosition`: the surface
  /// interpolates between anchors, and this is called only when its projection
  /// has actually drifted from Spotify's reported position.
  Future<void> syncPosition({
    required Duration position,
    required bool playing,
  }) => _invoke<void>('syncPosition', <String, Object?>{
    'positionMs': position.inMilliseconds,
    'playing': playing,
  });

  /// Takes the surface down. Playback, the MediaSession and the media
  /// notification are untouched — this removes a view, nothing else.
  Future<void> hide() => _invoke<void>('hide');

  Future<T?> _invoke<T>(String method, [Object? arguments]) async {
    try {
      return await _channel.invokeMethod<T>(method, arguments);
    } on MissingPluginException {
      // No native side here — web, desktop, or a widget test. Not an error.
      return null;
    } on PlatformException catch (error) {
      AppLogger.warn(
        'Island channel call failed ($method)',
        scope: 'island',
        error: '${error.code}: ${error.message}',
      );
      return null;
    }
  }

  Future<void> dispose() async {
    _channel.setMethodCallHandler(null);
    await _commands.close();
  }
}
