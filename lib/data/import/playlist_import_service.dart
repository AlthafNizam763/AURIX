import 'dart:async';

import '../../core/utils/app_logger.dart';
import '../models/media_source.dart';
import '../models/playlist.dart';
import '../models/song.dart';
import '../models/track.dart';
import '../repositories/catalog_repository.dart';
import '../repositories/library_repository.dart';
import 'imported_models.dart';
import 'music_import_provider.dart';
import 'playlist_fetcher.dart';
import 'playlist_url.dart';

/// The steps of an import, in the order they happen.
///
/// The UI renders one line per stage, so these are named for what the user is
/// told rather than for what the code is doing.
enum ImportPhase {
  detecting('Detecting playlist…'),
  fetching('Fetching playlist…'),
  importing('Importing songs…'),
  saving('Saving to AURIX…'),
  finishing('Almost done…'),
  complete('Playlist imported successfully');

  const ImportPhase(this.message);
  final String message;
}

/// Where an import has got to.
class ImportStep {
  const ImportStep({
    required this.phase,
    this.fetched = 0,
    this.total = 0,
  });

  final ImportPhase phase;
  final int fetched;
  final int total;

  String get message => phase.message;

  /// 0..1 across the whole import, or null when there is nothing to measure.
  ///
  /// Weighted rather than linear in the phase index: fetching is where the time
  /// actually goes on a long playlist, so it owns the middle 60% of the bar and
  /// fills in proportion to the pages that have arrived. A bar that jumped to
  /// 80% and then sat there for a minute would be worse than no bar.
  double? get fraction {
    switch (phase) {
      case ImportPhase.detecting:
        return 0.05;
      case ImportPhase.fetching:
        if (total <= 0) return null;
        return 0.1 + 0.6 * (fetched / total).clamp(0.0, 1.0);
      case ImportPhase.importing:
        return 0.75;
      case ImportPhase.saving:
        return 0.88;
      case ImportPhase.finishing:
        return 0.96;
      case ImportPhase.complete:
        return 1;
    }
  }
}

/// What an import produced.
class ImportOutcome {
  const ImportOutcome({
    required this.playlistId,
    required this.name,
    required this.source,
    required this.songCount,
    required this.wasResync,
    this.coverUrl,
    this.addedCount = 0,
    this.removedCount = 0,
    this.catalogueWrites = 0,
  });

  /// The AURIX playlist id — what "Open Playlist" navigates to.
  final String playlistId;

  final String name;
  final MediaSource source;

  /// How many songs the playlist holds now.
  final int songCount;

  /// True when this refreshed an existing import rather than creating one.
  final bool wasResync;

  final String? coverUrl;

  /// Songs added by this run. Equal to [songCount] on a first import.
  final int addedCount;

  /// Songs removed because the source no longer lists them. Always 0 on a
  /// first import.
  final int removedCount;

  /// Catalogue documents created or improved. Smaller than [songCount]
  /// whenever the catalogue already knew the songs — see
  /// [CatalogRepository.publishAll].
  final int catalogueWrites;
}

/// Already-imported playlists, reported before any work is done.
///
/// Not an [ImportFailure]: the user is not being told "no", they are being
/// offered a choice between opening what they already have and re-syncing it.
/// Modelling it as an error would make the UI render a red banner for a
/// perfectly ordinary situation.
class DuplicatePlaylist implements Exception {
  const DuplicatePlaylist(this.existing);
  final Playlist existing;
}

/// Imports a playlist from a pasted link.
///
/// ## The pipeline
///
/// ```
/// URL ──▶ PlaylistUrlParser ──▶ PlaylistFetcher ──▶ Track[]
///                                                    │
///                            ┌───────────────────────┤
///                            ▼                       ▼
///                    catalog/songs/{id}    users/{uid}/playlists/{id}/tracks
///                    (global, shared)      (this user's copy, + position)
/// ```
///
/// Both writes happen, and both are necessary. The catalogue is what makes a
/// song findable from global search anywhere in the app; the playlist rows are
/// what carry order, what render offline, and what the user is free to
/// rearrange without editing a shared record.
///
/// ## Why this class and not [MusicImportService]
///
/// [MusicImportService] imports *several* playlists chosen from a connected
/// account, and its central concern is that one failure must not lose the
/// other eleven. This imports *one* playlist named by a link, and its central
/// concerns are duplicate detection and re-sync — questions the other one never
/// has to ask because it works from a live account listing.
///
/// They share everything below: the same descriptions, the same normalisation,
/// the same catalogue, the same Firestore layout.
///
/// ## Nothing here fetches audio
///
/// Metadata and references. See the note on [ImportedTrack] — the rule holds
/// for every path through this class.
class PlaylistImportService {
  PlaylistImportService({
    required LibraryRepository library,
    required CatalogRepository catalog,
    required List<PlaylistFetcher> fetchers,
  }) : _library = library,
       _catalog = catalog,
       _fetchers = fetchers;

