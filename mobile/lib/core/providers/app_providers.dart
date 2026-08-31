import 'package:dio/dio.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../data/import/playlist_fetcher.dart';
import '../../data/import/playlist_import_service.dart';
import '../../data/import/providers/spotify_playlist_fetcher.dart';
import '../../data/import/providers/youtube_playlist_fetcher.dart';
import '../../data/migration/local_data_migration.dart';
import '../../data/repositories/auth_repository.dart';
import '../../data/repositories/catalog_repository.dart';
import '../../data/repositories/catalogue_repository.dart';
import '../../data/repositories/home_repository.dart';
import '../../data/repositories/library_repository.dart';
import '../../data/repositories/lyrics_repository.dart';
import '../../data/repositories/playlist_catalog_repository.dart';
import '../../data/repositories/search_repository.dart';
import '../../data/search/catalog_search_provider.dart';
import '../../data/search/library_search_provider.dart';
import '../../data/search/playlist_catalog_search_provider.dart';
import '../../data/search/search_provider.dart';
import '../../data/search/spotify_search_provider.dart';
import '../../data/services/api/api_auth_service.dart';
import '../../data/services/api/api_catalog_service.dart';
import '../../data/services/api/api_global_playlist_service.dart';
import '../../data/services/api/api_library_service.dart';
import '../../data/services/api/api_music_service.dart';
import '../../data/services/api/api_playlist_service.dart';
import '../../data/services/api/api_profile_service.dart';
import '../../data/services/api/api_session.dart';
import '../../data/services/api/api_theme_service.dart';
import '../../data/services/api/aurix_session_store.dart';
import '../../data/services/api/live_query.dart';
import '../../data/services/lyrics_service.dart';
import '../../data/services/spotify_album_service.dart';
import '../../data/services/spotify_api_service.dart';
import '../../data/services/spotify_app_remote_service.dart';
import '../../data/services/spotify_artist_service.dart';
import '../../data/services/spotify_auth_service.dart';
import '../../data/services/spotify_browse_service.dart';
import '../../data/services/spotify_player_service.dart';
import '../../data/services/spotify_playlist_service.dart';
import '../../data/services/spotify_recommendation_service.dart';
import '../../data/services/spotify_search_service.dart';
import '../../data/services/spotify_user_service.dart';
import '../../data/services/youtube_api_service.dart';
import '../../features/library/providers/library_provider.dart';
import '../../playback/background_island_channel.dart';
import '../../playback/media_permissions.dart';
import '../../playback/preview_audio_handler.dart';
import '../network/aurix_api_client.dart';
import '../network/connectivity_service.dart';
import '../network/dio_client.dart';
import '../storage/metadata_cache.dart';
import '../storage/preferences_store.dart';
import '../storage/secure_store.dart';
import '../theme/font_registry.dart';
import '../theme/player_themes.dart';
import '../theme/theme_config.dart';
import '../theme/theme_controller.dart';
import '../utils/album_palette.dart';

/// Dependency graph for AURIX.
///
/// Four providers at the top are *overridden in `main`* rather than
/// constructed lazily, because they need async setup that must complete before
/// the first frame — reading them without the override is a programming error,
/// so they throw a message that says exactly what to do.
///
/// Everything below them is constructed lazily and wired by hand. Explicit
/// wiring is the point: the arrows are readable, and swapping any service for
/// a fake in a test is one `overrideWithValue` away.

// ---------------------------------------------------------------------------
// Bootstrapped singletons — see `bootstrap()` in main.dart
// ---------------------------------------------------------------------------

final preferencesStoreProvider = Provider<PreferencesStore>(
  (ref) => throw UnimplementedError(
    'preferencesStoreProvider must be overridden in main() — see bootstrap()',
  ),
);

final audioHandlerProvider = Provider<PreviewAudioHandler>(
  (ref) => throw UnimplementedError(
    'audioHandlerProvider must be overridden in main() — see bootstrap()',
  ),
);

final connectivityServiceProvider = Provider<ConnectivityService>(
  (ref) => throw UnimplementedError(
    'connectivityServiceProvider must be overridden in main() — see bootstrap()',
  ),
);

/// Overridden in `main()` so the whole graph shares the instance the session
/// was restored from. The default exists for widget tests, which construct one
/// and never write to it.
final secureStoreProvider = Provider<SecureStore>((ref) => FlutterSecureStore());

