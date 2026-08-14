import 'dart:convert';

import 'package:aurix/core/network/api_exception.dart';
import 'package:aurix/data/models/album.dart';
import 'package:aurix/data/models/search_results.dart';
import 'package:aurix/data/services/spotify_album_service.dart';
import 'package:aurix/data/services/spotify_api_service.dart';
import 'package:aurix/data/services/spotify_artist_service.dart';
import 'package:aurix/data/services/spotify_player_service.dart';
import 'package:aurix/data/services/spotify_playlist_service.dart';
import 'package:aurix/data/services/spotify_search_service.dart';
import 'package:aurix/data/services/spotify_user_service.dart';
import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';

import '../support/fixtures.dart';

/// A Dio stand-in that records requests and replays canned responses.
///
/// Preferred over mocking Dio with mocktail here because the assertions are
/// mostly about *what was requested* — the query parameters, the batching,
/// the market — and a recorder makes those assertions direct.
class _FakeAdapter implements HttpClientAdapter {
  _FakeAdapter(this.handler);

  final Future<ResponseBody> Function(RequestOptions options) handler;
  final List<RequestOptions> requests = [];

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<List<int>>? requestStream,
    Future<void>? cancelFuture,
  ) {
    requests.add(options);
    return handler(options);
  }

  @override
  void close({bool force = false}) {}
}

