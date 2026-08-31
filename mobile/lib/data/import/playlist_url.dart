import '../models/media_source.dart';

/// Where a pasted playlist link points.
///
/// Distinct from [MediaSource], and the distinction is worth keeping. This
/// describes a *link the user pasted* — a transient thing that may well be
/// unrecognisable, hence [unknown]. [MediaSource] describes a stored record's
/// provenance, where "unknown" is not a state any document should ever be in.
/// Mapping between them ([toMediaSource]) is therefore a partial function, and
/// making that explicit is what stops an unparseable URL becoming a row in the
/// catalogue attributed to nothing.
enum PlaylistSource {
  spotify,
  youtube,
  unknown;

  String get label {
    switch (this) {
      case PlaylistSource.spotify:
        return 'Spotify';
      case PlaylistSource.youtube:
        return 'YouTube Music';
      case PlaylistSource.unknown:
        return 'Unknown';
    }
  }

  /// The stored provenance for this source, or null when there is none.
  MediaSource? get toMediaSource {
    switch (this) {
      case PlaylistSource.spotify:
        return MediaSource.spotify;
      case PlaylistSource.youtube:
        return MediaSource.youtube;
      case PlaylistSource.unknown:
        return null;
    }
  }
}

/// A playlist link, taken apart.
class PlaylistLink {
  const PlaylistLink({
    required this.source,
    required this.playlistId,
    required this.canonicalUrl,
  });

  final PlaylistSource source;

  /// The playlist's id at the source, with tracking parameters stripped.
  final String playlistId;

  /// The link rebuilt without `?si=`, `&utm_*` and friends.
  ///
  /// Stored on the playlist document rather than the raw paste, so that two
  /// users who share the same playlist through different share-sheets — which
  /// attach different `si` tokens — are recorded as having imported the same
  /// thing.
  final String canonicalUrl;

  MediaSource get mediaSource => source.toMediaSource ?? MediaSource.aurix;
}

/// Why a pasted link could not be used.
enum PlaylistLinkProblem {
  empty,
  notAUrl,
  unsupportedHost,
  notAPlaylist,
  missingId,
  malformedId;

  /// What the user is told. Never a raw exception, never an internal term.
  ///
  /// Each message names the *fix* rather than the fault, because the user's
  /// next action is always to paste a different link and the only useful thing
  /// to tell them is which one.
  String get message {
    switch (this) {
      case PlaylistLinkProblem.empty:
        return 'Paste a playlist link to import.';
      case PlaylistLinkProblem.notAUrl:
        return "That doesn't look like a link. Copy the playlist's share link "
            'from Spotify or YouTube Music and paste it here.';
      case PlaylistLinkProblem.unsupportedHost:
        return 'AURIX can import from Spotify and YouTube Music. That link is '
            'from somewhere else.';
      case PlaylistLinkProblem.notAPlaylist:
        return "That link isn't a playlist. Open the playlist itself, then "
            'use Share → Copy link.';
      case PlaylistLinkProblem.missingId:
        return 'That link has no playlist in it. Use Share → Copy link from '
            'the playlist page.';
      case PlaylistLinkProblem.malformedId:
        return 'That playlist link looks damaged. Copy it again from Spotify '
            'or YouTube Music.';
    }
  }
}

/// The outcome of reading a pasted link: a [PlaylistLink] or a reason why not.
sealed class PlaylistLinkResult {
  const PlaylistLinkResult();
}

class PlaylistLinkParsed extends PlaylistLinkResult {
  const PlaylistLinkParsed(this.link);
  final PlaylistLink link;
}

class PlaylistLinkRejected extends PlaylistLinkResult {
  const PlaylistLinkRejected(this.problem);
  final PlaylistLinkProblem problem;

  String get message => problem.message;
}

/// Reads a pasted playlist URL.
///
/// ## Why parsing is a class of its own
///
/// It is the only part of importing that runs before anything is known — no
/// network, no credentials, no account — and it is the part the user interacts
/// with most directly, because they will paste the wrong thing. Keeping it
/// separate means the "is this a valid link" question is answered
/// synchronously, as the user types, with a specific message per failure, and
/// without an import ever being started for a link that cannot work.
///
/// It is also the only piece with no dependencies at all, which makes the whole
/// matrix of link shapes testable without a Firestore, an HTTP client or a
/// signed-in user.
///
/// ## The shapes accepted
///
/// ```
/// Spotify   https://open.spotify.com/playlist/{id}
///           https://open.spotify.com/playlist/{id}?si=...
///           https://open.spotify.com/intl-de/playlist/{id}
///           spotify:playlist:{id}
///
/// YouTube   https://www.youtube.com/playlist?list={id}
///           https://music.youtube.com/playlist?list={id}
///           https://m.youtube.com/playlist?list={id}
///           https://youtu.be/{video}?list={id}
///           https://www.youtube.com/watch?v={video}&list={id}
/// ```
abstract final class PlaylistUrlParser {
  /// Spotify ids are base-62, 22 characters. The length is not asserted —
  /// editorial ids such as `37i9dQZF1DX...` are the same length but a future
  /// format need not be — but the character set is, because it is what
  /// separates an id from a path fragment that wandered into the capture.
  static final RegExp _spotifyId = RegExp(r'^[A-Za-z0-9]{16,40}$');

