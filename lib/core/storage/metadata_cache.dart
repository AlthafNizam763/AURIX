import '../constants/app_constants.dart';
import '../utils/app_logger.dart';
import 'preferences_store.dart';

/// A cached payload plus the time it was written.
class CacheEntry<T> {
  const CacheEntry({required this.value, required this.storedAt});

  final T value;
  final DateTime storedAt;

  Duration get age => DateTime.now().difference(storedAt);
  bool isFresh(Duration ttl) => age < ttl;
}

/// TTL cache for **metadata only**.
///
/// Album, artist, playlist and search payloads are cached so the app opens
/// instantly and still shows something useful with no connection. Audio is
/// never cached: Spotify's terms prohibit storing their audio, and AURIX
/// does not have access to it in the first place.
///
/// The cache is deliberately "stale-while-offline": expired entries are kept
/// rather than deleted, so an offline launch can still render last-known data
/// with an honest "showing offline data" banner instead of an empty screen.
class MetadataCache {
  MetadataCache(this._prefs);

  final PreferencesStore _prefs;

  /// Reads an object payload. Returns null when absent or unparseable.
  CacheEntry<Map<String, dynamic>>? readObject(String id) {
    final envelope = _prefs.getJson(PrefKeys.cache(id));
    if (envelope == null) return null;
    final storedAt = _storedAt(envelope);
    final data = envelope['data'];
    if (storedAt == null || data is! Map<String, dynamic>) return null;
    return CacheEntry(value: data, storedAt: storedAt);
  }

  CacheEntry<List<Map<String, dynamic>>>? readList(String id) {
    final envelope = _prefs.getJson(PrefKeys.cache(id));
    if (envelope == null) return null;
    final storedAt = _storedAt(envelope);
    final data = envelope['data'];
    if (storedAt == null || data is! List) return null;
    return CacheEntry(
      value: data.whereType<Map<String, dynamic>>().toList(growable: false),
      storedAt: storedAt,
    );
  }

  Future<void> writeObject(String id, Map<String, dynamic> data) =>
      _write(id, data);

  Future<void> writeList(String id, List<Map<String, dynamic>> data) =>
      _write(id, data);

  Future<void> _write(String id, Object data) async {
    try {
      await _prefs.setJson(PrefKeys.cache(id), <String, dynamic>{
        'stored_at': DateTime.now().toIso8601String(),
        'data': data,
      });
    } on Object catch (error) {
      // Caching is an optimisation. A device with no space left should still
      // be able to browse.
      AppLogger.warn('Cache write failed for "$id"', scope: 'cache', error: error);
    }
  }

  Future<void> invalidate(String id) => _prefs.remove(PrefKeys.cache(id));

  Future<void> clear() => _prefs.clearNamespace(PrefKeys.cachePrefix);

  bool isFresh(String id, {Duration ttl = AppConstants.metadataCacheTtl}) {
    final envelope = _prefs.getJson(PrefKeys.cache(id));
    final storedAt = envelope == null ? null : _storedAt(envelope);
    if (storedAt == null) return false;
    return DateTime.now().difference(storedAt) < ttl;
  }

  DateTime? _storedAt(Map<String, dynamic> envelope) {
    final raw = envelope['stored_at'];
    if (raw is! String) return null;
    return DateTime.tryParse(raw);
  }
}

/// Cache key builders, kept together so keys stay collision-free and are easy
/// to invalidate as a group.
abstract final class CacheKeys {
  static const String homeFeed = 'home_feed';
  static const String userProfile = 'user_profile';
  static const String likedTracks = 'library_liked_tracks';
  static const String savedAlbums = 'library_saved_albums';
  static const String followedArtists = 'library_followed_artists';
  static const String userPlaylists = 'library_playlists';
  static const String recentlyPlayed = 'recently_played';
  static const String categories = 'browse_categories';

  static String album(String id) => 'album_$id';
  static String artist(String id) => 'artist_$id';
  static String playlist(String id) => 'playlist_$id';
}
