import 'dart:async';

import '../../../core/config/env.dart';
import '../../../core/constants/aurix_endpoints.dart';
import '../../../core/network/api_exception.dart';
import '../../../core/network/aurix_api_client.dart';
import '../../../core/utils/app_logger.dart';
import '../../models/media_source.dart';
import 'oauth_launcher.dart';

/// Playlist import, as the app sees it.
///
/// ## What moved, and why the app got smaller
///
/// AURIX used to hold a complete Spotify client: a PKCE implementation, a token
/// store, a refresher, a paging loop and a normaliser, all in Dart. All of it
/// has moved behind `POST /music/import`, and what is left here is three calls
/// and a browser hop.
///
/// That is the whole of requirement §11. There is no client secret in the
/// binary because there is no token exchange in the binary; the app never holds
/// a Spotify or Google credential, and cannot leak one. It also stops the
/// import from being per-device: a connection made on a phone is a row in
/// MongoDB, so the same account importing from a tablet is already connected.
///
/// ## The one thing the app still does itself
///
/// Open a browser. A consent screen has to be rendered by the system browser —
/// that is the point of it, so the user types their password somewhere AURIX
/// cannot read — and only the app can open one. [connect] opens the URL the
/// server minted and waits for the redirect; by the time that redirect arrives
/// the connection is already stored server-side, so the URL carries a status
/// and nothing else. No code, no token, nothing worth intercepting.
class ApiMusicService {
  ApiMusicService({required AurixApiClient client, OAuthLauncher? launcher})
    : _client = client,
      _launcher = launcher ?? OAuthLauncher();

  final AurixApiClient _client;
  final OAuthLauncher _launcher;

  // ---- Status ------------------------------------------------------------

  /// What the import screen renders above the URL field.
  Future<List<MusicConnection>> connections() async {
    final body = await _client.get(AurixEndpoints.musicConnections);
    final raw = body['connections'];
    if (raw is! List) return const <MusicConnection>[];
    return raw
        .whereType<Map<String, dynamic>>()
        .map(MusicConnection.fromJson)
        .toList(growable: false);
  }

  // ---- Connecting --------------------------------------------------------

  /// Runs the consent flow for [provider].
  ///
  /// Returns when the connection is stored, or throws. Backing out of the
  /// consent screen throws [MusicConnectCancelled], which callers treat as a
  /// decision rather than as a failure — a red banner reading "connection
  /// cancelled" after the user cancelled a connection is noise.
  Future<void> connect(MediaSource provider) async {
    final id = _wire(provider);

    final started = await _client.post(
      AurixEndpoints.musicConnectionStart(id),
      body: <String, dynamic>{'redirectUri': Env.loginNativeRedirectUri},
    );

    final url = started['authorizationUrl'];
    if (url is! String || url.isEmpty) {
      throw const MusicConnectFailed(
        'AURIX could not start that connection. Try again in a moment.',
      );
    }

    final String callback;
    try {
      // Reuses the sign-in redirect, which is already registered with this
      // deployment and already has an intent filter on Android. Safe to share:
      // a sign-in callback carries `code=` and this one carries `status=`, the
      // two flows are never in flight at once, and whichever call is waiting is
      // the one that gets the URL.
      callback = await _launcher.awaitCallback(url);
    } on SocialSignInCancelled {
      throw const MusicConnectCancelled();
    }

    final params = Uri.tryParse(callback)?.queryParameters ?? const {};
    final status = params['status'] ?? '';

    if (status == 'connected') {
      AppLogger.info('$id connected', scope: 'import');
      return;
    }

    if (status == 'declined') {
      // The user pressed Cancel on the provider's own page. It redirected, so
      // it is not a dismissal — but it is still a decision.
      throw const MusicConnectCancelled();
    }

    throw MusicConnectFailed(
      switch (params['reason']) {
        'exchange_failed' =>
          'AURIX could not finish connecting to ${provider.label}. '
              'Please try again.',
        'mismatch' || 'no_code' =>
          'That connection came back in a form AURIX could not use. '
              'Please try again.',
        _ => 'That connection did not complete. Please try again.',
      },
    );
  }

