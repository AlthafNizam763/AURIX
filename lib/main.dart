import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'app.dart';
import 'core/config/brand_assets.dart';
import 'core/config/env.dart';
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

  // Which Spotify app and which token endpoint this run will use. A 403 from
  // the Web API is decided per application, so this line is the first thing
  // worth seeing when one shows up.
  AppLogger.info(Env.debugSummary, scope: 'boot');

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

  if (!Env.isConfigured) {
    // Not fatal: the router sends the user to the setup screen, which explains
    // exactly what is missing. Crashing here would be a worse first run.
    AppLogger.warn(Env.configurationHint, scope: 'boot');
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