  final LibraryRepository _library;
  final CatalogRepository _catalog;
  final List<PlaylistFetcher> _fetchers;

  /// The fetcher for a source, or null when this build has none.
  PlaylistFetcher? fetcherFor(PlaylistSource source) {
    for (final fetcher in _fetchers) {
      if (fetcher.source == source) return fetcher;
    }
    return null;
  }

  /// Imports the playlist at [url] into [uid]'s library.
  ///
  /// Throws [DuplicatePlaylist] when this user has imported it before and
  /// [allowResync] is false — the caller then offers "Open" or "Re-sync".
  /// Throws [ImportFailure] for everything else, always with a message written
  /// for a person.
  Future<ImportOutcome> importFromUrl({
    required String uid,
    required String url,
    bool allowResync = false,
    void Function(ImportStep step)? onProgress,
  }) async {
    onProgress?.call(const ImportStep(phase: ImportPhase.detecting));

    // ---- 1. Detect and extract ------------------------------------------

    final parsed = PlaylistUrlParser.parse(url);
    if (parsed is PlaylistLinkRejected) {
      throw ImportFailure(
        ImportFailureKind.unknown,
        detail: 'Rejected link: ${parsed.problem.name}',
      ).withMessage(parsed.message);
    }

    final link = (parsed as PlaylistLinkParsed).link;
    final fetcher = fetcherFor(link.source);

    if (fetcher == null) {
      throw const ImportFailure(ImportFailureKind.unavailable);
    }
    if (!fetcher.isAvailable) {
      throw ImportFailure(
        ImportFailureKind.notConfigured,
        detail: fetcher.unavailableReason,
      );
    }

    // ---- 2. Duplicate check, before any network work --------------------
    //
    // Done first deliberately. Checking after the fetch would spend the user's
    // bandwidth and someone else's API quota to discover something one
    // Firestore read already knew.

    final existing = await _library.findImportedPlaylist(
      uid: uid,
      source: link.mediaSource,
      sourceId: link.playlistId,
    );

    if (existing != null && !allowResync) {
      throw DuplicatePlaylist(existing);
    }

    // ---- 3. Fetch everything --------------------------------------------

    onProgress?.call(const ImportStep(phase: ImportPhase.fetching));

    final fetched = await fetcher.fetch(
      link.playlistId,
      onProgress: (progress) => onProgress?.call(
        ImportStep(
          phase: ImportPhase.fetching,
          fetched: progress.fetched,
          total: progress.total,
        ),
      ),
    );

    if (fetched.tracks.isEmpty) {
      // An empty result after a successful fetch is a real answer, not a
      // failure — but importing an empty playlist would leave the user with a
      // row that does nothing, so it is reported instead.
      throw const ImportFailure(
        ImportFailureKind.notFound,
        detail: 'Playlist fetched successfully but contained no usable tracks',
      ).withMessageText(
        'That playlist has no songs AURIX can import. Its tracks may have '
        'been removed at the source.',
      );
    }

    // ---- 4. Normalise ---------------------------------------------------

    onProgress?.call(
      ImportStep(
        phase: ImportPhase.importing,
        fetched: fetched.tracks.length,
        total: fetched.tracks.length,
      ),
    );

    final tracks = fetched.tracks
        .map((track) => track.toTrack(source: link.mediaSource))
        .toList(growable: false);

    // ---- 5. Publish to the shared catalogue -----------------------------
    //
    // Before the playlist rows, so that a song is globally searchable from the
    // moment the playlist appears rather than a beat later. A catalogue failure
    // is survivable — the playlist still imports and still plays — so it is
    // logged rather than thrown.

    var catalogueWrites = 0;
    try {
      catalogueWrites = await _catalog.publishAll(
        tracks.map(Song.fromTrack).toList(growable: false),
      );
    } on Object catch (error, stackTrace) {
      AppLogger.error(
        'Catalogue publish failed; the playlist will still import but its '
        'songs will not appear in global search until the next import',
        scope: 'import',
        error: error,
        stackTrace: stackTrace,
      );
    }

    // ---- 6. Write the playlist ------------------------------------------

    onProgress?.call(const ImportStep(phase: ImportPhase.saving));

    try {
      final outcome = existing == null
          ? await _createPlaylist(
              uid: uid,
              link: link,
              fetched: fetched,
              tracks: tracks,
              catalogueWrites: catalogueWrites,
            )
          : await _resyncPlaylist(
              uid: uid,
              existing: existing,
              fetched: fetched,
              tracks: tracks,
              catalogueWrites: catalogueWrites,
            );

      onProgress?.call(const ImportStep(phase: ImportPhase.complete));
      return outcome;
    } on ImportFailure {
      rethrow;
    } on Object catch (error, stackTrace) {
      AppLogger.error(
        'Import write failed',
        scope: 'import',
        error: error,
        stackTrace: stackTrace,
      );
      throw ImportFailure(
        ImportFailureKind.storage,
        detail: error.toString(),
      );
    }
  }