  /// YouTube playlist ids: `PL…`, `OLAK5uy_…`, `RDCLAK5uy_…`, `VL…`, plus the
  /// `LL`/`WL` pseudo-playlists. Hyphens and underscores are part of the set.
  static final RegExp _youtubeId = RegExp(r'^[A-Za-z0-9_-]{2,80}$');

  static const Set<String> _spotifyHosts = <String>{
    'open.spotify.com',
    'play.spotify.com',
    'spotify.com',
    'www.spotify.com',
  };

  static const Set<String> _youtubeHosts = <String>{
    'youtube.com',
    'www.youtube.com',
    'm.youtube.com',
    'music.youtube.com',
    'youtu.be',
    'www.youtu.be',
  };

  /// Detects the service a link belongs to without fully parsing it.
  ///
  /// Used by the import field to show the source badge while the user is still
  /// typing, before the id has necessarily been pasted.
  static PlaylistSource detect(String raw) {
    final trimmed = raw.trim();
    if (trimmed.isEmpty) return PlaylistSource.unknown;

    if (trimmed.toLowerCase().startsWith('spotify:')) {
      return PlaylistSource.spotify;
    }

    final uri = _tryParse(trimmed);
    if (uri == null) return PlaylistSource.unknown;

    final host = uri.host.toLowerCase();
    if (_spotifyHosts.contains(host)) return PlaylistSource.spotify;
    if (_youtubeHosts.contains(host)) return PlaylistSource.youtube;
    return PlaylistSource.unknown;
  }

  /// Reads [raw] into a [PlaylistLink], or explains why it cannot.
  static PlaylistLinkResult parse(String raw) {
    final trimmed = raw.trim();
    if (trimmed.isEmpty) {
      return const PlaylistLinkRejected(PlaylistLinkProblem.empty);
    }

    // The Spotify URI form, which is what the desktop client's "Copy Spotify
    // URI" produces and what a share sheet sometimes hands over.
    if (trimmed.toLowerCase().startsWith('spotify:')) {
      return _parseSpotifyUri(trimmed);
    }

    final uri = _tryParse(trimmed);
    if (uri == null || uri.host.isEmpty) {
      return const PlaylistLinkRejected(PlaylistLinkProblem.notAUrl);
    }

    final host = uri.host.toLowerCase();
    if (_spotifyHosts.contains(host)) return _parseSpotify(uri);
    if (_youtubeHosts.contains(host)) return _parseYouTube(uri);

    return const PlaylistLinkRejected(PlaylistLinkProblem.unsupportedHost);
  }

  // ---- Spotify -----------------------------------------------------------

  static PlaylistLinkResult _parseSpotify(Uri uri) {
    // Path segments, with the locale prefix dropped. Spotify's web player
    // inserts `/intl-de/`, `/intl-pt/` and so on into shared links depending on
    // where the sharer is, and a parser that does not know that reads the
    // locale as the resource type and rejects a perfectly good link.
    final segments = uri.pathSegments
        .where((segment) => segment.isNotEmpty && !segment.startsWith('intl-'))
        .toList(growable: false);

    if (segments.isEmpty) {
      return const PlaylistLinkRejected(PlaylistLinkProblem.missingId);
    }

    final playlistIndex = segments.indexOf('playlist');
    if (playlistIndex == -1) {
      // A valid Spotify link to something that is not a playlist — an album, a
      // track, an artist. Worth its own message: the user is one tap from the
      // right link rather than on the wrong service entirely.
      return const PlaylistLinkRejected(PlaylistLinkProblem.notAPlaylist);
    }

    if (playlistIndex + 1 >= segments.length) {
      return const PlaylistLinkRejected(PlaylistLinkProblem.missingId);
    }

    final id = segments[playlistIndex + 1];
    if (!_spotifyId.hasMatch(id)) {
      return const PlaylistLinkRejected(PlaylistLinkProblem.malformedId);
    }

    return PlaylistLinkParsed(
      PlaylistLink(
        source: PlaylistSource.spotify,
        playlistId: id,
        // Rebuilt rather than echoed, which is what drops `?si=` — the
        // share-sheet token that makes two links to one playlist look
        // different, and would otherwise defeat duplicate detection.
        canonicalUrl: 'https://open.spotify.com/playlist/$id',
      ),
    );
  }

