import 'dart:async';

import '../../core/utils/app_logger.dart';
import '../models/track.dart';
import '../services/lyrics_service.dart';

/// Fetches lyrics, once per track.
///
/// Sits between the UI and whichever [LyricsProvider] is configured, and owns
/// the three things a provider should not have to:
///
///  * **A per-session cache.** Reopening the lyrics for a track already looked
///    up costs nothing, and neither does a track the player loops back to.
///    Negative answers are cached too — a track with no lyrics must not be
///    re-requested every time the sheet opens.
///  * **De-duplication.** The strip on the player and the sheet opened over it
///    ask for the same track at the same moment; they share one request.
///  * **The decision not to ask.** A local file has no meaningful title/artist
///    pair to search on, and asking would be a wasted round trip.
class LyricsRepository {
  LyricsRepository({required LyricsProvider provider}) : _provider = provider;

  final LyricsProvider _provider;

  /// Track key → lyrics, where a null *value* is a cached "none available".
  ///
  /// `Map<String, Lyrics?>` rather than removing absent entries, because the
  /// difference between "asked, nothing there" and "never asked" is the whole
  /// point of the cache — collapsing them would re-request every miss.
  final Map<String, Lyrics?> _cache = <String, Lyrics?>{};
  final Map<String, Future<Lyrics?>> _inFlight = <String, Future<Lyrics?>>{};

  /// Bounded so a long listening session cannot grow this without limit.
  /// Synced lyrics for one track are a few kilobytes, so this is a small
  /// budget for a large win.
  static const int _cacheLimit = 80;

  String get providerName => _provider.name;

  /// The cached answer for [trackId], if the question has been asked. Never
  /// triggers a fetch, so it is safe to call during a build.
  Lyrics? peek(String trackId) => _cache[trackId];

  bool isKnown(String trackId) => _cache.containsKey(trackId);

  Future<Lyrics?> forTrack(Track track) {
    final key = track.id.isNotEmpty ? track.id : track.spotifyUri;

    if (_cache.containsKey(key)) return Future.value(_cache[key]);

    final pending = _inFlight[key];
    if (pending != null) return pending;

    final query = LyricsQuery(
      trackId: key,
      // The primary artist, not the joined credit list: "Artist A, Artist B,
      // Artist C" matches nothing in a lyrics database, and the featured
      // credits Spotify carries are exactly what makes a title unsearchable.
      title: track.name,
      artist: track.primaryArtist?.name ?? track.artistNames,
      album: track.album?.name,
      duration: track.durationMs > 0 ? track.duration : null,
    );

    // A local file has no catalogue identity worth searching on.
    if (track.isLocal || !query.isUsable) return Future<Lyrics?>.value();

    final flight = _fetch(key, query);
    _inFlight[key] = flight;
    return flight;
  }

  Future<Lyrics?> _fetch(String key, LyricsQuery query) async {
    try {
      final lyrics = await _provider.fetch(query);
      final resolved = (lyrics != null && lyrics.isEmpty && !lyrics.isInstrumental)
          ? null
          : lyrics;

      _remember(key, resolved);
      AppLogger.info(
        '${query.title} — ${switch (resolved) {
          null => 'none',
          final l when l.isInstrumental => 'instrumental',
          final l when l.isSynced => 'synced (${l.lines.length} lines)',
          final l => 'plain (${l.lines.length} lines)',
        }}',
        scope: 'lyrics',
      );
      return resolved;
    } on Object catch (error) {
      // Deliberately *not* cached: unlike "no lyrics exist for this track", a
      // provider being unreachable is worth retrying when the user next opens
      // the sheet.
      AppLogger.warn('Lookup failed', scope: 'lyrics', error: error);
      return null;
    } finally {
      _inFlight.remove(key);
    }
  }

  void _remember(String key, Lyrics? lyrics) {
    if (_cache.length >= _cacheLimit) _cache.remove(_cache.keys.first);
    _cache[key] = lyrics;
  }

  void clear() {
    _cache.clear();
    _inFlight.clear();
  }
}
