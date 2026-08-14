import 'package:equatable/equatable.dart';

import 'json_utils.dart';
import 'track.dart';

/// A device visible to Spotify Connect.
class SpotifyDevice extends Equatable {
  const SpotifyDevice({
    required this.id,
    required this.name,
    required this.type,
    this.isActive = false,
    this.isRestricted = false,
    this.isPrivateSession = false,
    this.volumePercent,
  });

  /// Null for a device Spotify will not let this app address directly.
  final String? id;
  final String name;

  /// `Computer`, `Smartphone`, `Speaker`, `TV`, `AVR`, `STB`, `CastVideo`, …
  final String type;

  final bool isActive;

  /// Restricted devices reject Web API control commands entirely — a Chromecast
  /// or a car head unit, typically. Showing them as selectable would promise
  /// something that cannot work.
  final bool isRestricted;

  final bool isPrivateSession;
  final int? volumePercent;

  factory SpotifyDevice.fromJson(Map<String, dynamic> json) => SpotifyDevice(
    id: Json.strOrNull(json, 'id'),
    name: Json.str(json, 'name', fallback: 'Unknown device'),
    type: Json.str(json, 'type', fallback: 'Unknown'),
    isActive: Json.boolVal(json, 'is_active'),
    isRestricted: Json.boolVal(json, 'is_restricted'),
    isPrivateSession: Json.boolVal(json, 'is_private_session'),
    volumePercent: Json.intOrNull(json, 'volume_percent'),
  );

  Map<String, dynamic> toJson() => <String, dynamic>{
    'id': id,
    'name': name,
    'type': type,
    'is_active': isActive,
    'is_restricted': isRestricted,
    'is_private_session': isPrivateSession,
    if (volumePercent != null) 'volume_percent': volumePercent,
  };

  /// True when AURIX can send transport commands to this device.
  bool get isControllable => id != null && !isRestricted;

  @override
  List<Object?> get props => [id, name, type, isActive, isRestricted, volumePercent];
}

enum RepeatState {
  off,
  context,
  track;

  static RepeatState parse(String? raw) {
    switch (raw) {
      case 'context':
        return RepeatState.context;
      case 'track':
        return RepeatState.track;
      default:
        return RepeatState.off;
    }
  }

  /// The value Spotify's `PUT /me/player/repeat` expects.
  String get apiValue => name;

  RepeatState get next {
    switch (this) {
      case RepeatState.off:
        return RepeatState.context;
      case RepeatState.context:
        return RepeatState.track;
      case RepeatState.track:
        return RepeatState.off;
    }
  }
}

/// Playback state as reported by Spotify Connect (`GET /me/player`).
///
/// This is the *remote* truth — what the user's Spotify app is doing. It is
/// deliberately separate from AURIX's own local player state, because the
/// two can legitimately disagree (local preview playing while a Connect device
/// is paused). The player controller reconciles them.
class RemotePlaybackState extends Equatable {
  const RemotePlaybackState({
    this.isPlaying = false,
    this.track,
    this.device,
    this.progressMs = 0,
    this.shuffleEnabled = false,
    this.repeatMode = RepeatState.off,
    this.contextUri,
    this.contextType,
    this.timestamp,
  });

  final bool isPlaying;
  final Track? track;
  final SpotifyDevice? device;
  final int progressMs;
  final bool shuffleEnabled;
  final RepeatState repeatMode;
  final String? contextUri;
  final String? contextType;
  final DateTime? timestamp;

  /// The state when Spotify returns `204 No Content` — nothing is playing
  /// anywhere. Distinct from "we failed to ask".
  static const RemotePlaybackState idle = RemotePlaybackState();

  factory RemotePlaybackState.fromJson(Map<String, dynamic> json) {
    final itemJson = Json.obj(json, 'item');
    final deviceJson = Json.obj(json, 'device');
    final contextJson = Json.obj(json, 'context');
    final timestampMs = Json.intOrNull(json, 'timestamp');

    // `item` is an episode when the user is listening to a podcast; AURIX
    // treats that as "nothing we can display" rather than mis-rendering it.
    final isTrack = itemJson != null &&
        (Json.strOrNull(itemJson, 'type') ?? 'track') == 'track';

    return RemotePlaybackState(
      isPlaying: Json.boolVal(json, 'is_playing'),
      track: isTrack ? Track.fromJson(itemJson) : null,
      device: deviceJson == null ? null : SpotifyDevice.fromJson(deviceJson),
      progressMs: Json.intVal(json, 'progress_ms'),
      shuffleEnabled: Json.boolVal(json, 'shuffle_state'),
      repeatMode: RepeatState.parse(Json.strOrNull(json, 'repeat_state')),
      contextUri: contextJson == null ? null : Json.strOrNull(contextJson, 'uri'),
      contextType: contextJson == null ? null : Json.strOrNull(contextJson, 'type'),
      timestamp: timestampMs == null
          ? null
          : DateTime.fromMillisecondsSinceEpoch(timestampMs),
    );
  }

  Duration get progress => Duration(milliseconds: progressMs);

  bool get hasActiveDevice => device?.isActive ?? false;
  bool get isIdle => track == null && device == null;

  /// Extrapolates progress between polls.
  ///
  /// `/me/player` is polled every few seconds, so using [progressMs] directly
  /// would make the seek bar jump. Advancing it locally from the report
  /// timestamp keeps the bar smooth without hammering the endpoint.
  Duration progressAt(DateTime now) {
    if (!isPlaying || timestamp == null) return progress;
    final elapsed = now.difference(timestamp!);
    if (elapsed.isNegative) return progress;
    final total = track?.duration;
    final projected = progress + elapsed;
    if (total != null && projected > total) return total;
    return projected;
  }

  @override
  List<Object?> get props => [
    isPlaying,
    track,
    device,
    progressMs,
    shuffleEnabled,
    repeatMode,
    contextUri,
    timestamp,
  ];
}
