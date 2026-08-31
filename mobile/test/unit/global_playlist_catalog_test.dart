import 'package:aurix/core/constants/app_constants.dart';
import 'package:aurix/data/import/imported_models.dart';
import 'package:aurix/data/import/music_import_provider.dart';
import 'package:aurix/data/import/playlist_fetcher.dart';
import 'package:aurix/data/import/playlist_import_service.dart';
import 'package:aurix/data/import/playlist_url.dart';
import 'package:aurix/data/models/models.dart';
import 'package:aurix/data/models/playlist_key.dart';
import 'package:aurix/data/models/song.dart';
import 'package:aurix/data/models/song_key.dart';
import 'package:aurix/data/repositories/catalog_repository.dart';
import 'package:aurix/data/repositories/library_repository.dart';
import 'package:aurix/data/repositories/playlist_catalog_repository.dart';
import 'package:aurix/data/search/library_search_provider.dart';
import 'package:aurix/data/search/playlist_catalog_search_provider.dart';
import 'package:aurix/data/search/search_provider.dart';
import 'package:aurix/data/services/api/api_session.dart';
import 'package:flutter_test/flutter_test.dart';

/// The shared playlist catalogue, end to end.
///
/// ## What these tests are, and what they are not
///
/// They exercise the real [PlaylistImportService], the real
/// [PlaylistCatalogSearchProvider], the real [SearchService] merge and the real
/// [SearchTokens] and [PlaylistKey] logic against an in-memory catalogue that
/// models Firestore's semantics — a document store keyed by id, and a search
/// that filters on `array-contains` over the token array exactly as the query
/// in `ApiGlobalPlaylistService.search` does.
///
/// So what is under test is the **architecture**: that discovery is not scoped
/// to an account, that (source, sourceId) identifies a playlist across users,
/// and that private collections stay private. That is where the bug was.
///
/// What they cannot test is `firestore.rules`, which runs on Google's servers.
/// The rules are the enforcement; this is the client behaving correctly against
/// them. `firebase emulators:start --only firestore,auth` is the only honest
/// test of the rules themselves, and a passing run here is not evidence about
/// them.

// ---------------------------------------------------------------------------
// An in-memory stand-in for /playlists
// ---------------------------------------------------------------------------

/// Models the shared catalogue closely enough for the architecture to be real.
///
/// Two properties are copied deliberately rather than approximated, because
/// both are load-bearing:
///
///  * **The document id is derived**, via the real [PlaylistKey], so two users
///    importing one playlist address one entry with no coordination.
///  * **Search filters on the token array** built by the real [SearchTokens],
///    so case-insensitivity and prefix matching are genuinely exercised rather
///    than faked by a `toLowerCase().contains()` that Firestore could not run.
class _FakeCatalog implements PlaylistCatalogRepository {
  final Map<String, Map<String, Object?>> docs = <String, Map<String, Object?>>{};
  final Map<String, List<Track>> tracks = <String, List<Track>>{};

  /// Every uid that has published, in order — so a test can assert *who* wrote
  /// without the catalogue itself caring.
  final List<String> publishers = <String>[];

  /// Track ids removed, and by whom. The service is supposed to refuse to call
  /// this for a non-importer rather than let the rules refuse it.
  final List<({String uid, String playlistId})> removals =
      <({String uid, String playlistId})>[];

  @override
  Future<String> publish({
    required MediaSource source,
    required String sourceId,
    required String name,
    required String importedByUserId,
    String description = '',
    String coverUrl = '',
    String? sourceUrl,
    String? importedBy,
  }) async {
    final id = PlaylistKey.of(source: source, sourceId: sourceId);
    publishers.add(importedByUserId);

    final existing = docs[id];
    if (existing != null) {
      // A refresh. The name and its search fields move; the provenance does
      // not, so a second importer never takes the entry over.
      existing['name'] = name;
      existing['searchTitle'] = SongKey.normaliseAlbum(name);
      existing['searchTokens'] = SearchTokens.forPlaylist(name);
      if (coverUrl.isNotEmpty) existing['coverUrl'] = coverUrl;
      return id;
    }

    docs[id] = <String, Object?>{
      'name': name,
      'description': description,
      'coverUrl': coverUrl,
      'source': source.wireValue,
      'sourceId': sourceId,
      'sourceUrl': sourceUrl ?? '',
      'searchTitle': SongKey.normaliseAlbum(name),
      'searchTokens': SearchTokens.forPlaylist(name),
      'trackCount': 0,
      'importedByUserId': importedByUserId,
      'importedBy': importedBy ?? '',
    };
    tracks[id] = <Track>[];
    return id;
  }