  /// Re-syncs a playlist that is already imported.
  ///
  /// A convenience over [importFromUrl] for the case where the playlist record
  /// is in hand and the URL has to be recovered from it.
  Future<ImportOutcome> resync({
    required String uid,
    required Playlist playlist,
    void Function(ImportStep step)? onProgress,
  }) {
    final url = playlist.sourceUrl ?? _urlFor(playlist);
    if (url == null) {
      throw const ImportFailure(
        ImportFailureKind.unavailable,
        detail: 'Playlist has no source URL to sync from',
      );
    }
    return importFromUrl(
      uid: uid,
      url: url,
      allowResync: true,
      onProgress: onProgress,
    );
  }

  /// Rebuilds a source URL for a playlist imported before `sourceUrl` was
  /// stored, so re-sync works on records created by earlier builds.
  static String? _urlFor(Playlist playlist) {
    final id = playlist.sourceId;
    if (id == null || id.isEmpty) return null;
    switch (playlist.source) {
      case MediaSource.spotify:
        return 'https://open.spotify.com/playlist/$id';
      case MediaSource.youtube:
        return 'https://music.youtube.com/playlist?list=$id';
      case MediaSource.aurix:
        return null;
    }
  }

  // ---- Write paths -------------------------------------------------------

  Future<ImportOutcome> _createPlaylist({
    required String uid,
    required PlaylistLink link,
    required FetchedPlaylist fetched,
    required List<Track> tracks,
    required int catalogueWrites,
  }) async {
    final coverUrl = fetched.playlist.coverUrl ?? _coverFrom(tracks);

    final playlistId = await _library.createPlaylist(
      uid: uid,
      name: fetched.playlist.name,
      description: _descriptionFor(fetched.playlist, link.source),
      coverUrl: coverUrl,
      source: link.mediaSource,
      sourceId: link.playlistId,
      sourceUrl: link.canonicalUrl,
    );

    final written = await _library.writePlaylistTracksInOrder(
      uid: uid,
      playlistId: playlistId,
      tracks: tracks,
    );

    AppLogger.info(
      'Imported "${fetched.playlist.name}" ($written songs) from '
      '${link.source.label}',
      scope: 'import',
    );

    return ImportOutcome(
      playlistId: playlistId,
      name: fetched.playlist.name,
      source: link.mediaSource,
      songCount: written,
      addedCount: written,
      wasResync: false,
      coverUrl: coverUrl.isEmpty ? null : coverUrl,
      catalogueWrites: catalogueWrites,
    );
  }

