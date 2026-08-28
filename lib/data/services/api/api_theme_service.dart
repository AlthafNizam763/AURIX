import 'dart:convert';
import 'dart:typed_data';

import '../../../core/config/env.dart';
import '../../../core/constants/aurix_endpoints.dart';
import '../../../core/network/aurix_api_client.dart';
import '../../../core/storage/preferences_store.dart';
import '../../../core/theme/theme_config.dart';
import '../../../core/utils/app_logger.dart';

/// Reads and writes the application theme.
///
/// ## The cache is what makes the first frame instant
///
/// The theme is on the cold-start path: the splash screen is already painted
/// before the network answers. So the last configuration the app successfully
/// applied is written to preferences as raw JSON and read back synchronously
/// during `bootstrap()`.
///
/// The *raw response* is cached rather than the parsed object, and that detail
/// matters: asset paths are resolved against the API base URL at parse time, so
/// caching the resolved form would bake yesterday's base URL into today's logo
/// and break every install that moved to a new server.
///
/// ## Fetching never throws
///
/// [fetch] returns null on any failure. A theme that cannot be loaded must
/// leave the app rendering its previous appearance, not showing an error — the
/// user did not ask for a theme, they asked for their music.
class ApiThemeService {
  ApiThemeService({
    required AurixApiClient client,
    required PreferencesStore preferences,
  }) : _client = client,
       _preferences = preferences;

  final AurixApiClient _client;
  final PreferencesStore _preferences;

  static const String _cacheKey = 'aurix.theme.cache';

  /// The current configuration, or null when it could not be read.
  Future<ThemeConfig?> fetch() async {
    try {
      final response = await _client.get(AurixEndpoints.theme);
      final body = response['theme'];
      if (body is! Map<String, dynamic>) return null;

      await _cache(body);
      return ThemeConfig.fromJson(body, baseUrl: Env.apiBaseUrl);
    } on Object catch (error) {
      AppLogger.debug('Could not fetch the theme: $error', scope: 'theme');
      return null;
    }
  }

  /// The last configuration this device successfully applied.
  ///
  /// Synchronous in effect — [PreferencesStore] is already open by the time
  /// this is called — which is what lets the first frame carry the operator's
  /// branding rather than the shipped default.
  ThemeConfig? cached() {
    final raw = _preferences.getString(_cacheKey);
    if (raw == null || raw.isEmpty) return null;

    try {
      final decoded = jsonDecode(raw);
      if (decoded is! Map<String, dynamic>) return null;
      return ThemeConfig.fromJson(decoded, baseUrl: Env.apiBaseUrl);
    } on Object catch (error) {
      // A cache written by an older build, or a truncated write. Dropped
      // rather than repaired: the network copy is authoritative and one
      // unstyled launch is a cheaper failure than a half-parsed theme.
      AppLogger.debug('Discarding an unreadable theme cache: $error', scope: 'theme');
      return null;
    }
  }

  /// Only the version, for the cheap "has anything changed?" poll.
  Future<int?> version() async {
    try {
      final response = await _client.get(AurixEndpoints.themeVersion);
      return (response['version'] as num?)?.toInt();
    } on Object {
      return null;
    }
  }

  /// What the admin pickers offer — the font catalogue and the player variants.
  Future<ThemeOptions> options() async {
    try {
      final response = await _client.get(AurixEndpoints.themeOptions);
      return ThemeOptions.fromJson(response);
    } on Object catch (error) {
      AppLogger.debug('Could not read the theme options: $error', scope: 'theme');
      return ThemeOptions.fallback;
    }
  }

  // -------------------------------------------------------------------------
  // Administration
  // -------------------------------------------------------------------------

  /// Applies a patch. Administrators only — the API enforces it.
  ///
  /// Sends the whole configuration rather than a delta, so a half-applied theme
  /// is not a state the server can end up in.
  Future<ThemeConfig> save(ThemeConfig config) async {
    final response = await _client.put(
      AurixEndpoints.theme,
      body: <String, dynamic>{
        'fontFamily': config.fontFamily,
        'fontAssetId': config.fontAssetId,
        'typography': config.typography.toJson(),
        'colors': <String, dynamic>{
          'dark': config.dark.toJson(),
          'light': config.light.toJson(),
        },
        'musicPlayer': config.musicPlayer.toJson(),
      },
    );
    return _applied(response);
  }