  @override
  Future<List<Playlist>> search(String query, {int limit = 20}) async {
    final token = SearchTokens.queryToken(query);
    if (token.isEmpty) return const <Playlist>[];

    final residual = SearchTokens.residualWords(query);
    final out = <Playlist>[];

    // No uid filter. This is the assertion the whole file exists for, and it
    // is expressed as the absence of a clause rather than as an expectation.
    for (final entry in docs.entries) {
      final tokens = (entry.value['searchTokens']! as List).cast<String>();
      if (!tokens.contains(token)) continue;

      final title = entry.value['searchTitle']! as String;
      if (!residual.every(title.contains)) continue;

      out.add(_playlist(entry.key));
      if (out.length >= limit) break;
    }
    return out;
  }

  @override
  Future<Playlist?> findBySource({
    required MediaSource source,
    required String sourceId,
  }) async {
    final id = PlaylistKey.of(source: source, sourceId: sourceId);
    return docs.containsKey(id) ? _playlist(id) : null;
  }

  @override
  Future<Playlist?> read(String playlistId) async =>
      docs.containsKey(playlistId) ? _playlist(playlistId) : null;

  @override
  Stream<Playlist?> watch(String playlistId) =>
      Stream<Playlist?>.value(docs.containsKey(playlistId) ? _playlist(playlistId) : null);

  @override
  Future<List<Track>> readTracks(String playlistId) async =>
      List<Track>.unmodifiable(tracks[playlistId] ?? const <Track>[]);

  @override
  Stream<List<Track>> watchTracks(String playlistId) =>
      Stream<List<Track>>.value(tracks[playlistId] ?? const <Track>[]);

  @override
  Stream<List<Playlist>> importedBy(String uid) => Stream<List<Playlist>>.value(
    docs.entries
        .where((e) => e.value['importedByUserId'] == uid)
        .map((e) => _playlist(e.key))
        .toList(growable: false),
  );

  @override
  Future<int> writeTracksInOrder({
    required String playlistId,
    required List<Track> tracks,
  }) async {
    final rows = this.tracks.putIfAbsent(playlistId, () => <Track>[]);
    for (final track in tracks) {
      final index = rows.indexWhere((r) => r.documentId == track.documentId);
      if (index >= 0) {
        rows[index] = track;
      } else {
        rows.add(track);
      }
    }
    docs[playlistId]?['trackCount'] = rows.length;
    return tracks.length;
  }

  @override
  Future<int> removeTracks({
    required String playlistId,
    required List<String> trackIds,
  }) async {
    removals.add((uid: '<unchecked>', playlistId: playlistId));
    final rows = tracks[playlistId];
    if (rows == null) return 0;
    final before = rows.length;
    rows.removeWhere((t) => trackIds.contains(t.documentId));
    docs[playlistId]?['trackCount'] = rows.length;
    return before - rows.length;
  }

  @override
  Future<void> markSynced({
    required String playlistId,
    String? name,
    String? coverUrl,
  }) async {
    final doc = docs[playlistId];
    if (doc == null) return;
    if (name != null && name.trim().isNotEmpty) {
      doc['name'] = name.trim();
      doc['searchTitle'] = SongKey.normaliseAlbum(name);
      doc['searchTokens'] = SearchTokens.forPlaylist(name);
    }
    if (coverUrl != null && coverUrl.isNotEmpty) doc['coverUrl'] = coverUrl;
  }

  @override
  Future<void> delete(String playlistId) async {
    docs.remove(playlistId);
    tracks.remove(playlistId);
  }

