@Tags(<String>['live'])
library;

import 'dart:io';

import 'package:aurix/core/network/aurix_api_client.dart';
import 'package:aurix/core/storage/preferences_store.dart';
import 'package:aurix/core/storage/secure_store.dart';
import 'package:aurix/core/theme/theme_config.dart';
import 'package:aurix/data/models/models.dart';
import 'package:aurix/data/models/song.dart';
import 'package:aurix/data/services/api/api_auth_service.dart';
import 'package:aurix/data/services/api/api_catalog_service.dart';
import 'package:aurix/data/services/api/api_global_playlist_service.dart';
import 'package:aurix/data/services/api/api_library_service.dart';
import 'package:aurix/data/services/api/api_playlist_service.dart';
import 'package:aurix/data/services/api/api_profile_service.dart';
import 'package:aurix/data/services/api/api_session.dart';
import 'package:aurix/data/services/api/api_theme_service.dart';
import 'package:aurix/data/services/api/aurix_session_store.dart';
import 'package:aurix/data/services/api/live_query.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// The Flutter client, against a real AURIX API.
///
/// ## What this exists to catch
///
/// Every other test in this repository mocks the network, and the server's own
/// suites assert what the server *sends*. Neither can catch the failure this
/// migration is most likely to produce: a response whose shape the Dart models
/// no longer parse. A renamed key, a `204` that became a `200`, a timestamp
/// that arrived as a number instead of an ISO-8601 string — each of those
/// passes a server test and a mocked client test, and fails on a real device.
///
/// So this drives the **production** service classes, through the production
/// [AurixApiClient], against a running server, and asserts on the *models* they
/// return rather than on JSON.
///
/// ## Running it
///
/// ```
///   cd web    && npm run build && npm start
///   cd mobile && flutter test test/live \
///                  --dart-define=AURIX_LIVE_API=http://127.0.0.1:3000
/// ```
///
/// Tagged `live` and excluded from the default run by `dart_test.yaml`, so a
/// machine with no server does not collect failures it cannot fix.
///
/// Every account and row it creates is namespaced and removed at the end.
void main() {
  const String baseUrl = String.fromEnvironment('AURIX_LIVE_API');

  if (baseUrl.isEmpty) {
    test('live API contract', () {}, skip: 'Set --dart-define=AURIX_LIVE_API to run.');
    return;
  }

  // The binding is needed for `SharedPreferences`, which speaks over a method
  // channel. It also installs an `HttpOverrides` that answers every request
  // with 400 and makes no connection — sensible for a widget test, fatal for
  // this one, which exists precisely to make real requests. Clearing it is the
  // documented escape hatch and is why this suite is opt-in rather than part of
  // the default run.
  TestWidgetsFlutterBinding.ensureInitialized();
  HttpOverrides.global = null;

  late AurixApiClient client;
  late AurixSessionStore session;
  late ApiAuthService auth;
  late ApiProfileService profiles;
  late ApiLibraryService library;
  late ApiPlaylistService playlists;
  late ApiCatalogService catalog;
  late ApiThemeService themes;

  final String stamp = DateTime.now().millisecondsSinceEpoch.toString();
  final String email = 'aurix-dart-$stamp@example.invalid';
  const String password = 'dart-contract-password-123';

  late AurixUser user;

  /// A track in the flat document shape the app stores and sends.
  Track trackNamed(String id, String title) => Track.fromDocument(id, <String, dynamic>{
    'title': title,
    'artist': 'The Weeknd',
    'album': 'After Hours',
    'durationMs': 200040,
    'artworkUrl': '',
    'explicit': false,
    'source': 'aurix',
  });

  setUpAll(() async {
    // Fail once, clearly, rather than producing twenty confusing failures.
    try {
      final HttpClientResponse probe = await HttpClient()
          .getUrl(Uri.parse('$baseUrl/health'))
          .then((HttpClientRequest r) => r.close());
      if (probe.statusCode != 200) {
        fail('The API answered /health with ${probe.statusCode}. Is the database up?');
      }
    } on SocketException {
      fail('No API reachable at $baseUrl. Start it with: cd web && npm start');
    }

    SharedPreferences.setMockInitialValues(<String, Object>{});

    session = AurixSessionStore(store: InMemorySecureStore());
    client = AurixApiClient(session: session, baseUrl: baseUrl);

    final LiveQueries live = LiveQueries(pollInterval: null);
    final AurixSession apiSession = AurixSession(store: session);

    auth = ApiAuthService(client: client, session: session);
    profiles = ApiProfileService(client: client, session: session, live: live);
    library = ApiLibraryService(client: client, live: live);
    catalog = ApiCatalogService(client: client, live: live);
    playlists = ApiPlaylistService(
      client: client,
      live: live,
      session: apiSession,
      catalog: ApiGlobalPlaylistService(
        client: client,
        live: live,
        session: apiSession,
      ),
    );
    themes = ApiThemeService(client: client, preferences: await PreferencesStore.open());
  });

  tearDownAll(() async {
    // Deleting the account removes everything it owns: liked tracks, history,
    // playlists, tokens and linked identities.
    //
    // It does **not** remove the catalogue song this file contributes, and that
    // is correct rather than an oversight. A song in `catalogSongs` is shared —
    // other accounts' playlists may reference it — so `DELETE /auth/me`
    // deliberately spares the two shared collections. There is no endpoint that
    // deletes one, by design, so this suite cannot clean it either.
    //
    // The row is harmless: a single song titled "Contract Test Song" with a
    // `dart_song_<timestamp>` id. Remove them with:
    //
    //   db.catalogSongs.deleteMany({ _id: /^dart_song_/ })
    try {
      await auth.deleteAccount(password);
    } catch (_) {
      // Already gone, or never created because an earlier expectation failed.
    }
  });

  // -------------------------------------------------------------------------

  group('identity', () {
    test('registers and returns a parsed AurixUser', () async {
      user = await auth.register(email: email, password: password, name: 'Dart Contract');

      expect(user.uid, isNotEmpty);
      expect(user.email, email);
      expect(user.name, 'Dart Contract');
      // The field that decides which buttons the login screen draws. A server
      // that stopped sending it would leave the account looking method-less.
      expect(
        user.linkedMethods.map((AuthMethod m) => m.id),
        contains('password'),
      );
      expect(user.isAdmin, isFalse);
    });

    test('stored a usable session', () async {
      expect(session.currentUser?.uid, user.uid);
      // Authenticated purely from what `register` persisted — proving the token
      // was both stored and accepted.
      expect((await auth.reload())?.uid, user.uid);
    });

    test('signs in, and reports a wrong password as invalidCredentials', () async {
      expect((await auth.signIn(email: email, password: password)).uid, user.uid);

      // `AuthFailure.kind` is a switch over the server's error codes. Rename one
      // and this degrades to a generic message on a real device — precisely the
      // regression a mocked test cannot see.
      await expectLater(
        auth.signIn(email: email, password: 'wrong-password'),
        throwsA(
          isA<AuthFailure>().having((AuthFailure f) => f.kind, 'kind', AuthFailureKind.invalidCredentials),
        ),
      );
    });

    test('reports a duplicate registration as emailInUse', () async {
      await expectLater(
        auth.register(email: email, password: password, name: 'Duplicate'),
        throwsA(
          isA<AuthFailure>().having((AuthFailure f) => f.kind, 'kind', AuthFailureKind.emailAlreadyInUse),
        ),
      );
    });
  });

  // -------------------------------------------------------------------------

  group('profile', () {
    test('reads the profile and its statistics', () async {
      expect((await profiles.read(user.uid))?.uid, user.uid);

      final ({int likedTracks, int playlists, int recentlyPlayed}) stats =
          await profiles.stats();
      expect(stats.likedTracks, isA<int>());
      expect(stats.playlists, isA<int>());
      expect(stats.recentlyPlayed, isA<int>());
    });

    test('sets an avatar', () async {
      await profiles.setAvatar(user.uid, 'avatar_04');
      expect((await profiles.read(user.uid))?.avatarId, 'avatar_04');
    });
  });

  // -------------------------------------------------------------------------

  group('library', () {
    late Track track;

    setUpAll(() {
      track = trackNamed('dart_contract_track_$stamp', 'Blinding Lights');
    });

    test('likes a track and reads it back as a Track', () async {
      await library.like(user.uid, track);
      await library.like(user.uid, track); // Idempotent, server-side.

      final List<Track> liked = await library.readLikedTracks(user.uid);
      final Iterable<Track> found =
          liked.where((Track t) => t.documentId == track.documentId);

      expect(found, hasLength(1), reason: 'liking twice must produce one row');
      // The round trip is the assertion: these survived `toDocument()` on the
      // way out and `fromDocument()` on the way back.
      expect(found.first.name, track.name);
      expect(found.first.durationMs, track.durationMs);
    });

    test('answers whether one track is liked', () async {
      expect(await library.isLiked(user.uid, track.documentId), isTrue);
      expect(await library.isLiked(user.uid, 'never_liked_this'), isFalse);
    });

    test('filters a set of ids down to the liked ones', () async {
      expect(
        await library.likedAmong(user.uid, <String>[track.documentId, 'not_liked']),
        <String>{track.documentId},
      );
    });

    test('records a play and reads the history back', () async {
      await library.recordPlay(user.uid, track, position: Duration.zero);

      final List<PlayHistoryEntry> history = await library.readRecentlyPlayed(user.uid);
      expect(
        history.map((PlayHistoryEntry e) => e.track.documentId),
        contains(track.documentId),
      );
      // `playedAt` crosses the wire as an ISO-8601 string. A server sending a
      // number would produce a null here and an empty "Recently played".
      expect(history.first.playedAt, isNotNull);
    });

    test('unlikes', () async {
      await library.unlike(user.uid, track);
      expect(await library.isLiked(user.uid, track.documentId), isFalse);
    });
  });

  // -------------------------------------------------------------------------

  group('playlists', () {
    late String playlistId;
    late List<Track> entries;

    setUpAll(() {
      entries = <Track>[
        for (final String suffix in <String>['a', 'b', 'c'])
          trackNamed('dart_pl_${stamp}_$suffix', 'Track ${suffix.toUpperCase()}'),
      ];
    });

    test('creates one and reads it back as a Playlist', () async {
      playlistId = await playlists.create(
        uid: user.uid,
        name: 'Dart Contract Playlist',
        description: 'created by the contract test',
      );
      expect(playlistId, isNotEmpty);

      final Playlist? playlist = await playlists.readPlaylist(user.uid, playlistId);
      expect(playlist?.name, 'Dart Contract Playlist');
      expect(playlist?.trackCount, 0);
    });

    test('writes tracks in order and reads that order back', () async {
      expect(
        await playlists.writeTracksInOrder(
          uid: user.uid,
          playlistId: playlistId,
          tracks: entries,
        ),
        3,
      );

      final List<Track> tracks = await playlists.readTracks(user.uid, playlistId);
      expect(
        tracks.map((Track t) => t.documentId).toList(),
        entries.map((Track t) => t.documentId).toList(),
      );
    });

    test('recomputed the track count', () async {
      expect((await playlists.readPlaylist(user.uid, playlistId))?.trackCount, 3);
    });

    test('reorders, and the moved track lands where it was dropped', () async {
      final List<Track> before = await playlists.readTracks(user.uid, playlistId);
      final List<String> ids = before.map((Track t) => t.documentId).toList();

      await playlists.reorder(
        uid: user.uid,
        playlistId: playlistId,
        ordered: before,
        from: 0,
        to: 2,
      );

      final List<Track> after = await playlists.readTracks(user.uid, playlistId);
      expect(after, hasLength(3));
      expect(after.last.documentId, ids.first);
    });

    test('removes tracks and reports how many went', () async {
      expect(
        await playlists.removeTracks(
          uid: user.uid,
          playlistId: playlistId,
          trackIds: <String>[entries.first.documentId],
        ),
        1,
      );
    });

    test('lists the account playlists', () async {
      final List<Playlist> all = await playlists.readPlaylists(user.uid);
      expect(all.map((Playlist p) => p.id), contains(playlistId));
    });

    test('deletes', () async {
      await playlists.delete(uid: user.uid, playlistId: playlistId);
      expect(await playlists.readPlaylist(user.uid, playlistId), isNull);
    });
  });

  // -------------------------------------------------------------------------

  group('catalogue', () {
    late Song sparse;

    setUpAll(() {
      sparse = Song.fromDocument('dart_song_$stamp', const <String, dynamic>{
        'title': 'Contract Test Song',
        'artists': <String>['The Weeknd'],
        'album': '',
        'duration': 0,
        'artworkUrl': '',
        'source': 'aurix',
      });
    });

    test('contributes a song and reads it back as a Song', () async {
      expect(await catalog.upsertAll(<Song>[sparse]), 1);

      final Song? stored = await catalog.song(sparse.id);
      expect(stored?.id, sparse.id);
      expect(stored?.title, sparse.title);
      expect(stored?.artists, sparse.artists);
    });

    test('enriches rather than overwriting on a second contribution', () async {
      // The write that matters. A server that *replaced* the row would look
      // identical here to one that merged — until a sparser import wiped a
      // field it should have kept, which is the next assertion.
      await catalog.upsertAll(<Song>[
        Song.fromDocument(sparse.id, <String, dynamic>{
          'title': sparse.title,
          'artists': sparse.artists,
          'album': 'After Hours',
          'duration': 200040,
          'artworkUrl': '',
          'source': 'aurix',
        }),
      ]);
      expect((await catalog.song(sparse.id))?.album, 'After Hours');

      // The sparser submission again. The album must survive it.
      await catalog.upsertAll(<Song>[sparse]);
      expect((await catalog.song(sparse.id))?.album, 'After Hours');
    });

    test('reads many songs by id', () async {
      final Map<String, Song> map =
          await catalog.songsByIds(<String>[sparse.id, 'absent_song']);
      expect(map.keys, contains(sparse.id));
      expect(map.keys, isNot(contains('absent_song')));
    });
  });

  // -------------------------------------------------------------------------

  group('appearance', () {
    test('fetches a ThemeConfig the app can render from', () async {
      final ThemeConfig? theme = await themes.fetch();
      expect(theme, isNotNull);
      // A partial config is the one piece of data that can make AURIX unusable
      // rather than merely incomplete, so every field the app paints with has
      // to arrive.
      expect(theme!.fontFamily, isNotEmpty);
    });

    test('reports a version, which is the cache key', () async {
      expect(await themes.version(), isA<int>());
    });

    test('lists the options the appearance editor offers', () async {
      expect((await themes.options()).fonts, isNotEmpty);
    });
  });

  // -------------------------------------------------------------------------

  group('authorisation', () {
    test('refuses an admin route to an ordinary account', () async {
      // No Dart service calls the admin API, so this goes through the client
      // directly. Worth asserting regardless: the app must not reach it either.
      await expectLater(
        client.get('/api/v1/admin/stats'),
        throwsA(
          isA<AurixApiException>().having((AurixApiException e) => e.code, 'code', 'admin_only'),
        ),
      );
    });
  });
}