  /// Refreshes an existing import against its source.
  ///
  /// ## What a re-sync does, and the one thing it deliberately does not
  ///
  /// Songs the source has added are added. Songs the source no longer lists are
  /// removed. The order becomes the source's order again, and the playlist's
  /// name and cover are refreshed.
  ///
  /// The description is **not** overwritten. It is the one field a user is
  /// likely to have edited here, and replacing an edit with a stale line from
  /// the source is worse than leaving the line stale.
  ///
  /// Removal is what makes this a sync rather than a merge, and it is the part
  /// worth being careful about: a track is removed only when it was in this
  /// playlist and is absent from the freshly fetched list. Nothing outside this
  /// playlist is touched — the song stays in the catalogue, stays liked if it
  /// was liked, and stays in every other playlist it is in.
  Future<ImportOutcome> _resyncPlaylist({
    required String uid,
    required Playlist existing,
    required FetchedPlaylist fetched,
    required List<Track> tracks,
    required int catalogueWrites,
  }) async {
    final current = await _library.readPlaylistTracks(uid, existing.id);

    final incomingIds = tracks.map((track) => track.documentId).toSet();
    final staleIds = current
        .map((track) => track.documentId)
        .where((id) => !incomingIds.contains(id))
        .toList(growable: false);

    final existingIds = current.map((track) => track.documentId).toSet();
    final addedCount =
        incomingIds.where((id) => !existingIds.contains(id)).length;

    // Written before the removals, so an interruption between the two leaves a
    // playlist with too much in it rather than too little. Extra rows are
    // visible and fixable by syncing again; missing ones look like data loss.
    final written = await _library.writePlaylistTracksInOrder(
      uid: uid,
      playlistId: existing.id,
      tracks: tracks,
    );

    final removed = staleIds.isEmpty
        ? 0
        : await _library.removePlaylistTracks(
            uid: uid,
            playlistId: existing.id,
            trackIds: staleIds,
          );

    await _library.markPlaylistSynced(
      uid: uid,
      playlistId: existing.id,
      name: fetched.playlist.name,
      coverUrl: fetched.playlist.coverUrl,
    );

    AppLogger.info(
      'Re-synced "${fetched.playlist.name}": $addedCount added, $removed '
      'removed, $written total',
      scope: 'import',
    );

    return ImportOutcome(
      playlistId: existing.id,
      name: fetched.playlist.name,
      source: existing.source,
      songCount: written,
      addedCount: addedCount,
      removedCount: removed,
      wasResync: true,
      coverUrl: fetched.playlist.coverUrl ?? existing.imageUrl,
      catalogueWrites: catalogueWrites,
    );
  }

  // ---- Helpers -----------------------------------------------------------

  /// The description an imported playlist gets when it has none of its own.
  ///
  /// Attribution rather than decoration: a playlist that appeared in someone's
  /// library with no explanation is confusing, and this line is what says where
  /// it came from. Only ever used on create.
  static String _descriptionFor(
    ImportedPlaylist playlist,
    PlaylistSource source,
  ) {
    if (playlist.description.trim().isNotEmpty) {
      return playlist.description.trim();
    }
    final owner = playlist.ownerName;
    return owner == null || owner.isEmpty
        ? 'Imported from ${source.label}'
        : 'Imported from ${source.label} · $owner';
  }

  /// Falls back to the first song's artwork when the playlist has no cover.
  ///
  /// A reference to the source's CDN, not a copy. AURIX has no cover-upload
  /// path, so without this a coverless playlist would show a generated
  /// placeholder forever.
  static String _coverFrom(List<Track> tracks) {
    for (final track in tracks) {
      final url = track.artworkUrl;
      if (url != null && url.isNotEmpty) return url;
    }
    return '';
  }
}

/// Lets a failure carry a message written for one specific situation.
///
/// [ImportFailureKind] gives every failure a good default message, which is
/// what most of them should use. A few — a malformed link, a playlist that
/// fetched but held nothing — know something more specific than their kind
/// does, and this is how they say it without inventing a new kind for every
/// sentence.
extension ImportFailureMessage on ImportFailure {
  ImportFailure withMessage(String message) =>
      _MessagedFailure(kind, message, detail: detail, retryAfter: retryAfter);

  ImportFailure withMessageText(String message) => withMessage(message);
}

class _MessagedFailure extends ImportFailure {
  const _MessagedFailure(
    super.kind,
    this._message, {
    super.detail,
    super.retryAfter,
  });

  final String _message;

  @override
  String get message => _message;
}
