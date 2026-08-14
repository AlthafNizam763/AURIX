/// Defensive readers for Spotify JSON.
///
/// Every model parses through these rather than casting directly. Spotify's
/// responses are not as uniform as the docs suggest — playlist items can carry
/// a null `track` (a removed or local file), `total` is occasionally a string,
/// and `available_markets` is omitted entirely on some endpoints. A single
/// unexpected null in a 50-item page must degrade that item, not blank the
/// whole screen with a TypeError.
abstract final class Json {
  static String str(Map<String, dynamic> json, String key, {String fallback = ''}) {
    final value = json[key];
    if (value is String) return value;
    if (value == null) return fallback;
    return value.toString();
  }

  static String? strOrNull(Map<String, dynamic> json, String key) {
    final value = json[key];
    if (value is String && value.isNotEmpty) return value;
    return null;
  }

  static int intVal(Map<String, dynamic> json, String key, {int fallback = 0}) {
    final value = json[key];
    if (value is int) return value;
    if (value is num) return value.toInt();
    if (value is String) return int.tryParse(value) ?? fallback;
    return fallback;
  }

  static int? intOrNull(Map<String, dynamic> json, String key) {
    final value = json[key];
    if (value is int) return value;
    if (value is num) return value.toInt();
    if (value is String) return int.tryParse(value);
    return null;
  }

  static double dbl(Map<String, dynamic> json, String key, {double fallback = 0}) {
    final value = json[key];
    if (value is num) return value.toDouble();
    if (value is String) return double.tryParse(value) ?? fallback;
    return fallback;
  }

  static bool boolVal(Map<String, dynamic> json, String key, {bool fallback = false}) {
    final value = json[key];
    if (value is bool) return value;
    if (value is String) return value.toLowerCase() == 'true';
    if (value is num) return value != 0;
    return fallback;
  }

  static Map<String, dynamic>? obj(Map<String, dynamic> json, String key) {
    final value = json[key];
    return value is Map<String, dynamic> ? value : null;
  }

  static List<String> stringList(Map<String, dynamic> json, String key) {
    final value = json[key];
    if (value is! List) return const [];
    return value.whereType<String>().toList(growable: false);
  }

  /// Maps a JSON array through [parse], dropping entries that are not objects
  /// or that fail to parse. One bad row never costs the whole list.
  static List<T> list<T>(
    Map<String, dynamic> json,
    String key,
    T Function(Map<String, dynamic>) parse,
  ) {
    final value = json[key];
    if (value is! List) return const [];
    final result = <T>[];
    for (final entry in value) {
      if (entry is! Map<String, dynamic>) continue;
      try {
        result.add(parse(entry));
      } on Object {
        // Skip the malformed entry; the rest of the page is still good.
        continue;
      }
    }
    return result;
  }

  static List<T> listFrom<T>(
    Object? value,
    T Function(Map<String, dynamic>) parse,
  ) {
    if (value is! List) return const [];
    final result = <T>[];
    for (final entry in value) {
      if (entry is! Map<String, dynamic>) continue;
      try {
        result.add(parse(entry));
      } on Object {
        continue;
      }
    }
    return result;
  }

  /// Reads the `external_urls.spotify` link that appears on every object.
  static String? spotifyUrl(Map<String, dynamic> json) {
    final urls = obj(json, 'external_urls');
    if (urls == null) return null;
    return strOrNull(urls, 'spotify');
  }

  static DateTime? dateTime(Map<String, dynamic> json, String key) {
    final raw = strOrNull(json, key);
    return raw == null ? null : DateTime.tryParse(raw);
  }
}
