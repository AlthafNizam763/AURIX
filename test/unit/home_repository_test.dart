import 'package:aurix/core/network/api_exception.dart';
import 'package:aurix/core/network/connectivity_service.dart';
import 'package:aurix/core/storage/metadata_cache.dart';
import 'package:aurix/core/storage/preferences_store.dart';
import 'package:aurix/data/models/album.dart';
import 'package:aurix/data/models/artist.dart';
import 'package:aurix/data/models/category.dart';
import 'package:aurix/data/models/home_feed.dart';
import 'package:aurix/data/models/paging.dart';
import 'package:aurix/data/models/playlist.dart';
import 'package:aurix/data/models/saved_item.dart';
import 'package:aurix/data/models/track.dart';
import 'package:aurix/data/repositories/home_repository.dart';
import 'package:aurix/data/services/spotify_browse_service.dart';
import 'package:aurix/data/services/spotify_playlist_service.dart';
import 'package:aurix/data/services/spotify_recommendation_service.dart';
import 'package:aurix/data/services/spotify_user_service.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../support/fixtures.dart';

class _MockUsers extends Mock implements SpotifyUserService {}

class _MockPlaylists extends Mock implements SpotifyPlaylistService {}

class _MockBrowse extends Mock implements SpotifyBrowseService {}

class _MockRecommendations extends Mock implements SpotifyRecommendationService {}

class _MockConnectivity extends Mock implements ConnectivityService {}

