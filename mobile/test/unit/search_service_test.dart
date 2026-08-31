import 'package:aurix/data/models/models.dart';
import 'package:aurix/data/search/library_search_provider.dart';
import 'package:aurix/data/search/search_provider.dart';
import 'package:flutter_test/flutter_test.dart';

import '../support/fixtures.dart';

/// A provider that returns a fixed answer, or refuses to.
class _ScriptedProvider implements SearchProvider {
  _ScriptedProvider({
    required this.displayName,
    required this.priority,
    required this.results,
    this.isAvailable = true,
    this.throws = false,
  });

  @override
  final String displayName;

  @override
  final int priority;

  @override
  final bool isAvailable;

  final SearchResults results;
  final bool throws;

  var searched = false;

  @override
  Future<SearchResults> search(String query, {int limit = 20}) async {
    searched = true;
    if (throws) throw StateError('provider is broken');
    return results;
  }
}

SearchResults _withTracks(List<Track> tracks) => SearchResults(
  tracks: Paging<Track>(
    items: tracks,
    total: tracks.length,
    limit: 20,
    offset: 0,
  ),
);

void main() {
  group('SearchService', () {
    test('merges results in provider priority order', () async {
      final mine = Track.fromDocument('aurix_a', {
        ...Fixtures.aurixTrackData,
        'title': 'Mine',
      });
      final theirs = Track.fromDocument('spotify_b', {
        ...Fixtures.aurixTrackData,
        'title': 'Theirs',
      });

      final service = SearchService(
        providers: [
          // Deliberately registered out of order: the service sorts.
          _ScriptedProvider(
            displayName: 'Catalogue',
            priority: 100,
            results: _withTracks([theirs]),
          ),
          _ScriptedProvider(
            displayName: 'Library',
            priority: 0,
            results: _withTracks([mine]),
          ),
        ],
      );

      final results = await service.search('anything');
      expect(results.tracks.items.map((t) => t.name), ['Mine', 'Theirs']);
    });

    test('the same track from two providers appears once', () async {
      // The library's copy wins because it is merged first: it is the one the
      // user can add to a playlist and that is already in their library.
      final track = Fixtures.importedTrack;
      final service = SearchService(
        providers: [
          _ScriptedProvider(
            displayName: 'Library',
            priority: 0,
            results: _withTracks([track]),
          ),
          _ScriptedProvider(
            displayName: 'Catalogue',
            priority: 100,
            results: _withTracks([track]),
          ),
        ],
      );

      final results = await service.search('midnight');
      expect(results.tracks.items, hasLength(1));
    });

    test('an unavailable provider is not asked', () async {
      final offline = _ScriptedProvider(
        displayName: 'Catalogue',
        priority: 100,
        results: SearchResults.empty,
        isAvailable: false,
      );
      final service = SearchService(providers: [offline]);

      await service.search('anything');
      expect(offline.searched, isFalse);
    });

    test('one broken provider does not empty the page', () async {
      // The property the whole fan-out exists for. Search used to be one
      // endpoint, so a Spotify failure was a blank results screen.
      final mine = Fixtures.aurixTrack;
      final service = SearchService(
        providers: [
          _ScriptedProvider(
            displayName: 'Library',
            priority: 0,
            results: _withTracks([mine]),
          ),
          _ScriptedProvider(
            displayName: 'Catalogue',
            priority: 100,
            results: SearchResults.empty,
            throws: true,
          ),
        ],
      );

      final results = await service.search('midnight');
      expect(results.tracks.items, hasLength(1));
    });

    test('an empty query asks nobody', () async {
      final provider = _ScriptedProvider(
        displayName: 'Library',
        priority: 0,
        results: SearchResults.empty,
      );
      final service = SearchService(providers: [provider]);

      expect((await service.search('   ')).isEmpty, isTrue);
      expect(provider.searched, isFalse);
    });
  });

  group('LibrarySearchProvider', () {
    late LibrarySearchProvider provider;

    setUp(() {
      provider = LibrarySearchProvider(
        likedTracks: () => [
          Track.fromDocument('aurix_1', {
            ...Fixtures.aurixTrackData,
            'title': 'Midnight Signal',
            'artist': 'Neon Meridian',
          }),
          Track.fromDocument('aurix_2', {
            ...Fixtures.aurixTrackData,
            'title': 'Daylight',
            'artist': 'Other Band',
            'album': 'Sunrise',
          }),
        ],
        playlists: () => [Fixtures.aurixPlaylist],
        playlistTracks: () => const [],
      );
    });

    test('is always available — that is the point of it', () {
      expect(provider.isAvailable, isTrue);
      // And outranks any catalogue: the user's own copy is the useful hit.
      expect(provider.priority, 0);
    });

    test('matches on title, artist and album', () async {
      expect((await provider.search('midnight')).tracks.items, hasLength(1));
      expect((await provider.search('other band')).tracks.items, hasLength(1));
      expect((await provider.search('sunrise')).tracks.items, hasLength(1));
    });

    test('matching is case-insensitive', () async {
      expect((await provider.search('MIDNIGHT')).tracks.items, hasLength(1));
    });

    test('finds playlists by name', () async {
      final results = await provider.search('late drive');
      expect(results.playlists.items.single.name, 'Late Drive');
    });

    test('returns no artists or albums', () async {
      // AURIX stores an artist as a display string on a track, not as a record
      // with an id, so an artist row here would navigate nowhere. A result that
      // cannot be tapped is worse than no result.
      final results = await provider.search('neon');
      expect(results.artists.items, isEmpty);
      expect(results.albums.items, isEmpty);
    });

    test('de-duplicates a track that is both liked and in a playlist',
        () async {
      final shared = Fixtures.aurixTrack;
      final withOverlap = LibrarySearchProvider(
        likedTracks: () => [shared],
        playlists: () => const [],
        playlistTracks: () => [shared],
      );
      final results = await withOverlap.search('midnight');
      expect(results.tracks.items, hasLength(1));
    });
  });
}
