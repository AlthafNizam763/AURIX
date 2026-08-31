import 'dart:async';

import '../../core/utils/app_logger.dart';
import '../models/track.dart';
import '../repositories/catalog_repository.dart';
import '../repositories/library_repository.dart';
import 'imported_models.dart';
import 'music_import_provider.dart';

/// What happened to one playlist during an import.
class PlaylistImportResult {
  const PlaylistImportResult({
    required this.name,
    required this.trackCount,
    required this.wasUpdate,
    this.error,
  });

  final String name;
  final int trackCount;

  /// True when this refreshed a playlist imported before, rather than creating
  /// a new one.
  final bool wasUpdate;

  /// Non-null when this playlist failed. The others in the same run still
  /// succeeded — see [MusicImportService.importPlaylists].
  final String? error;

  bool get succeeded => error == null;
}

/// The outcome of a whole import run.
class ImportSummary {
  const ImportSummary({required this.results});

  final List<PlaylistImportResult> results;

  List<PlaylistImportResult> get succeeded =>
      results.where((r) => r.succeeded).toList(growable: false);

  List<PlaylistImportResult> get failed =>
      results.where((r) => !r.succeeded).toList(growable: false);

  int get trackCount =>
      succeeded.fold<int>(0, (sum, result) => sum + result.trackCount);

  bool get isCompleteSuccess => failed.isEmpty && succeeded.isNotEmpty;
}

/// Progress through an import, for the UI.
class ImportProgress {
  const ImportProgress({
    required this.playlistName,
    required this.playlistIndex,
    required this.playlistTotal,
    this.tracksFetched = 0,
    this.tracksTotal = 0,
  });

  final String playlistName;
  final int playlistIndex;
  final int playlistTotal;
  final int tracksFetched;
  final int tracksTotal;

  /// 0..1 across the whole run, or null when there is nothing to measure.
  double? get fraction {
    if (playlistTotal <= 0) return null;
    final withinPlaylist = tracksTotal <= 0
        ? 0.0
        : (tracksFetched / tracksTotal).clamp(0.0, 1.0);
    return ((playlistIndex + withinPlaylist) / playlistTotal).clamp(0.0, 1.0);
  }
}

/// Turns what a [MusicImportProvider] produced into AURIX records.
///
/// ## Why this is one class and not one per provider
///
/// It is the whole point of the abstraction. A provider answers "what is in
/// this account"; this answers "what does that become in AURIX" — the document
/// layout, the de-duplication rule, the update-versus-create decision, the
/// batching. Those answers must be identical for every provider, and the way to
/// guarantee that is for there to be one copy of them.
///
/// Adding YouTube therefore means writing a provider and changing nothing here.
///
/// ## Where imported playlists go
///
/// To the shared catalogue at `/playlists`, not to `/users/{uid}/playlists` —
/// the same destination as the paste-a-link path, and for the same reason. An
/// import is a contribution: the playlist becomes searchable and playable by
/// every signed-in AURIX user, with the importing account recorded on the
/// document rather than gating it. See [PlaylistCatalogRepository].
///
/// ## Re-importing
///
/// Importing the same playlist twice updates it, and so does a *different
/// account* importing it. The pair (`source`, `sourceId`) identifies the
/// playlist across the whole product — see
/// [LibraryRepository.findImportedPlaylist] — and the tracks are written with
/// `merge`, so metadata improves and any hand-arranged order survives.
///
/// The one thing a re-import does *not* do is remove tracks deleted at the
/// source. That is deliberate here in a way it is not in
/// [PlaylistImportService]: this path has no explicit "sync" gesture behind it,
/// so a removal would be a side effect of an import the user asked for rather
/// than of a refresh they requested.
class MusicImportService {
  MusicImportService({
    required LibraryRepository library,
    CatalogRepository? catalog,
  }) : _library = library,
       _catalog = catalog;

  final LibraryRepository _library;

  /// Where imported songs are published so global search can find them.
  ///
  /// Optional so that existing tests — which exercise the playlist-writing
  /// behaviour and have no Firestore — construct this class unchanged. A null
  /// catalogue means the playlists still import correctly and their songs are
  /// simply not published, which is exactly what happened before the catalogue
  /// existed.
  final CatalogRepository? _catalog;

