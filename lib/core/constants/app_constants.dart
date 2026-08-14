/// Application-wide constants that are not colours, sizes or endpoints.
abstract final class AppConstants {
  static const String appName = 'AURIX';
  static const String appTagline = 'Your sound. Your universe.';

  /// Identifier used in the Android media notification channel and iOS
  /// background audio session.
  static const String audioNotificationChannelId = 'com.aurix.app.audio';
  static const String audioNotificationChannelName = 'AURIX playback';

  /// Shown under the channel's name in Android's notification settings.
  ///
  /// Worth writing rather than leaving blank, because this channel is the one
  /// a user is most likely to go looking for: switching it off is what removes
  /// the media controls, and the sentence has to make clear that doing so does
  /// not stop the music.
  static const String audioNotificationChannelDescription =
      'Playback controls for the track AURIX is playing. '
      'Turning this off hides the controls; it does not stop playback.';

  /// Deep-link host used when building shareable links.
  static const String deepLinkScheme = 'aurix';
  static const String webFallbackHost = 'open.spotify.com';

  // ---- Networking -------------------------------------------------------
  static const Duration connectTimeout = Duration(seconds: 15);
  static const Duration receiveTimeout = Duration(seconds: 20);
  static const Duration sendTimeout = Duration(seconds: 20);

  /// How many times a request is retried on a transient failure.
  static const int maxRetries = 2;

  /// Refresh the access token this long before it actually expires, so a
  /// long-running request never starts with a token that dies mid-flight.
  static const Duration tokenRefreshLeeway = Duration(seconds: 60);

  // ---- Paging -----------------------------------------------------------
  static const int defaultPageSize = 20;
  static const int largePageSize = 50;

  /// Spotify caps most `limit` parameters at 50.
  static const int maxPageSize = 50;

  /// `/search` is capped far lower than everything else.
  ///
  /// Spotify's February 2026 changes cut the search `limit` maximum from 50 to
  /// 10 (and the default from 20 to 5) for apps in Development Mode. Asking
  /// for more is a flat `400`, so search fails *completely* rather than
  /// returning a short page — which is what a 20-item request did.
  ///
  /// 10 is safe on every quota mode: an app with extended access simply gets
  /// smaller pages, and paging is driven by how many items are already loaded
  /// rather than by a fixed page size, so nothing else has to change.
  /// See https://developer.spotify.com/documentation/web-api/references/changes/february-2026
  static const int maxSearchPageSize = 10;

  /// Spotify caps `/me/top/*` offsets; requesting beyond this returns 404
  /// rather than an empty page.
  static const int maxTopItemsOffset = 950;

  /// The `/me/library` family accepts at most 40 URIs per request.
  ///
  /// Applies to all three verbs — `PUT`, `DELETE` and `GET …/contains` — and is
  /// lower than every per-type limit it replaced (50 for tracks, 20 for
  /// albums), so a straight port of any old chunk size would `400` on a full
  /// page rather than degrade.
  static const int maxLibraryContainsUris = 40;

  // ---- Interaction ------------------------------------------------------
  static const Duration searchDebounce = Duration(milliseconds: 350);
  static const int maxRecentSearches = 12;
  static const int maxRecentlyViewed = 40;

  // ---- Caching ----------------------------------------------------------
  /// Metadata cache lifetime. Only metadata is cached — never audio.
  static const Duration metadataCacheTtl = Duration(hours: 6);
  static const Duration homeCacheTtl = Duration(minutes: 30);

  // ---- Animation --------------------------------------------------------
  static const Duration fast = Duration(milliseconds: 160);
  static const Duration medium = Duration(milliseconds: 280);
  static const Duration slow = Duration(milliseconds: 450);
  static const Duration splashHold = Duration(milliseconds: 1600);

  // ---- External links ---------------------------------------------------

  /// Where AURIX's own backend is configured. The setup screen links it.
  static const String firebaseConsoleUrl = 'https://console.firebase.google.com';

  // The Spotify links below serve the optional import provider and the
  // playback provider that still drives full-track playback. Nothing on the
  // sign-in path uses them any more.
  static const String spotifyDashboardUrl = 'https://developer.spotify.com/dashboard';
  static const String spotifyPremiumUrl = 'https://www.spotify.com/premium/';

  /// Where to send someone who has no Spotify app installed.
  ///
  /// The https form rather than `market://` so the same constant works on both
  /// platforms: Android resolves it to the Play Store app, iOS to the App
  /// Store. App Remote cannot play anything without this installed, so this is
  /// the one remedy that actually unblocks mobile playback.
  static const String spotifyInstallUrl =
      'https://play.google.com/store/apps/details?id=com.spotify.music';
  static const String spotifyTermsUrl = 'https://developer.spotify.com/terms';
}
