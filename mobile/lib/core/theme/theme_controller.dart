import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../data/services/api/api_theme_service.dart';
import '../utils/app_logger.dart';
import 'font_registry.dart';
import 'theme_config.dart';

/// The application's appearance, as live state.
///
/// ## The launch sequence
///
/// ```
///   Application start
///         ↓
///   Cached configuration          ← rendered on the FIRST frame, no await
///         ↓
///   Fetch from the API (MongoDB)  ← behind the splash screen
///         ↓
///   Register the font             ← the previous face keeps rendering
///         ↓
///   Rebuild with the new palette, logo and player themes
/// ```
///
/// The order is the design. Rendering the cache first is what makes the first
/// frame carry the operator's branding instead of the shipped default; doing
/// the fetch behind it is what keeps a slow network from delaying the app; and
/// registering the font *after* painting is what stops a font download from
/// reflowing every screen twice.
///
/// ## Why the resolved font is part of the state
///
/// [ThemeState.fontFamily] is what the app should render with *right now*,
/// which is not always what the configuration asks for: a family whose file is
/// still downloading is not registered yet, and naming it in a `TextStyle` would
/// silently fall through to the platform default. So the registry answers the
/// question and the answer is state, which is what makes the app re-render at
/// the moment the font becomes available.
@immutable
class ThemeState {
  const ThemeState({
    required this.config,
    required this.fontFamily,
    this.isRefreshing = false,
    this.error,
  });

  final ThemeConfig config;

  /// The family that is actually registered and renderable. See the class note.
  final String fontFamily;

  /// True while a fetch is in flight. Never blocks rendering — the current
  /// configuration stays on screen throughout.
  final bool isRefreshing;

  /// The last failure, for the Appearance screen. Never surfaced elsewhere: a
  /// theme that could not be refreshed is not something to interrupt a listener
  /// with.
  final String? error;

  static const ThemeState initial = ThemeState(
    config: ThemeConfig.fallback,
    fontFamily: FontRegistry.fallbackFamily,
  );

  ThemeState copyWith({
    ThemeConfig? config,
    String? fontFamily,
    bool? isRefreshing,
    String? error,
    bool clearError = false,
  }) => ThemeState(
    config: config ?? this.config,
    fontFamily: fontFamily ?? this.fontFamily,
    isRefreshing: isRefreshing ?? this.isRefreshing,
    error: clearError ? null : (error ?? this.error),
  );
}

/// Owns the theme, and is the only thing that writes it.
///
/// Every admin mutation goes through here rather than through the service
/// directly, so there is one place that saves to MongoDB, invalidates the
/// cache, re-registers the font and pushes new state:
///
/// ```
///   Admin changes a setting
///         ↓
///   Save to MongoDB           (ApiThemeService)
///         ↓
///   Cache the new document    (preferences, same call)
///         ↓
///   Register the font if it changed
///         ↓
///   Emit new state → MaterialApp rebuilds → every screen repaints
/// ```
class ThemeController extends Notifier<ThemeState> {
  late final ApiThemeService _service;
  late final FontRegistry _fonts;

  @override
  ThemeState build() {
    _service = ref.watch(themeServiceProvider);
    _fonts = ref.watch(fontRegistryProvider);

    // The cached configuration, applied synchronously. This is the first frame.
    final cached = _service.cached() ?? ThemeConfig.fallback;

    // The fetch runs after this method returns, so `build` stays synchronous
    // and nothing on the launch path awaits the network.
    scheduleMicrotask(refresh);

    return ThemeState(config: cached, fontFamily: _fonts.resolve(cached.fontFamily));
  }

  /// Re-reads the configuration from the API.
  ///
  /// Safe to call at any time. A failure leaves the current appearance exactly
  /// as it is — see [ApiThemeService.fetch], which returns null rather than
  /// throwing for precisely this reason.
  Future<void> refresh() async {
    state = state.copyWith(isRefreshing: true, clearError: true);

    final fetched = await _service.fetch();
    if (fetched == null) {
      state = state.copyWith(isRefreshing: false);
      return;
    }

    await _apply(fetched);
    state = state.copyWith(isRefreshing: false);
  }

  /// Applies a configuration and loads whatever it needs.
  Future<void> _apply(ThemeConfig config) async {
    // The palette, logo and player themes land immediately — they are values,
    // and there is nothing to load.
    state = state.copyWith(
      config: config,
      fontFamily: _fonts.resolve(config.fontFamily),
      clearError: true,
    );

    // The font may not be. `ensure` returns true only when the family became
    // available as a result of this call, which is exactly when a second
    // rebuild is worth doing.
    final loaded = await _fonts.ensure(config.fontFamily, assetId: config.fontAssetId);
    if (loaded) {
      state = state.copyWith(fontFamily: _fonts.resolve(config.fontFamily));
      AppLogger.info('Applied theme v${config.version} in ${config.fontFamily}', scope: 'theme');
    }
  }

