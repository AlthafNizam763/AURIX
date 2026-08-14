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
/// /playlists/{playlistId}                        Playlist   (shared, global)
///   /tracks/{trackId}                            Track      (+ position)
///
/// /users/{uid}                                   AurixUser
///   /playlists/{playlistId}                      Playlist   (private)
///     /tracks/{trackId}                          Track      (+ position)
///   /likedTracks/{trackId}                       Track      (private)
///   /recentlyPlayed/{itemId}                     play history entry (private)
///   /settings/{settingId}                        user settings documents
/// ```
///
/// Everything a user *owns* is nested under their own `/users/{uid}` document.
/// This is the single most important property of the schema: it makes the rule
/// that authorises a write one line — `request.auth.uid == uid` — and it makes
/// that one line cover every collection there, including ones added later.
///
/// ## The two shared collections, and why they sit outside `/users`
///
/// `/catalog/songs` and `/playlists` are deliberately *shared*. They are what
/// make an import a contribution to AURIX rather than a private copy:
///
///  * **`/catalog/songs`** makes a song imported by one user findable in global
///    search rather than only inside the playlist it arrived in, and stops the
///    same song being stored once per user who imports it.
///  * **`/playlists`** does the same for the playlist itself. User A imports
///    "Love" and User C can find it, open it and play it — see
///    [globalPlaylists]. This is the *only* reason it is a top-level collection
///    rather than a subcollection: a subcollection of `/users/{uid}` cannot be
///    read by anybody else without a rule that reads like a mistake.
///
/// Neither can use the one-line ownership rule — nobody owns them — so each
/// gets a strict *shape* rule instead: readable by any signed-in account,
/// creatable only in the exact shape the model produces, updatable only in the
/// narrow set of fields a re-import may legitimately improve, and deletable by
/// nobody (songs) or by the importer alone (playlists). See the matching blocks
/// in `firestore.rules`, which are the security boundary this comment
/// describes.
///
/// What stays private stays private. Liked songs, play history, the profile,
/// per-account settings and playlists the user built here are all still under
/// `/users/{uid}` and still readable only by that account. Sharing the
/// *imported catalogue* is not sharing the *library*.
///
/// A user's own playlist still holds its own copy of each track row. That is
/// not redundancy to be optimised away: the copy is what carries the playlist's
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

  // ---- The shared playlist catalogue --------------------------------------

  /// `/playlists` — every playlist any user has imported, shared by all.
  ///
  /// ## Why this is top-level and not `/users/{uid}/playlists`
  ///
  /// Because discovery is the requirement. An imported playlist is a
  /// contribution to AURIX's catalogue, not a private copy: User A imports
  /// "Love", and User B and User C must be able to search it, open it and play
  /// it without being the importer. A subcollection of `/users/{uid}` cannot
  /// express that — the path itself is the ownership claim, and the rule that
  /// let other accounts read it would be indistinguishable from a leak.
  ///
  /// So provenance moves from the *path* into *fields*: `importedByUserId`,
  /// `importedBy` and `importedAt` record who brought the playlist in, and none
  /// of them narrows who may read it. That distinction — recorded, not
  /// enforcing — is the whole design.
  ///
  /// Document ids come from [PlaylistKey], derived from
  /// (`source`, `sourceId`), so the same source playlist imported by two
  /// accounts addresses one document. See the class comment there for why
  /// de-duplication is structural rather than a check.
  static CollectionReference<Map<String, dynamic>> globalPlaylists(
    FirebaseFirestore db,
  ) => db.collection(playlists);

  /// `/playlists/{playlistId}`
  static DocumentReference<Map<String, dynamic>> globalPlaylist(
    FirebaseFirestore db,
    String playlistId,
  ) => globalPlaylists(db).doc(playlistId);

  /// `/playlists/{playlistId}/tracks`
  ///
  /// One copy of the track list, read by every user who opens the playlist —
  /// not one copy per user. That is the point of the tracks living under the
  /// shared document rather than being duplicated into each importer's library.
  static CollectionReference<Map<String, dynamic>> globalPlaylistTracks(
    FirebaseFirestore db,
    String playlistId,
  ) => globalPlaylist(db, playlistId).collection(tracks);

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

  // ---- Provenance on a shared playlist ------------------------------------
  //
  // Recorded, never enforcing. These three say who brought a playlist into the
  // shared catalogue; not one of them appears in a search or read query, and
  // the security rules use `importedByUserId` only to decide who may *delete*.
  // Filtering discovery by any of them would undo the architecture — see
  // FirestorePaths.globalPlaylists.

  /// The Firebase uid of the account that first imported this playlist.
  static const String importedByUserId = 'importedByUserId';

  /// The display name of that account, denormalised so a search result can
  /// credit the importer without a second read per row.
  static const String importedBy = 'importedBy';

  /// When the playlist first entered the shared catalogue. Never moved by a
  /// later re-sync, including one run by a different account.
  static const String importedAt = 'importedAt';

  /// The playlist title, normalised for comparison — lower-cased, accent-folded
  /// and stripped of punctuation.
  ///
  /// Not what search *queries*: that is [searchTokens], because Firestore
  /// cannot prefix-match the middle of a field. This is what lets a result page
  /// rank an exact title match above a prefix match without re-normalising
  /// every row client-side, and it is legible in the console.
  static const String searchTitle = 'searchTitle';
}
