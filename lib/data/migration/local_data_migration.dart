import 'dart:async';

import '../../core/storage/metadata_cache.dart';
import '../../core/storage/preferences_store.dart';
import '../../core/utils/app_logger.dart';
import '../models/avatar.dart';
import '../models/media_source.dart';
import '../models/playlist.dart';
import '../models/saved_item.dart';
import '../models/track.dart';
import '../repositories/library_repository.dart';
import '../services/firebase/firestore_profile_service.dart';

/// What a migration run did.
class MigrationResult {
  const MigrationResult({
    this.likedTracks = 0,
    this.playlists = 0,
    this.avatarMoved = false,
    this.skipped = false,
    this.error,
  });

  final int likedTracks;
  final int playlists;
  final bool avatarMoved;

  /// True when there was nothing to migrate, or it had already run.
  final bool skipped;

  final String? error;

  bool get didSomething => likedTracks > 0 || playlists > 0 || avatarMoved;
}

/// Moves a pre-Firebase install's local data into the user's Firestore account.
///
/// ## The problem this solves
///
/// A user upgrading from a Spotify-backed build of AURIX has data on disk:
/// a cached copy of their liked tracks and playlists in `SharedPreferences`
/// (written by the old `MetadataCache`), and an avatar choice keyed by their
/// Spotify account id. After the upgrade they sign in to a *new* AURIX account
/// with a Firebase uid that has never seen any of it.
///
/// Without this, that user's first launch after the update shows an empty
/// library. The data was only ever a cache of Spotify's copy — so nothing is
/// permanently lost — but "my music is gone" is what it looks like, and for the
/// avatar it would be a genuine loss.
///
/// ## What it does and does not touch
///
///  * **Reads** the old cache keys and the old avatar preference.
///  * **Writes** liked tracks and playlists into Firestore under the new uid.
///  * **Deletes nothing.** The local data is left exactly where it was. That is
///    deliberate: a migration that clears the source has no second attempt, and
///    if this one is interrupted half-way — the app killed, the network gone
///    mid-write — the next launch must be able to start over. Firestore's
///    document ids are derived from the tracks themselves (see [TrackKey]), so
///    running twice writes the same documents twice and produces one library.
///
/// ## When it runs
///
/// Once per uid, on the first launch after signing in, gated by a preference
/// key. Not on every launch: it reads several preference blobs and does a
/// handful of Firestore writes, and doing that behind the splash screen every
/// time would be a permanent cost for a one-time need.
class LocalDataMigration {
  LocalDataMigration({
    required PreferencesStore preferences,
    required MetadataCache cache,
    required LibraryRepository library,
    required FirestoreProfileService profiles,
  }) : _prefs = preferences,
       _cache = cache,
       _library = library,
       _profiles = profiles;

  final PreferencesStore _prefs;
  final MetadataCache _cache;
  final LibraryRepository _library;
  final FirestoreProfileService _profiles;

  /// Marks a uid as migrated. Keyed by uid, not global: two accounts on one
  /// device each get their chance at the local data.
  static String _doneKey(String uid) => '${PrefKeys.namespace}migration.v1.$uid';

  bool hasRun(String uid) => _prefs.getBool(_doneKey(uid)) ?? false;

  /// Runs the migration for [uid], if it has not already run.
  Future<MigrationResult> run(String uid) async {
    if (hasRun(uid)) return const MigrationResult(skipped: true);

    try {
      final liked = await _migrateLikedTracks(uid);
      final playlists = await _migratePlaylists(uid);
      final avatar = await _migrateAvatar(uid);

      // Marked done only after every step succeeded. A failure part-way leaves
      // the flag unset, so the next launch retries — which is safe precisely
      // because the writes are idempotent.
      await _prefs.setBool(_doneKey(uid), true);

      final result = MigrationResult(
        likedTracks: liked,
        playlists: playlists,
        avatarMoved: avatar,
      );

      if (result.didSomething) {
        AppLogger.info(
          'Migrated local data for $uid — $liked liked tracks, '
          '$playlists playlists${avatar ? ', avatar' : ''}',
          scope: 'migration',
        );
      }

      return result;
    } on Object catch (error, stackTrace) {
      // Never fatal. A user whose migration fails still has a working app with
      // an empty library, and their local data is untouched for the next
      // attempt. Crashing the launch would be strictly worse.
      AppLogger.error(
        'Local data migration failed for $uid; local data is untouched and '
        'will be retried on the next launch',
        scope: 'migration',
        error: error,
        stackTrace: stackTrace,
      );
      return MigrationResult(error: error.toString());
    }
  }