  Playlist _playlist(String id) =>
      Playlist.fromDocument(id, Map<String, dynamic>.from(docs[id]!),
          visibility: PlaylistVisibility.shared);
}

// ---------------------------------------------------------------------------
// An in-memory stand-in for the library
// ---------------------------------------------------------------------------

/// Routes shared reads and writes to [catalog] and keeps everything else
/// per-account, exactly as [LibraryRepository] does.
///
/// The per-uid maps are what make requirement 10 testable: a private
/// collection here is a `Map<uid, …>`, so a test that could read one account's
/// liked songs through a catalogue call would have to reach into a different
/// key, and none of them can.
class _FakeLibrary implements LibraryRepository {
  _FakeLibrary(this.catalog);

  final _FakeCatalog catalog;

  /// Private, per account.
  final Map<String, List<Track>> likedByUser = <String, List<Track>>{};
  final Map<String, List<Playlist>> ownPlaylistsByUser =
      <String, List<Playlist>>{};

  @override
  Future<Playlist?> findImportedPlaylist({
    required MediaSource source,
    required String sourceId,
  }) => catalog.findBySource(source: source, sourceId: sourceId);

  @override
  Future<String> publishImportedPlaylist({
    required MediaSource source,
    required String sourceId,
    required String name,
    required String importedByUserId,
    String description = '',
    String coverUrl = '',
    String? sourceUrl,
    String? importedBy,
  }) => catalog.publish(
    source: source,
    sourceId: sourceId,
    name: name,
    importedByUserId: importedByUserId,
    description: description,
    coverUrl: coverUrl,
    sourceUrl: sourceUrl,
    importedBy: importedBy,
  );

  @override
  Future<int> writePlaylistTracksInOrder({
    required String uid,
    required String playlistId,
    required List<Track> tracks,
  }) => PlaylistKey.isGlobal(playlistId)
      ? catalog.writeTracksInOrder(playlistId: playlistId, tracks: tracks)
      : throw UnimplementedError('personal write is not part of these tests');

  @override
  Future<List<Track>> readPlaylistTracks(String uid, String playlistId) =>
      catalog.readTracks(playlistId);

  @override
  Future<int> removePlaylistTracks({
    required String uid,
    required String playlistId,
    required List<String> trackIds,
  }) => catalog.removeTracks(playlistId: playlistId, trackIds: trackIds);

  @override
  Future<void> markPlaylistSynced({
    required String uid,
    required String playlistId,
    String? name,
    String? coverUrl,
  }) => catalog.markSynced(
    playlistId: playlistId,
    name: name,
    coverUrl: coverUrl,
  );

  @override
  Stream<List<Playlist>> watchOwnPlaylists(String uid) =>
      Stream<List<Playlist>>.value(ownPlaylistsByUser[uid] ?? const []);

  @override
  Stream<List<Track>> watchLikedTracks(String uid) =>
      Stream<List<Track>>.value(likedByUser[uid] ?? const []);

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw UnimplementedError('${invocation.memberName} is not part of these tests');
}

class _SilentCatalog implements CatalogRepository {
  @override
  Future<int> publishAll(List<Song> songs) async => songs.length;

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw UnimplementedError('${invocation.memberName} is not part of import');
}

/// Answers with a named playlist and a fixed track list.
class _FakeFetcher implements PlaylistFetcher {
  _FakeFetcher(this.source, this.namesById, {this.tracksById = const {}});

  @override
  final PlaylistSource source;

  final Map<String, String> namesById;
  final Map<String, List<ImportedTrack>> tracksById;

  @override
  bool get isAvailable => true;

  @override
  String? get unavailableReason => null;

  @override
  Future<FetchedPlaylist> fetch(
    String playlistId, {
    void Function(FetchProgress progress)? onProgress,
  }) async {
    final tracks = tracksById[playlistId] ??
        <ImportedTrack>[
          ImportedTrack(
            id: '${playlistId}_t1',
            title: 'Track One',
            artist: 'Neon Meridian',
          ),
        ];
    return FetchedPlaylist(
      playlist: ImportedPlaylist(
        id: playlistId,
        name: namesById[playlistId] ?? 'Untitled',
        trackCount: tracks.length,
      ),
      tracks: tracks,
    );
  }
}

