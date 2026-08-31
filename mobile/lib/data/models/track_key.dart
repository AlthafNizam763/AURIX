import 'media_source.dart';
import 'track.dart';

/// Turns a track into the Firestore document id that represents it.
///
/// ## Why this exists at all
///
/// Firestore will happily generate a random id for every `add()`. Using one
/// here would break three things that have to work:
///
///  * **Liking is idempotent.** Tapping the heart twice, or on two devices at
///    once, must converge on one document. With a random id it produces two,
///    and unliking then removes one of them and leaves the song liked.
///  * **Re-importing updates.** Importing the same Spotify playlist a second
///    time must refresh its rows, not double them. That requires the second
///    import to compute the same ids as the first.
///  * **Cross-collection identity.** The same song is a row in Liked Songs, a
///    row in two playlists and an entry in play history. They agree on what
///    "the same song" means only if the id is a function of the song.
///
/// So the id is derived, never allocated.
///
/// ## The shape
///
/// `<source>_<id>` for anything that came from a provider — `spotify_4uLU6hMC`,
/// `youtube_dQw4w9WgXcQ`. Provider-qualified because two services can hand out
/// the same id string, and an unqualified key would silently merge two
/// different songs into one document.
///
/// For a track with no provider id, the key is derived from the title and
/// artist instead, normalised so that trivial differences in spacing and case
/// do not create a second row for a song the user already has.
abstract final class TrackKey {
  /// The document id for [track].
  static String of(Track track) {
    final spotifyId = track.spotifyId;
    if (spotifyId != null && spotifyId.isNotEmpty) {
      return forProvider(MediaSource.spotify, spotifyId);
    }

    final youtubeId = track.youtubeVideoId;
    if (youtubeId != null && youtubeId.isNotEmpty) {
      return forProvider(MediaSource.youtube, youtubeId);
    }

    final sourceId = track.sourceId;
    if (sourceId != null && sourceId.isNotEmpty) {
      return forProvider(track.source, sourceId);
    }

    // An id that is already one of ours passes straight through, so a track
    // read back out of Firestore and re-saved keeps its document rather than
    // being re-derived into a near-miss.
    if (isAurixKey(track.id)) return track.id;

    return forMetadata(title: track.name, artist: track.artistNames);
  }

  /// `<source>_<id>`, sanitised for use as a document id.
  static String forProvider(MediaSource source, String id) =>
      '${source.wireValue}_${_sanitize(id)}';

  /// A key derived from what the track *is*, for tracks with no provider id.
  ///
  /// Not a hash. A readable key makes a Firestore console session possible
  /// without a lookup table, and the collision cost is bounded and benign:
  /// two genuinely different songs with the same title and artist collapse into
  /// one library row, which is also what a user would call them.
  static String forMetadata({required String title, required String artist}) {
    final slug = _sanitize('${_normalise(title)}-${_normalise(artist)}');
    return slug.isEmpty ? 'aurix_untitled' : 'aurix_$slug';
  }

  /// True when [id] already looks like a key this class produced.
  static bool isAurixKey(String id) {
    for (final source in MediaSource.values) {
      if (id.startsWith('${source.wireValue}_')) return true;
    }
    return false;
  }

  /// The provider id embedded in [key], or null when it carries none.
  ///
  /// The inverse of [forProvider], used by the import providers to ask "have I
  /// already imported this?" without re-reading the document body.
  static String? providerIdIn(String key, MediaSource source) {
    final prefix = '${source.wireValue}_';
    if (!key.startsWith(prefix)) return null;
    final id = key.substring(prefix.length);
    return id.isEmpty ? null : id;
  }

  static String _normalise(String value) => value
      .toLowerCase()
      .trim()
      // Collapse any run of whitespace to one hyphen so "The  Weeknd" and
      // "The Weeknd" are the same key.
      .replaceAll(RegExp(r'\s+'), '-');

  /// Strips everything Firestore forbids or that would make a key ambiguous.
  ///
  /// Firestore rejects `/` in a document id outright and reserves ids matching
  /// `__.*__`. The rest is trimmed to keep keys addressable by hand.
  ///
  /// Length is capped because Firestore's limit is 1500 *bytes* and a very long
  /// title would otherwise produce a write that fails only for that one row.
  static String _sanitize(String value) {
    final cleaned = value
        .replaceAll(RegExp(r'[^A-Za-z0-9._~-]'), '-')
        .replaceAll(RegExp(r'-{2,}'), '-')
        .replaceAll(RegExp(r'^-+|-+$'), '');
    if (cleaned.isEmpty) return '';
    // Well under the byte limit even if every character is multi-byte before
    // sanitising, and long enough that real titles are not truncated.
    return cleaned.length <= 200 ? cleaned : cleaned.substring(0, 200);
  }
}
