import 'package:equatable/equatable.dart';

import '../data/models/playback.dart';
import '../data/models/track.dart';
import '../data/services/spotify_player_service.dart' show ConnectStatus;

/// How a track is being played — or why it cannot be.
///
/// ## The honest summary
///
/// A third-party app cannot decode Spotify's audio. There are exactly two
/// authorised ways to make sound happen, and AURIX implements both:
///
///  * **[preview]** — Spotify publishes a 30-second MP3 for many tracks
///    (`preview_url`). AURIX streams it with `just_audio`. Nothing is
///    downloaded to disk, and the field is simply absent for apps registered
///    after 27 November 2024.
///  * **[connect]** — Spotify Connect. AURIX sends transport commands to a
///    Spotify client the user already has running; that client plays the full
///    track. Requires Premium and an active device.
///
/// When neither is possible the mode is [unavailable] and the UI says so. It
/// never advances a progress bar over silence.
enum PlaybackMode {
  /// Nothing is loaded.
  idle,

  /// Streaming Spotify's 30-second preview locally.
  preview,

  /// Controlling a remote Spotify device.
  connect,

  /// Driving the Spotify app installed on this phone, over App Remote.
  ///
  /// Distinct from [connect] in the mechanism, not the outcome: both play a
  /// full track somewhere other than AURIX's own audio pipeline. Connect
  /// commands a device registered with Spotify's servers; App Remote binds to
  /// the local Spotify app. The distinction matters because a phone with no
  /// other Spotify device signed in has no Connect target at all, and that is
  /// the case where AURIX used to report "No Spotify device available" and
  /// stop.
  appRemote,

  /// A track is selected but cannot be played by either mechanism.
  unavailable;

  bool get isPlayable => this == preview || this == connect || this == appRemote;
  bool get isLocal => this == preview;

  /// True when the audio is coming out of Spotify rather than AURIX — whether
  /// that is a Connect device or the Spotify app on this phone. Everything
  /// that asks this question (progress mirroring, the device chip, transport
  /// enablement) means "not our audio pipeline".
  bool get isRemote => this == connect || this == appRemote;
}

/// Which mechanism the user would rather use, from Settings.
enum PlaybackPreference {
  /// Prefer a Connect device; fall back to previews.
  connectFirst,

  /// Prefer local previews; only use Connect when there is no preview.
  previewFirst;

  String get label {
    switch (this) {
      case PlaybackPreference.connectFirst:
        return 'Spotify Connect (full tracks)';
      case PlaybackPreference.previewFirst:
        return 'Previews on this device';
    }
  }

  String get description {
    switch (this) {
      case PlaybackPreference.connectFirst:
        return 'Play full tracks on another Spotify device. Requires Premium.';
      case PlaybackPreference.previewFirst:
        return 'Play 30-second previews here when Spotify provides them.';
    }
  }
}

/// Why playback is limited or impossible, phrased for the user.
class PlaybackLimitation extends Equatable {
  const PlaybackLimitation({
    required this.headline,
    required this.detail,
    this.action,
    this.isBlocking = true,
  });

  final String headline;
  final String detail;

  /// What the user can do about it, if anything.
  final PlaybackRemedy? action;

  /// False for informational notes (e.g. "this is a 30-second preview") that
  /// do not stop playback.
  final bool isBlocking;

  static const PlaybackLimitation previewOnly = PlaybackLimitation(
    headline: '30-second preview',
    detail:
        'Spotify provides a short preview for this track. '
        'Connect a Spotify device to play it in full.',
    action: PlaybackRemedy.chooseDevice,
    isBlocking: false,
  );

  static const PlaybackLimitation premiumRequired = PlaybackLimitation(
    headline: 'Premium required for full playback',
    detail:
        'Spotify only allows apps to control playback for Premium accounts. '
        'Previews still work where Spotify provides them.',
    action: PlaybackRemedy.learnAboutPremium,
  );

  static const PlaybackLimitation noDevice = PlaybackLimitation(
    headline: 'No Spotify device available',
    detail:
        'Open Spotify on your phone, computer or speaker, then pick it here to '
        'play full tracks.',
    action: PlaybackRemedy.chooseDevice,
  );

  static const PlaybackLimitation noSource = PlaybackLimitation(
    headline: "This track can't be played here",
    detail:
        'Spotify provides no preview for this track, and no Spotify device is '
        'available to play it in full. AURIX will not pretend to play it.',
    action: PlaybackRemedy.chooseDevice,
  );

  static const PlaybackLimitation localFile = PlaybackLimitation(
    headline: 'Local file',
    detail:
        'This entry is a file from the owner\'s own device. Spotify does not '
        'expose it through the Web API, so it cannot be played here.',
  );

  static const PlaybackLimitation offline = PlaybackLimitation(
    headline: 'You are offline',
    detail: 'Playback needs a connection. Cached details are still browsable.',
    action: PlaybackRemedy.retry,
  );

  @override
  List<Object?> get props => [headline, detail, action, isBlocking];
}

enum PlaybackRemedy {
  chooseDevice,
  learnAboutPremium,
  retry,

