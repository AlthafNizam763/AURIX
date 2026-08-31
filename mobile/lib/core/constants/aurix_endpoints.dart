/// Every path on the AURIX API, in one place.
///
/// The counterpart of `FirestorePaths`, and it exists for the same reason that
/// did: a path built by string concatenation at the call site is a path nobody
/// checked against the server, and the failure mode — a 404 that looks like
/// missing data — is indistinguishable from an empty library.
///
/// ## The version prefix lives here and nowhere else
///
/// [prefix] is prepended by every constant below, and `Env.apiBaseUrl` is
/// deliberately stripped of a trailing `/api/v1` if someone pastes the full API
/// root into configuration. So there is exactly one place that decides which
/// version of the API this build speaks, and shipping a `/api/v2` alongside is
/// a change to that one constant plus the endpoints that moved.
abstract final class AurixEndpoints {
  static const String prefix = '/api/v1';

  // ---- Identity ----------------------------------------------------------
  static const String register = '$prefix/auth/register';
  static const String login = '$prefix/auth/login';
  static const String refresh = '$prefix/auth/refresh';
  static const String logout = '$prefix/auth/logout';
  static const String me = '$prefix/auth/me';
  static const String changePassword = '$prefix/auth/password/change';
  static const String forgotPassword = '$prefix/auth/password/forgot';
  static const String resetPassword = '$prefix/auth/password/reset';
  static const String sendVerification = '$prefix/auth/email/verify/send';
  static const String verifyEmail = '$prefix/auth/email/verify';
  static const String deleteAccount = '$prefix/auth/me';

  // ---- The other ways in -------------------------------------------------
  //
  // Everything below reaches the same place as [login] does: a session in the
  // shape `services/session.js` defines, which is the only shape
  // `ApiAuthService` knows how to store. The paths differ; the answer does not.

  /// Which sign-in methods this *deployment* offers. Public, and read before
  /// anyone has signed in — like [theme], and for the same reason: the login
  /// screen has to be drawn first.
  static const String authMethods = '$prefix/auth/methods';

  /// Unlinks one method from the signed-in account.
  static String authMethod(String provider) => '$prefix/auth/methods/$provider';

  // ---- Phone -------------------------------------------------------------
  static const String phoneStart = '$prefix/auth/phone/start';
  static const String phoneVerify = '$prefix/auth/phone/verify';
  static const String phoneLink = '$prefix/auth/phone/link';

  // ---- Social ------------------------------------------------------------
  //
  // There is deliberately no constant for the provider *callback*. That URL is
  // the server's own, it is registered in Google's and Apple's consoles rather
  // than typed here, and the app never navigates to it — the browser does.

  /// Opens a browser transaction. Returns the URL to put in front of the user.
  static String oauthStart(String provider) =>
      '$prefix/auth/oauth/$provider/start';

  /// Redeems the grant the browser came back with, for a session or a
  /// challenge to link an existing account.
  static const String oauthExchange = '$prefix/auth/oauth/exchange';

  // ---- Account linking ---------------------------------------------------
  static const String linkCode = '$prefix/auth/link/code';
  static const String linkConfirm = '$prefix/auth/link/confirm';
  static const String linkCancel = '$prefix/auth/link/cancel';

  // ---- Profile -----------------------------------------------------------
  static const String profileMe = '$prefix/profile/me';
  static const String profileEnsure = '$prefix/profile/ensure';
  static const String profileAvatar = '$prefix/profile/me/avatar';
  static const String profileStats = '$prefix/profile/me/stats';
  static String profile(String uid) => '$prefix/profile/$uid';

  // ---- Library -----------------------------------------------------------
  static const String liked = '$prefix/library/liked';
  static const String likedAmong = '$prefix/library/liked/among';
  static const String recentlyPlayed = '$prefix/library/recently-played';
  static String likedTrack(String trackId) => '$prefix/library/liked/$trackId';

  // ---- The user's own playlists -----------------------------------------
  static const String playlists = '$prefix/playlists';
  static const String findPlaylist = '$prefix/playlists/find';
  static String playlist(String id) => '$prefix/playlists/$id';
  static String playlistTracks(String id) => '$prefix/playlists/$id/tracks';
  static String playlistTracksBulk(String id) => '$prefix/playlists/$id/tracks/bulk';
  static String playlistTracksRemove(String id) => '$prefix/playlists/$id/tracks/remove';
  static String playlistTrack(String id, String trackId) =>
      '$prefix/playlists/$id/tracks/$trackId';
  static String playlistCover(String id) => '$prefix/playlists/$id/cover';
  static String playlistSynced(String id) => '$prefix/playlists/$id/synced';
  static String playlistReorder(String id) => '$prefix/playlists/$id/reorder';

  // ---- The shared playlist catalogue ------------------------------------
  static const String sharedPlaylists = '$prefix/shared-playlists';
  static const String sharedPlaylistSearch = '$prefix/shared-playlists/search';
  static const String findSharedPlaylist = '$prefix/shared-playlists/find';
  static String sharedPlaylist(String id) => '$prefix/shared-playlists/$id';
  static String sharedPlaylistTracks(String id) => '$prefix/shared-playlists/$id/tracks';
  static String sharedPlaylistTracksRemove(String id) =>
      '$prefix/shared-playlists/$id/tracks/remove';
  static String sharedPlaylistSynced(String id) => '$prefix/shared-playlists/$id/synced';
  static String sharedPlaylistsImportedBy(String uid) =>
      '$prefix/shared-playlists/imported-by/$uid';

  // ---- The shared song catalogue ----------------------------------------
  static const String catalogSongs = '$prefix/catalog/songs';
  static const String catalogSongsBatch = '$prefix/catalog/songs/batch';
  static const String catalogSongSearch = '$prefix/catalog/songs/search';
  static String catalogSong(String id) => '$prefix/catalog/songs/$id';

  // ---- Appearance --------------------------------------------------------
  static const String theme = '$prefix/theme';
  static const String themeVersion = '$prefix/theme/version';
  static const String themeOptions = '$prefix/theme/options';
  static const String themeReset = '$prefix/theme/reset';
  static const String themeLogo = '$prefix/theme/logo';
  static const String themeIcon = '$prefix/theme/icon';
  static const String themeFonts = '$prefix/theme/fonts';

  // ---- Administration ----------------------------------------------------
  static const String adminStats = '$prefix/admin/stats';
  static const String adminUsers = '$prefix/admin/users';
  static String adminUserRole(String uid) => '$prefix/admin/users/$uid/admin';

  /// Health check. Deliberately outside [prefix] — it reports on the process,
  /// not on a version of the API.
  static const String health = '/health';
}
