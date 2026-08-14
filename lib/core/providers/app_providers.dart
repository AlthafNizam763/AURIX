import 'package:cloud_firestore/cloud_firestore.dart';
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
import '../../data/repositories/search_repository.dart';
import '../../data/search/catalog_search_provider.dart';
import '../../data/search/library_search_provider.dart';
import '../../data/search/search_provider.dart';
import '../../data/search/spotify_search_provider.dart';
import '../../data/services/firebase/firebase_auth_service.dart';
import '../../data/services/firebase/firestore_catalog_service.dart';
import '../../data/services/firebase/firestore_library_service.dart';
import '../../data/services/firebase/firestore_playlist_service.dart';
import '../../data/services/firebase/firestore_profile_service.dart';
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
import '../network/connectivity_service.dart';
import '../network/dio_client.dart';
import '../storage/metadata_cache.dart';
import '../storage/preferences_store.dart';
import '../storage/secure_store.dart';
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

final secureStoreProvider = Provider<SecureStore>((ref) => FlutterSecureStore());

// ---------------------------------------------------------------------------
// Firebase — AURIX's backend
// ---------------------------------------------------------------------------
//
// These sit above everything else in the graph because they are what the app
// is built on now. `Firebase.initializeApp` has already run by the time any of
// them is first read — see `bootstrap()` in main.dart — so reaching for
// `.instance` here is safe rather than lazy-initialising anything.

/// The Firestore handle every AURIX read and write goes through.
///
/// One instance for the whole app: Firestore's offline cache, its listener
/// de-duplication and its write batching are per-instance, and a second one
/// would quietly double the app's reads.
final firestoreProvider = Provider<FirebaseFirestore>((ref) {
  final db = FirebaseFirestore.instance;
  // Offline support, switched on explicitly rather than relied on by default.
  //
  // This is what makes the "works offline" requirement true for free: every
  // query below is served from the local cache when the network is gone, every
  // write is queued and replayed on reconnect, and the snapshot listeners keep
  // firing throughout. `unlimited` because a music library is small — a few
  // thousand documents of text — and the alternative is evicting the user's own
  // playlists to save a megabyte.
  db.settings = const Settings(
    persistenceEnabled: true,
    cacheSizeBytes: Settings.CACHE_SIZE_UNLIMITED,
  );
  return db;
});

final firebaseAuthServiceProvider = Provider<FirebaseAuthService>(
  (ref) => FirebaseAuthService(),
);

final firestoreProfileServiceProvider = Provider<FirestoreProfileService>(
  (ref) => FirestoreProfileService(firestore: ref.watch(firestoreProvider)),
);

final firestorePlaylistServiceProvider = Provider<FirestorePlaylistService>(
  (ref) => FirestorePlaylistService(firestore: ref.watch(firestoreProvider)),
);

final firestoreLibraryServiceProvider = Provider<FirestoreLibraryService>(
  (ref) => FirestoreLibraryService(firestore: ref.watch(firestoreProvider)),
);

/// The shared song catalogue at `/catalog/songs`.
///
/// The one collection in the database that is not owned by the account reading
/// it — see [FirestorePaths] and the `/catalog/songs` block in
/// `firestore.rules`.
final firestoreCatalogServiceProvider = Provider<FirestoreCatalogService>(
  (ref) => FirestoreCatalogService(firestore: ref.watch(firestoreProvider)),
);

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
    authService: ref.watch(firebaseAuthServiceProvider),
    profileService: ref.watch(firestoreProfileServiceProvider),
  ),
);

/// The user's own library. Firestore only.
final libraryRepositoryProvider = Provider<LibraryRepository>(
  (ref) => LibraryRepository(
    libraryService: ref.watch(firestoreLibraryServiceProvider),
    playlistService: ref.watch(firestorePlaylistServiceProvider),
  ),
);

/// The shared song catalogue.
///
/// **The only path to a catalogue write in the app.** See [CatalogRepository]
/// for why that matters and for what moving the write server-side would
/// involve.
final catalogRepositoryProvider = Provider<CatalogRepository>(
  (ref) => CatalogRepository(
    catalogService: ref.watch(firestoreCatalogServiceProvider),
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
    profiles: ref.watch(firestoreProfileServiceProvider),
  ),
);

/// The Home feed, assembled from the user's own Firestore data.
final homeRepositoryProvider = Provider<HomeRepository>(
  (ref) => HomeRepository(
    libraryService: ref.watch(firestoreLibraryServiceProvider),
    playlistService: ref.watch(firestorePlaylistServiceProvider),
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
///  2. **The AURIX catalogue** (50) — every song any import has written. This
///     is what makes an imported song findable from anywhere in the app rather
///     than only from inside the playlist it arrived in.
///  3. **Spotify** (100) — joins in only while an import session happens to be
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