  /// Send the user to install Spotify. Only reachable on mobile, where App
  /// Remote is the playback path and its absence is the whole blocker.
  installSpotify,
}

/// Resolves which mode a given track can use right now.
///
/// Kept as a pure function so the decision is testable without a player, and
/// so the UI can ask "would this play?" before the user taps anything.
abstract final class PlaybackResolver {
  static PlaybackResolution resolve({
    required Track track,
    required PlaybackPreference preference,
    required ConnectAvailabilitySnapshot connect,
    required bool isOffline,
    bool appRemoteAvailable = false,
  }) {
    if (isOffline) {
      return const PlaybackResolution(
        mode: PlaybackMode.unavailable,
        limitation: PlaybackLimitation.offline,
      );
    }

    if (track.isLocal) {
      return const PlaybackResolution(
        mode: PlaybackMode.unavailable,
        limitation: PlaybackLimitation.localFile,
      );
    }

    // App Remote outranks everything on a phone that has Spotify installed.
    //
    // It plays the full track with no second device required, which is the
    // whole point: Connect can only command a device that is already signed in
    // somewhere else, and a 30-second preview is not the song. Spotify also
    // documents App Remote — not `PUT /me/player/play` — as the way a mobile
    // client should drive playback.
    if (appRemoteAvailable && track.isConnectPlayable) {
      return const PlaybackResolution(mode: PlaybackMode.appRemote);
    }

    final canConnect = connect.canPlay && track.isConnectPlayable;
    final canPreview = track.hasPreview;

    if (preference == PlaybackPreference.connectFirst) {
      if (canConnect) return const PlaybackResolution(mode: PlaybackMode.connect);
      if (canPreview) {
        return PlaybackResolution(
          mode: PlaybackMode.preview,
          limitation: _previewNote(connect),
        );
      }
    } else {
      if (canPreview) {
        return PlaybackResolution(
          mode: PlaybackMode.preview,
          limitation: canConnect ? null : PlaybackLimitation.previewOnly,
        );
      }
      if (canConnect) return const PlaybackResolution(mode: PlaybackMode.connect);
    }

    return PlaybackResolution(
      mode: PlaybackMode.unavailable,
      limitation: _blockerFor(connect),
    );
  }

  /// A preview is playing but the user could have had the full track — say
  /// which obstacle is in the way rather than a generic note.
  static PlaybackLimitation _previewNote(ConnectAvailabilitySnapshot connect) {
    switch (connect.status) {
      case ConnectStatus.premiumRequired:
        return PlaybackLimitation.premiumRequired.copyAsNonBlocking();
      case ConnectStatus.noDevices:
      case ConnectStatus.onlyRestrictedDevices:
        return PlaybackLimitation.previewOnly;
      default:
        return PlaybackLimitation.previewOnly;
    }
  }

  static PlaybackLimitation _blockerFor(ConnectAvailabilitySnapshot connect) {
    switch (connect.status) {
      case ConnectStatus.premiumRequired:
        return PlaybackLimitation.premiumRequired;
      case ConnectStatus.noDevices:
      case ConnectStatus.onlyRestrictedDevices:
      case ConnectStatus.deviceIdle:
        return PlaybackLimitation.noDevice;
      default:
        return PlaybackLimitation.noSource;
    }
  }
}

/// Public because the player controller builds App Remote limitations of its
/// own and needs the same "informational, not blocking" downgrade when a
/// preview is playing behind the notice.
extension NonBlockingLimitation on PlaybackLimitation {
  PlaybackLimitation copyAsNonBlocking() => PlaybackLimitation(
    headline: headline,
    detail: detail,
    action: action,
    isBlocking: false,
  );
}

class PlaybackResolution extends Equatable {
  const PlaybackResolution({required this.mode, this.limitation});

  final PlaybackMode mode;
  final PlaybackLimitation? limitation;

  bool get canPlay => mode.isPlayable;

  @override
  List<Object?> get props => [mode, limitation];
}

/// A cached, cheap-to-read view of Connect availability.
///
/// The full [ConnectAvailability] involves a network call; the resolver needs
/// something it can consult synchronously on every track change.
class ConnectAvailabilitySnapshot extends Equatable {
  const ConnectAvailabilitySnapshot({
    this.status = ConnectStatus.noDevices,
    this.activeDevice,
    this.devices = const [],
    this.checkedAt,
  });

  final ConnectStatus status;
  final SpotifyDevice? activeDevice;
  final List<SpotifyDevice> devices;
  final DateTime? checkedAt;

  static const ConnectAvailabilitySnapshot unknown = ConnectAvailabilitySnapshot();

  bool get canPlay =>
      status == ConnectStatus.ready || status == ConnectStatus.deviceIdle;

  bool get needsTransfer => status == ConnectStatus.deviceIdle;

  List<SpotifyDevice> get controllableDevices =>
      devices.where((d) => d.isControllable).toList(growable: false);

  /// Availability goes stale quickly — a laptop closing removes a device.
  bool get isStale {
    final at = checkedAt;
    if (at == null) return true;
    return DateTime.now().difference(at) > const Duration(seconds: 30);
  }

  @override
  List<Object?> get props => [status, activeDevice, devices, checkedAt];
}