/// The Home feed after the 2026 endpoint removals.
///
/// The property under test is not "does it render" but *what it is allowed to
/// ask for*. Every `/browse/*` endpoint answers 403 to a Development Mode
/// application, so a shelf that depends on one is not degraded — it is dead,
/// and it costs a refused round trip on every load to discover that again.
void main() {
  late _MockUsers users;
  late _MockPlaylists playlists;
  late _MockBrowse browse;
  late _MockRecommendations recommendations;
  late _MockConnectivity connectivity;
  late MetadataCache cache;
  late HomeRepository repository;

  final track = Track.fromJson(Fixtures.trackJson);
  final artist = Artist.fromJson(Fixtures.artistJson);
  final album = Album.fromJson(Fixtures.albumWithoutTracksJson);
  final playlist = Playlist.fromJson(Fixtures.playlistJson);

  Paging<T> page<T>(List<T> items) =>
      Paging<T>(items: items, total: items.length, limit: items.length, offset: 0);

  /// Every user endpoint returns data. This is the "established account" case.
  void stubEverythingPopulated() {
    when(() => users.recentlyPlayed(limit: any(named: 'limit')))
        .thenAnswer((_) async => CursorPaging<PlayHistoryEntry>(
              items: [PlayHistoryEntry(track: track, playedAt: DateTime(2026))],
              limit: 1,
            ));
    when(() => users.topTracks(
          range: any(named: 'range'),
          limit: any(named: 'limit'),
        )).thenAnswer((_) async => page<Track>([track]));
    when(() => users.topArtists(
          range: any(named: 'range'),
          limit: any(named: 'limit'),
        )).thenAnswer((_) async => page<Artist>([artist]));
    when(() => users.savedTracks(limit: any(named: 'limit')))
        .thenAnswer((_) async => page<SavedTrack>([SavedTrack(track: track)]));
    when(() => users.savedAlbumsFlat(limit: any(named: 'limit')))
        .thenAnswer((_) async => <Album>[album]);
    when(() => users.followedArtists(limit: any(named: 'limit'))).thenAnswer(
      (_) async => CursorPaging<Artist>(items: [artist], limit: 1),
    );
    when(() => playlists.myPlaylists(limit: any(named: 'limit')))
        .thenAnswer((_) async => page<Playlist>([playlist]));
    when(() => recommendations.recommendedTracks(limit: any(named: 'limit')))
        .thenAnswer((_) async => <Track>[track]);
    when(() => browse.categories(limit: any(named: 'limit')))
        .thenAnswer((_) async => MoodCatalogue.defaults);
  }

  // mocktail needs a concrete instance before `any(named: 'range')` can stand
  // in for an enum argument.
  setUpAll(() => registerFallbackValue(TopItemRange.mediumTerm));

  setUp(() async {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    cache = MetadataCache(await PreferencesStore.open());

    users = _MockUsers();
    playlists = _MockPlaylists();
    browse = _MockBrowse();
    recommendations = _MockRecommendations();
    connectivity = _MockConnectivity();
    when(() => connectivity.isOffline).thenReturn(false);

    repository = HomeRepository(
      userService: users,
      playlistService: playlists,
      browseService: browse,
      recommendationService: recommendations,
      cache: cache,
      connectivity: connectivity,
    );
  });

  group('shelf composition', () {
    test('every shelf is built from the signed-in user\'s own data', () async {
      stubEverythingPopulated();

      final feed = await repository.load(forceRefresh: true);
      final ids = feed.visibleShelves.map((s) => s.id).toSet();

      expect(ids, contains(ShelfIds.recentlyPlayed));
      expect(ids, contains(ShelfIds.trending));
      expect(ids, contains(ShelfIds.popularArtists));
      expect(ids, contains(ShelfIds.madeForYou));
      expect(ids, contains(ShelfIds.likedSongs));
      expect(ids, contains(ShelfIds.savedAlbums));
      expect(ids, contains(ShelfIds.followedArtists));
    });

    test('no shelf depends on a removed browse endpoint', () async {
      stubEverythingPopulated();

      final feed = await repository.load(forceRefresh: true);
      final ids = feed.visibleShelves.map((s) => s.id).toSet();

      // `new_releases` and `popular_albums` were built on
      // `/browse/new-releases`; `featured_playlists` and `categories` on the
      // other restricted browse endpoints.
      expect(ids.intersection(ShelfIds.retired), isEmpty);
    });

    test('the playlists shelf never asks for editorial playlists', () async {
      stubEverythingPopulated();

      await repository.load(forceRefresh: true);

      // `/browse/featured-playlists` is restricted; the shelf is the user's
      // own playlists and nothing else.
      verify(() => playlists.myPlaylists(limit: any(named: 'limit'))).called(1);
    });
  });

  group('an account with no history', () {
    setUp(() {
      stubEverythingPopulated();
      // A brand-new account: top tracks and top artists are empty at every
      // time range, and nothing has been saved or followed yet.
      when(() => users.topTracks(
            range: any(named: 'range'),
            limit: any(named: 'limit'),
          )).thenAnswer((_) async => page<Track>(const []));
      when(() => users.topArtists(
            range: any(named: 'range'),
            limit: any(named: 'limit'),
          )).thenAnswer((_) async => page<Artist>(const []));
      when(() => users.savedTracks(limit: any(named: 'limit')))
          .thenAnswer((_) async => page<SavedTrack>(const []));
      when(() => users.savedAlbumsFlat(limit: any(named: 'limit')))
          .thenAnswer((_) async => <Album>[]);
      when(() => recommendations.recommendedTracks(limit: any(named: 'limit')))
          .thenAnswer((_) async => <Track>[]);
    });

    test('empty shelves are hidden rather than shown broken', () async {
      final feed = await repository.load(forceRefresh: true);
      final ids = feed.visibleShelves.map((s) => s.id).toSet();

      expect(ids, isNot(contains(ShelfIds.trending)));
      expect(ids, isNot(contains(ShelfIds.popularArtists)));
      expect(ids, isNot(contains(ShelfIds.likedSongs)));
      expect(ids, isNot(contains(ShelfIds.savedAlbums)));
      // What the account does have still renders.
      expect(ids, contains(ShelfIds.recentlyPlayed));
    });

    test('the top-tracks shelf widens its time range before giving up', () async {
      // Short term is empty for a new account, but a month-old one may have
      // long-term data. Asking once and quitting would hide a usable shelf.
      await repository.load(forceRefresh: true);

      verify(() => users.topTracks(
            range: any(named: 'range'),
            limit: any(named: 'limit'),
          )).called(3);
    });
  });

  group('failure isolation', () {
    test('a 403 on one shelf never fails the whole feed', () async {
      stubEverythingPopulated();
      when(() => users.savedAlbumsFlat(limit: any(named: 'limit'))).thenThrow(
        const ApiException(
          kind: ApiFailureKind.forbidden,
          message: 'Spotify would not allow that request for this account.',
          statusCode: 403,
          endpoint: '/me/albums',
        ),
      );

      final feed = await repository.load(forceRefresh: true);
      final ids = feed.visibleShelves.map((s) => s.id).toSet();

      // The failed shelf is dropped; every other shelf still renders. It is
      // emphatically *not* routed to the global access-denied screen — only a
      // 403 on GET /me means the application is refused, and that decision
      // lives in AuthRepository.
      expect(ids, isNot(contains(ShelfIds.savedAlbums)));
      expect(ids, contains(ShelfIds.recentlyPlayed));
      expect(ids, contains(ShelfIds.likedSongs));
    });

    test('a failed shelf shows no error text to the user', () async {
      stubEverythingPopulated();
      when(() => users.followedArtists(limit: any(named: 'limit')))
          .thenThrow(Exception('boom'));

      final feed = await repository.load(forceRefresh: true);

      // shouldRender is false for an errored shelf, so nothing reaches the UI.
      expect(
        feed.visibleShelves.every((s) => s.error == null),
        isTrue,
        reason: 'an error shelf must be dropped, not rendered',
      );
    });
  });
}