void main() {
  late _FakeAdapter adapter;
  late Dio dio;

  /// Builds a Dio whose responses come from [routes], keyed by path prefix.
  Dio buildDio(Map<String, Object> routes, {int status = 200}) {
    adapter = _FakeAdapter((options) async {
      final match = routes.entries
          .where((entry) => options.path.startsWith(entry.key))
          .toList();

      if (match.isEmpty) {
        return ResponseBody.fromString(
          '{"error":{"status":404,"message":"no route"}}',
          404,
          headers: {
            Headers.contentTypeHeader: [Headers.jsonContentType],
          },
        );
      }

      return ResponseBody.fromString(
        _encode(match.first.value),
        status,
        headers: {
          Headers.contentTypeHeader: [Headers.jsonContentType],
        },
      );
    });

    final client = Dio(
      BaseOptions(
        baseUrl: 'https://api.spotify.com/v1',
        validateStatus: (s) => s != null && s < 400,
      ),
    );
    client.httpClientAdapter = adapter;
    return client;
  }

  setUp(() {
    SpotifyApiService.market = 'from_token';
    // Static, and deliberately session-scoped in production. Left over from a
    // previous test it would silence requests a later test is asserting on.
    SpotifyApiService.resetAvailability();
  });

  group('SpotifySearchService', () {
    test('requests every type in one call and parses each section', () async {
      dio = buildDio({'/search': Fixtures.searchResponseJson});
      final service = SpotifySearchService(dio);

      final results = await service.searchAll('neon');

      expect(adapter.requests.length, 1, reason: 'one request, not three');
      final query = adapter.requests.single.queryParameters;
      expect(query['q'], 'neon');
      // Playlist is deliberately absent: a playlist search returns mostly null
      // entries to a Development Mode app, so the tab would render empty for
      // every query.
      expect(query['type'], 'track,artist,album');
      expect(query['market'], 'from_token');

      expect(results.tracks.items.length, 2);
      expect(results.artists.items.length, 1);
    });

    test('an empty query short-circuits without a request', () async {
      dio = buildDio({'/search': Fixtures.searchResponseJson});
      final service = SpotifySearchService(dio);

      final results = await service.searchAll('   ');

      expect(adapter.requests, isEmpty);
      expect(results.isEmpty, isTrue);
    });

    test('clamps limit to the search maximum of 10, not the general 50', () async {
      // Spotify's February 2026 changes cut the search cap from 50 to 10 for
      // Development Mode apps. Anything above it is a flat 400, so this is the
      // difference between search working and search being entirely dead.
      dio = buildDio({'/search': Fixtures.searchResponseJson});
      await SpotifySearchService(dio).searchAll('x', limit: 500);

      expect(adapter.requests.single.queryParameters['limit'], 10);
    });

    test('the default page size is clamped too', () async {
      // The reported failure: the default of 20 exceeded the cap, so every
      // single query 400'd — not just unusually large ones.
      dio = buildDio({'/search': Fixtures.searchResponseJson});
      await SpotifySearchService(dio).searchAll('x');

      final limit = adapter.requests.single.queryParameters['limit'] as int;
      expect(limit, lessThanOrEqualTo(10));
    });

    test('paging still works, driven by offset rather than page size', () async {
      dio = buildDio({'/search': Fixtures.searchResponseJson});
      await SpotifySearchService(dio).searchType(
        'x',
        SearchType.track,
        offset: 30,
      );

      final query = adapter.requests.single.queryParameters;
      expect(query['offset'], 30);
      expect(query['limit'], 10);
    });

    test('single-type search asks for only that type', () async {
      dio = buildDio({'/search': Fixtures.searchResponseJson});
      await SpotifySearchService(dio).searchType('x', SearchType.album);

      expect(adapter.requests.single.queryParameters['type'], 'album');
    });

    test('suggestions de-duplicate across artists and tracks', () async {
      dio = buildDio({'/search': Fixtures.searchResponseJson});
      final suggestions = await SpotifySearchService(dio).suggestions('neon');

      expect(suggestions, isNotEmpty);
      expect(suggestions.toSet().length, suggestions.length);
    });

    test('a query under two characters makes no request', () async {
      dio = buildDio({'/search': Fixtures.searchResponseJson});
      final suggestions = await SpotifySearchService(dio).suggestions('n');

      expect(adapter.requests, isEmpty);
      expect(suggestions, isEmpty);
    });

    group('parameters Spotify rejects', () {
      // Each of these is a 400 from Spotify, and a 400 on /search means the
      // feature is dead rather than degraded — there is no partial result.
      test('an empty type list still sends a valid type', () async {
        dio = buildDio({'/search': Fixtures.searchResponseJson});
        await SpotifySearchService(dio).searchAll('x', types: const []);

        expect(
          adapter.requests.single.queryParameters['type'],
          'track,artist,album',
        );
      });

      test('a whitespace-only query never reaches the network', () async {
        dio = buildDio({'/search': Fixtures.searchResponseJson});
        await SpotifySearchService(dio).searchAll('\n\t  ');

        expect(adapter.requests, isEmpty);
      });

      test('the query is trimmed, not sent with padding', () async {
        dio = buildDio({'/search': Fixtures.searchResponseJson});
        await SpotifySearchService(dio).searchAll('  Arijit Singh  ');

        expect(adapter.requests.single.queryParameters['q'], 'Arijit Singh');
      });

      test('a negative offset is clamped rather than sent', () async {
        dio = buildDio({'/search': Fixtures.searchResponseJson});
        await SpotifySearchService(dio).searchAll('x', offset: -5);

        expect(adapter.requests.single.queryParameters['offset'], 0);
      });

      test('spaces and non-Latin scripts survive encoding', () async {
        dio = buildDio({'/search': Fixtures.searchResponseJson});
        await SpotifySearchService(dio).searchAll('അതിമനോഹരം vaazha');

        // Dio percent-encodes on the wire; the parameter itself must stay raw
        // so it is not double-escaped.
        expect(
          adapter.requests.single.queryParameters['q'],
          'അതിമനോഹരം vaazha',
        );
        expect(adapter.requests.single.uri.query, contains('%'));
      });
    });
  });

  group('endpoint availability memo', () {
    // Spotify's February 2026 changes folded the per-entity `contains`
    // endpoints into /me/library/contains; the per-type paths now answer 403
    // to a Development Mode app. Every library screen calls one; without the
    // memo the same refusal is paid for on every scroll.
    const path = '/me/library/contains';

    test('a 403 yields all-false rather than throwing', () async {
      dio = buildDio({path: <String, dynamic>{}}, status: 403);

      final flags = await SpotifyUserService(dio).areTracksSaved(['t1', 't2']);

      // Short responses are padded to the requested length by the caller, so
      // the heart renders unfilled instead of the list failing to render.
      expect(flags, [false, false]);
    });

    test('the refusal is remembered and not requested again', () async {
      dio = buildDio({path: <String, dynamic>{}}, status: 403);
      final service = SpotifyUserService(dio);

      await service.areTracksSaved(['t1']);
      expect(adapter.requests.length, 1);

      for (var i = 0; i < 4; i++) {
        await service.areTracksSaved(['t$i']);
      }
      expect(
        adapter.requests.length,
        1,
        reason: 'the refusal should be replayed from memory',
      );
      expect(SpotifyApiService.isKnownUnavailable(path), isTrue);
    });

    test('resetAvailability lets a session change be picked up', () async {
      dio = buildDio({path: <String, dynamic>{}}, status: 403);
      final service = SpotifyUserService(dio);

      await service.areTracksSaved(['t1']);
      expect(adapter.requests.length, 1);

      SpotifyApiService.resetAvailability();
      expect(SpotifyApiService.isKnownUnavailable(path), isFalse);

      await service.areTracksSaved(['t1']);
      expect(adapter.requests.length, 2, reason: 'asked again after a reset');
    });

    test('a success is not memoised', () async {
      dio = buildDio({path: [true, false]});
      final service = SpotifyUserService(dio);

      await service.areTracksSaved(['t1', 't2']);
      await service.areTracksSaved(['t1', 't2']);

      expect(adapter.requests.length, 2);
      expect(SpotifyApiService.isKnownUnavailable(path), isFalse);
    });
  });

  group('in-flight GET coalescing', () {
    test('two identical concurrent GETs cost one request', () async {
      dio = buildDio({'/me/top/artists': {'items': [Fixtures.artistJson]}});
      final service = SpotifyUserService(dio);

      // The Home feed's real shape: both branches start before either returns,
      // so no response cache can help — only coalescing can.
      final results = await Future.wait(<Future<Object?>>[
        service.topArtists(limit: 12),
        service.topArtists(limit: 12),
      ]);

      expect(adapter.requests.length, 1, reason: 'one flight, two callers');
      expect(results.length, 2);
      expect(results[0], isNotNull);
      expect(results[1], isNotNull);
    });

    test('a differing query is a different flight', () async {
      dio = buildDio({'/me/top/artists': {'items': [Fixtures.artistJson]}});
      final service = SpotifyUserService(dio);

      await Future.wait(<Future<Object?>>[
        service.topArtists(limit: 12),
        service.topArtists(limit: 20),
      ]);

      expect(adapter.requests.length, 2);
    });

    test('the entry is released, so a later identical GET is made again', () async {
      dio = buildDio({'/me/top/artists': {'items': [Fixtures.artistJson]}});
      final service = SpotifyUserService(dio);

      // Sequential, not concurrent: coalescing must not become a cache.
      await service.topArtists(limit: 12);
      await service.topArtists(limit: 12);

      expect(adapter.requests.length, 2);
    });

    test('a failed flight is released rather than pinned', () async {
      dio = buildDio({'/me/top/artists': <String, dynamic>{}}, status: 500);
      final service = SpotifyUserService(dio);

      for (var i = 0; i < 2; i++) {
        try {
          await service.topArtists(limit: 12);
        } on ApiException {
          // expected
        }
      }

      expect(adapter.requests.length, 2);
    });
  });

  group('SpotifyAlbumService', () {
    test('sends the market with an album request', () async {
      dio = buildDio({'/albums/': Fixtures.albumJson});
      SpotifyApiService.setMarketFromCountry('gb');

      await SpotifyAlbumService(dio).album('album_1');

      expect(adapter.requests.single.queryParameters['market'], 'GB');
    });

    test('grafts the parent album onto tracks that lack one', () async {
      // /albums/{id}/tracks omits `album`, so rows would render with no
      // artwork unless the parent is applied.
      dio = buildDio({
        '/albums/album_1/tracks': {
          'items': [Fixtures.trackJson],
          'total': 1,
          'limit': 50,
          'offset': 0,
        },
      });

      final page = await SpotifyAlbumService(dio).albumTracks(
        'album_1',
        parent: Fixtures.album,
      );

      expect(page.items.single.album?.id, 'album_1');
      expect(page.items.single.artworkUrl, isNotNull);
    });

    test('batches an id list into chunks of 20', () async {
      dio = buildDio({
        '/albums': {
          'albums': [Fixtures.albumWithoutTracksJson],
        },
      });

      final ids = List.generate(45, (i) => 'album_$i');
      await SpotifyAlbumService(dio).albums(ids);

      // 45 ids → 20 + 20 + 5.
      expect(adapter.requests.length, 3);
      expect(
        adapter.requests.first.queryParameters['ids'].toString().split(',').length,
        20,
      );
      expect(
        adapter.requests.last.queryParameters['ids'].toString().split(',').length,
        5,
      );
    });

    test('an empty id list makes no request', () async {
      dio = buildDio({'/albums': <String, dynamic>{}});
      final result = await SpotifyAlbumService(dio).albums(const []);

      expect(adapter.requests, isEmpty);
      expect(result, isEmpty);
    });

  });

  group('SpotifyArtistService', () {
    test('requests the right include_groups per discography section', () async {
      dio = buildDio({
        '/artists/artist_1/albums': {
          'items': [Fixtures.albumWithoutTracksJson],
          'total': 1,
          'limit': 20,
          'offset': 0,
        },
      });

      final service = SpotifyArtistService(dio);
      await service.albums('artist_1');
      await service.singles('artist_1');
      await service.appearsOn('artist_1');

      expect(adapter.requests[0].queryParameters['include_groups'], 'album');
      expect(adapter.requests[1].queryParameters['include_groups'], 'single');
      expect(
        adapter.requests[2].queryParameters['include_groups'],
        'appears_on,compilation',
      );
    });

    test(
      'related artists come from genre search, never from the dead endpoint',
      () async {
        // `/artists/{id}/related-artists` has been restricted since November
        // 2024 and is no longer called at all — it was a guaranteed 403 on
        // every artist screen. The adapter would answer 403 if it were hit.
        var relatedCalls = 0;
        adapter = _FakeAdapter((options) async {
          if (options.path.contains('related-artists')) {
            relatedCalls++;
            return ResponseBody.fromString(
              '{"error":{"status":403,"message":"Forbidden"}}',
              403,
              headers: {
                Headers.contentTypeHeader: [Headers.jsonContentType],
              },
            );
          }
          return ResponseBody.fromString(
            _encode({
              'artists': {
                'items': [
                  {...Fixtures.artistJson, 'id': 'artist_other', 'name': 'Other'},
                ],
                'total': 1,
                'limit': 20,
                'offset': 0,
              },
            }),
            200,
            headers: {
              Headers.contentTypeHeader: [Headers.jsonContentType],
            },
          );
        });

        final client = Dio(
          BaseOptions(
            baseUrl: 'https://api.spotify.com/v1',
            validateStatus: (s) => s != null && s < 400,
          ),
        )..httpClientAdapter = adapter;

        final related = await SpotifyArtistService(client).relatedArtists(
          'artist_1',
          genreHints: const ['synthwave', 'electronic'],
          excludeName: 'Neon Meridian',
        );

        expect(
          relatedCalls,
          0,
          reason: 'the restricted endpoint must not be requested at all',
        );
        expect(related, isNotEmpty);
        expect(related.every((a) => a.id != 'artist_1'), isTrue);

        // Results come from a real Spotify genre search.
        final searchRequest =
            adapter.requests.firstWhere((r) => r.path.contains('/search'));
        expect(searchRequest.queryParameters['q'], contains('genre:'));
      },
    );

    test('related-artists returns empty when there are no genre hints', () async {
      adapter = _FakeAdapter(
        (options) async => ResponseBody.fromString(
          '{"error":{"status":403,"message":"Forbidden"}}',
          403,
          headers: {
            Headers.contentTypeHeader: [Headers.jsonContentType],
          },
        ),
      );
      final client = Dio(
        BaseOptions(
          baseUrl: 'https://api.spotify.com/v1',
          validateStatus: (s) => s != null && s < 400,
        ),
      )..httpClientAdapter = adapter;

      final related = await SpotifyArtistService(client).relatedArtists('artist_1');
      expect(related, isEmpty);
    });
  });

  group('SpotifyPlaylistService contents', () {
    // The reported bug, reduced: `GET /playlists/{id}` answers 200 with correct
    // name, owner and follower count, but carries no inline contents. The old
    // code returned early and the screen rendered "24.5K likes · 0 songs" and
    // "This playlist is empty" over a playlist that plainly had songs.
    Map<String, dynamic> detailWithoutContents() {
      final json = Map<String, dynamic>.from(Fixtures.playlistJson);
      json.remove('tracks');
      return json;
    }

    Map<String, dynamic> contentsPage() => <String, dynamic>{
      'items': [
        {
          'added_at': '2024-02-01T10:00:00Z',
          'added_by': {'id': 'user_owner'},
          'is_local': false,
          'track': Fixtures.trackJson,
        },
      ],
      'total': 137,
      'limit': 50,
      'offset': 0,
      'next': null,
    };

    test('a detail response with no inline contents still loads the songs',
        () async {
      dio = buildDio({
        '/playlists/playlist_1/items': contentsPage(),
        '/playlists/playlist_1': detailWithoutContents(),
      });

      final playlist =
          await SpotifyPlaylistService(dio).playlistWithTracks('playlist_1');

      expect(playlist.items, isNotNull, reason: 'contents must be fetched');
      expect(playlist.playableTracks, hasLength(1));
      expect(
        playlist.trackCount,
        137,
        reason: "the contents page's total stands in for the missing count",
      );
      expect(
        adapter.requests.map((r) => r.path),
        contains('/playlists/playlist_1/items'),
      );
    });

    test('falls back to the legacy /tracks spelling when /items is refused',
        () async {
      // Which spelling answers depends on the app's quota mode, so both are
      // tried before the contents are called unavailable.
      adapter = _FakeAdapter((options) async {
        if (options.path.contains('/items')) {
          return ResponseBody.fromString(
            '{"error":{"status":404,"message":"not found"}}',
            404,
            headers: {
              Headers.contentTypeHeader: [Headers.jsonContentType],
            },
          );
        }
        final body = options.path.endsWith('/tracks')
            ? contentsPage()
            : detailWithoutContents();
        return ResponseBody.fromString(
          _encode(body),
          200,
          headers: {
            Headers.contentTypeHeader: [Headers.jsonContentType],
          },
        );
      });
      final client = Dio(
        BaseOptions(
          baseUrl: 'https://api.spotify.com/v1',
          validateStatus: (s) => s != null && s < 400,
        ),
      )..httpClientAdapter = adapter;

      final playlist =
          await SpotifyPlaylistService(client).playlistWithTracks('playlist_1');

      expect(playlist.items, isNotNull);
      expect(playlist.playableTracks, hasLength(1));
    });

    test('a refusal leaves contents null rather than looking empty', () async {
      // The distinction the UI depends on: null means "Spotify would not say",
      // an empty page means "this playlist really has nothing in it".
      //
      // Routed by hand rather than through `buildDio`, whose prefix matching
      // would serve the detail body to `/items` as well and turn a refusal into
      // an accidental empty page.
      adapter = _FakeAdapter((options) async {
        final refused = options.path.endsWith('/items') ||
            options.path.endsWith('/tracks');
        return ResponseBody.fromString(
          refused
              ? '{"error":{"status":403,"message":"forbidden"}}'
              : _encode(detailWithoutContents()),
          refused ? 403 : 200,
          headers: {
            Headers.contentTypeHeader: [Headers.jsonContentType],
          },
        );
      });
      final client = Dio(
        BaseOptions(
          baseUrl: 'https://api.spotify.com/v1',
          validateStatus: (s) => s != null && s < 400,
        ),
      )..httpClientAdapter = adapter;

      final playlist =
          await SpotifyPlaylistService(client).playlistWithTracks('playlist_1');

      expect(
        playlist.items,
        isNull,
        reason: 'a refused fetch must not be reported as an empty playlist',
      );
      // The playlist itself still loaded, which is why the screen keeps its
      // name, cover and follower count instead of showing an error.
      expect(playlist.name, 'Night Drive');
      expect(playlist.followers, 42150);
    });

    test('a genuinely empty playlist reports an empty page, not null', () async {
      dio = buildDio({
        '/playlists/playlist_1/items': <String, dynamic>{
          'items': <dynamic>[],
          'total': 0,
          'limit': 50,
          'offset': 0,
        },
        '/playlists/playlist_1': detailWithoutContents(),
      });

      final playlist =
          await SpotifyPlaylistService(dio).playlistWithTracks('playlist_1');

      expect(playlist.items, isNotNull);
      expect(playlist.items!.items, isEmpty);
    });

    test('a 403 on the saved check is unknown, never false', () async {
      dio = buildDio({'/me/library/contains': <String, dynamic>{}}, status: 403);

      final following = await SpotifyPlaylistService(dio).isFollowing('playlist_1');

      expect(
        following,
        isNull,
        reason: 'an unfilled heart is a claim the app cannot make on a 403',
      );
    });

    test('the refusal is remembered rather than re-asked', () async {
      dio = buildDio({'/me/library/contains': <String, dynamic>{}}, status: 403);
      final service = SpotifyPlaylistService(dio);

      await service.isFollowing('playlist_1');
      await service.isFollowing('playlist_1');

      expect(adapter.requests.length, 1);
    });

    test('a real saved answer still comes through', () async {
      dio = buildDio({'/me/library/contains': [true]});

      final following = await SpotifyPlaylistService(dio).isFollowing('playlist_1');

      expect(following, isTrue);
      expect(
        adapter.requests.single.queryParameters['uris'],
        'spotify:playlist:playlist_1',
        reason: 'the library endpoint is asked by URI, not by user id',
      );
    });

    test('an empty playlist id never reaches the network', () async {
      dio = buildDio({'/me/library/contains': [true]});

      expect(await SpotifyPlaylistService(dio).isFollowing(''), isNull);
      expect(adapter.requests, isEmpty);
    });
  });

  group('SpotifyPlayerService', () {
    test('a 204 means "nothing playing", not an error', () async {
      adapter = _FakeAdapter(
        (options) async => ResponseBody.fromString(
          '',
          204,
          headers: {
            Headers.contentTypeHeader: [Headers.jsonContentType],
          },
        ),
      );
      final client = Dio(
        BaseOptions(
          baseUrl: 'https://api.spotify.com/v1',
          validateStatus: (s) => s != null && s < 400,
        ),
      )..httpClientAdapter = adapter;

      final state = await SpotifyPlayerService(client).playbackState();
      expect(state.isIdle, isTrue);
      expect(state.isPlaying, isFalse);
    });

    test('play with a context sends context_uri and an offset', () async {
      dio = buildDio({'/me/player/play': <String, dynamic>{}});

      await SpotifyPlayerService(dio).play(
        contextUri: 'spotify:album:album_1',
        offsetPosition: 4,
        deviceId: 'device_1',
      );

      final request = adapter.requests.single;
      final body = request.data as Map<String, dynamic>;
      expect(body['context_uri'], 'spotify:album:album_1');
      expect((body['offset'] as Map)['position'], 4);
      expect(request.queryParameters['device_id'], 'device_1');
      expect(body.containsKey('uris'), isFalse);
    });

    test('play with track uris omits context_uri', () async {
      dio = buildDio({'/me/player/play': <String, dynamic>{}});

      await SpotifyPlayerService(dio).play(
        trackUris: const ['spotify:track:track_1'],
      );

      final body = adapter.requests.single.data as Map<String, dynamic>;
      expect(body['uris'], ['spotify:track:track_1']);
      expect(body.containsKey('context_uri'), isFalse);
    });

    test('checkAvailability reports ready when an active device exists', () async {
      dio = buildDio({
        '/me/player/devices': {
          'devices': [Fixtures.deviceJson],
        },
      });

      final availability = await SpotifyPlayerService(dio).checkAvailability();
      expect(availability.status, ConnectStatus.ready);
      expect(availability.canPlay, isTrue);
      expect(availability.blockerMessage, isNull);
    });

    test('checkAvailability reports noDevices for an empty list', () async {
      dio = buildDio({'/me/player/devices': {'devices': <dynamic>[]}});

      final availability = await SpotifyPlayerService(dio).checkAvailability();
      expect(availability.status, ConnectStatus.noDevices);
      expect(availability.canPlay, isFalse);
      expect(availability.blockerMessage, contains('Open Spotify'));
    });

    test('checkAvailability separates restricted-only from empty', () async {
      dio = buildDio({
        '/me/player/devices': {
          'devices': [Fixtures.restrictedDeviceJson],
        },
      });

      final availability = await SpotifyPlayerService(dio).checkAvailability();
      expect(availability.status, ConnectStatus.onlyRestrictedDevices);
      expect(availability.controllableDevices, isEmpty);
    });

    test('an idle controllable device reports deviceIdle', () async {
      dio = buildDio({
        '/me/player/devices': {
          'devices': [
            {...Fixtures.deviceJson, 'is_active': false},
          ],
        },
      });

      final availability = await SpotifyPlayerService(dio).checkAvailability();
      expect(availability.status, ConnectStatus.deviceIdle);
      expect(availability.canPlay, isTrue);
    });
  });

  group('SpotifyUserService', () {
    test('contains-checks stay aligned with the items sent', () async {
      dio = buildDio({'/me/library/contains': [true, false, true]});

      final result = await SpotifyUserService(dio).areTracksSaved(
        const ['a', 'b', 'c'],
      );

      expect(result, [true, false, true]);
    });

    test('library membership is asked for by URI, not by id', () async {
      // February 2026 replaced /me/{type}/contains with /me/library/contains,
      // which takes Spotify URIs. Sending bare IDs to it is a 400, and sending
      // URIs to the old path was a 404 — so the pairing matters, not just the
      // path.
      dio = buildDio({'/me/library/contains': [true, false]});

      await SpotifyUserService(dio).areTracksSaved(const ['t1', 't2']);

      final request = adapter.requests.single;
      expect(request.path, '/me/library/contains');
      expect(
        request.queryParameters['uris'],
        'spotify:track:t1,spotify:track:t2',
      );
      expect(request.queryParameters.containsKey('ids'), isFalse);
    });

    test('albums use the same endpoint with album URIs', () async {
      dio = buildDio({'/me/library/contains': [true]});

      await SpotifyUserService(dio).areAlbumsSaved(const ['al1']);

      expect(
        adapter.requests.single.queryParameters['uris'],
        'spotify:album:al1',
      );
    });

    test('batches at 40 URIs, not the old 50', () async {
      // /me/library/contains caps at 40. Chunking at the old size would 400 on
      // any library page bigger than that.
      dio = buildDio({'/me/library/contains': List.filled(40, true)});

      final ids = List.generate(45, (i) => 't$i');
      await SpotifyUserService(dio).areTracksSaved(ids);

      expect(adapter.requests.length, 2, reason: '45 URIs → 40 + 5');
      expect(
        adapter.requests.first.queryParameters['uris'].toString().split(',').length,
        40,
      );
      expect(
        adapter.requests.last.queryParameters['uris'].toString().split(',').length,
        5,
      );
    });

    test('a short contains response is discarded rather than misaligned', () async {
      // A truncated response would otherwise shift every heart by one row.
      dio = buildDio({'/me/library/contains': [true]});

      final result = await SpotifyUserService(dio).areTracksSaved(
        const ['a', 'b', 'c'],
      );

      expect(result, [false, false, false]);
    });

    test('an empty id list makes no request', () async {
      dio = buildDio({'/me/library/contains': <dynamic>[]});
      final result = await SpotifyUserService(dio).areTracksSaved(const []);

      expect(adapter.requests, isEmpty);
      expect(result, isEmpty);
    });

    test('recently-played returns empty rather than throwing on 204', () async {
      adapter = _FakeAdapter(
        (options) async => ResponseBody.fromString(
          '',
          204,
          headers: {
            Headers.contentTypeHeader: [Headers.jsonContentType],
          },
        ),
      );
      final client = Dio(
        BaseOptions(
          baseUrl: 'https://api.spotify.com/v1',
          validateStatus: (s) => s != null && s < 400,
        ),
      )..httpClientAdapter = adapter;

      final page = await SpotifyUserService(client).recentlyPlayed();
      expect(page.items, isEmpty);
    });
  });

  group('SpotifyApiService plumbing', () {
    test('empty query values are stripped before the request', () async {
      dio = buildDio({'/albums/': Fixtures.albumJson});
      SpotifyApiService.market = '';

      await SpotifyAlbumService(dio).album('album_1');

      // `?market=` would be a 400 from Spotify.
      expect(adapter.requests.single.queryParameters.containsKey('market'), isFalse);
    });

    test('tryGet swallows a 403 and returns null', () async {
      dio = buildDio(const {}, status: 403);
      final service = SpotifyAlbumService(dio);

      final result = await service.tryGet<Album>(
        '/recommendations',
        Album.fromJson,
      );
      expect(result, isNull);
    });

    test('tryGet rethrows a non-availability failure', () async {
      adapter = _FakeAdapter(
        (options) async => ResponseBody.fromString(
          '{"error":{"status":500,"message":"boom"}}',
          500,
          headers: {
            Headers.contentTypeHeader: [Headers.jsonContentType],
          },
        ),
      );
      final client = Dio(
        BaseOptions(
          baseUrl: 'https://api.spotify.com/v1',
          validateStatus: (s) => s != null && s < 400,
        ),
      )..httpClientAdapter = adapter;

      expect(
        () => SpotifyAlbumService(client).tryGet<Album>('/x', Album.fromJson),
        throwsA(
          isA<ApiException>().having(
            (e) => e.kind,
            'kind',
            ApiFailureKind.serverError,
          ),
        ),
      );
    });

    test('chunk splits evenly and handles the remainder', () {
      expect(SpotifyApiService.chunk(List.generate(10, (i) => i), 3).length, 4);
      expect(SpotifyApiService.chunk(<int>[], 5), isEmpty);
      expect(SpotifyApiService.chunk([1, 2], 5).single.length, 2);
    });

    test('setMarketFromCountry ignores anything that is not a 2-letter code', () {
      SpotifyApiService.market = 'from_token';
      SpotifyApiService.setMarketFromCountry('GBR');
      expect(SpotifyApiService.market, 'from_token');

      SpotifyApiService.setMarketFromCountry(null);
      expect(SpotifyApiService.market, 'from_token');

      SpotifyApiService.setMarketFromCountry('se');
      expect(SpotifyApiService.market, 'SE');
    });
  });
}

String _encode(Object value) => jsonEncode(value);