// ---------------------------------------------------------------------------
// The AURIX API — the backend
// ---------------------------------------------------------------------------
//
// These sit above everything else in the graph because they are what the app is
// built on. All three are constructed in `bootstrap()` and overridden here,
// because the session has to be read from the keystore before the first frame
// and the API client has to be the same instance that owns the refresh.
//
// The shape of this block is the migration in miniature. There is no
// "connect to the database" step, because the app has no database connection:
// it has an HTTP client pointed at a server that does. MongoDB appears nowhere
// in this file, in this package, or in the built binary.

/// The signed-in session — tokens and the cached user record.
final sessionStoreProvider = Provider<AurixSessionStore>(
  (ref) => throw UnimplementedError(
    'sessionStoreProvider must be overridden in main() — see bootstrap()',
  ),
);

/// The HTTP client every AURIX read and write goes through.
///
/// One instance for the whole app, and for a reason directly analogous to the
/// one that made the Firestore handle a singleton: connection pooling and the
/// single-flight token refresh in its auth interceptor only work if they see
/// all the traffic. A second client would refresh the token underneath the
/// first and invalidate it.
final aurixApiClientProvider = Provider<AurixApiClient>(
  (ref) => throw UnimplementedError(
    'aurixApiClientProvider must be overridden in main() — see bootstrap()',
  ),
);

/// Pushes the configured "outside player" variant into the media session.
///
/// The audio handler is built in `bootstrap()`, long before any theme has been
/// read, and it outlives every theme change after that — so it cannot take the
/// style as a constructor argument. This provider is the bridge: it watches the
/// one variant that surface uses and assigns it whenever it changes.
///
/// Mounted with `ref.listen` in `app.dart` rather than watched by a widget,
/// because nothing in the tree renders from it: the notification is drawn by
/// the OS, and this only tells the OS what to draw.
final outsidePlayerSyncProvider = Provider<void>((ref) {
  final style = OutsidePlayerStyle.of(
    ref.watch(playerVariantProvider(PlayerSurface.outside)),
  );
  ref.watch(audioHandlerProvider).outsideStyle = style;
});

/// The change bus that feeds every `watch…` stream in the data layer.
///
/// What replaced Firestore's snapshot listeners. See [LiveQueries] for what it
/// does, and — more importantly — for what it deliberately does not do.
final liveQueriesProvider = Provider<LiveQueries>((ref) {
  final live = LiveQueries();
  ref.onDispose(live.dispose);
  return live;
});

/// Who the app believes is signed in.
///
/// Read from [AurixSessionStore] rather than from the app's own auth state,
/// which can lag it by a frame or hold a uid from a session that has since been
/// revoked. Under Firestore this mattered because the security rules read
/// Firebase directly and a guard consulting a different source could pass while
/// the write was refused. It matters less now — the API resolves the account
/// from the token itself and cannot be talked into another one — but consulting
/// the same source the request will is still the right habit.
final aurixSessionProvider = Provider<AurixSession>(
  (ref) => AurixSession(store: ref.watch(sessionStoreProvider)),
);

final apiAuthServiceProvider = Provider<ApiAuthService>(
  (ref) => ApiAuthService(
    client: ref.watch(aurixApiClientProvider),
    session: ref.watch(sessionStoreProvider),
  ),
);

final apiProfileServiceProvider = Provider<ApiProfileService>(
  (ref) => ApiProfileService(
    client: ref.watch(aurixApiClientProvider),
    session: ref.watch(sessionStoreProvider),
    live: ref.watch(liveQueriesProvider),
  ),
);

final apiLibraryServiceProvider = Provider<ApiLibraryService>(
  (ref) => ApiLibraryService(
    client: ref.watch(aurixApiClientProvider),
    live: ref.watch(liveQueriesProvider),
  ),
);

final apiPlaylistServiceProvider = Provider<ApiPlaylistService>(
  (ref) => ApiPlaylistService(
    client: ref.watch(aurixApiClientProvider),
    live: ref.watch(liveQueriesProvider),
    session: ref.watch(aurixSessionProvider),
    catalog: ref.watch(apiGlobalPlaylistServiceProvider),
  ),
);

