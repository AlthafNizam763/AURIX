import 'imported_models.dart';
import 'playlist_url.dart';

/// One playlist, fetched whole.
class FetchedPlaylist {
  const FetchedPlaylist({required this.playlist, required this.tracks});

  final ImportedPlaylist playlist;

  /// Every track, in playlist order. Order is load-bearing — it is what the
  /// import writes into `position`, and therefore what Next/Previous follow.
  final List<ImportedTrack> tracks;
}

/// How far a fetch has got, for the progress UI.
enum FetchStage {
  /// Reading the playlist's own metadata: name, description, cover, count.
  metadata,

  /// Paging through its contents.
  items,
}

class FetchProgress {
  const FetchProgress({
    required this.stage,
    this.fetched = 0,
    this.total = 0,
  });

  final FetchStage stage;
  final int fetched;

  /// The source's own count. Advisory — it counts entries, including ones the
  /// import will skip, so [fetched] can legitimately end below it.
  final int total;

  /// 0..1, or null when the total is not yet known.
  double? get fraction {
    if (total <= 0) return null;
    return (fetched / total).clamp(0.0, 1.0);
  }
}

/// Fetches a playlist identified by a pasted link.
///
/// ## Why this is separate from [MusicImportProvider]
///
/// They answer different questions and it is worth not conflating them.
/// [MusicImportProvider] is *account-shaped*: sign in, list what this account
/// has, pick some. This is *link-shaped*: here is one playlist id, fetch it.
///
/// A link import needs no account listing and often no sign-in at all — a
/// public YouTube playlist is readable with an API key, and a public Spotify
/// playlist needs only an app-level authorization. Forcing the link flow
/// through the account interface would mean making the user authorize an
/// account before AURIX could read a link they already have, which is the
/// friction this whole feature exists to remove.
///
/// The two share everything below them: the same [ImportedPlaylist] and
/// [ImportedTrack] descriptions, the same normalisation, the same catalogue,
/// the same Firestore layout. Only the *acquisition* differs.
///
/// ## What an implementation may and may not do
///
/// It produces descriptions and nothing else — it does not touch Firestore,
/// does not compute a document id, and does not decide what an AURIX record
/// looks like. [PlaylistImportService] owns all of that.
///
/// It **must not fetch audio**. Titles, artists, durations, artwork URLs and
/// the source's own id for the song. No stream downloading, no caching of
/// audio, no circumvention of any protection, nothing written to Firebase
/// Storage. See the note on [ImportedTrack].
abstract interface class PlaylistFetcher {
  /// Which service this reads from.
  PlaylistSource get source;

  /// False when this build has no credentials for the service. The import
  /// screen reports the reason rather than failing at paste time.
  bool get isAvailable;

  /// Why [isAvailable] is false, or null when it is true.
  String? get unavailableReason;

  /// Fetches one playlist and **all** of its items.
  ///
  /// Paging is this method's responsibility and it must run to completion: a
  /// playlist is imported whole or not at all. An implementation that stops at
  /// the first page produces a library that silently disagrees with the source,
  /// which is the failure mode this contract exists to forbid.
  ///
  /// Throws [ImportFailure] for every failure, with the kind that matches what
  /// the service actually said. Never throws a transport exception.
  Future<FetchedPlaylist> fetch(
    String playlistId, {
    void Function(FetchProgress progress)? onProgress,
  });
}
