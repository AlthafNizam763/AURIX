import 'package:firebase_core/firebase_core.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'app.dart';
import 'core/config/brand_assets.dart';
import 'core/config/env.dart';
import 'core/config/firebase_options.dart';
import 'core/network/connectivity_service.dart';
import 'core/providers/app_providers.dart';
import 'core/storage/preferences_store.dart';
import 'core/theme/app_theme.dart';
import 'core/utils/app_logger.dart';
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
/// connectivity or play a note until these exist. Anything that *can* wait
/// (the profile, the home feed, palette extraction) is deliberately not here —
/// it loads behind the splash screen instead.
Future<List<Override>> bootstrap() async {
  await Env.load();

  // Which Firebase project this run will talk to, and — separately — which
  // Spotify app an import would use, if one is configured at all.
  AppLogger.info(Env.debugSummary, scope: 'boot');

  await _initFirebase();

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

  final connectivity = ConnectivityService();
  await connectivity.start();

  final audioHandler = await _initAudio();

  return <Override>[
    preferencesStoreProvider.overrideWithValue(preferences),
    connectivityServiceProvider.overrideWithValue(connectivity),
    audioHandlerProvider.overrideWithValue(audioHandler),
  ];
}

/// Connects to the Firebase project, if this build has one configured.
///
/// Not fatal when it fails, and that is a considered choice rather than
/// leniency. Two outcomes are possible and both have a better answer than a
/// crash on the first frame:
///
///  * **No configuration.** A fresh clone has no `.env`. The router sends the
///    developer to the setup screen, which names the keys to paste and where to
///    get them. Crashing here would replace that with a stack trace.
///  * **Configuration present but initialisation fails** — a wrong project id,
///    a bundle id that does not match, no network on a cold start. The app
///    comes up signed-out and says so, which is recoverable; a crash loop is
///    not.
///
/// Either way `Env.isFirebaseConfigured` is what the rest of the app gates on,
/// and it is false in both cases.
Future<void> _initFirebase() async {
  final options = AurixFirebaseOptions.forCurrentPlatform();
  if (options == null) {
    AppLogger.warn(Env.firebaseConfigurationHint, scope: 'boot');
    return;
  }

  try {
    // Guarded because a hot restart re-runs `main` against a process where the
    // default app already exists, and initialising it twice throws
    // `duplicate-app`.
    if (Firebase.apps.isEmpty) {
      await Firebase.initializeApp(options: options);
    }
    AppLogger.info(
      'Firebase ready — project ${Env.firebaseProjectId}',
      scope: 'boot',
    );
  } on Object catch (error, stackTrace) {
    AppLogger.error(
      'Firebase failed to initialise. AURIX will start signed out. '
      'Check the FIREBASE_* values in .env against the Firebase console.',
      scope: 'boot',
      error: error,
      stackTrace: stackTrace,
    );
  }
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
