/// Every Spotify Web API path AURIX talks to, in one place.
///
/// Paths are relative to [apiBaseUrl] unless documented otherwise.
///
/// ## A note on availability
///
/// Spotify has narrowed what a Development Mode application may call twice:
/// on 27 November 2024 (Recommendations, Audio Features, Related Artists,
/// Featured Playlists, Category Playlists) and again in February 2026
/// (`/browse/*`, `/artists/{id}/top-tracks`, multi-ID batch gets,
/// `/users/{id}`, `/markets`).
///
/// AURIX no longer calls the endpoints in either group that it cannot use.
/// They are **absent from this file**, not listed-and-retried: an endpoint
/// that answers `403` for every request this application will ever make is not
/// a fallback candidate, it is dead weight that costs a round trip and fills
/// the log with noise. What replaced them is documented in
/// `docs/API_LIMITATIONS.md`.
///
/// The rule for adding anything here: it must be an endpoint a Development
/// Mode app can actually call, or it must have a real, reachable fallback.
abstract final class SpotifyEndpoints {
  static const String apiBaseUrl = 'https://api.spotify.com/v1';
  static const String accountsBaseUrl = 'https://accounts.spotify.com';

  // ---- OAuth (absolute URLs — these are not on api.spotify.com) ---------
  static const String authorize = '$accountsBaseUrl/authorize';
  static const String token = '$accountsBaseUrl/api/token';

  // ---- Current user -----------------------------------------------------
  static const String me = '/me';
  static const String myTopArtists = '/me/top/artists';
  static const String myTopTracks = '/me/top/tracks';
  static const String myPlaylists = '/me/playlists';

  /// `GET /me/tracks` — still the current way to *list* saved tracks.
  ///
  /// February 2026 consolidated the library **writes** and the membership
  /// check, not the reads: `PUT`/`DELETE /me/tracks` were replaced by
  /// [library], and `GET /me/tracks/contains` by [libraryContains]. There is no
  /// `GET /me/library` collection endpoint — `GET /me/tracks` and
  /// `GET /me/albums` are undeprecated and remain the only way to page a
  /// user's saved items. Only the verbs moved.
  static const String mySavedTracks = '/me/tracks';
  static const String mySavedAlbums = '/me/albums';

  /// `PUT /me/library?uris=…` and `DELETE /me/library?uris=…`
  ///
  /// The February 2026 replacement for every per-type library write:
  /// `PUT`/`DELETE` on `/me/{tracks,albums,episodes,shows,audiobooks}`, on
  /// `/me/following`, and on `/playlists/{id}/followers`. Those paths now
  /// answer `403` to a Development Mode application — which is exactly the
  /// `✗ 403 PUT /me/tracks` in the logs, and why the heart never filled.
  ///
  /// Three things differ from the endpoints it replaces, and all three break a
  /// naive port:
  ///  * it takes **Spotify URIs**, not bare IDs;
  ///  * `uris` is a **query parameter**, not a JSON body — the old endpoints
  ///    took `{"ids": [...]}` in the body, and sending that here is a `400`;
  ///  * the cap is **40** URIs, not 50 (tracks) or 20 (albums).
  ///
  /// Scope: `user-library-modify`.
  /// See https://developer.spotify.com/documentation/web-api/reference/save-library-items
  static const String library = '/me/library';

  /// `GET /me/library/contains?uris=…`
  ///
  /// Replaced the per-type `/me/{tracks,albums,episodes,shows,audiobooks}
  /// /contains` endpoints in February 2026, which now answer `403` to a
  /// Development Mode application.
  ///
  /// Three things differ from the endpoints it replaced, and all three break
  /// a naive port:
  ///  * it takes **Spotify URIs**, not bare IDs;
  ///  * one call covers every type, so tracks and albums no longer need
  ///    separate requests;
  ///  * the cap is **40** URIs, not 50.
  ///
  /// The response is a bare array of booleans, positionally aligned with
  /// `uris`. See https://developer.spotify.com/documentation/web-api/reference/check-library-contains
  static const String libraryContains = '/me/library/contains';