/// The shared playlist catalogue.
///
/// The second collection in the database that is not owned by the account
/// reading it. It is what makes a playlist imported by one user searchable,
/// openable and playable by every other signed-in user — see
/// [ApiGlobalPlaylistService] for why provenance is recorded in fields rather
/// than expressed in the query.
final apiGlobalPlaylistServiceProvider = Provider<ApiGlobalPlaylistService>(
  (ref) => ApiGlobalPlaylistService(
    client: ref.watch(aurixApiClientProvider),
    live: ref.watch(liveQueriesProvider),
    session: ref.watch(aurixSessionProvider),
  ),
);

/// Playlist import, and the provider connections it needs.
///
/// The whole of the Spotify and YouTube integration for import is behind this
/// one service now. The app holds no client secret, no provider token and no
/// paging loop — it asks the API whether a provider is connected, asks it for a
/// consent URL, and posts a link. See [ApiMusicService].
final apiMusicServiceProvider = Provider<ApiMusicService>(
  (ref) => ApiMusicService(client: ref.watch(aurixApiClientProvider)),
);

/// Connection status for the import screen.
///
/// A future rather than a stream: it changes only when the user presses
/// Connect or Disconnect, and both of those invalidate it explicitly. Polling
/// a row that changes twice a year would be waste.
final musicConnectionsProvider = FutureProvider<List<MusicConnection>>(
  (ref) => ref.watch(apiMusicServiceProvider).connections(),
);

/// The shared song catalogue.
///
/// The other collection nobody owns. Every import contributes to it and every
/// signed-in account searches it.
final apiCatalogServiceProvider = Provider<ApiCatalogService>(
  (ref) => ApiCatalogService(
    client: ref.watch(aurixApiClientProvider),
    live: ref.watch(liveQueriesProvider),
  ),
);

// ---------------------------------------------------------------------------
// Appearance
// ---------------------------------------------------------------------------
//
// The two providers `ThemeController` depends on are declared in
// `theme_controller.dart` — so the theme graph can be read from `main()`
// without importing this file — and wired here, where the API client and the
// preferences store live. These overrides are what connect the two halves.

/// The overrides that connect the theme graph to the API client.
///
/// Applied in `bootstrap()`. Exposed as a list rather than as individual
/// providers so a test that wants a themed app can apply the whole set with one
/// spread, and so adding a third theme dependency does not become a change to
/// every test.
List<Override> themeOverrides({
  required ApiThemeService service,
  required FontRegistry fonts,
}) => <Override>[
  themeServiceProvider.overrideWithValue(service),
  fontRegistryProvider.overrideWithValue(fonts),
];

// ---------------------------------------------------------------------------
// Storage
// ---------------------------------------------------------------------------

final metadataCacheProvider = Provider<MetadataCache>(
  (ref) => MetadataCache(ref.watch(preferencesStoreProvider)),
);

final albumPaletteServiceProvider = Provider<AlbumPaletteService>((ref) {
  final service = AlbumPaletteService();
  ref.onDispose(service.clear);
  return service;
});

// ---------------------------------------------------------------------------
// Networking
// ---------------------------------------------------------------------------

/// Emits when the session ends irrecoverably, so the router can redirect.
final sessionExpiredProvider = StateProvider<int>((ref) => 0);

final spotifyAuthServiceProvider = Provider<SpotifyAuthService>((ref) {
  final service = SpotifyAuthService(secureStore: ref.watch(secureStoreProvider));
  ref.onDispose(service.dispose);
  return service;
});

/// The authenticated Dio instance every catalogue service shares.
///
/// One instance, not one per service: connection pooling and the single-flight
/// token refresh in `AuthInterceptor` only work if they see all the traffic.
final spotifyDioProvider = Provider<Dio>((ref) {
  final auth = ref.watch(spotifyAuthServiceProvider);
  final dio = DioClient.buildApiClient(
    tokenProvider: auth,
    onSessionExpired: () {
      // Bump a counter rather than navigating from here — the network layer
      // has no business knowing about routes.
      ref.read(sessionExpiredProvider.notifier).state++;
    },
  );
  ref.onDispose(dio.close);
  return dio;
});

// ---------------------------------------------------------------------------
// Services
// ---------------------------------------------------------------------------

