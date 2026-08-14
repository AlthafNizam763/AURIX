import 'package:dio/dio.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../data/repositories/auth_repository.dart';
import '../../data/repositories/catalogue_repository.dart';
import '../../data/repositories/home_repository.dart';
import '../../data/repositories/library_repository.dart';
import '../../data/repositories/lyrics_repository.dart';
import '../../data/repositories/profile_repository.dart';
import '../../data/repositories/search_repository.dart';
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

final authRepositoryProvider = Provider<AuthRepository>(
  (ref) => AuthRepository(
    authService: ref.watch(spotifyAuthServiceProvider),
    userService: ref.watch(spotifyUserServiceProvider),
    preferences: ref.watch(preferencesStoreProvider),
    cache: ref.watch(metadataCacheProvider),
  ),
);

/// Owns the selected AURIX avatar. Takes only preferences — the avatar
/// catalogue is bundled, so nothing here needs the network.
final profileRepositoryProvider = Provider<ProfileRepository>(
  (ref) => ProfileRepository(preferences: ref.watch(preferencesStoreProvider)),
);

final libraryRepositoryProvider = Provider<LibraryRepository>(
  (ref) => LibraryRepository(
    userService: ref.watch(spotifyUserServiceProvider),
    playlistService: ref.watch(spotifyPlaylistServiceProvider),
    cache: ref.watch(metadataCacheProvider),
    connectivity: ref.watch(connectivityServiceProvider),
  ),
);

final homeRepositoryProvider = Provider<HomeRepository>(
  (ref) => HomeRepository(
    userService: ref.watch(spotifyUserServiceProvider),
    playlistService: ref.watch(spotifyPlaylistServiceProvider),
    browseService: ref.watch(spotifyBrowseServiceProvider),
    recommendationService: ref.watch(spotifyRecommendationServiceProvider),
    cache: ref.watch(metadataCacheProvider),
    connectivity: ref.watch(connectivityServiceProvider),
  ),
);

final catalogueRepositoryProvider = Provider<CatalogueRepository>((ref) {
  final library = ref.watch(libraryRepositoryProvider);
  return CatalogueRepository(
    albumService: ref.watch(spotifyAlbumServiceProvider),
    artistService: ref.watch(spotifyArtistServiceProvider),
    playlistService: ref.watch(spotifyPlaylistServiceProvider),
    recommendationService: ref.watch(spotifyRecommendationServiceProvider),
    cache: ref.watch(metadataCacheProvider),
    connectivity: ref.watch(connectivityServiceProvider),
    areAlbumsSaved: library.areAlbumsSaved,
    areArtistsFollowed: library.areArtistsFollowed,
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

final searchRepositoryProvider = Provider<SearchRepository>((ref) {
  final repository = SearchRepository(
    searchService: ref.watch(spotifySearchServiceProvider),
    preferences: ref.watch(preferencesStoreProvider),
  );
  ref.onDispose(repository.cancelInFlight);
  return repository;
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