  /// The old `CacheKeys.likedTracks` blob — up to 100 `SavedTrack` rows.
  Future<int> _migrateLikedTracks(String uid) async {
    final entry = _cache.readList(CacheKeys.likedTracks);
    if (entry == null || entry.value.isEmpty) return 0;

    final tracks = <Track>[];
    for (final row in entry.value) {
      try {
        final saved = SavedTrack.fromJson(row);
        tracks.add(saved.track);
      } on Object {
        // One unreadable row must not cost the rest. The old cache was written
        // by a build whose model has since changed.
        continue;
      }
    }

    if (tracks.isEmpty) return 0;

    // Written individually rather than batched: `likeTrack` is the same call
    // the heart makes, so the documents it produces are identical to the ones a
    // fresh like would produce. A bespoke batch write here would be a second
    // definition of "a liked track" that could drift from the first.
    var written = 0;
    for (final track in tracks) {
      try {
        await _library.likeTrack(uid, track.copyWith(id: track.documentId));
        written++;
      } on Object {
        continue;
      }
    }
    return written;
  }

  /// The old `CacheKeys.userPlaylists` blob.
  ///
  /// Only the playlist records were cached, never their contents, so what comes
  /// across is a set of empty playlists carrying their Spotify `sourceId`. That
  /// is deliberately still worth doing: the user sees their playlist names
  /// again, and re-importing from Spotify fills them in and — because the
  /// `sourceId` matches — updates these rather than creating duplicates.
  Future<int> _migratePlaylists(String uid) async {
    final entry = _cache.readList(CacheKeys.userPlaylists);
    if (entry == null || entry.value.isEmpty) return 0;

    var written = 0;
    for (final row in entry.value) {
      try {
        final playlist = Playlist.fromJson(row);
        if (playlist.id.isEmpty) continue;

        // Skip anything already imported, so a user who upgraded, imported
        // from Spotify, and only then triggered this does not get a second
        // copy of every playlist.
        //
        // Checked against this user's **own** playlists rather than the shared
        // catalogue, matching where the write below goes. These rows are names
        // and source ids recovered from a local cache — no tracks, no cover, no
        // verified metadata — and publishing them into a catalogue every other
        // user searches would fill it with empty playlists. A real import of
        // the same playlist later publishes it properly and the shelf
        // de-duplicates the placeholder away; see
        // `LibraryRepository.watchPlaylists`.
        final existing = await _library.findOwnImportedPlaylist(
          uid: uid,
          source: MediaSource.spotify,
          sourceId: playlist.id,
        );
        if (existing != null) continue;

        await _library.createPlaylist(
          uid: uid,
          name: playlist.name,
          description: playlist.description,
          coverUrl: playlist.imageUrl ?? '',
          source: MediaSource.spotify,
          sourceId: playlist.id,
        );
        written++;
      } on Object {
        continue;
      }
    }
    return written;
  }

  /// The old per-Spotify-account avatar preference.
  ///
  /// The trickiest of the three, because the old key is
  /// `aurix.profile.avatar_id.{spotify user id}` and this build has a Firebase
  /// uid instead —
  /// there is no way to know which Spotify account belonged to the person now
  /// signing in.
  ///
  /// So it takes the only stored choice when there is exactly one, and gives up
  /// when there are several. A device with two previous Spotify accounts would
  /// be a coin flip, and showing someone else's avatar is worse than showing
  /// the default.
  Future<bool> _migrateAvatar(String uid) async {
    final existing = await _profiles.read(uid);
    // Already chosen on this account — never overwrite a real choice with a
    // guess at an old one.
    if (existing != null && existing.avatarId != AvatarCatalog.defaultId) {
      return false;
    }

    final stored = _storedAvatarIds();
    if (stored.length != 1) return false;

    final avatarId = stored.single;
    if (!AvatarResolver.isValid(avatarId)) return false;

    await _profiles.setAvatar(uid, avatarId);
    return true;
  }

  /// Every avatar id in preferences, whichever account it was stored against.
  Set<String> _storedAvatarIds() {
    final ids = <String>{};
    // `PreferencesStore` exposes no key enumeration by design, so the search is
    // over the catalogue rather than over the keyspace: for each known account
    // key prefix there is at most one value, and the values are what matter.
    for (final key in _prefs.keysWithPrefix(PrefKeys.profileAvatarPrefix)) {
      final value = _prefs.getString(key);
      if (value != null && value.isNotEmpty) ids.add(value);
    }
    return ids;
  }
}
