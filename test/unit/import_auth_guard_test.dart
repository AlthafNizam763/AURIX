import 'package:aurix/data/import/imported_models.dart';
import 'package:aurix/data/import/music_import_provider.dart';
import 'package:aurix/data/import/playlist_fetcher.dart';
import 'package:aurix/data/import/playlist_import_service.dart';
import 'package:aurix/data/import/playlist_url.dart';
import 'package:aurix/data/models/models.dart';
import 'package:aurix/data/models/song.dart';
import 'package:aurix/data/repositories/catalog_repository.dart';
import 'package:aurix/data/repositories/library_repository.dart';
import 'package:aurix/data/services/api/api_session.dart';
import 'package:flutter_test/flutter_test.dart';

/// The link the tests import. A real Spotify playlist URL shape — the parser
/// validates the id, so a placeholder would fail for the wrong reason.
const String _spotifyUrl =
    'https://open.spotify.com/playlist/37i9dQZF1DX3lmpQSniUBH';

const String _youtubeUrl =
    'https://music.youtube.com/playlist?list=PLxA687tYuMWjHDeHtSAOFY4dxlgnKJHiP';

/// A library that records whether it was touched at all.
///
/// The assertion these tests care about most is not what the import returns —
/// it is that a signed-out import reaches **no** Firestore call. A fake that
/// merely returns null would pass a test written the obvious way while the app
/// still queried the database and still got a permission error.
class _RecordingLibrary implements LibraryRepository {
  int findCalls = 0;
  int createCalls = 0;

  /// Thrown from [findImportedPlaylist] when set, to stand in for what
  /// `ApiPlaylistService.findBySource` raises against undeployed rules.
  Exception? findThrows;

  /// The lookup carries no uid — the catalogue is shared, and asking "has
  /// anybody imported this?" is the whole point. A fake that still took one
  /// would not compile against the repository, which is the compile-time half
  /// of the guarantee.
  @override
  Future<Playlist?> findImportedPlaylist({
    required MediaSource source,
    required String sourceId,
  }) async {
    findCalls++;
    final failure = findThrows;
    if (failure != null) throw failure;
    return null;
  }

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
  }) async {
    createCalls++;
    return 'pl_${source.wireValue}_$sourceId';
  }

  @override
  Future<int> writePlaylistTracksInOrder({
    required String uid,
    required String playlistId,
    required List<Track> tracks,
  }) async => tracks.length;

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw UnimplementedError('${invocation.memberName} is not part of import');
}

/// A catalogue that accepts anything. The catalogue is not what is under test,
/// and the import already treats a catalogue failure as survivable.
class _SilentCatalog implements CatalogRepository {
  @override
  Future<int> publishAll(List<Song> songs) async => songs.length;

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw UnimplementedError('${invocation.memberName} is not part of import');
}

/// A fetcher that answers from memory, for whichever source it is built with.
class _FakeFetcher implements PlaylistFetcher {
  _FakeFetcher(this.source);

  @override
  final PlaylistSource source;

  int fetchCalls = 0;

  @override
  bool get isAvailable => true;

  @override
  String? get unavailableReason => null;

  @override
  Future<FetchedPlaylist> fetch(
    String playlistId, {
    void Function(FetchProgress progress)? onProgress,
  }) async {
    fetchCalls++;
    return FetchedPlaylist(
      playlist: ImportedPlaylist(
        id: playlistId,
        name: 'Night Drive',
        trackCount: 1,
      ),
      tracks: const <ImportedTrack>[
        ImportedTrack(id: 't1', title: 'One', artist: 'Neon Meridian'),
      ],
    );
  }
}

PlaylistImportService _service({
  required _RecordingLibrary library,
  required String? signedInUid,
  List<PlaylistFetcher>? fetchers,
}) => PlaylistImportService(
  library: library,
  catalog: _SilentCatalog(),
  fetchers: fetchers ??
      <PlaylistFetcher>[
        _FakeFetcher(PlaylistSource.spotify),
        _FakeFetcher(PlaylistSource.youtube),
      ],
  session: AurixSession(currentUid: () => signedInUid),
);

