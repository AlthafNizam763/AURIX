import 'package:aurix/data/models/song.dart';
import 'package:aurix/data/models/song_key.dart';
import 'package:aurix/data/services/youtube_api_service.dart';
import 'package:flutter_test/flutter_test.dart';

/// The catalogue's whole value rests on one claim: the same song, arriving from
/// different services and described differently, becomes one document.
///
/// These tests are that claim, plus the opposite one that matters just as much
/// — that two genuinely different recordings stay apart.
void main() {
  group('cross-service identity', () {
    // The case from the requirements: Spotify hands over a structured record,
    // YouTube hands over an uploader's title. Both must key to one document,
    // or a user who imports one playlist from each ends up with the same song
    // twice in search.
    test('a Spotify record and a YouTube upload title agree', () {
      final spotify = SongKey.of(
        title: 'Blinding Lights',
        artist: 'The Weeknd',
      );
      final youtube = SongKey.of(
        title: 'Blinding Lights (Official Video)',
        artist: 'The Weeknd',
      );

      expect(spotify, youtube);
    });

    test('remaster and packaging noise does not fork the key', () {
      final plain = SongKey.of(title: 'Come Together', artist: 'The Beatles');

      for (final variant in const <String>[
        'Come Together - Remastered 2009',
        'Come Together (2009 Remaster)',
        'Come Together [4K] (Official Audio)',
        'Come Together (Official Music Video)',
      ]) {
        expect(
          SongKey.of(title: variant, artist: 'The Beatles'),
          plain,
          reason: '"$variant" should key the same as "Come Together"',
        );
      }
    });

    // Spotify lists every collaborator; YouTube names one channel. Keying on
    // the full credit would fork the song.
    test('only the primary artist decides identity', () {
      expect(
        SongKey.of(title: 'Starboy', artist: 'The Weeknd, Daft Punk'),
        SongKey.of(title: 'Starboy', artist: 'The Weeknd'),
      );
    });

    test('a featured credit in the title does not fork the key', () {
      expect(
        SongKey.of(title: 'Starboy (feat. Daft Punk)', artist: 'The Weeknd'),
        SongKey.of(title: 'Starboy', artist: 'The Weeknd'),
      );
    });

    test('accents fold', () {
      expect(
        SongKey.of(title: 'Déjà Vu', artist: 'Beyoncé'),
        SongKey.of(title: 'Deja Vu', artist: 'Beyonce'),
      );
    });

    test('a Topic channel suffix is not part of the artist', () {
      expect(
        SongKey.normaliseArtist('The Weeknd - Topic'),
        SongKey.normaliseArtist('The Weeknd'),
      );
    });
  });

  group('recordings that must stay apart', () {
    // The rule the normaliser is deliberately conservative about: packaging
    // describes the upload and is stripped, but these words describe a
    // different performance and must survive. Merging them would silently
    // replace a user's live album track with the studio version.
    test('live, acoustic, remix and instrumental are different songs', () {
      final studio = SongKey.of(title: 'Creep', artist: 'Radiohead');

      for (final variant in const <String>[
        'Creep (Live)',
        'Creep (Acoustic)',
        'Creep (Remix)',
        'Creep - Instrumental',
      ]) {
        expect(
          SongKey.of(title: variant, artist: 'Radiohead'),
          isNot(studio),
          reason: '"$variant" is a different recording from "Creep"',
        );
      }
    });

    test('different artists are different songs', () {
      expect(
        SongKey.of(title: 'Hurt', artist: 'Johnny Cash'),
        isNot(SongKey.of(title: 'Hurt', artist: 'Nine Inch Nails')),
      );
    });

    // Two long titles sharing a prefix must not collide once the readable slug
    // has been truncated. The hash is what guarantees that.
    test('long titles sharing a prefix stay distinct', () {
      final a = 'A' * 120;
      expect(
        SongKey.of(title: '$a one', artist: 'Someone'),
        isNot(SongKey.of(title: '$a two', artist: 'Someone')),
      );
    });

    test('keys are stable across calls', () {
      expect(
        SongKey.of(title: 'Blinding Lights', artist: 'The Weeknd'),
        SongKey.of(title: 'Blinding Lights', artist: 'The Weeknd'),
      );
    });
  });

  group('video title splitting', () {
    test('splits the Artist - Title convention', () {
      final split = SongKey.splitVideoTitle(
        'The Weeknd - Blinding Lights (Official Video)',
      );
      expect(split?.artist, 'The Weeknd');
      expect(split?.title, 'Blinding Lights (Official Video)');
    });

    test('handles an en dash', () {
      final split = SongKey.splitVideoTitle('Daft Punk – One More Time');
      expect(split?.artist, 'Daft Punk');
      expect(split?.title, 'One More Time');
    });

    // Returning null is the honest answer, and the caller then keeps the raw
    // title and credits the channel rather than inventing a split.
    test('gives up on a title with no separator', () {
      expect(SongKey.splitVideoTitle('Best Songs Of 2024'), isNull);
    });
  });

  group('search tokens', () {
    test('index a word from the middle of a title', () {
      final tokens = SearchTokens.forSong(
        title: 'Blinding Lights',
        artist: 'The Weeknd',
      );

      // The property a range-scan approach could not provide: "lights" is not
      // a prefix of the whole field, but it is a prefix of a word in it.
      expect(tokens, contains('light'));
      expect(tokens, contains('lights'));
      expect(tokens, contains('blind'));
      expect(tokens, contains('weeknd'));
    });

    test('index the album too', () {
      final tokens = SearchTokens.forSong(
        title: 'Starboy',
        artist: 'The Weeknd',
        album: 'Starboy',
      );
      expect(tokens, contains('starboy'));
    });

    // A featured artist must be findable even though only the primary artist
    // decides identity.
    test('index every credited artist, not only the primary one', () {
      final tokens = SearchTokens.forSong(
        title: 'Starboy',
        artist: 'The Weeknd, Daft Punk',
      );
      expect(tokens, contains('daft'));
      expect(tokens, contains('punk'));
    });

    test('stay within the per-document cap', () {
      final tokens = SearchTokens.forSong(
        title: List<String>.filled(60, 'verylongwordhere').join(' '),
        artist: List<String>.filled(60, 'anotherlongword').join(' '),
        album: List<String>.filled(60, 'albumwordhere').join(' '),
      );
      expect(tokens.length, lessThanOrEqualTo(SearchTokens.maxTokens));
    });

    test('a query is matched on its most selective word', () {
      // "blinding" is longer than "lights", so it goes to the index and
      // "lights" is applied in memory over the bounded page.
      expect(SearchTokens.queryToken('blinding lights'), 'blinding');
      expect(SearchTokens.residualWords('blinding lights'), contains('lights'));
    });

    test('a query with nothing indexable yields no token', () {
      expect(SearchTokens.queryToken('   '), isEmpty);
      expect(SearchTokens.queryToken('!!!'), isEmpty);
    });
  });

  group('Song round trip', () {
    test('survives a Firestore round trip', () {
      final song = Song(
        id: SongKey.of(title: 'Blinding Lights', artist: 'The Weeknd'),
        title: 'Blinding Lights',
        artists: const <String>['The Weeknd'],
        album: 'After Hours',
        durationMs: 200040,
        artworkUrl: 'https://i.scdn.co/image/abc',
        sourceId: '0VjIjW4GlUZAMYd2vXMi3b',
        spotifyId: '0VjIjW4GlUZAMYd2vXMi3b',
        searchTokens: const <String>['blind', 'blinding'],
      );

      final restored = Song.fromDocument(song.id, song.toDocument());

      expect(restored.id, song.id);
      expect(restored.title, song.title);
      expect(restored.artists, song.artists);
      expect(restored.album, song.album);
      expect(restored.durationMs, song.durationMs);
      expect(restored.spotifyId, song.spotifyId);
    });

    // The conversion the rest of the app depends on: a catalogue row must drop
    // into any existing list, queue or player with nothing changed at the call
    // site.
    test('converts to a runtime track the UI can render', () {
      final song = Song(
        id: SongKey.of(title: 'Starboy', artist: 'The Weeknd'),
        title: 'Starboy',
        artists: const <String>['The Weeknd', 'Daft Punk'],
        album: 'Starboy',
        durationMs: 230000,
        artworkUrl: 'https://i.scdn.co/image/xyz',
        spotifyId: '7MXVkk9YMctZqd1Srtv4MB',
      );

      final track = song.toTrack();

      expect(track.name, 'Starboy');
      expect(track.artistNames, 'The Weeknd, Daft Punk');
      expect(track.album?.name, 'Starboy');
      expect(track.artworkUrl, 'https://i.scdn.co/image/xyz');
      expect(track.hasSpotifyId, isTrue);
    });

    // The merge is what lets a second import improve a row rather than erase
    // it — and specifically what lets a Spotify-sourced song gain its YouTube
    // id, so either player can address it.
    test('a merge fills gaps and never overwrites what is there', () {
      const existing = Song(
        id: 'sng_x',
        title: 'Blinding Lights',
        artists: <String>['The Weeknd'],
        album: 'After Hours',
        durationMs: 200040,
        artworkUrl: 'https://spotify/art',
        spotifyId: 'spotify-id',
      );

      const incoming = Song(
        id: 'sng_x',
        title: 'Blinding Lights',
        artists: <String>['The Weeknd'],
        artworkUrl: 'https://youtube/art',
        youtubeVideoId: 'yt-id',
      );

      final delta = incoming.toDocumentMerge(existing);

      expect(delta['youtubeVideoId'], 'yt-id', reason: 'gap is filled');
      expect(delta.containsKey('artworkUrl'), isFalse,
          reason: 'existing artwork is not overwritten');
      expect(delta.containsKey('album'), isFalse);
      expect(delta.containsKey('spotifyId'), isFalse);
    });

    test('a merge with nothing to contribute is empty', () {
      const song = Song(
        id: 'sng_x',
        title: 'Blinding Lights',
        artists: <String>['The Weeknd'],
        album: 'After Hours',
        durationMs: 200040,
        artworkUrl: 'https://spotify/art',
        spotifyId: 'spotify-id',
      );

      // An empty delta is what makes a re-import of an unchanged playlist cost
      // zero writes.
      expect(song.toDocumentMerge(song), isEmpty);
    });
  });

  group('YouTube ISO-8601 durations', () {
    test('parses the shapes the API actually returns', () {
      expect(YouTubeApiService.parseIso8601Duration('PT3M52S'), 232000);
      expect(YouTubeApiService.parseIso8601Duration('PT4M'), 240000);
      expect(YouTubeApiService.parseIso8601Duration('PT47S'), 47000);
      expect(YouTubeApiService.parseIso8601Duration('PT1H2M3S'), 3723000);
      expect(YouTubeApiService.parseIso8601Duration('P1DT2H'), 93600000);
    });

    // An unknown duration renders as `--:--`, which is better than a wrong one.
    test('returns zero for anything unparseable', () {
      expect(YouTubeApiService.parseIso8601Duration('nonsense'), 0);
      expect(YouTubeApiService.parseIso8601Duration(''), 0);
    });
  });
}
