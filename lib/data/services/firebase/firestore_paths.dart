import 'package:cloud_firestore/cloud_firestore.dart';

/// The shape of AURIX's Firestore database, in one place.
///
/// Every collection reference in the app is built here rather than by
/// concatenating strings at the call site. That is not tidiness — it is what
/// makes the security rules auditable. `firestore.rules` grants access by path,
/// so a path typed by hand somewhere in a repository is a path nobody checked
/// against the rules, and the failure mode is either a permission error in
/// production or, worse, a document written somewhere the rules do not cover.
///
/// ## The layout
///
/// ```
/// /catalog/songs/{songId}                        Song       (shared, global)
///
/// /users/{uid}                                   AurixUser
///   /playlists/{playlistId}                      Playlist
///     /tracks/{trackId}                          Track      (+ position)
///   /likedTracks/{trackId}                       Track
///   /recentlyPlayed/{itemId}                     play history entry
///   /settings/{settingId}                        user settings documents
/// ```
///
/// Everything a user owns is nested under their own `/users/{uid}` document.
/// This is the single most important property of the schema: it makes the rule
/// that authorises a write one line — `request.auth.uid == uid` — and it makes
/// that one line cover every collection here, including ones added later.
///
/// A flat top-level `playlists` collection with an `ownerUid` field would have
/// been the alternative. It was not chosen: it needs a rule per collection, it
/// needs every query to remember its `where('ownerUid')` clause or leak, and a
/// document written without that field is invisible to its owner and readable
/// by a rule that forgot to check it.
///
/// ## The catalogue is the one exception, and why
///
/// `/catalog/songs` sits outside `/users` because it is deliberately *shared*:
/// it is what makes a song imported by one user findable in global search
/// rather than only inside the playlist it arrived in, and what stops the same
/// song being stored once per user who imports it.
///
/// Being shared, it cannot use the one-line ownership rule — nobody owns it —
/// so it gets the only other rule in the database, and that rule is
/// correspondingly strict: readable by any signed-in user, creatable only in
/// the exact shape [Song.toFirestore] produces, updatable only in the narrow
/// set of metadata fields a re-import may improve, and **never deletable by a
/// client**. See the `/catalog/songs` block in `firestore.rules`, which is the
/// security boundary this comment describes.
///
/// A user's playlist still holds its own copy of each track row. That is not
/// redundancy to be optimised away: the copy is what carries the playlist's
/// `position`, what keeps a playlist readable offline, and what means a
/// catalogue change can never silently rewrite a playlist the user arranged.
abstract final class FirestorePaths {
  static const String users = 'users';
  static const String playlists = 'playlists';
  static const String tracks = 'tracks';
  static const String likedTracks = 'likedTracks';
  static const String recentlyPlayed = 'recentlyPlayed';
  static const String settings = 'settings';

  /// The shared catalogue root.
  static const String catalog = 'catalog';
  static const String songs = 'songs';

  /// The catalogue partition. See [catalogSongs] for why there is one at all.
  static const String catalogPartition = 'global';

  /// `/catalog/global/songs/{songId}`
  ///
  /// ## Why not the literal `catalog/songs/{songId}`
  ///
  /// Because Firestore cannot represent it. Path segments alternate
  /// collection → document → collection → document, so a three-segment path is
  /// a *collection*, not a document: `catalog/songs/{songId}` names a
  /// collection whose id happens to be a wildcard, which holds nothing and
  /// which a security rule cannot match with an `allow` on a document.
  ///
  /// The four-segment form is the same idea, spelled legally. `global` is a
  /// fixed partition document — it holds no fields and exists only to make the
  /// path valid, which is ordinary Firestore practice for exactly this case.
  ///
  /// Keeping the `catalog/…/songs` shape rather than flattening to a top-level
  /// `songs` collection buys two things: the rules can treat `/catalog/**` as
  /// one boundary, and a later catalogue collection — albums, artists — nests
  /// beside this one instead of adding another root collection with its own
  /// rule block to keep in step.
  static CollectionReference<Map<String, dynamic>> catalogSongs(
    FirebaseFirestore db,
  ) => db.collection(catalog).doc(catalogPartition).collection(songs);

  /// `/catalog/global/songs/{songId}`
  static DocumentReference<Map<String, dynamic>> catalogSong(
    FirebaseFirestore db,
    String songId,
  ) => catalogSongs(db).doc(songId);

  /// `/users`
  static CollectionReference<Map<String, dynamic>> usersCollection(
    FirebaseFirestore db,
  ) => db.collection(users);

  /// `/users/{uid}`
  static DocumentReference<Map<String, dynamic>> user(
    FirebaseFirestore db,
    String uid,
  ) => usersCollection(db).doc(uid);

  /// `/users/{uid}/playlists`
  static CollectionReference<Map<String, dynamic>> playlistsOf(
    FirebaseFirestore db,
    String uid,
  ) => user(db, uid).collection(playlists);

  /// `/users/{uid}/playlists/{playlistId}`
  static DocumentReference<Map<String, dynamic>> playlist(
    FirebaseFirestore db,
    String uid,
    String playlistId,
  ) => playlistsOf(db, uid).doc(playlistId);

  /// `/users/{uid}/playlists/{playlistId}/tracks`
  static CollectionReference<Map<String, dynamic>> playlistTracks(
    FirebaseFirestore db,
    String uid,
    String playlistId,
  ) => playlist(db, uid, playlistId).collection(tracks);

  /// `/users/{uid}/likedTracks`
  static CollectionReference<Map<String, dynamic>> likedTracksOf(
    FirebaseFirestore db,
    String uid,
  ) => user(db, uid).collection(likedTracks);

  /// `/users/{uid}/recentlyPlayed`
  static CollectionReference<Map<String, dynamic>> recentlyPlayedOf(
    FirebaseFirestore db,
    String uid,
  ) => user(db, uid).collection(recentlyPlayed);

  /// `/users/{uid}/settings`
  static CollectionReference<Map<String, dynamic>> settingsOf(
    FirebaseFirestore db,
    String uid,
  ) => user(db, uid).collection(settings);
}

/// Field names shared across documents.
///
/// Spelled out as constants for the fields that appear in queries and in
/// `firestore.rules`. A typo in a `where()` clause is silent — Firestore
/// returns an empty result for a field that does not exist rather than an
/// error — so the ones that order or filter a collection are named here.
abstract final class FirestoreFields {
  static const String createdAt = 'createdAt';
  static const String updatedAt = 'updatedAt';
  static const String playedAt = 'playedAt';

  /// Sort key within a playlist. A double, not an int — see
  /// `FirestorePlaylistService.reorder` for why that matters.
  static const String position = 'position';

  static const String trackCount = 'trackCount';
  static const String source = 'source';
  static const String sourceId = 'sourceId';
  static const String name = 'name';

  /// The prefix-token array that global search queries with `array-contains`.
  ///
  /// On catalogue songs and on playlist documents alike. Named here because a
  /// typo in it is the silent kind of bug: Firestore returns an empty result
  /// for a field that does not exist rather than an error, so search would
  /// simply find nothing and look like it was working.
  static const String searchTokens = 'searchTokens';

  /// The canonical source URL of an imported playlist, tracking parameters
  /// stripped. Part of the duplicate-import check.
  static const String sourceUrl = 'sourceUrl';

  /// When an imported playlist was last re-synced against its source.
  static const String syncedAt = 'syncedAt';
}