void main() {
  group('AurixSession', () {
    test('a signed-out session refuses with the caller\'s own sentence', () {
      const session = AurixSession(currentUid: _noOne);

      expect(
        () => session.requireOwner('uid_1', whenSignedOut: 'Sign in first.'),
        throwsA(
          isA<NotSignedIn>().having((e) => e.message, 'message', 'Sign in first.'),
        ),
      );
    });

    test('a session belonging to somebody else is refused, not accepted', () {
      const session = AurixSession(currentUid: _somebodyElse);

      // The distinction that matters: this is not "sign in", because the user
      // is signed in. Writing to uid_1's path as uid_2 is what the rules
      // refuse, and saying so beats letting Firestore say it.
      expect(
        () => session.requireOwner('uid_1', whenSignedOut: 'Sign in first.'),
        throwsA(
          isA<NotSignedIn>().having(
            (e) => e.message,
            'message',
            contains('session changed'),
          ),
        ),
      );
    });

    test('the owner passes and gets their uid back', () {
      const session = AurixSession(currentUid: _somebodyElse);
      expect(session.requireOwner('uid_2', whenSignedOut: 'x'), 'uid_2');
      expect(session.isSignedIn, isTrue);
    });
  });

  group('PlaylistImportService — the session guard', () {
    late _RecordingLibrary library;

    setUp(() => library = _RecordingLibrary());

    test('the shared-catalogue lookup still requires a signed-in account',
        () async {
      // Requirement 13, from the other side: the catalogue is shared between
      // signed-in users, not public. Removing the *ownership* check on the
      // discovery path does not remove the *authentication* check.
      const session = AurixSession(currentUid: _noOne);
      expect(
        () => session.requireSignedIn(whenSignedOut: 'Sign in first.'),
        throwsA(isA<NotSignedIn>()),
      );

      const signedIn = AurixSession(currentUid: _somebodyElse);
      // And any signed-in account passes — no uid comparison, because the
      // catalogue has no owner to compare against.
      expect(signedIn.requireSignedIn(whenSignedOut: 'x'), 'uid_2');
    });

    test('a signed-out import touches Firestore not once', () async {
      final service = _service(library: library, signedInUid: null);

      await expectLater(
        service.importFromUrl(uid: 'uid_1', url: _spotifyUrl),
        throwsA(
          isA<ImportFailure>()
              .having((e) => e.kind, 'kind', ImportFailureKind.authFailed)
              .having(
                (e) => e.message,
                'message',
                'Please sign in to import playlists.',
              ),
        ),
      );

      // The whole point of checking before the query rather than after it.
      expect(library.findCalls, 0);
      expect(library.createCalls, 0);
    });

    test('a uid that is not the signed-in account is refused', () async {
      final service = _service(library: library, signedInUid: 'uid_2');

      await expectLater(
        service.importFromUrl(uid: 'uid_1', url: _spotifyUrl),
        throwsA(
          isA<ImportFailure>()
              .having((e) => e.kind, 'kind', ImportFailureKind.authFailed)
              .having((e) => e.message, 'message', contains('session changed')),
        ),
      );

      expect(library.findCalls, 0);
    });

    test('the owner imports normally — Spotify', () async {
      final service = _service(library: library, signedInUid: 'uid_1');

      final outcome = await service.importFromUrl(
        uid: 'uid_1',
        url: _spotifyUrl,
      );

      expect(outcome.source, MediaSource.spotify);
      expect(outcome.songCount, 1);
      expect(outcome.wasResync, isFalse);
      expect(library.findCalls, 1);
      expect(library.createCalls, 1);
    });

    test('the owner imports normally — YouTube Music', () async {
      final service = _service(library: library, signedInUid: 'uid_1');

      final outcome = await service.importFromUrl(
        uid: 'uid_1',
        url: _youtubeUrl,
      );

      expect(outcome.source, MediaSource.youtube);
      expect(library.createCalls, 1);
    });

    test(
      'a refused Firestore read becomes a sentence, not a raw exception',
      () async {
        library.findThrows = const AurixAccessDenied(
          'AURIX could not read your playlists. If this is a new Firebase '
          'project, deploy the security rules: '
          'firebase deploy --only firestore:rules',
          code: 'permission-denied',
        );
        final service = _service(library: library, signedInUid: 'uid_1');

        await expectLater(
          service.importFromUrl(uid: 'uid_1', url: _spotifyUrl),
          throwsA(
            isA<ImportFailure>()
                // A deployment problem, not a sign-in problem — telling the
                // user to sign in again would send them somewhere useless.
                .having((e) => e.kind, 'kind', ImportFailureKind.storage)
                .having(
                  (e) => e.message,
                  'message',
                  contains('firebase deploy --only firestore:rules'),
                ),
          ),
        );

        // Refused before the network work, so no quota was spent finding out.
        expect(library.createCalls, 0);
      },
    );
  });
}

String? _noOne() => null;
String? _somebodyElse() => 'uid_2';