  // -------------------------------------------------------------------------
  // Administration
  // -------------------------------------------------------------------------

  /// Saves a configuration and applies it. Administrators only.
  ///
  /// The optimistic update is deliberate: the admin sees the change on the
  /// frame they made it, and a failure rolls back to what the server actually
  /// holds. Waiting for the round trip would make every colour picker feel
  /// broken.
  Future<bool> save(ThemeConfig config) async {
    final previous = state;
    await _apply(config);

    try {
      final saved = await _service.save(config);
      await _apply(saved);
      return true;
    } on Object catch (error) {
      state = previous.copyWith(error: _messageFor(error));
      AppLogger.warn('Could not save the theme', scope: 'theme', error: error);
      return false;
    }
  }

  /// Applies a change to the working copy without saving it.
  ///
  /// What the colour pickers and the player-theme grid call on every
  /// interaction, so the app repaints live while the admin is deciding. The
  /// version is left alone — an unsaved edit is not a new version — and
  /// [refresh] discards it.
  Future<void> preview(ThemeConfig config) => _apply(config);

  Future<bool> reset() => _guard(() => _service.reset());

  Future<bool> uploadLogo(Uint8List bytes, {required String filename}) =>
      _guard(() => _service.uploadLogo(bytes, filename: filename));

  Future<bool> clearLogo() => _guard(_service.clearLogo);

  Future<bool> uploadIcon(Uint8List bytes, {required String filename}) =>
      _guard(() => _service.uploadIcon(bytes, filename: filename));

  Future<bool> clearIcon() => _guard(_service.clearIcon);

  Future<bool> uploadFont(
    Uint8List bytes, {
    required String family,
    required String filename,
  }) => _guard(
    () => _service.uploadFont(bytes, family: family, filename: filename),
  );

  /// Runs an admin write, applies the result, and reports failure as state.
  Future<bool> _guard(Future<ThemeConfig> Function() write) async {
    state = state.copyWith(isRefreshing: true, clearError: true);
    try {
      await _apply(await write());
      state = state.copyWith(isRefreshing: false);
      return true;
    } on Object catch (error) {
      state = state.copyWith(isRefreshing: false, error: _messageFor(error));
      AppLogger.warn('Theme write failed', scope: 'theme', error: error);
      return false;
    }
  }

  static String _messageFor(Object error) {
    final text = error.toString();
    // `ApiException.message` is already written to be read by a person — see
    // the note there — so it is used as-is when there is one.
    return text.startsWith('AurixApiException') ? 'That change was refused.' : text;
  }
}

// ---------------------------------------------------------------------------
// Providers
// ---------------------------------------------------------------------------
//
// Declared here rather than in `app_providers.dart` because the theme graph is
// self-contained and is read from `main()` before the rest of the app exists.
// The two overridden below are wired in `app_providers.dart`, which is where
// the API client and the preferences store live.

final themeServiceProvider = Provider<ApiThemeService>(
  (ref) => throw UnimplementedError(
    'themeServiceProvider is wired in app_providers.dart',
  ),
);

final fontRegistryProvider = Provider<FontRegistry>(
  (ref) => throw UnimplementedError(
    'fontRegistryProvider is wired in app_providers.dart',
  ),
);

final themeControllerProvider = NotifierProvider<ThemeController, ThemeState>(
  ThemeController.new,
);

/// The live configuration. What every widget that needs a theme value reads.
final themeConfigProvider = Provider<ThemeConfig>(
  (ref) => ref.watch(themeControllerProvider.select((s) => s.config)),
);

/// Which design each player surface should use.
///
/// Its own provider so a player widget rebuilds when the *player* theme
/// changes and not when a colour does — the player tree is the most expensive
/// one in the app to rebuild, and it is on screen while audio is playing.
final playerThemesProvider = Provider<PlayerThemes>(
  (ref) => ref.watch(themeConfigProvider.select((c) => c.musicPlayer)),
);

/// The variant for one surface. Watch this, not [playerThemesProvider], from a
/// player widget: it rebuilds only when that surface's own variant changes.
final playerVariantProvider = Provider.family<PlayerVariant, PlayerSurface>(
  (ref, surface) =>
      ref.watch(playerThemesProvider.select((themes) => themes.forSurface(surface))),
);

/// The logo URL, or null for the drawn mark.
final appLogoProvider = Provider<String?>(
  (ref) => ref.watch(themeConfigProvider.select((c) => c.appLogo)),
);