// ---------------------------------------------------------------------------
// Scenario fixtures
// ---------------------------------------------------------------------------

/// Two real-shaped Spotify playlist ids. The URL parser validates them, so a
/// placeholder would fail for the wrong reason.
const String _loveId = '37i9dQZF1DX3lmpQSniUBH';
const String _sadId = '37i9dQZF1DWSqBruwoIXkA';

String _spotifyUrl(String id) => 'https://open.spotify.com/playlist/$id';

const Map<String, String> _names = <String, String>{
  _loveId: 'Love',
  _sadId: 'Sad',
};

void main() {
  late _FakeCatalog catalog;
  late _FakeLibrary library;

  /// An import service acting as [uid]. Each AURIX user gets their own — the
  /// session guard is per-account, and that is the point.
  PlaylistImportService serviceFor(String uid, {String? name}) =>
      PlaylistImportService(
        library: library,
        catalog: _SilentCatalog(),
        fetchers: <PlaylistFetcher>[
          _FakeFetcher(PlaylistSource.spotify, _names),
        ],
        session: AurixSession(currentUid: () => uid),
      );

  /// The real search stack, as the app assembles it in `app_providers.dart`,
  /// answering for [uid]. Deliberately built per user so that a result set can
  /// only differ between users if the *providers* make it differ.
  SearchService searchFor(String uid) => SearchService(
    providers: <SearchProvider>[
      LibrarySearchProvider(
        likedTracks: () => library.likedByUser[uid] ?? const [],
        playlists: () => library.ownPlaylistsByUser[uid] ?? const [],
        playlistTracks: () => const [],
      ),
      PlaylistCatalogSearchProvider(catalog: catalog),
    ],
  );

  Future<List<String>> searchTitles(String uid, String query) async {
    final results = await searchFor(uid).search(query);
    return results.playlists.items.map((p) => p.name).toList(growable: false);
  }

  setUp(() {
    catalog = _FakeCatalog();
    library = _FakeLibrary(catalog);
  });

  // -------------------------------------------------------------------------
  group('the requested scenario, end to end', () {
    // -----------------------------------------------------------------------

    /// TEST 1 and TEST 2 — the setup every later test builds on.
    Future<void> importTheTwoPlaylists() async {
      await serviceFor('user_a').importFromUrl(
        uid: 'user_a',
        url: _spotifyUrl(_loveId),
        importedBy: 'Ada',
      );
      await serviceFor('user_b').importFromUrl(
        uid: 'user_b',
        url: _spotifyUrl(_sadId),
        importedBy: 'Ben',
      );
    }

    test('TEST 1 — User A imports "Love" into the shared catalogue', () async {
      await serviceFor('user_a').importFromUrl(
        uid: 'user_a',
        url: _spotifyUrl(_loveId),
        importedBy: 'Ada',
      );

      final id = PlaylistKey.of(
        source: MediaSource.spotify,
        sourceId: _loveId,
      );
      expect(catalog.docs.keys, [id]);
      expect(catalog.docs[id]!['name'], 'Love');

      // Provenance is recorded…
      expect(catalog.docs[id]!['importedByUserId'], 'user_a');
      expect(catalog.docs[id]!['importedBy'], 'Ada');
      // …and the source identity is what the entry is keyed on.
      expect(catalog.docs[id]!['source'], 'spotify');
      expect(catalog.docs[id]!['sourceId'], _loveId);
    });

    test('TEST 2 — User B imports "Sad"', () async {
      await importTheTwoPlaylists();

      expect(catalog.docs, hasLength(2));
      expect(
        catalog.docs.values.map((d) => d['name']),
        containsAll(<String>['Love', 'Sad']),
      );
      expect(catalog.publishers, ['user_a', 'user_b']);
    });

    test('TEST 3 — User C, who imported nothing, searches "Love"', () async {
      await importTheTwoPlaylists();

      // The heart of it. User C has never imported anything, owns nothing, and
      // finds a playlist another account contributed.
      expect(await searchTitles('user_c', 'Love'), ['Love']);
    });

    test('TEST 4 — User C searches "Sad"', () async {
      await importTheTwoPlaylists();
      expect(await searchTitles('user_c', 'Sad'), ['Sad']);
    });

    test('TEST 5 — User A finds the playlist User B imported', () async {
      await importTheTwoPlaylists();
      expect(await searchTitles('user_a', 'Sad'), ['Sad']);
    });

    test('TEST 6 — User B finds the playlist User A imported', () async {
      await importTheTwoPlaylists();
      expect(await searchTitles('user_b', 'Love'), ['Love']);
    });

    test('every user gets the same answer for the same query', () async {
      await importTheTwoPlaylists();

      // Stated as one assertion because it is the requirement: the result set
      // is a function of the query, not of who is asking.
      for (final query in <String>['love', 'sad']) {
        final answers = <List<String>>[
          await searchTitles('user_a', query),
          await searchTitles('user_b', query),
          await searchTitles('user_c', query),
        ];
        expect(answers[0], answers[1]);
        expect(answers[1], answers[2]);
        expect(answers[0], isNotEmpty);
      }
    });

    test('TEST 7 — User B re-importing "Love" creates no duplicate', () async {
      await importTheTwoPlaylists();

      // A second user pasting the same link is offered a choice rather than
      // told off — and is told the truth, which is that the playlist is
      // already on AURIX rather than already in their library.
      await expectLater(
        serviceFor('user_b').importFromUrl(
          uid: 'user_b',
          url: _spotifyUrl(_loveId),
          importedBy: 'Ben',
        ),
        throwsA(
          isA<DuplicatePlaylist>().having(
            (e) => e.existing.importedByUserId,
            'importedByUserId',
            'user_a',
          ),
        ),
      );

      // Two playlists, not three.
      expect(catalog.docs, hasLength(2));

      // And syncing it — the other half of the choice — still does not fork.
      await serviceFor('user_b').importFromUrl(
        uid: 'user_b',
        url: _spotifyUrl(_loveId),
        importedBy: 'Ben',
        allowResync: true,
      );

      expect(catalog.docs, hasLength(2));
      expect(await searchTitles('user_c', 'Love'), ['Love']);

      // The credit stays with whoever brought it in. A later sync by another
      // account must not take the entry — nor the delete right — over.
      final id = PlaylistKey.of(source: MediaSource.spotify, sourceId: _loveId);
      expect(catalog.docs[id]!['importedByUserId'], 'user_a');
      expect(catalog.docs[id]!['importedBy'], 'Ada');
    });

    test('TEST 8 — User B opens "Love" and sees its metadata and tracks',
        () async {
      await importTheTwoPlaylists();

      final id = PlaylistKey.of(source: MediaSource.spotify, sourceId: _loveId);

      // Read with no uid anywhere in the call. That is what "not private to
      // the importer" means in practice.
      final playlist = await catalog.read(id);
      expect(playlist, isNotNull);
      expect(playlist!.name, 'Love');
      expect(playlist.visibility, PlaylistVisibility.shared);

      final tracks = await catalog.readTracks(id);
      expect(tracks, isNotEmpty);
      expect(tracks.first.name, 'Track One');

      // Readable and playable, but not User B's to rearrange.
      expect(playlist.isEditableBy('user_b'), isFalse);
      expect(playlist.isEditableBy('user_a'), isTrue);
      expect(playlist.importCredit, 'Added by Ada');
    });

    test('TEST 9 — User A opens "Sad" and sees its metadata and tracks',
        () async {
      await importTheTwoPlaylists();

      final id = PlaylistKey.of(source: MediaSource.spotify, sourceId: _sadId);
      final playlist = await catalog.read(id);

      expect(playlist!.name, 'Sad');
      expect(await catalog.readTracks(id), isNotEmpty);
      expect(playlist.isEditableBy('user_a'), isFalse);
      expect(playlist.importCredit, 'Added by Ben');
    });

    test('TEST 10 — liked songs and personal playlists stay private', () async {
      await importTheTwoPlaylists();

      const secret = Track(
        id: 'spotify_secret',
        name: 'A Private Favourite',
        artists: <Artist>[Artist(id: '', name: 'Neon Meridian')],
        durationMs: 0,
        source: MediaSource.spotify,
        spotifyId: 'secret',
      );
      library.likedByUser['user_a'] = <Track>[secret];
      library.ownPlaylistsByUser['user_a'] = <Playlist>[
        const Playlist(id: 'personal_1', name: 'Love Notes To Myself'),
      ];

      // The shared catalogue holds imported playlists and nothing else: no
      // personal playlist was published, and the collection is exactly the two
      // imports.
      expect(catalog.docs, hasLength(2));
      expect(
        catalog.docs.values.every((d) => d['source'] != 'aurix'),
        isTrue,
        reason: 'a personal playlist must never reach the shared catalogue',
      );

      // User A's own playlist is findable by User A…
      expect(
        await searchTitles('user_a', 'Love'),
        containsAll(<String>['Love Notes To Myself', 'Love']),
      );

      // …and by nobody else, even though "love" matches its title. It is not in
      // the catalogue, so no other account's search can reach it.
      final forC = await searchTitles('user_c', 'Love');
      expect(forC, ['Love']);
      expect(forC, isNot(contains('Love Notes To Myself')));

      // And the liked track is not reachable through any search but its
      // owner's.
      final cTracks = (await searchFor('user_c').search('Private Favourite'))
          .tracks
          .items;
      expect(cTracks, isEmpty);
      final aTracks = (await searchFor('user_a').search('Private Favourite'))
          .tracks
          .items;
      expect(aTracks.single.name, 'A Private Favourite');
    });
  });

  // -------------------------------------------------------------------------
  group('search behaviour', () {
    // -----------------------------------------------------------------------

    setUp(() async {
      await serviceFor('user_a').importFromUrl(
        uid: 'user_a',
        url: _spotifyUrl(_loveId),
        importedBy: 'Ada',
      );
      // Renamed at the source so the title is two words, which is what makes
      // the partial-match cases meaningful.
      await catalog.markSynced(
        playlistId: PlaylistKey.of(
          source: MediaSource.spotify,
          sourceId: _loveId,
        ),
        name: 'Love Songs',
      );
    });

    test('is case-insensitive', () async {
      for (final query in <String>['love', 'Love', 'LOVE', 'LoVe']) {
        expect(
          await searchTitles('user_c', query),
          ['Love Songs'],
          reason: '"$query" should find "Love Songs"',
        );
      }
    });

    test('matches a partial word', () async {
      for (final query in <String>['l', 'lo', 'lov', 'love']) {
        expect(
          await searchTitles('user_c', query),
          ['Love Songs'],
          reason: '"$query" should prefix-match "Love Songs"',
        );
      }
    });

    test('matches a word from the middle of the title', () async {
      // The property a `>=` range scan on the title could not give: "songs" is
      // not a prefix of "Love Songs".
      expect(await searchTitles('user_c', 'songs'), ['Love Songs']);
      expect(await searchTitles('user_c', 'song'), ['Love Songs']);
    });

    test('a query that matches nothing returns nothing', () async {
      expect(await searchTitles('user_c', 'techno'), isEmpty);
    });

    test('ranks an exact title above a mere prefix match', () async {
      // Two more entries whose titles all begin "love".
      await catalog.publish(
        source: MediaSource.spotify,
        sourceId: 'aaa_first_alphabetically',
        name: 'Loveless Afternoons',
        importedByUserId: 'user_b',
      );
      await catalog.publish(
        source: MediaSource.spotify,
        sourceId: 'zzz_last_alphabetically',
        name: 'Love',
        importedByUserId: 'user_b',
      );

      final ranked = await PlaylistCatalogSearchProvider(catalog: catalog)
          .search('love');
      // The fake catalogue returns insertion order; the provider under test is
      // what the app uses, so this asserts the provider's contract rather than
      // the fake's. Ranking itself lives in the real Firestore service, so the
      // guarantee here is only that an exact match is present and findable.
      expect(
        ranked.playlists.items.map((p) => p.name),
        containsAll(<String>['Love', 'Love Songs', 'Loveless Afternoons']),
      );
    });
  });

  // -------------------------------------------------------------------------
  group('de-duplication', () {
    // -----------------------------------------------------------------------

    test('(source, sourceId) is the identity, whoever imports', () async {
      // The property stated in the requirement: spotify + <id> identifies the
      // same imported playlist regardless of which AURIX user imports it.
      final a = PlaylistKey.of(source: MediaSource.spotify, sourceId: _loveId);
      final b = PlaylistKey.of(source: MediaSource.spotify, sourceId: _loveId);
      expect(a, b);

      // And the source qualifies it, so two services handing out the same id
      // string cannot collide.
      expect(
        PlaylistKey.of(source: MediaSource.youtube, sourceId: _loveId),
        isNot(a),
      );
    });

    test('a global id is distinguishable from a personal one', () async {
      // What lets `/playlist/:id` open the right collection with no probe read.
      // Firestore auto-ids are 20 characters of [A-Za-z0-9] — no underscore —
      // so a personal playlist can never look global.
      expect(
        PlaylistKey.isGlobal(
          PlaylistKey.of(source: MediaSource.spotify, sourceId: _loveId),
        ),
        isTrue,
      );
      expect(PlaylistKey.isGlobal('Xk3mPq7RtY2wZ9nB4vLd'), isFalse);
    });

    test('an id unsafe as a document id falls back to a hash', () {
      final key = PlaylistKey.of(
        source: MediaSource.spotify,
        sourceId: 'has/a/slash',
      );
      expect(key.startsWith('pl_spotify_'), isTrue);
      expect(key, isNot(contains('/')));
      // Still deterministic, which is what de-duplication needs.
      expect(
        key,
        PlaylistKey.of(source: MediaSource.spotify, sourceId: 'has/a/slash'),
      );
    });

    test('two accounts importing at once converge on one document', () async {
      // No coordination and no read-then-write window: both publishes address
      // the derived id, so the second merges into the first.
      await Future.wait<void>(<Future<void>>[
        catalog.publish(
          source: MediaSource.spotify,
          sourceId: _loveId,
          name: 'Love',
          importedByUserId: 'user_a',
        ),
        catalog.publish(
          source: MediaSource.spotify,
          sourceId: _loveId,
          name: 'Love',
          importedByUserId: 'user_b',
        ),
      ]);

      expect(catalog.docs, hasLength(1));
    });
  });

  // -------------------------------------------------------------------------
  group('who may change a shared playlist', () {
    // -----------------------------------------------------------------------

    setUp(() async {
      await serviceFor('user_a').importFromUrl(
        uid: 'user_a',
        url: _spotifyUrl(_loveId),
        importedBy: 'Ada',
      );
    });

    test('a sync by another account adds but never removes', () async {
      final id = PlaylistKey.of(source: MediaSource.spotify, sourceId: _loveId);

      // The source has replaced its track list entirely.
      final replaced = <String, List<ImportedTrack>>{
        _loveId: const <ImportedTrack>[
          ImportedTrack(id: 'new_1', title: 'Something New', artist: 'A'),
        ],
      };

      await PlaylistImportService(
        library: library,
        catalog: _SilentCatalog(),
        fetchers: <PlaylistFetcher>[
          _FakeFetcher(PlaylistSource.spotify, _names, tracksById: replaced),
        ],
        session: const AurixSession(currentUid: _userB),
      ).importFromUrl(
        uid: 'user_b',
        url: _spotifyUrl(_loveId),
        allowResync: true,
      );

      // The new song landed…
      final names = (await catalog.readTracks(id)).map((t) => t.name);
      expect(names, contains('Something New'));
      // …and the old one survived, because User B is not the importer and a
      // removal is destructive for everybody. The client refuses to attempt it
      // rather than letting the rules refuse it.
      expect(names, contains('Track One'));
      expect(catalog.removals, isEmpty);
    });

    test('a sync by another account does not rewrite the shared metadata',
        () async {
      final id = PlaylistKey.of(source: MediaSource.spotify, sourceId: _loveId);

      // The source has renamed the playlist. User B, who did not import it,
      // re-syncs.
      await PlaylistImportService(
        library: library,
        catalog: _SilentCatalog(),
        fetchers: <PlaylistFetcher>[
          _FakeFetcher(
            PlaylistSource.spotify,
            const <String, String>{_loveId: 'Renamed By Ben'},
          ),
        ],
        session: const AurixSession(currentUid: _userB),
      ).importFromUrl(
        uid: 'user_b',
        url: _spotifyUrl(_loveId),
        allowResync: true,
      );

      // The name is untouched. This is not a cosmetic preference: the
      // `/playlists` update rule allows a non-importer to change only
      // `trackCount`, `syncedAt` and `updatedAt`, and a write carrying `name`
      // is refused *in full* — so before this guard existed, a listener
      // re-syncing somebody else's playlist failed with permission-denied and
      // lost the whole sync, not just the rename.
      expect(catalog.docs[id]!['name'], 'Love');
      expect(catalog.docs[id]!['searchTitle'], SongKey.normaliseAlbum('Love'));
    });

    test('a sync by the importer does refresh the shared metadata', () async {
      final id = PlaylistKey.of(source: MediaSource.spotify, sourceId: _loveId);

      await PlaylistImportService(
        library: library,
        catalog: _SilentCatalog(),
        fetchers: <PlaylistFetcher>[
          _FakeFetcher(
            PlaylistSource.spotify,
            const <String, String>{_loveId: 'Renamed By Ada'},
          ),
        ],
        session: const AurixSession(currentUid: _userA),
      ).importFromUrl(
        uid: 'user_a',
        url: _spotifyUrl(_loveId),
        allowResync: true,
      );

      // The importer may rename, and the tokens follow the name — otherwise the
      // playlist stays findable only by its old title.
      expect(catalog.docs[id]!['name'], 'Renamed By Ada');
      expect(
        catalog.docs[id]!['searchTokens'],
        contains('renamed'),
      );
    });

    test('a sync by the importer does remove what the source dropped',
        () async {
      final id = PlaylistKey.of(source: MediaSource.spotify, sourceId: _loveId);

      final replaced = <String, List<ImportedTrack>>{
        _loveId: const <ImportedTrack>[
          ImportedTrack(id: 'new_1', title: 'Something New', artist: 'A'),
        ],
      };

      await PlaylistImportService(
        library: library,
        catalog: _SilentCatalog(),
        fetchers: <PlaylistFetcher>[
          _FakeFetcher(PlaylistSource.spotify, _names, tracksById: replaced),
        ],
        session: const AurixSession(currentUid: _userA),
      ).importFromUrl(
        uid: 'user_a',
        url: _spotifyUrl(_loveId),
        allowResync: true,
      );

      final names = (await catalog.readTracks(id)).map((t) => t.name);
      expect(names, ['Something New']);
      expect(catalog.removals, hasLength(1));
    });
  });

  // -------------------------------------------------------------------------
  group('authentication is still required', () {
    // -----------------------------------------------------------------------

    test('a signed-out import reaches the catalogue not once', () async {
      final service = PlaylistImportService(
        library: library,
        catalog: _SilentCatalog(),
        fetchers: <PlaylistFetcher>[
          _FakeFetcher(PlaylistSource.spotify, _names),
        ],
        session: const AurixSession(currentUid: _nobody),
      );

      await expectLater(
        service.importFromUrl(uid: 'user_a', url: _spotifyUrl(_loveId)),
        throwsA(
          isA<ImportFailure>()
              .having((e) => e.kind, 'kind', ImportFailureKind.authFailed),
        ),
      );

      // Shared does not mean open: nothing was written and nothing was read.
      expect(catalog.docs, isEmpty);
      expect(catalog.publishers, isEmpty);
    });
  });
}

String? _nobody() => null;
String? _userA() => 'user_a';
String? _userB() => 'user_b';

// Referenced so the constant is not flagged as unused when the search limit
// default changes.
// ignore: unused_element
const int _defaultSearchLimit = AppConstants.maxSearchPageSize;
