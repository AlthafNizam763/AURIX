import 'dart:async';
import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

import '../utils/app_logger.dart';

/// Non-sensitive local persistence: user settings, search history, the
/// recently-viewed list and cached metadata envelopes.
///
/// Nothing secret goes here — see `SecureStore` for tokens.
class PreferencesStore {
  PreferencesStore(this._prefs);

  final SharedPreferences _prefs;

  static Future<PreferencesStore> open() async =>
      PreferencesStore(await SharedPreferences.getInstance());

  // ---- Primitives -------------------------------------------------------
  String? getString(String key) => _prefs.getString(key);
  Future<void> setString(String key, String value) => _prefs.setString(key, value);

  bool? getBool(String key) => _prefs.getBool(key);
  Future<void> setBool(String key, bool value) => _prefs.setBool(key, value);

  int? getInt(String key) => _prefs.getInt(key);
  Future<void> setInt(String key, int value) => _prefs.setInt(key, value);

  double? getDouble(String key) => _prefs.getDouble(key);
  Future<void> setDouble(String key, double value) => _prefs.setDouble(key, value);

  List<String> getStringList(String key) => _prefs.getStringList(key) ?? const [];
  Future<void> setStringList(String key, List<String> value) =>
      _prefs.setStringList(key, value);

  Future<void> remove(String key) => _prefs.remove(key);
  bool contains(String key) => _prefs.containsKey(key);

  // ---- JSON -------------------------------------------------------------
  /// Reads a JSON object. Returns null rather than throwing when the stored
  /// blob was written by an older build with an incompatible shape.
  Map<String, dynamic>? getJson(String key) {
    final raw = _prefs.getString(key);
    if (raw == null || raw.isEmpty) return null;
    try {
      final decoded = jsonDecode(raw);
      return decoded is Map<String, dynamic> ? decoded : null;
    } on FormatException catch (error) {
      AppLogger.warn('Discarding malformed JSON at "$key"', scope: 'prefs', error: error);
      unawaited(_prefs.remove(key));
      return null;
    }
  }

  Future<void> setJson(String key, Map<String, dynamic> value) =>
      _prefs.setString(key, jsonEncode(value));

  List<Map<String, dynamic>>? getJsonList(String key) {
    final raw = _prefs.getString(key);
    if (raw == null || raw.isEmpty) return null;
    try {
      final decoded = jsonDecode(raw);
      if (decoded is! List) return null;
      return decoded.whereType<Map<String, dynamic>>().toList(growable: false);
    } on FormatException catch (error) {
      AppLogger.warn('Discarding malformed JSON list at "$key"', scope: 'prefs', error: error);
      unawaited(_prefs.remove(key));
      return null;
    }
  }

  Future<void> setJsonList(String key, List<Map<String, dynamic>> value) =>
      _prefs.setString(key, jsonEncode(value));

  /// Every key beginning with [prefix].
  ///
  /// The one place enumeration is offered, and it exists for the migration:
  /// avatar choices were stored per Spotify account under a key that embedded
  /// the account id, and finding them again means asking which keys exist.
  /// Nothing in the running app needs this — a feature that has to search the
  /// keyspace for its own data has lost track of where it put it.
  List<String> keysWithPrefix(String prefix) =>
      _prefs.getKeys().where((key) => key.startsWith(prefix)).toList();

  /// Wipes everything owned by AURIX. Used on logout and by "Clear cache".
  Future<void> clearNamespace(String prefix) async {
    final keys = _prefs.getKeys().where((k) => k.startsWith(prefix)).toList();
    for (final key in keys) {
      await _prefs.remove(key);
    }
  }
}

/// Keys used in [PreferencesStore].
abstract final class PrefKeys {
  static const String namespace = 'aurix.';

  // Settings
  static const String themeMode = '${namespace}settings.theme_mode';

  /// Orphaned by the monochrome identity — nothing reads or writes it any more.
  ///
  /// Kept declared rather than deleted, and deliberately *not* migrated away:
  /// an install that upgrades still has `miles` or `neon` sitting in its
  /// preferences, and the one thing worse than a stale key is a startup
  /// migration that rewrites storage to delete a string nobody reads. Holding
  /// the name here also stops it being reused for something unrelated.
  static const String themeVariant = '${namespace}settings.theme_variant';
  static const String streamingQuality = '${namespace}settings.streaming_quality';
  static const String downloadOverCellular = '${namespace}settings.cellular_streaming';
  static const String crossfadeSeconds = '${namespace}settings.crossfade_seconds';
  static const String gaplessPlayback = '${namespace}settings.gapless';
  static const String autoplaySimilar = '${namespace}settings.autoplay_similar';
  static const String normalizeVolume = '${namespace}settings.normalize_volume';
  static const String showExplicit = '${namespace}settings.show_explicit';
  static const String notificationsNewReleases = '${namespace}settings.notify_new_releases';
  static const String notificationsRecommendations = '${namespace}settings.notify_recs';
  static const String preferredPlaybackMode = '${namespace}settings.playback_mode';
  static const String reduceMotion = '${namespace}settings.reduce_motion';
  static const String dynamicIsland = '${namespace}settings.dynamic_island';

  /// Whether the island may be drawn *outside* AURIX, over other apps.
  ///
  /// A second key rather than a mode on [dynamicIsland] because the two are
  /// different consents: the first is a visual preference inside the user's own
  /// app, the second hands AURIX the ability to draw over everything else and
  /// requires a system permission to match. Collapsing them would mean enabling
  /// a pill implied granting an overlay, which is exactly the pattern the
  /// permission exists to prevent.
  ///
  /// Off by default, and — like [dynamicIsland] — kept out of Android's cloud
  /// backup so a reinstall cannot arrive with it already on.
  static const String dynamicIslandOverlay =
      '${namespace}settings.dynamic_island_overlay';

  // Profile
  /// The chosen AURIX avatar, per Spotify account.
  ///
  /// Keyed by user id rather than stored as one global value, for two reasons:
  ///
  ///  * Two accounts on one device keep their own avatars, so signing out and
  ///    back in as someone else does not show them the previous user's choice.
  ///  * It survives sign-out. `AuthRepository.signOut` clears tokens, the
  ///    metadata cache and the playback keys — deliberately not this one, so
  ///    the same user signing back in finds the avatar they picked rather than
  ///    being silently reset to the default.
  ///
  /// The value is an [Avatar] id (`avatar_05`) and never image data — see the
  /// rule in `lib/data/models/avatar.dart`.
  static const String profileAvatarPrefix = '${namespace}profile.avatar_id.';
  static String profileAvatar(String userId) => '$profileAvatarPrefix$userId';

  // Onboarding
  /// Set once the intro has been completed or skipped. Absent — not `false` —
  /// is what marks a first run, so a build that adds this key never replays
  /// onboarding for an existing install.
  static const String onboardingComplete = '${namespace}onboarding.complete';

  // History
  static const String recentSearches = '${namespace}history.recent_searches';
  static const String recentlyViewed = '${namespace}history.recently_viewed';
  static const String lastPlayedTrack = '${namespace}history.last_played_track';
  static const String lastQueue = '${namespace}history.last_queue';

  // Library UI state
  static const String libraryFilter = '${namespace}library.filter';
  static const String librarySort = '${namespace}library.sort';

  // Cache
  static const String cachePrefix = '${namespace}cache.';
  static String cache(String id) => '$cachePrefix$id';
}
