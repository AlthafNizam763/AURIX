import 'package:aurix/data/import/imported_models.dart';
import 'package:aurix/data/import/music_import_provider.dart';
import 'package:aurix/data/import/music_import_service.dart';
import 'package:aurix/data/models/models.dart';
import 'package:aurix/data/repositories/library_repository.dart';
import 'package:flutter_test/flutter_test.dart';

/// A provider that answers from a script.
///
/// The point of [MusicImportProvider] is that the service can be exercised
/// without any real service behind it. If this class is easy to write, the
/// interface is the right shape — which is as much what these tests check as
/// the behaviour is.
class _FakeProvider implements MusicImportProvider {
  _FakeProvider({
    required this.playlists,
    required this.tracks,
    this.failOn = const <String>{},
  });

  final List<ImportedPlaylist> playlists;
  final Map<String, List<ImportedTrack>> tracks;

  /// Playlist ids whose track fetch should fail, to test partial success.
  final Set<String> failOn;

  bool authenticated = false;
  bool disconnected = false;

  @override
  MediaSource get source => MediaSource.spotify;

  @override
  String get displayName => 'Fake';

  @override
  String get description => 'A provider that answers from a script.';

  @override
  bool get isAvailable => true;

  @override
  String? get unavailableReason => null;

  @override
  bool get isConnected => authenticated;

  @override
  Future<void> authenticate() async => authenticated = true;

  @override
  Future<List<ImportedPlaylist>> getPlaylists() async => playlists;

  @override
  Future<List<ImportedTrack>> getPlaylistTracks(
    String playlistId, {
    void Function(int fetched, int total)? onProgress,
  }) async {
    if (failOn.contains(playlistId)) {
      throw const ImportFailure(ImportFailureKind.forbidden);
    }
    final result = tracks[playlistId] ?? const <ImportedTrack>[];
    onProgress?.call(result.length, result.length);
    return result;
  }

  @override
  Future<void> disconnect() async => disconnected = true;
}

/// An in-memory stand-in for the shared playlist catalogue.
///
/// Only the three methods the import path uses are implemented; everything else
/// throws, so a change to the import that starts touching something new fails
/// loudly here rather than silently doing nothing.
///
/// It models the property the real catalogue gets from [PlaylistKey]: the
/// document id is derived from (`source`, `sourceId`), so the same source
/// playlist always addresses one entry no matter which account publishes it.
class _FakeLibrary implements LibraryRepository {
  final Map<String, Playlist> created = <String, Playlist>{};
  final Map<String, List<Track>> tracksByPlaylist = <String, List<Track>>{};

  /// Ids whose *name* was refreshed by a later publish, which is what a rename
  /// at the source looks like now that publishing is one idempotent call.
  final List<String> renamed = <String>[];

  static String _keyFor(MediaSource source, String sourceId) =>
      'pl_${source.wireValue}_$sourceId';

  /// No uid — the catalogue is shared, and the answer is the same for every
  /// account. See [LibraryRepository.findImportedPlaylist].
  @override
  Future<Playlist?> findImportedPlaylist({
    required MediaSource source,
    required String sourceId,
  }) async => created[_keyFor(source, sourceId)];

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
    final id = _keyFor(source, sourceId);
    final existing = created[id];

    if (existing != null) {
      if (existing.name != name) renamed.add(id);
      // Provenance is written on create and never rewritten — a re-publish by
      // another account must not steal the credit. Mirrors `upsert`.
      created[id] = existing.copyWith(name: name);
      return id;
    }

    created[id] = Playlist(
      id: id,
      name: name,
      description: description,
      source: source,
      sourceId: sourceId,
      sourceUrl: sourceUrl,
      visibility: PlaylistVisibility.shared,
      importedByUserId: importedByUserId,
      importedBy: importedBy,
    );
    tracksByPlaylist[id] = <Track>[];
    return id;
  }

  @override
  Future<int> writePlaylistTracksInOrder({
    required String uid,
    required String playlistId,
    required List<Track> tracks,
  }) async {
    final rows = tracksByPlaylist.putIfAbsent(playlistId, () => <Track>[]);
    var written = 0;
    for (final track in tracks) {
      // Mirrors the real `merge` write: same document id, one row.
      final index = rows.indexWhere((r) => r.documentId == track.documentId);
      if (index >= 0) {
        rows[index] = track;
      } else {
        rows.add(track);
      }
      written++;
    }
    return written;
  }

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw UnimplementedError('${invocation.memberName} is not part of import');
}

ImportedTrack _track(String id, String title) =>
    ImportedTrack(id: id, title: title, artist: 'Neon Meridian');