final spotifySearchServiceProvider = Provider<SpotifySearchService>(
  (ref) => SpotifySearchService(ref.watch(spotifyDioProvider)),
);

final spotifyAlbumServiceProvider = Provider<SpotifyAlbumService>(
  (ref) => SpotifyAlbumService(ref.watch(spotifyDioProvider)),
);

final spotifyArtistServiceProvider = Provider<SpotifyArtistService>(
  (ref) => SpotifyArtistService(
    ref.watch(spotifyDioProvider),
    searchService: ref.watch(spotifySearchServiceProvider),
  ),
);

final spotifyPlaylistServiceProvider = Provider<SpotifyPlaylistService>(
  (ref) => SpotifyPlaylistService(ref.watch(spotifyDioProvider)),
);

final spotifyUserServiceProvider = Provider<SpotifyUserService>(
  (ref) => SpotifyUserService(ref.watch(spotifyDioProvider)),
);

final spotifyPlayerServiceProvider = Provider<SpotifyPlayerService>(
  (ref) => SpotifyPlayerService(ref.watch(spotifyDioProvider)),
);

/// Drives the Spotify app installed on this phone, over App Remote.
///
/// Lazy, and deliberately not bootstrapped like [audioHandlerProvider]: it
/// takes no Dio client and no platform channel until something actually asks
/// it to connect, so constructing it on web or in a test costs nothing and
/// throws nothing. Every method inside short-circuits off Android/iOS.
final spotifyAppRemoteServiceProvider = Provider<SpotifyAppRemoteService>((ref) {
  final service = SpotifyAppRemoteService();
  ref.onDispose(service.dispose);
  return service;
});

/// The bridge to whatever floating playback surface this platform owns.
///
/// Lazy and platform-agnostic: constructing it opens a `MethodChannel`, which
/// costs nothing anywhere and answers `MissingPluginException` on web, desktop
/// and in widget tests — the wrapper turns that into "no floating surface here"
/// rather than an exception. Nothing is drawn and no permission is touched
/// until [DynamicIslandController] decides one is warranted.
final backgroundIslandChannelProvider = Provider<BackgroundIslandChannel>((ref) {
  final channel = BackgroundIslandChannel();
  ref.onDispose(channel.dispose);
  return channel;
});

/// The runtime grant the media notification needs on Android 13+.
///
/// Separate from the island: the notification and lock screen are AURIX's
/// baseline background surface and exist whether or not the island is switched
/// on, so this must never be reachable from the island's own code paths.
final mediaPermissionsProvider = Provider<MediaPermissions>(
  (ref) => MediaPermissions(),
);

final spotifyBrowseServiceProvider = Provider<SpotifyBrowseService>(
  (ref) => SpotifyBrowseService(
    ref.watch(spotifyDioProvider),
    searchService: ref.watch(spotifySearchServiceProvider),
  ),
);

final spotifyRecommendationServiceProvider = Provider<SpotifyRecommendationService>(
  (ref) => SpotifyRecommendationService(
    ref.watch(spotifyDioProvider),
    userService: ref.watch(spotifyUserServiceProvider),
    artistService: ref.watch(spotifyArtistServiceProvider),
  ),
);

// ---------------------------------------------------------------------------
// Repositories
// ---------------------------------------------------------------------------

/// AURIX's identity. Firebase Auth plus the Firestore profile behind it.
///
/// Note what it no longer takes: no Spotify service, no preferences store, no
/// metadata cache. Firebase persists the session itself and Firestore persists
/// the profile, so there is nothing left for this repository to cache by hand.
final authRepositoryProvider = Provider<AuthRepository>(
  (ref) => AuthRepository(
    authService: ref.watch(apiAuthServiceProvider),
    profileService: ref.watch(apiProfileServiceProvider),
  ),
);

/// The user's own library. Firestore only.
///
/// Takes the shared playlist catalogue as well as the private collections,
/// because "my playlists" now spans both: the ones the user built here are
/// private, and the ones they imported are in the catalogue every user can
/// search. [LibraryRepository.watchPlaylists] is where the two are joined.
final libraryRepositoryProvider = Provider<LibraryRepository>(
  (ref) => LibraryRepository(
    libraryService: ref.watch(apiLibraryServiceProvider),
    playlistService: ref.watch(apiPlaylistServiceProvider),
    playlistCatalog: ref.watch(playlistCatalogRepositoryProvider),
  ),
);

