/// Route paths and names, in one place.
///
/// Detail routes are top-level rather than nested under a tab so that a deep
/// link (`aurix://album/xyz`) lands on the same screen regardless of which
/// tab the user was on, and so the album screen can push over the shell with
/// the mini player still visible.
abstract final class Routes {
  // Shell-less
  static const String splash = '/';
  static const String onboarding = '/welcome';
  static const String login = '/login';
  static const String setup = '/setup';

  // Shell tabs
  static const String home = '/home';
  static const String search = '/search';
  static const String library = '/library';
  static const String playlists = '/playlists';

  // Detail
  static const String album = '/album/:id';
  static const String artist = '/artist/:id';
  static const String playlist = '/playlist/:id';
  static const String category = '/category/:id';
  static const String searchResults = '/search/results';

  // Modal-ish
  static const String player = '/player';
  static const String queue = '/queue';
  static const String devices = '/devices';

  // Account
  /// A pushed page on the root navigator, *not* a shell tab — reach it with
  /// `pushDistinct`, never with `goNamed`.
  ///
  /// It was a tab once, and the note here still said so long after it stopped
  /// being one. `go` sets the whole route stack from a location, so going to a
  /// top-level route like this one replaces the shell rather than covering it:
  /// the tabs are torn down, Profile becomes the only page in the stack, and
  /// the next Back press finds nothing beneath it and closes the app. Pushing
  /// keeps the shell underneath, which is what puts the user back on the tab
  /// they came from.
  static const String profile = '/profile';

  /// Nested under [profile] so Back lands on the profile it was opened from
  /// rather than on whichever tab is underneath the shell.
  static const String editProfile = '/profile/edit';
  static const String settings = '/settings';
  static const String about = '/settings/about';
  static const String likedSongs = '/library/liked';

  /// Bringing playlists in from another service.
  ///
  /// Nested under [settings] because that is where the entry point lives, and
  /// because the nesting is the statement: importing is a *setting*, an
  /// occasional deliberate act, not one of the app's destinations. The whole of
  /// AURIX works with nothing here ever having been opened.
  static const String importMusic = '/settings/import';
  static String importProviderPath(String provider) =>
      '/settings/import/$provider';

  /// Import one playlist from a pasted link.
  ///
  /// A sibling of the per-provider flow rather than a child of it, because it
  /// is not a provider's flow at all: the link decides the source, so there is
  /// no provider to choose before arriving here.
  static const String importPlaylist = '/settings/import/link';

  // ---- Builders ---------------------------------------------------------
  static String albumPath(String id) => '/album/$id';
  static String artistPath(String id) => '/artist/$id';
  static String playlistPath(String id) => '/playlist/$id';
  static String categoryPath(String id) => '/category/$id';
  static String searchResultsPath(String query) =>
      '/search/results?q=${Uri.encodeQueryComponent(query)}';
}

/// Named routes for `goNamed` / `pushNamed`.
abstract final class RouteNames {
  static const String splash = 'splash';
  static const String onboarding = 'onboarding';
  static const String login = 'login';
  static const String setup = 'setup';
  static const String home = 'home';
  static const String search = 'search';
  static const String library = 'library';
  static const String playlists = 'playlists';
  static const String album = 'album';
  static const String artist = 'artist';
  static const String playlist = 'playlist';
  static const String category = 'category';
  static const String searchResults = 'searchResults';
  static const String player = 'player';
  static const String queue = 'queue';
  static const String devices = 'devices';
  static const String profile = 'profile';
  static const String editProfile = 'editProfile';
  static const String settings = 'settings';
  static const String about = 'about';
  static const String likedSongs = 'likedSongs';
  static const String importMusic = 'importMusic';
  static const String importProvider = 'importProvider';
  static const String importPlaylist = 'importPlaylist';
}