  /// Restores the shipped AURIX identity.
  Future<ThemeConfig> reset() async =>
      _applied(await _client.post(AurixEndpoints.themeReset));

  Future<ThemeConfig> uploadLogo(Uint8List bytes, {required String filename}) async =>
      _applied(
        await _client.upload(AurixEndpoints.themeLogo, bytes: bytes, filename: filename),
      );

  Future<ThemeConfig> clearLogo() async =>
      _applied(await _client.delete(AurixEndpoints.themeLogo));

  Future<ThemeConfig> uploadIcon(Uint8List bytes, {required String filename}) async =>
      _applied(
        await _client.upload(AurixEndpoints.themeIcon, bytes: bytes, filename: filename),
      );

  Future<ThemeConfig> clearIcon() async =>
      _applied(await _client.delete(AurixEndpoints.themeIcon));

  /// Uploads a font file for [family], and optionally selects it.
  Future<ThemeConfig> uploadFont(
    Uint8List bytes, {
    required String family,
    required String filename,
    bool apply = true,
  }) async => _applied(
    await _client.upload(
      AurixEndpoints.themeFonts,
      bytes: bytes,
      filename: filename,
      fields: <String, String>{'family': family, 'apply': '$apply'},
    ),
  );

  /// Parses a write response, caching the new configuration on the way through.
  Future<ThemeConfig> _applied(Map<String, dynamic> response) async {
    final body = response['theme'];
    if (body is! Map<String, dynamic>) {
      throw StateError('The API did not return a theme.');
    }
    await _cache(body);
    return ThemeConfig.fromJson(body, baseUrl: Env.apiBaseUrl);
  }

  Future<void> _cache(Map<String, dynamic> body) async {
    try {
      await _preferences.setString(_cacheKey, jsonEncode(body));
    } on Object catch (error) {
      // A cache that cannot be written costs one unstyled first frame on the
      // next launch. Not worth failing a working theme fetch over.
      AppLogger.debug('Could not cache the theme: $error', scope: 'theme');
    }
  }
}

/// What the admin screens offer.
class ThemeOptions {
  const ThemeOptions({required this.fonts, required this.colorRoles});

  final List<FontOption> fonts;
  final List<String> colorRoles;

  /// Used when the options endpoint cannot be reached, so the Appearance screen
  /// still shows a usable font picker instead of an empty dropdown.
  static const ThemeOptions fallback = ThemeOptions(
    fonts: <FontOption>[
      FontOption(family: 'Manrope', bundled: true, available: true),
    ],
    colorRoles: <String>[
      'primary',
      'secondary',
      'accent',
      'background',
      'surface',
      'text',
      'player',
      'button',
    ],
  );

  factory ThemeOptions.fromJson(Map<String, dynamic> json) {
    final fonts = json['fonts'];
    final roles = json['colorRoles'];

    return ThemeOptions(
      fonts: fonts is List
          ? fonts
                .whereType<Map<String, dynamic>>()
                .map(FontOption.fromJson)
                .toList(growable: false)
          : fallback.fonts,
      colorRoles: roles is List
          ? roles.whereType<String>().toList(growable: false)
          : fallback.colorRoles,
    );
  }
}

/// One entry in the font picker.
class FontOption {
  const FontOption({
    required this.family,
    required this.bundled,
    required this.available,
    this.assetId,
    this.note,
  });

  final String family;

  /// True when the family ships inside the app. Always usable, offline
  /// included.
  final bool bundled;

  /// True when the family can actually be rendered — bundled, or with a font
  /// file uploaded.
  ///
  /// A family that is listed but unavailable is shown in the picker as needing
  /// an upload rather than hidden, so an administrator can see the whole
  /// catalogue and understand why one entry is not selectable yet.
  final bool available;

  final String? assetId;
  final String? note;

  factory FontOption.fromJson(Map<String, dynamic> json) => FontOption(
    family: json['family'] as String? ?? '',
    bundled: json['bundled'] == true,
    available: json['available'] == true,
    assetId: json['assetId'] as String?,
    note: json['note'] as String?,
  );
}