  /// "Disconnect Spotify". Idempotent.
  Future<void> disconnect(MediaSource provider) async {
    await _client.delete(AurixEndpoints.musicConnection(_wire(provider)));
    AppLogger.info('${_wire(provider)} disconnected', scope: 'import');
  }

  // ---- Importing ---------------------------------------------------------

  /// Imports the playlist at [url].
  ///
  /// Every failure arrives as an [AurixApiException] whose `code` is one of the
  /// `provider_*` strings the API publishes. Callers branch on that rather than
  /// on the message — see `PlaylistLinkImportController`.
  Future<ImportedPlaylistResult> importFromUrl(String url) async {
    final body = await _client.post(
      AurixEndpoints.musicImport,
      body: <String, dynamic>{'url': url},
    );
    return ImportedPlaylistResult.fromJson(body);
  }

  static String _wire(MediaSource provider) => switch (provider) {
    MediaSource.spotify => 'spotify',
    MediaSource.youtube => 'youtube',
    // Unreachable: the import screen only ever offers the two above.
    MediaSource.aurix => throw ArgumentError('AURIX is not a music provider'),
  };
}

// ---------------------------------------------------------------------------
// Results
// ---------------------------------------------------------------------------

/// One provider's connection state, as the import screen shows it.
class MusicConnection {
  const MusicConnection({
    required this.provider,
    required this.label,
    required this.connected,
    required this.configured,
    required this.publicReads,
    this.accountName,
    this.expiring = false,
  });

  factory MusicConnection.fromJson(Map<String, dynamic> json) => MusicConnection(
    provider: MediaSource.parse(json['provider']),
    label: (json['label'] as String?) ?? '',
    connected: json['connected'] == true,
    configured: json['configured'] == true,
    publicReads: json['publicReads'] == true,
    accountName: (json['accountName'] as String?)?.trim(),
    expiring: json['expiring'] == true,
  );

  final MediaSource provider;

  /// "Spotify", "YouTube" — the server's wording, so one deployment can rename
  /// a provider without a client release.
  final String label;

  final bool connected;

  /// False when this deployment holds no credentials for the provider. The
  /// button is shown disabled with the reason rather than offered and then
  /// failing inside a browser tab.
  final bool configured;

  /// True when a *public* playlist imports with no connection at all.
  ///
  /// True for YouTube, false for Spotify — which is why the Spotify row asks to
  /// be connected before an import and the YouTube row does not.
  final bool publicReads;

  /// Whose account it is, when the provider would say.
  final String? accountName;

  /// A connection with no refresh token: it works now and will need
  /// reconnecting when its access token lapses. A note, not a warning.
  final bool expiring;

  /// What the row says under the provider's name.
  String get subtitle {
    if (!configured) return 'Not available on this AURIX server';
    if (!connected) {
      return publicReads ? 'Connect for private playlists' : 'Not connected';
    }
    final name = accountName;
    return name == null || name.isEmpty ? 'Connected' : 'Connected as $name';
  }
}

/// What an import produced.
class ImportedPlaylistResult {
  const ImportedPlaylistResult({
    required this.playlistId,
    required this.name,
    required this.coverUrl,
    required this.trackCount,
    required this.songsCreated,
    required this.songsReused,
    required this.created,
    required this.skipped,
    required this.truncated,
    required this.providerTrackCount,
  });