  /// `/me/following?type=artist` — **artists only**, and still current.
  ///
  /// Artist follows are the one relationship the consolidation left behind.
  /// [library] documents its accepted URI types as tracks, albums, episodes,
  /// shows, audiobooks, users and playlists — `spotify:artist:` is absent from
  /// that list, so routing artist follows through it would trade a working
  /// call for a `400`. Left here deliberately, not by omission.
  static const String myFollowing = '/me/following';

  /// `GET /me/following/contains?type=artist&ids=…`
  ///
  /// Superseded by [libraryContains] for users and playlists, but kept for
  /// artists for the reason above. Calls still degrade through
  /// `getBoolArray`, which remembers a refusal rather than re-asking.
  static const String myFollowingContains = '/me/following/contains';

  static String userProfile(String userId) => '/users/$userId';
  static String userPlaylists(String userId) => '/users/$userId/playlists';

  // ---- Player (Spotify Connect — Premium required for write calls) ------
  static const String playerState = '/me/player';
  static const String playerDevices = '/me/player/devices';
  static const String playerCurrentlyPlaying = '/me/player/currently-playing';
  static const String playerRecentlyPlayed = '/me/player/recently-played';
  static const String playerPlay = '/me/player/play';
  static const String playerPause = '/me/player/pause';
  static const String playerNext = '/me/player/next';
  static const String playerPrevious = '/me/player/previous';
  static const String playerSeek = '/me/player/seek';
  static const String playerShuffle = '/me/player/shuffle';
  static const String playerRepeat = '/me/player/repeat';
  static const String playerVolume = '/me/player/volume';
  static const String playerQueue = '/me/player/queue';
  static const String playerTransfer = '/me/player';

  // ---- Catalogue --------------------------------------------------------
  static const String search = '/search';
  static const String albums = '/albums';
  static const String artists = '/artists';
  static const String tracks = '/tracks';

  static String album(String id) => '/albums/$id';
  static String albumTracks(String id) => '/albums/$id/tracks';
  static String artist(String id) => '/artists/$id';
  static String artistTopTracks(String id) => '/artists/$id/top-tracks';
  static String artistAlbums(String id) => '/artists/$id/albums';
  static String track(String id) => '/tracks/$id';
  static String playlist(String id) => '/playlists/$id';

  /// A playlist's contents, current spelling.
  ///
  /// Spotify's February 2026 changes renamed a playlist's contents from
  /// `tracks` to `items` on the detail response, and `/playlists/{id}/items`
  /// is the matching collection endpoint. The model already parsed both
  /// spellings; only this constant was left behind, so the fallback path
  /// pointed at the legacy endpoint alone.
  static String playlistItems(String id) => '/playlists/$id/items';

  /// The pre-2026 spelling, still live for many applications.
  ///
  /// Kept because which of the two answers depends on the application's quota
  /// mode and registration date, and picking one at build time is what makes a
  /// playlist render as empty on the accounts that got the other.
  static String playlistTracks(String id) => '/playlists/$id/tracks';

  static String playlistFollowers(String id) => '/playlists/$id/followers';
  static String playlistImages(String id) => '/playlists/$id/images';

  // ---- Browse -----------------------------------------------------------
  //
  // Deliberately empty. Every `/browse/*` endpoint AURIX used to call is
  // unavailable to a Development Mode application:
  //
  //   /browse/new-releases              removed February 2026
  //   /browse/categories                removed February 2026
  //   /browse/categories/{id}           removed February 2026
  //   /browse/categories/{id}/playlists restricted November 2024
  //   /browse/featured-playlists        restricted November 2024
  //
  // The Home shelves and genre tiles that used them are now built from the
  // signed-in user's own endpoints and from `/search`, which are available.
  // See HomeRepository and SpotifyBrowseService.
}
