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
abstract final class FirestorePaths {
  static const String users = 'users';
  static const String playlists = 'playlists';
  static const String tracks = 'tracks';
  static const String likedTracks = 'likedTracks';
  static const String recentlyPlayed = 'recentlyPlayed';
  static const String settings = 'settings';

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
}