  static PlaylistLinkResult _parseSpotifyUri(String raw) {
    // spotify:playlist:37i9dQZF1DX3lmpQSniUBH
    final parts = raw.split(':').where((part) => part.isNotEmpty).toList();
    if (parts.length < 3) {
      return const PlaylistLinkRejected(PlaylistLinkProblem.missingId);
    }
    if (parts[1].toLowerCase() != 'playlist') {
      return const PlaylistLinkRejected(PlaylistLinkProblem.notAPlaylist);
    }

    final id = parts[2].split('?').first;
    if (!_spotifyId.hasMatch(id)) {
      return const PlaylistLinkRejected(PlaylistLinkProblem.malformedId);
    }

    return PlaylistLinkParsed(
      PlaylistLink(
        source: PlaylistSource.spotify,
        playlistId: id,
        canonicalUrl: 'https://open.spotify.com/playlist/$id',
      ),
    );
  }

  // ---- YouTube -----------------------------------------------------------

  static PlaylistLinkResult _parseYouTube(Uri uri) {
    // `list` is where the playlist id lives on every YouTube URL shape that
    // has one — /playlist, /watch and the youtu.be short form alike. Reading
    // it from the query rather than from the path is what makes one branch
    // cover all of them.
    final id = uri.queryParameters['list'];

    if (id == null || id.isEmpty) {
      // A YouTube link with no `list` is a video, a channel or the home page.
      final isWatch = uri.pathSegments.contains('watch') ||
          uri.host.toLowerCase().contains('youtu.be');
      return PlaylistLinkRejected(
        isWatch
            ? PlaylistLinkProblem.notAPlaylist
            : PlaylistLinkProblem.missingId,
      );
    }

    if (!_youtubeId.hasMatch(id)) {
      return const PlaylistLinkRejected(PlaylistLinkProblem.malformedId);
    }

    // `RD…` ids are radio/mix playlists: generated per viewer, unbounded, and
    // not enumerable through the Data API. Refused here with the real reason
    // rather than allowed through to fail as an opaque 404 several layers down.
    if (id.startsWith('RD') || id == 'LL' || id == 'WL') {
      return const PlaylistLinkRejected(PlaylistLinkProblem.notAPlaylist);
    }

    return PlaylistLinkParsed(
      PlaylistLink(
        source: PlaylistSource.youtube,
        playlistId: id,
        // Normalised onto music.youtube.com regardless of which YouTube
        // property the link came from, so the same playlist shared from the
        // main site and from YouTube Music is recognised as one playlist.
        canonicalUrl: 'https://music.youtube.com/playlist?list=$id',
      ),
    );
  }

  // ---- Helpers -----------------------------------------------------------

  /// Parses [raw] as a URL, tolerating a missing scheme.
  ///
  /// People paste `open.spotify.com/playlist/…` as often as they paste the
  /// full link — the browser address bar hides the scheme, so that is what
  /// they see and copy. `Uri.parse` reads it as a relative path with an empty
  /// host, so the scheme is supplied before parsing rather than the input being
  /// rejected for a difference the user cannot see.
  static Uri? _tryParse(String raw) {
    final candidate = raw.contains('://') ? raw : 'https://$raw';
    final uri = Uri.tryParse(candidate);
    if (uri == null) return null;
    if (uri.scheme != 'http' && uri.scheme != 'https') return null;
    if (!_isPlausibleHost(uri.host)) return null;
    return uri;
  }

  /// Whether [host] could be a hostname at all.
  ///
  /// Needed because prepending a scheme above turns *any* text into something
  /// `Uri.tryParse` accepts: "my workout playlist" becomes
  /// `https://my workout playlist`, which parses with that phrase as the host.
  /// Without this check the user is told their link is "from somewhere else",
  /// which is a confusing answer to something that was never a link.
  ///
  /// The test is deliberately loose — a dot and no whitespace — because it only
  /// has to separate "this is a URL" from "this is a sentence". Deciding
  /// whether the host is one AURIX supports is the caller's job.
  static bool _isPlausibleHost(String host) {
    if (host.isEmpty) return false;
    if (host.contains(RegExp(r'\s'))) return false;
    return host.contains('.');
  }
}
