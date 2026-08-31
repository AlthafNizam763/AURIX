/// Defensive readers for the JSON-ish maps AURIX parses.
///
/// Every model parses through these rather than casting directly, and it is
/// worth being precise about why, because the two sources have *different*
/// reasons:
///
///  * **Spotify payloads.** Responses are not as uniform as the docs suggest —
///    playlist items can carry a null `track` (a removed or local file),
///    `total` is occasionally a string, and `available_markets` is omitted
///    entirely on some endpoints.
///  * **Firestore documents.** A document is whatever some build of the app
///    wrote, and old builds are still installed. A field can be absent because
///    the version that created the document did not have it yet.
///
/// Both come down to the same rule: a single unexpected null in a 50-item page
/// must degrade that item, not blank the whole screen with a TypeError.
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

  /// Reads a Firestore timestamp field as a local [DateTime].
  ///
  /// Four shapes have to be accepted, and each one is a real case rather than
  /// defensive padding:
  ///
  ///  * a `Timestamp` — the normal read from a server document;
  ///  * `null` — the window between a write with `FieldValue.serverTimestamp()`
  ///    and the server's acknowledgement. Firestore's local echo of that write
  ///    carries a null there, so a freshly created row would otherwise throw on
  ///    the very frame it appears;
  ///  * an `int` of epoch milliseconds — what the offline cache and the local
  ///    migration path write;
  ///  * an ISO-8601 string — what the pre-Firebase `MetadataCache` wrote, which
  ///    the migration in `LocalDataMigration` reads back.
  ///
  /// `Timestamp` is matched structurally rather than by importing
  /// `cloud_firestore`, so this file stays free of a plugin dependency and can
  /// be exercised by a plain `dart test` with no Firebase in the process.
  static DateTime? timestamp(Map<String, dynamic> json, String key) {
    final value = json[key];
    if (value == null) return null;
    if (value is DateTime) return value;
    if (value is int) return DateTime.fromMillisecondsSinceEpoch(value);
    if (value is String) return DateTime.tryParse(value);
    try {
      // Firestore's `Timestamp`. Duck-typed for the reason above.
      final converted = (value as dynamic).toDate();
      return converted is DateTime ? converted : null;
    } on Object {
      return null;
    }
  }
}