  /// Imports [playlists] into the user's library.
  ///
  /// Every playlist is attempted even if an earlier one failed, and each
  /// failure is recorded against its own playlist. Importing twelve playlists
  /// and getting nothing because the seventh was refused is the outcome this
  /// avoids.
  Future<ImportSummary> importPlaylists({
    required String uid,
    required MusicImportProvider provider,
    required List<ImportedPlaylist> playlists,
    String? importedBy,
    void Function(ImportProgress progress)? onProgress,
  }) async {
    final results = <PlaylistImportResult>[];

    for (var index = 0; index < playlists.length; index++) {
      final playlist = playlists[index];

      onProgress?.call(
        ImportProgress(
          playlistName: playlist.name,
          playlistIndex: index,
          playlistTotal: playlists.length,
          tracksTotal: playlist.trackCount,
        ),
      );

      try {
        final result = await _importOne(
          uid: uid,
          provider: provider,
          playlist: playlist,
          importedBy: importedBy,
          onTrackProgress: (fetched, total) => onProgress?.call(
            ImportProgress(
              playlistName: playlist.name,
              playlistIndex: index,
              playlistTotal: playlists.length,
              tracksFetched: fetched,
              tracksTotal: total,
            ),
          ),
        );
        results.add(result);
      } on Object catch (error, stackTrace) {
        AppLogger.error(
          'Import of "${playlist.name}" failed',
          scope: 'import',
          error: error,
          stackTrace: stackTrace,
        );
        results.add(
          PlaylistImportResult(
            name: playlist.name,
            trackCount: 0,
            wasUpdate: false,
            error: error is ImportFailure
                ? error.message
                : 'Could not import this playlist.',
          ),
        );
      }
    }

    return ImportSummary(results: results);
  }

  Future<PlaylistImportResult> _importOne({
    required String uid,
    required MusicImportProvider provider,
    required ImportedPlaylist playlist,
    String? importedBy,
    void Function(int fetched, int total)? onTrackProgress,
  }) async {
    final imported = await provider.getPlaylistTracks(
      playlist.id,
      onProgress: onTrackProgress,
    );

    final tracks = imported
        .map((track) => track.toTrack(source: provider.source))
        .toList(growable: false);

    // Published to the shared catalogue so these songs are findable from
    // global search rather than only from inside this playlist — the same
    // guarantee the link-import path gives. A catalogue failure is survivable:
    // the playlist still imports and still plays, so it is logged rather than
    // thrown.
    final catalog = _catalog;
    if (catalog != null) {
      try {
        await catalog.publishTracks(tracks);
      } on Object catch (error, stackTrace) {
        AppLogger.error(
          'Catalogue publish failed for "${playlist.name}"; the playlist will '
          'still import but its songs will not appear in global search until '
          'the next import',
          scope: 'import',
          error: error,
          stackTrace: stackTrace,
        );
      }
    }

    // Has *anybody* imported this playlist before?
    //
    // No uid in the question. The catalogue is shared, so a playlist another
    // account already brought in is refreshed rather than duplicated — which is
    // the same answer this path gave before for the *same* account, extended to
    // every account.
    final existing = await _library.findImportedPlaylist(
      source: provider.source,
      sourceId: playlist.id,
    );

    // One call for both cases. Publishing is idempotent — the document id is
    // derived from (source, sourceId) — and it refreshes the source-side name
    // on an entry that already exists, which is what the separate create/rename
    // pair here used to do. The description is still left alone: a user may
    // have edited it, and overwriting an edit is worse than a stale line.
    final playlistId = await _library.publishImportedPlaylist(
      source: provider.source,
      sourceId: playlist.id,
      name: playlist.name,
      importedByUserId: uid,
      importedBy: importedBy,
      description: _descriptionFor(playlist, provider),
      coverUrl: playlist.coverUrl ?? _coverFrom(tracks),
    );

    final written = await _library.writePlaylistTracksInOrder(
      uid: uid,
      playlistId: playlistId,
      tracks: tracks,
    );

    AppLogger.info(
      '${existing == null ? 'Imported' : 'Refreshed'} "${playlist.name}" '
      '($written tracks) from ${provider.source.wireValue}',
      scope: 'import',
    );

    return PlaylistImportResult(
      name: playlist.name,
      trackCount: written,
      wasUpdate: existing != null,
    );
  }

  /// The description an imported playlist gets when it has none of its own.
  ///
  /// Attribution rather than decoration: a playlist that appeared in someone's
  /// library without explanation is confusing, and the line is what tells them
  /// where it came from. Only used on create — a re-import never overwrites it.
  String _descriptionFor(
    ImportedPlaylist playlist,
    MusicImportProvider provider,
  ) {
    if (playlist.description.trim().isNotEmpty) return playlist.description;
    final owner = playlist.ownerName;
    return owner == null || owner.isEmpty
        ? 'Imported from ${provider.source.label}'
        : 'Imported from ${provider.source.label} · $owner';
  }

  /// Falls back to the first track's artwork when the playlist has no cover.
  ///
  /// AURIX has no cover-upload path, so a playlist with no image would show a
  /// generated placeholder forever. Borrowing the first track's artwork — a
  /// reference to the source's CDN, not a copy — is what every music app does
  /// and is what the user expects to see.
  String _coverFrom(List<Track> tracks) {
    for (final track in tracks) {
      final url = track.artworkUrl;
      if (url != null && url.isNotEmpty) return url;
    }
    return '';
  }
}
