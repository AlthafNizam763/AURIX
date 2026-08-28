import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'app.dart';
import 'core/config/brand_assets.dart';
import 'core/config/env.dart';
import 'core/network/aurix_api_client.dart';
import 'core/network/connectivity_service.dart';
import 'core/providers/app_providers.dart';
import 'core/storage/preferences_store.dart';
import 'core/storage/secure_store.dart';
import 'core/theme/app_theme.dart';
import 'core/theme/font_registry.dart';
import 'core/theme/theme_controller.dart';
import 'core/utils/app_logger.dart';
import 'data/services/api/api_theme_service.dart';
import 'data/services/api/aurix_session_store.dart';
import 'playback/preview_audio_handler.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();

  // Portrait-first, but landscape is allowed — the player and detail screens
  // have dedicated landscape layouts, and tablets are used that way.
  await SystemChrome.setPreferredOrientations(const <DeviceOrientation>[
    DeviceOrientation.portraitUp,
    DeviceOrientation.portraitDown,
    DeviceOrientation.landscapeLeft,
    DeviceOrientation.landscapeRight,
  ]);

  SystemChrome.setSystemUIOverlayStyle(AppTheme.darkOverlay);
  await SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);

  final overrides = await bootstrap();

  runApp(ProviderScope(overrides: overrides, child: const AurixApp()));
}

/// Performs the async setup that must finish before the first frame, and
/// returns the provider overrides that carry the results into the graph.
///
/// Everything here is genuinely blocking: the app cannot read a setting, check
/// connectivity, know who is signed in or play a note until these exist.
/// Anything that *can* wait — the profile, the home feed, palette extraction,
/// and the theme *refresh* — is deliberately not here. It loads behind the
/// splash screen instead.
///
/// ## The one thing that changed shape in the MongoDB migration
///
/// `Firebase.initializeApp` used to be on this path, and it did two jobs:
/// connect to the backend, and restore the persisted session. Neither survives
/// as a single call. There is no connection to open — the API is reached with
/// ordinary HTTP requests, so the first one *is* the connection — and the
/// session is restored explicitly by [AurixSessionStore.restore], which reads
/// the tokens out of the platform keystore.
///
/// That restore genuinely has to block. Without it the router cannot tell a
/// signed-in user from a signed-out one on the first frame, and the app flashes
/// the login screen at someone who is already signed in.
Future<List<Override>> bootstrap() async {
  await Env.load();

  // Which backend this run will talk to, and — separately — which Spotify app
  // an import would use, if one is configured at all.
  AppLogger.info(Env.debugSummary, scope: 'boot');

  if (!Env.isApiConfigured) {
    // Not fatal, and that is a considered choice rather than leniency. A fresh
    // clone has no `.env`; the router sends the developer to the setup screen,
    // which names the keys to add and where to get them. Crashing here would
    // replace that with a stack trace.
    AppLogger.warn(Env.apiConfigurationHint, scope: 'boot');
  } else if (Env.isApiInsecure) {
    // Every request carries a bearer token, and a token on an unencrypted
    // connection is a token anyone on the network has. Warned rather than
    // refused, because a LAN address during development is legitimate.
    AppLogger.warn(
      'The AURIX API is configured over plain HTTP (${Env.apiBaseUrl}). '
      'Session tokens will cross the network unencrypted. Use HTTPS for '
      'anything but local development.',
      scope: 'boot',
    );
  }

  final proxyProblem = Env.authProxyProblem;
  if (proxyProblem != null) {
    AppLogger.warn(proxyProblem, scope: 'boot');
  }

  // On web the redirect URI is derived from wherever the dev server happens to
  // be listening. Say so before Spotify rejects it.
  final redirectProblem = Env.webRedirectUriWarning;
  if (redirectProblem != null) {
    AppLogger.warn(redirectProblem, scope: 'boot');
  }

  // Cheap one-shot bundle probe. Doing it here rather than per-widget keeps
  // AurixLogo synchronous, so the splash screen never flashes the drawn mark
  // before swapping to a custom one.
  await BrandAssets.detect();

  final preferences = await PreferencesStore.open();

  // Identity. Reads the keystore, so the first frame knows who is signed in.
  final secureStore = FlutterSecureStore();
  final session = AurixSessionStore(store: secureStore);
  await session.restore();

  if (session.isSignedIn) {
    AppLogger.info('Restored the session for ${session.uid}', scope: 'boot');
  }

  final apiClient = AurixApiClient(session: session);
  final fontRegistry = FontRegistry(client: apiClient);
  final themeService = ApiThemeService(client: apiClient, preferences: preferences);

  // The cached theme's font, registered before the first frame *when it is
  // already on disk*. This is what stops a launch from painting in Manrope and
  // then reflowing into the configured face a moment later; a font that has
  // never been downloaded is fetched later, behind the splash, by
  // ThemeController.
  final cachedTheme = themeService.cached();
  if (cachedTheme != null) {
    await fontRegistry.ensure(
      cachedTheme.fontFamily,
      assetId: cachedTheme.fontAssetId,
    );
  }

  final connectivity = ConnectivityService();
  await connectivity.start();

  final audioHandler = await _initAudio();

  return <Override>[
    preferencesStoreProvider.overrideWithValue(preferences),
    connectivityServiceProvider.overrideWithValue(connectivity),
    audioHandlerProvider.overrideWithValue(audioHandler),
    secureStoreProvider.overrideWithValue(secureStore),
    sessionStoreProvider.overrideWithValue(session),
    aurixApiClientProvider.overrideWithValue(apiClient),
    fontRegistryProvider.overrideWithValue(fontRegistry),
    themeServiceProvider.overrideWithValue(themeService),
  ];
}

/// Starts the background audio service.
///
/// A failure here must not stop the app: on an emulator without the media
/// session, or a device where the foreground service is blocked, browsing the
/// library still works — only preview playback is lost. The handler is
/// returned uninitialised in that case and its play calls fail gracefully.
Future<PreviewAudioHandler> _initAudio() async {
  try {
    return await initAudioService();
  } on Object catch (error, stackTrace) {
    AppLogger.error(
      'Audio service failed to start; previews will be unavailable',
      scope: 'boot',
      error: error,
      stackTrace: stackTrace,
    );
    return PreviewAudioHandler();
  }
}
