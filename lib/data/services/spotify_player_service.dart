import 'package:dio/dio.dart';

import '../../core/constants/spotify_endpoints.dart';
import '../../core/network/api_exception.dart';
import '../models/json_utils.dart';
import '../models/playback.dart';
import '../models/track.dart';
import 'spotify_api_service.dart';

/// Spotify Connect — remote control of playback on the user's Spotify devices.
///
/// ## What this can and cannot do
///
/// This is the **only** officially supported way for a third-party mobile app
/// to play full-length Spotify tracks. It does not stream audio into AURIX;
/// it tells an existing Spotify client (desktop app, phone app, speaker, web
/// player) what to play. Consequently:
///
///  * Every write endpoint here requires **Spotify Premium**. A free account
///    gets `403 PREMIUM_REQUIRED`, which the UI explains rather than swallows.
///  * There must be an **active device**. With none, Spotify answers
///    `404 NO_ACTIVE_DEVICE`; [transferPlayback] can wake a known device.
///  * AURIX never receives, decrypts, caches or stores Spotify audio. There
///    is no mechanism here that could, and adding one would breach Spotify's
///    Developer Terms.
///
/// When Connect is unavailable, the app falls back to 30-second preview
/// streams where Spotify provides them — and where it provides neither, the UI
/// says so instead of pretending to play.
class SpotifyPlayerService extends SpotifyApiService {
  SpotifyPlayerService(super.dio);

  // ---- State -------------------------------------------------------------

  /// Current remote playback state, or [RemotePlaybackState.idle] when
  /// Spotify answers 204 (nothing playing anywhere).
  Future<RemotePlaybackState> playbackState({CancelToken? cancelToken}) =>
      get<RemotePlaybackState>(
        SpotifyEndpoints.playerState,
        RemotePlaybackState.fromJson,
        query: <String, dynamic>{
          'market': SpotifyApiService.market,
          'additional_types': 'track',
        },
        cancelToken: cancelToken,
        onEmpty: () => RemotePlaybackState.idle,
      );

  Future<List<SpotifyDevice>> devices({CancelToken? cancelToken}) =>
      get<List<SpotifyDevice>>(
        SpotifyEndpoints.playerDevices,
        (json) => Json.list(json, 'devices', SpotifyDevice.fromJson),
        cancelToken: cancelToken,
        onEmpty: () => const [],
      );

  /// The upcoming queue as Spotify sees it.
  Future<List<Track>> queue({CancelToken? cancelToken}) => get<List<Track>>(
    SpotifyEndpoints.playerQueue,
    (json) => Json.list(json, 'queue', Track.fromJson),
    cancelToken: cancelToken,
    onEmpty: () => const [],
  );

  // ---- Transport ---------------------------------------------------------

  /// Starts or resumes playback.
  ///
  /// Exactly one of [contextUri] (album/playlist/artist) or [trackUris] should
  /// be supplied; passing both is a 400 from Spotify. With neither, this
  /// resumes whatever was paused.
  ///
  /// [offsetPosition] selects a starting track inside a context — that is how
  /// "tap track 7 of an album" plays the album *from* track 7 rather than
  /// playing that one track in isolation.
  Future<void> play({
    String? contextUri,
    List<String>? trackUris,
    int? offsetPosition,
    Duration? startAt,
    String? deviceId,
  }) {
    assert(
      contextUri == null || trackUris == null,
      'Spotify rejects a play request carrying both a context and a URI list',
    );

    final body = <String, dynamic>{
      'context_uri': ?contextUri,
      if (trackUris != null && trackUris.isNotEmpty) 'uris': trackUris,
      if (offsetPosition != null)
        'offset': <String, dynamic>{'position': offsetPosition},
      if (startAt != null) 'position_ms': startAt.inMilliseconds,
    };

    return command(
      () => dio.put<dynamic>(
        SpotifyEndpoints.playerPlay,
        queryParameters: <String, dynamic>{'device_id': ?deviceId},
        data: body.isEmpty ? null : body,
      ),
    );
  }

  Future<void> pause({String? deviceId}) => command(
    () => dio.put<dynamic>(
      SpotifyEndpoints.playerPause,
      queryParameters: <String, dynamic>{'device_id': ?deviceId},
    ),
  );

  Future<void> next({String? deviceId}) => command(
    () => dio.post<dynamic>(
      SpotifyEndpoints.playerNext,
      queryParameters: <String, dynamic>{'device_id': ?deviceId},
    ),
  );

  Future<void> previous({String? deviceId}) => command(
    () => dio.post<dynamic>(
      SpotifyEndpoints.playerPrevious,
      queryParameters: <String, dynamic>{'device_id': ?deviceId},
    ),
  );

  Future<void> seek(Duration position, {String? deviceId}) => command(
    () => dio.put<dynamic>(
      SpotifyEndpoints.playerSeek,
      queryParameters: <String, dynamic>{
        'position_ms': position.inMilliseconds.clamp(0, 1 << 31),
        'device_id': ?deviceId,
      },
    ),
  );

