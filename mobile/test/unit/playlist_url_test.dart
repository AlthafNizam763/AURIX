import 'package:aurix/data/import/playlist_url.dart';
import 'package:aurix/data/models/media_source.dart';
import 'package:flutter_test/flutter_test.dart';

/// The parser is the only part of importing that runs before anything is
/// known — no network, no credentials, no account — and it is the part a user
/// interacts with most directly, because they will paste the wrong thing.
///
/// These tests are the matrix of what people actually paste.
void main() {
  PlaylistLink parse(String raw) {
    final result = PlaylistUrlParser.parse(raw);
    expect(
      result,
      isA<PlaylistLinkParsed>(),
      reason: 'expected "$raw" to parse',
    );
    return (result as PlaylistLinkParsed).link;
  }

  PlaylistLinkProblem reject(String raw) {
    final result = PlaylistUrlParser.parse(raw);
    expect(
      result,
      isA<PlaylistLinkRejected>(),
      reason: 'expected "$raw" to be rejected',
    );
    return (result as PlaylistLinkRejected).problem;
  }

  group('Spotify', () {
    // The exact URL from the requirements. Its `si` token is a share-sheet
    // artifact and must not survive into the stored record — two people
    // sharing one playlist produce different `si` values, and keeping them
    // would defeat duplicate detection.
    test('extracts the id from a share link and drops the si token', () {
      final link = parse(
        'https://open.spotify.com/playlist/37i9dQZF1DX3lmpQSniUBH'
        '?si=571b0f1f575349ef',
      );

      expect(link.source, PlaylistSource.spotify);
      expect(link.playlistId, '37i9dQZF1DX3lmpQSniUBH');
      expect(link.canonicalUrl, isNot(contains('si=')));
      expect(
        link.canonicalUrl,
        'https://open.spotify.com/playlist/37i9dQZF1DX3lmpQSniUBH',
      );
      expect(link.mediaSource, MediaSource.spotify);
    });

    test('two share links to one playlist canonicalise identically', () {
      final a = parse(
        'https://open.spotify.com/playlist/37i9dQZF1DX3lmpQSniUBH?si=aaa',
      );
      final b = parse(
        'https://open.spotify.com/playlist/37i9dQZF1DX3lmpQSniUBH?si=bbb'
        '&utm_source=copy-link',
      );

      expect(a.canonicalUrl, b.canonicalUrl);
      expect(a.playlistId, b.playlistId);
    });

    // Spotify's web player inserts a locale into shared links depending on
    // where the sharer is. A parser that reads the locale as the resource type
    // rejects a perfectly good link.
    test('tolerates an intl- locale segment', () {
      final link = parse(
        'https://open.spotify.com/intl-de/playlist/37i9dQZF1DX3lmpQSniUBH',
      );
      expect(link.playlistId, '37i9dQZF1DX3lmpQSniUBH');
    });

    test('accepts the spotify: URI form', () {
      final link = parse('spotify:playlist:37i9dQZF1DX3lmpQSniUBH');
      expect(link.source, PlaylistSource.spotify);
      expect(link.playlistId, '37i9dQZF1DX3lmpQSniUBH');
    });

    // People copy from the address bar, which hides the scheme.
    test('tolerates a missing scheme', () {
      final link = parse('open.spotify.com/playlist/37i9dQZF1DX3lmpQSniUBH');
      expect(link.playlistId, '37i9dQZF1DX3lmpQSniUBH');
    });

    // A valid Spotify link to the wrong kind of thing gets its own message:
    // the user is one tap from the right link, not on the wrong service.
    test('an album link is rejected as not-a-playlist', () {
      expect(
        reject('https://open.spotify.com/album/4aawyAB9vmqN3uQ7FjRGTy'),
        PlaylistLinkProblem.notAPlaylist,
      );
    });

    test('a track link is rejected as not-a-playlist', () {
      expect(
        reject('https://open.spotify.com/track/0VjIjW4GlUZAMYd2vXMi3b'),
        PlaylistLinkProblem.notAPlaylist,
      );
    });
  });

  group('YouTube', () {
    test('reads the list parameter from a youtube.com playlist link', () {
      final link = parse(
        'https://www.youtube.com/playlist?list=PLFgquLnL59amjTf6Rl6BhH9pMEsRy_Bkc',
      );
      expect(link.source, PlaylistSource.youtube);
      expect(link.playlistId, 'PLFgquLnL59amjTf6Rl6BhH9pMEsRy_Bkc');
      expect(link.mediaSource, MediaSource.youtube);
    });

    // The same playlist shared from YouTube Music and from the main site must
    // be recognised as one playlist, or duplicate detection fails for anyone
    // who shares from a different app than they imported from.
    test('music.youtube.com and youtube.com canonicalise identically', () {
      final music = parse(
        'https://music.youtube.com/playlist?list=PLtest123',
      );
      final main = parse('https://www.youtube.com/playlist?list=PLtest123');

      expect(music.canonicalUrl, main.canonicalUrl);
      expect(music.playlistId, main.playlistId);
    });

    // A watch URL with a list parameter is how someone shares "this playlist,
    // starting here". The playlist is what AURIX imports.
    test('reads the list parameter out of a watch URL', () {
      final link = parse(
        'https://www.youtube.com/watch?v=dQw4w9WgXcQ&list=PLtest123',
      );
      expect(link.playlistId, 'PLtest123');
    });

    test('a bare video link is rejected as not-a-playlist', () {
      expect(
        reject('https://www.youtube.com/watch?v=dQw4w9WgXcQ'),
        PlaylistLinkProblem.notAPlaylist,
      );
    });

    // RD ids are per-viewer radio mixes: unbounded and not enumerable through
    // the Data API. Refused up front with the real reason rather than allowed
    // through to fail as an opaque 404 several layers down.
    test('a radio mix is refused rather than attempted', () {
      expect(
        reject('https://music.youtube.com/playlist?list=RDCLAK5uy_abc'),
        PlaylistLinkProblem.notAPlaylist,
      );
    });
  });

  group('rejections', () {
    test('empty input', () {
      expect(reject('   '), PlaylistLinkProblem.empty);
    });

    test('not a URL at all', () {
      expect(reject('my workout playlist'), PlaylistLinkProblem.notAUrl);
    });

    test('a supported-looking host that is neither', () {
      expect(
        reject('https://music.apple.com/us/playlist/chill/pl.abc123'),
        PlaylistLinkProblem.unsupportedHost,
      );
    });
  });

  group('detect', () {
    // Drives the source badge beside the field, so it has to answer before the
    // id has necessarily been pasted.
    test('names the service from the host alone', () {
      expect(
        PlaylistUrlParser.detect('https://open.spotify.com/'),
        PlaylistSource.spotify,
      );
      expect(
        PlaylistUrlParser.detect('https://music.youtube.com/'),
        PlaylistSource.youtube,
      );
      expect(
        PlaylistUrlParser.detect('https://example.com/'),
        PlaylistSource.unknown,
      );
      expect(PlaylistUrlParser.detect(''), PlaylistSource.unknown);
    });
  });
}