  factory ImportedPlaylistResult.fromJson(Map<String, dynamic> json) =>
      ImportedPlaylistResult(
        playlistId: (json['playlistId'] as String?) ?? '',
        name: (json['name'] as String?) ?? '',
        coverUrl: (json['coverUrl'] as String?) ?? '',
        trackCount: (json['trackCount'] as num?)?.toInt() ?? 0,
        songsCreated: (json['songsCreated'] as num?)?.toInt() ?? 0,
        songsReused: (json['songsReused'] as num?)?.toInt() ?? 0,
        created: json['created'] == true,
        skipped: (json['skipped'] as List?)?.length ?? 0,
        truncated: json['truncated'] == true,
        providerTrackCount: (json['providerTrackCount'] as num?)?.toInt() ?? 0,
      );

  final String playlistId;
  final String name;
  final String coverUrl;

  /// Rows actually linked to the playlist. The authoritative count.
  final int trackCount;

  final int songsCreated;
  final int songsReused;

  /// False when the playlist was already in the catalogue and was refreshed.
  final bool created;

  /// Entries the provider listed that could not be imported — a track removed
  /// from the catalogue, a local file, a video since made private.
  final int skipped;

  /// True when the fetch stopped at the server's safety cap.
  final bool truncated;

  /// The provider's own count. Advisory: it counts entries this import
  /// legitimately skipped, so it can legitimately exceed [trackCount].
  final int providerTrackCount;

  /// A sentence for the success card, when there is something worth saying
  /// beyond the count.
  String? get caveat {
    if (truncated) {
      return 'This playlist is very large, so the first $trackCount songs were '
          'imported.';
    }
    if (skipped > 0) {
      return skipped == 1
          ? '1 song could not be imported — it is no longer available on the '
                'source.'
          : '$skipped songs could not be imported — they are no longer '
                'available on the source.';
    }
    return null;
  }
}

// ---------------------------------------------------------------------------
// Failures
// ---------------------------------------------------------------------------

/// The user backed out of the consent screen. Not an error.
class MusicConnectCancelled implements Exception {
  const MusicConnectCancelled();

  @override
  String toString() => 'MusicConnectCancelled';
}

/// The connection did not complete, for a reason worth showing.
class MusicConnectFailed implements Exception {
  const MusicConnectFailed(this.message);

  final String message;

  @override
  String toString() => 'MusicConnectFailed: $message';
}

/// The API's `provider_*` error codes, as something to switch on.
///
/// The whole of §10 lives in this enum. The old client had one failure — the
/// playlist's contents were "unavailable" — which named neither the cause nor
/// the remedy, and the causes below have genuinely different remedies. One of
/// them has none at all, and saying so plainly is better than an offer to retry
/// that can never work.
enum ImportProblem {
  /// No connection. The screen shows "Connect Spotify".
  authRequired,

  /// A connection that can no longer be renewed. "Reconnect Spotify".
  reconnectRequired,

  /// The provider refused, and reconnecting will not change that — most often
  /// because the playlist belongs to somebody else's account.
  forbidden,

  /// No such playlist.
  notFound,

  /// The link is not a playlist AURIX can import.
  badLink,

  /// The provider is throttling AURIX.
  rateLimited,

  /// This deployment has no credentials for the provider.
  notConfigured,

  /// Network, or an AURIX fault.
  unknown;

  static ImportProblem of(ApiException error) {
    final code = error is AurixApiException ? error.code : null;
    return switch (code) {
      'provider_auth_required' => ImportProblem.authRequired,
      'provider_reconnect_required' => ImportProblem.reconnectRequired,
      'provider_forbidden' => ImportProblem.forbidden,
      'provider_not_found' => ImportProblem.notFound,
      'provider_unsupported_link' || 'bad_request' => ImportProblem.badLink,
      'provider_rate_limited' || 'rate_limited' => ImportProblem.rateLimited,
      'provider_unavailable' => ImportProblem.notConfigured,
      _ => switch (error.kind) {
        ApiFailureKind.offline || ApiFailureKind.timeout => ImportProblem.unknown,
        _ => ImportProblem.unknown,
      },
    };
  }

  /// True when the remedy is a button rather than a retry.
  bool get needsConnection =>
      this == ImportProblem.authRequired || this == ImportProblem.reconnectRequired;
}