  Future<void> setShuffle(bool enabled, {String? deviceId}) => command(
    () => dio.put<dynamic>(
      SpotifyEndpoints.playerShuffle,
      queryParameters: <String, dynamic>{
        'state': enabled,
        'device_id': ?deviceId,
      },
    ),
  );

  Future<void> setRepeat(RepeatState mode, {String? deviceId}) => command(
    () => dio.put<dynamic>(
      SpotifyEndpoints.playerRepeat,
      queryParameters: <String, dynamic>{
        'state': mode.apiValue,
        'device_id': ?deviceId,
      },
    ),
  );

  Future<void> setVolume(int percent, {String? deviceId}) => command(
    () => dio.put<dynamic>(
      SpotifyEndpoints.playerVolume,
      queryParameters: <String, dynamic>{
        'volume_percent': percent.clamp(0, 100),
        'device_id': ?deviceId,
      },
    ),
  );

  /// Appends a track to the active device's queue.
  Future<void> addToQueue(String uri, {String? deviceId}) => command(
    () => dio.post<dynamic>(
      SpotifyEndpoints.playerQueue,
      queryParameters: <String, dynamic>{'uri': uri, 'device_id': ?deviceId},
    ),
  );

  /// Moves playback to [deviceId], optionally starting it.
  ///
  /// This is the recovery path for `NO_ACTIVE_DEVICE`: pick a device from
  /// [devices] and transfer to it before retrying the original command.
  Future<void> transferPlayback(String deviceId, {bool startPlaying = false}) =>
      command(
        () => dio.put<dynamic>(
          SpotifyEndpoints.playerTransfer,
          data: <String, dynamic>{
            'device_ids': <String>[deviceId],
            'play': startPlaying,
          },
        ),
      );

  // ---- Capability probing ------------------------------------------------

  /// Reports whether a Connect command could succeed right now, without
  /// causing a side effect.
  ///
  /// Called before enabling transport controls so the UI can explain the
  /// blocker up front ("Open Spotify on a device") rather than showing an
  /// error after the user taps play.
  Future<ConnectAvailability> checkAvailability({CancelToken? cancelToken}) async {
    try {
      final available = await devices(cancelToken: cancelToken);
      final controllable = available.where((d) => d.isControllable).toList();

      if (controllable.isEmpty) {
        return ConnectAvailability(
          status: available.isEmpty
              ? ConnectStatus.noDevices
              : ConnectStatus.onlyRestrictedDevices,
          devices: available,
        );
      }

      final active = controllable.where((d) => d.isActive).toList();
      return ConnectAvailability(
        status: active.isEmpty ? ConnectStatus.deviceIdle : ConnectStatus.ready,
        devices: available,
        activeDevice: active.isEmpty ? null : active.first,
      );
    } on ApiException catch (error) {
      if (error.kind == ApiFailureKind.forbidden) {
        return ConnectAvailability(
          status: error.requiresPremium
              ? ConnectStatus.premiumRequired
              : ConnectStatus.notPermitted,
          devices: const [],
        );
      }
      return const ConnectAvailability(
        status: ConnectStatus.unavailable,
        devices: [],
      );
    }
  }
}

/// Why Spotify Connect can or cannot be used at this moment.
enum ConnectStatus {
  /// An active, controllable device is ready — full playback works.
  ready,

  /// A controllable device exists but is not active. A transfer wakes it.
  deviceIdle,

  /// No Spotify device is visible. The user must open Spotify somewhere.
  noDevices,

  /// Devices exist but all reject Web API control (Chromecast, some cars).
  onlyRestrictedDevices,

  /// The account is not Premium.
  premiumRequired,

  /// The token lacks the playback scopes.
  notPermitted,

  /// Network or service failure; unknown.
  unavailable,
}

class ConnectAvailability {
  const ConnectAvailability({
    required this.status,
    required this.devices,
    this.activeDevice,
  });

  final ConnectStatus status;
  final List<SpotifyDevice> devices;
  final SpotifyDevice? activeDevice;

  bool get canPlay => status == ConnectStatus.ready || status == ConnectStatus.deviceIdle;

  /// Devices worth offering in the device picker.
  List<SpotifyDevice> get controllableDevices =>
      devices.where((d) => d.isControllable).toList(growable: false);

  /// Explains the blocker in one sentence, or null when playback is available.
  String? get blockerMessage {
    switch (status) {
      case ConnectStatus.ready:
      case ConnectStatus.deviceIdle:
        return null;
      case ConnectStatus.noDevices:
        return 'Open Spotify on a phone, computer or speaker to play full tracks here.';
      case ConnectStatus.onlyRestrictedDevices:
        return 'Your available Spotify devices do not accept remote control.';
      case ConnectStatus.premiumRequired:
        return 'Spotify Premium is required to play full tracks through Spotify Connect.';
      case ConnectStatus.notPermitted:
        return 'AURIX was not granted playback permission. Sign in again to fix this.';
      case ConnectStatus.unavailable:
        return "Couldn't reach Spotify Connect. Check your connection.";
    }
  }
}