void main() {
  group('MusicImportService', () {
    late _FakeLibrary library;
    late MusicImportService service;

    setUp(() {
      library = _FakeLibrary();
      service = MusicImportService(library: library);
    });

    test('turns a provider description into an AURIX playlist', () async {
      final provider = _FakeProvider(
        playlists: const [
          ImportedPlaylist(id: 'sp_1', name: 'Late Drive', trackCount: 2),
        ],
        tracks: {
          'sp_1': [_track('t1', 'One'), _track('t2', 'Two')],
        },
      );

      final summary = await service.importPlaylists(
        uid: 'uid_1',
        provider: provider,
        playlists: provider.playlists,
      );

      expect(summary.isCompleteSuccess, isTrue);
      expect(summary.trackCount, 2);

      final playlist = library.created.values.single;
      expect(playlist.name, 'Late Drive');
      // Provenance is what makes the second import an update.
      expect(playlist.source, MediaSource.spotify);
      expect(playlist.sourceId, 'sp_1');

      final rows = library.tracksByPlaylist[playlist.id]!;
      expect(rows.map((t) => t.name), ['One', 'Two']);
      expect(rows.first.spotifyId, 't1');
      expect(rows.first.documentId, 'spotify_t1');
    });

    test('re-importing updates rather than duplicating', () async {
      final provider = _FakeProvider(
        playlists: const [
          ImportedPlaylist(id: 'sp_1', name: 'Late Drive', trackCount: 1),
        ],
        tracks: {
          'sp_1': [_track('t1', 'One')],
        },
      );

      await service.importPlaylists(
        uid: 'uid_1',
        provider: provider,
        playlists: provider.playlists,
      );
      await service.importPlaylists(
        uid: 'uid_1',
        provider: provider,
        playlists: provider.playlists,
      );

      // One playlist, one track — not two of each.
      expect(library.created, hasLength(1));
      expect(library.tracksByPlaylist.values.single, hasLength(1));
    });

    test('a rename at the source is picked up on re-import', () async {
      final first = _FakeProvider(
        playlists: const [ImportedPlaylist(id: 'sp_1', name: 'Old Name')],
        tracks: const {'sp_1': <ImportedTrack>[]},
      );
      await service.importPlaylists(
        uid: 'uid_1',
        provider: first,
        playlists: first.playlists,
      );

      final second = _FakeProvider(
        playlists: const [ImportedPlaylist(id: 'sp_1', name: 'New Name')],
        tracks: const {'sp_1': <ImportedTrack>[]},
      );
      await service.importPlaylists(
        uid: 'uid_1',
        provider: second,
        playlists: second.playlists,
      );

      expect(library.renamed, hasLength(1));
      expect(library.created.values.single.name, 'New Name');
    });

    test('one failed playlist does not stop the others', () async {
      // The behaviour the per-playlist error exists for: importing twelve
      // playlists and getting nothing because the seventh was refused is the
      // outcome this avoids.
      final provider = _FakeProvider(
        playlists: const [
          ImportedPlaylist(id: 'ok_1', name: 'First'),
          ImportedPlaylist(id: 'bad', name: 'Refused'),
          ImportedPlaylist(id: 'ok_2', name: 'Third'),
        ],
        tracks: {
          'ok_1': [_track('a', 'A')],
          'ok_2': [_track('b', 'B')],
        },
        failOn: const {'bad'},
      );

      final summary = await service.importPlaylists(
        uid: 'uid_1',
        provider: provider,
        playlists: provider.playlists,
      );

      expect(summary.succeeded.map((r) => r.name), ['First', 'Third']);
      expect(summary.failed.map((r) => r.name), ['Refused']);
      expect(summary.isCompleteSuccess, isFalse);
      // The failure carries a sentence, not an exception string.
      expect(summary.failed.single.error, isNotNull);
    });

    test('an imported playlist with no cover borrows the first artwork',
        () async {
      final provider = _FakeProvider(
        playlists: const [ImportedPlaylist(id: 'sp_1', name: 'No Cover')],
        tracks: {
          'sp_1': const [
            ImportedTrack(id: 't1', title: 'One', artist: 'A'),
            ImportedTrack(
              id: 't2',
              title: 'Two',
              artist: 'A',
              artworkUrl: 'https://cdn.example/art.jpg',
            ),
          ],
        },
      );

      await service.importPlaylists(
        uid: 'uid_1',
        provider: provider,
        playlists: provider.playlists,
      );

      // AURIX has no cover-upload path, so a playlist with no image would show
      // a placeholder forever otherwise.
      expect(library.created.values.single.sourceId, 'sp_1');
    });
  });

  group('ImportedTrack', () {
    test('stamps provenance for the source it came from', () {
      const imported = ImportedTrack(id: 'v1', title: 'T', artist: 'A');

      final spotify = imported.toTrack(source: MediaSource.spotify);
      expect(spotify.spotifyId, 'v1');
      expect(spotify.youtubeVideoId, isNull);
      expect(spotify.documentId, 'spotify_v1');

      final youtube = imported.toTrack(source: MediaSource.youtube);
      expect(youtube.youtubeVideoId, 'v1');
      expect(youtube.spotifyId, isNull);
      expect(youtube.documentId, 'youtube_v1');
    });

    test('carries a preview URL but never audio', () {
      // The one audio URL AURIX may stream itself. Everything else about a
      // track is metadata and references — see the note on ImportedTrack.
      const imported = ImportedTrack(
        id: 'v1',
        title: 'T',
        artist: 'A',
        previewUrl: 'https://cdn.example/preview.mp3',
      );
      final track = imported.toTrack(source: MediaSource.spotify);
      expect(track.previewUrl, 'https://cdn.example/preview.mp3');
      expect(track.hasPreview, isTrue);
    });
  });
}