/// The shared playlist catalogue.
///
/// **The only path to a shared-playlist write in the app.** See
/// [PlaylistCatalogRepository] for why that matters and for what moving the
/// write server-side would involve.
final playlistCatalogRepositoryProvider = Provider<PlaylistCatalogRepository>(
  (ref) => PlaylistCatalogRepository(
    catalogService: ref.watch(apiGlobalPlaylistServiceProvider),
  ),
);

/// The shared song catalogue.
///
/// **The only path to a catalogue write in the app.** See [CatalogRepository]
/// for why that matters and for what moving the write server-side would
/// involve.
final catalogRepositoryProvider = Provider<CatalogRepository>(
  (ref) => CatalogRepository(
    catalogService: ref.watch(apiCatalogServiceProvider),
  ),
);

// ---------------------------------------------------------------------------
// Playlist import from a link
// ---------------------------------------------------------------------------

/// The YouTube Data API client.
///
/// Constructed with its own HTTP client rather than [spotifyDioProvider] —
/// that instance attaches the user's Spotify bearer token to everything it
/// sends, and Google must never receive it. Same reasoning as
/// [lyricsProviderProvider].
final youTubeApiServiceProvider = Provider<YouTubeApiService>(
  (ref) => YouTubeApiService(),
);

/// Every service AURIX can import a playlist *link* from.
///
/// The registry a new source is added to. A source appears in the import UI by
/// being in this list and nowhere else — there is no second registration step.
final playlistFetchersProvider = Provider<List<PlaylistFetcher>>((ref) {
  return <PlaylistFetcher>[
    SpotifyPlaylistFetcher(
      authService: ref.watch(spotifyAuthServiceProvider),
      playlistService: ref.watch(spotifyPlaylistServiceProvider),
    ),
    YouTubePlaylistFetcher(api: ref.watch(youTubeApiServiceProvider)),
  ];
});

/// Imports one playlist from a pasted link.
final playlistImportServiceProvider = Provider<PlaylistImportService>(
  (ref) => PlaylistImportService(
    library: ref.watch(libraryRepositoryProvider),
    catalog: ref.watch(catalogRepositoryProvider),
    fetchers: ref.watch(playlistFetchersProvider),
    session: ref.watch(aurixSessionProvider),
  ),
);

/// Moves a pre-Firebase install's local data into the signed-in account.
///
/// Runs once per uid, from `AuthController` on the first session after
/// sign-in. See [LocalDataMigration] for what it moves and why it deletes
/// nothing.
final localDataMigrationProvider = Provider<LocalDataMigration>(
  (ref) => LocalDataMigration(
    preferences: ref.watch(preferencesStoreProvider),
    cache: ref.watch(metadataCacheProvider),
    library: ref.watch(libraryRepositoryProvider),
    profiles: ref.watch(apiProfileServiceProvider),
  ),
);

/// The Home feed, assembled from the user's own Firestore data.
final homeRepositoryProvider = Provider<HomeRepository>(
  (ref) => HomeRepository(
    libraryService: ref.watch(apiLibraryServiceProvider),
    playlistService: ref.watch(apiPlaylistServiceProvider),
  ),
);

/// Catalogue detail — the Album and Artist screens.
///
/// The one part of AURIX still reading Spotify's Web API outside the import
/// flow, and it is worth stating exactly why rather than leaving it as a
/// leftover.
///
/// AURIX has no music catalogue. An imported track carries a `spotifyId` and a
/// title, and tapping through to "the album" or "the artist" is a question only
/// the source can answer. So these screens work when Spotify is reachable and
/// show an explanatory empty state when it is not — see `detail_providers.dart`
/// — instead of being removed, which would have deleted working navigation from
/// the imported library.
///
/// Nothing on the Home, Library, Liked Songs, Playlist or Profile paths reaches
/// this provider. That is the property that matters: Spotify being unavailable
/// costs two detail screens, not the app.
final catalogueRepositoryProvider = Provider<CatalogueRepository>((ref) {
  return CatalogueRepository(
    albumService: ref.watch(spotifyAlbumServiceProvider),
    artistService: ref.watch(spotifyArtistServiceProvider),
    playlistService: ref.watch(spotifyPlaylistServiceProvider),
    recommendationService: ref.watch(spotifyRecommendationServiceProvider),
    cache: ref.watch(metadataCacheProvider),
    connectivity: ref.watch(connectivityServiceProvider),
  );
});

