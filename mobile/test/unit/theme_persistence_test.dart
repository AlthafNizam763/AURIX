import 'dart:convert';

import 'package:aurix/core/storage/metadata_cache.dart';
import 'package:aurix/core/storage/preferences_store.dart';
import 'package:aurix/core/theme/theme_config.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// The theme must outlive a sign-out.
///
/// ## Why this is a test and not a comment
///
/// "Persists across logout and reload" is a requirement that nothing in the
/// code states out loud. It holds for a reason that is easy to break by
/// accident: the theme is cached under `aurix.theme.cache`, and the only bulk
/// delete on sign-out is `clearNamespace(PrefKeys.cachePrefix)`, which is
/// `aurix.cache.` — a *different* prefix that happens not to match.
///
/// Nothing enforces that today. Someone widening the sign-out sweep to
/// `aurix.` — a plausible tidy-up, and the obvious way to "clear everything for
/// the next user" — would silently reset the operator's branding to the shipped
/// default on every sign-out, and the first frame after it would be the wrong
/// colours. That is a visible regression with no error attached to it, which is
/// exactly the kind worth pinning down.
void main() {
  const themeCacheKey = 'aurix.theme.cache';

  /// The shape `ApiThemeService` writes: the raw server response, not the
  /// parsed object. See the note on the cache there.
  String encodedTheme() => jsonEncode(<String, dynamic>{
    'version': 7,
    'fontFamily': 'Poppins',
    'colors': <String, dynamic>{
      'dark': ThemeConfig.fallback.dark.toJson(),
      'light': ThemeConfig.fallback.light.toJson(),
    },
    'musicPlayer': <String, String>{
      'mini': 'theme4',
      'large': 'theme2',
      'outside': 'theme3',
      'dynamic': 'theme4',
    },
  });

  setUp(() => SharedPreferences.setMockInitialValues(<String, Object>{}));

  test('the theme cache is not under the namespace sign-out clears', () {
    // Stated as a relationship between the two constants rather than as a
    // literal, so it keeps holding if either is renamed.
    expect(themeCacheKey.startsWith(PrefKeys.cachePrefix), isFalse);
  });

  test('clearing the metadata cache leaves the theme in place', () async {
    final prefs = PreferencesStore(await SharedPreferences.getInstance());
    await prefs.setString(themeCacheKey, encodedTheme());
    // A key that *is* swept, so the test proves the sweep ran rather than
    // passing because nothing happened.
    await prefs.setString(PrefKeys.cache('home_feed'), '{"stale":true}');

    await MetadataCache(prefs).clear();

    expect(prefs.getString(PrefKeys.cache('home_feed')), isNull);
    expect(prefs.getString(themeCacheKey), isNotNull);
  });

  test('the surviving cache still parses into the configuration it stored', () async {
    final prefs = PreferencesStore(await SharedPreferences.getInstance());
    await prefs.setString(themeCacheKey, encodedTheme());

    await MetadataCache(prefs).clear();

    // Round-tripped the way the service does on the next launch, so this fails
    // if the stored shape and the parser ever drift apart.
    final config = ThemeConfig.fromJson(
      jsonDecode(prefs.getString(themeCacheKey)!) as Map<String, dynamic>,
    );

    expect(config.version, 7);
    expect(config.fontFamily, 'Poppins');
    expect(config.musicPlayer.mini, PlayerVariant.theme4);
    expect(config.musicPlayer.large, PlayerVariant.theme2);
    expect(config.musicPlayer.outside, PlayerVariant.theme3);
    expect(config.musicPlayer.dynamic, PlayerVariant.theme4);
  });
}