/// Where lyrics come from.
///
/// The one place the choice of provider is made. Spotify does not serve lyrics
/// and its terms do not permit deriving them from the Spotify client or its
/// audio, so this is a separate source under its own terms — swapping it for a
/// commercially licensed one is a change to this line and nothing else.
///
/// Deliberately constructed with its own HTTP client rather than
/// [spotifyDioProvider]: that instance attaches the user's Spotify bearer token
/// to everything it sends, and a lyrics host must never receive it.
final lyricsProviderProvider = Provider<LyricsProvider>(
  (ref) => LrcLibLyricsService(),
);

final lyricsRepositoryProvider = Provider<LyricsRepository>((ref) {
  final repository = LyricsRepository(provider: ref.watch(lyricsProviderProvider));
  ref.onDispose(repository.clear);
  return repository;
});

/// Where search looks.
///
/// The list *is* the policy, in priority order:
///
///  1. **The user's library** (priority 0) — their liked songs and playlists,
///     matched in memory. Instant, offline, and outranks everything because
///     the user's own copy of a song is the one they can already play.
///  2. **The shared playlist catalogue** (40) — every playlist any account has
///     imported. This is what makes User A's "Love" findable by User B and
///     User C. It runs for every signed-in user and filters by no uid.
///  3. **The AURIX song catalogue** (50) — every song any import has written.
///     This is what makes an imported song findable from anywhere in the app
///     rather than only from inside the playlist it arrived in.
///  4. **Spotify** (100) — joins in only while an import session happens to be
///     live, and is the first to drop out.
///
/// Adding a licensed catalogue later is one more entry here.
final searchProvidersProvider = Provider<List<SearchProvider>>((ref) {
  return <SearchProvider>[
    LibrarySearchProvider(
      // Read lazily through callbacks, so constructing the provider does not
      // subscribe to anything — the query is what pulls the data, and the data
      // is already in memory by then.
      likedTracks: () => ref.read(likedTracksProvider).value ?? const [],
      playlists: () => ref.read(userPlaylistsProvider).value ?? const [],
      // Still empty, and now correctly so. This used to be the gap that made
      // an imported song unfindable unless its playlist happened to be open:
      // there was nowhere to search but memory, and a playlist's tracks are
      // not in memory until it is opened. Loading every track of every
      // playlist to fill it would have been one read per track on every
      // keystroke. The catalogue provider below answers the question properly
      // — one indexed lookup over every song ever imported.
      playlistTracks: () => const [],
    ),
    PlaylistCatalogSearchProvider(
      catalog: ref.watch(playlistCatalogRepositoryProvider),
    ),
    CatalogSearchProvider(catalog: ref.watch(catalogRepositoryProvider)),
    SpotifySearchProvider(
      authService: ref.watch(spotifyAuthServiceProvider),
      searchService: ref.watch(spotifySearchServiceProvider),
    ),
  ];
});

final searchServiceProvider = Provider<SearchService>(
  (ref) => SearchService(providers: ref.watch(searchProvidersProvider)),
);

final searchRepositoryProvider = Provider<SearchRepository>((ref) {
  return SearchRepository(
    searchService: ref.watch(searchServiceProvider),
    preferences: ref.watch(preferencesStoreProvider),
  );
});

// ---------------------------------------------------------------------------
// Ambient state
// ---------------------------------------------------------------------------

/// Live network status. Screens watch this to show the offline banner and to
/// auto-retry when the connection returns.
final networkStatusProvider = StreamProvider<NetworkStatus>((ref) {
  final service = ref.watch(connectivityServiceProvider);
  return service.onStatusChanged;
});

final isOfflineProvider = Provider<bool>((ref) {
  final live = ref.watch(networkStatusProvider).value;
  if (live != null) return live == NetworkStatus.offline;
  return ref.watch(connectivityServiceProvider).isOffline;
});

/// The market currently used for catalogue requests. Exposed for the Settings
/// screen, which shows it so a user seeing odd availability can understand why.
final marketProvider = Provider<String>((ref) => SpotifyApiService.market);
