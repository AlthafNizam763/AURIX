import 'package:dio/dio.dart';

import '../../core/utils/app_logger.dart';
import '../models/lyrics.dart';

// The lyrics UI imports this file for both the contract and the model, so the
// model is re-exported rather than forcing every widget to import two paths.
export '../models/lyrics.dart';

/// A source of lyrics.
///
/// ## Why this is an interface
///
/// The Spotify Web API does not serve lyrics, and Spotify's Developer Terms do
/// not permit extracting them from the Spotify client or deriving them from its
/// audio. AURIX does neither. So lyrics come from somewhere else, under that
/// source's own terms — and which source is a deployment decision, not an
/// architectural one. AURIX ships one implementation and can take another
/// without any screen knowing.
///
/// Implementations must never be handed a Spotify access token, and never a
/// Spotify URI to resolve. They get a title, an artist and a length.
abstract class LyricsProvider {
  /// Display name, shown as attribution under the lyrics.
  String get name;

  /// Returns lyrics for [query], or null when this provider has none.
  ///
  /// Null is the ordinary negative answer — no catalogue covers every track.
  /// Throwing is for a provider that is broken or unreachable, which the
  /// repository treats differently because it is worth retrying.
  Future<Lyrics?> fetch(LyricsQuery query);
}

/// Lyrics from LRCLIB.
///
/// ## Why this provider
///
/// LRCLIB is an open, community-contributed lyrics database with a public API
/// that needs no key and permits third-party clients — which is why it is the
/// implementation AURIX ships. Swapping it for a commercially licensed provider
/// means writing another [LyricsProvider] and changing one line in
/// `app_providers.dart`; no screen knows the difference.
///
/// ## What it is never given
///
/// Its Dio instance is built here rather than shared with the Spotify client,
/// and that is the point: the Spotify [Dio] carries an `AuthInterceptor` that
/// attaches the user's bearer token to every request it sends. Reusing it would
/// mail that token to a third-party host on every lyric lookup. This client has
/// no interceptors, no token, and no Spotify base URL.
class LrcLibLyricsService implements LyricsProvider {
  LrcLibLyricsService({Dio? client}) : _dio = client ?? _buildClient();

  final Dio _dio;

  static const String _baseUrl = 'https://lrclib.net';

  /// How far a search hit's length may differ from the track before it is
  /// treated as a different song that happens to share a name.
  static const int _durationToleranceSeconds = 20;

  @override
  String get name => 'LRCLIB';

  /// A plain client. See the class doc for why this is not the Spotify one.
  ///
  /// LRCLIB asks clients to identify themselves in the User-Agent so it can
  /// contact the operators of misbehaving ones; giving it a real name is the
  /// polite minimum for using a free, donation-funded service.
  static Dio _buildClient() => Dio(
    BaseOptions(
      baseUrl: _baseUrl,
      connectTimeout: const Duration(seconds: 8),
      receiveTimeout: const Duration(seconds: 10),
      responseType: ResponseType.json,
      headers: const <String, String>{
        'Accept': 'application/json',
        'User-Agent': 'AURIX (Flutter music client)',
      },
      // 404 is LRCLIB's ordinary "no lyrics for this track" answer, not a
      // failure — letting it through as data keeps it out of the error path.
      validateStatus: (status) =>
          status != null && (status < 400 || status == 404),
    ),
  );

  @override
  Future<Lyrics?> fetch(LyricsQuery query) async {
    if (!query.isUsable) return null;

    // The exact-match endpoint first: it takes the duration, which is what
    // separates a three-minute radio edit from the seven-minute album cut that
    // shares its title and artist. A wrong-length match drifts further out of
    // sync the longer the song runs.
    final direct = await _get(query);
    if (direct != null) return direct;

    // Nothing matched exactly. Search is looser — no album, no duration — and
    // covers the common case of Spotify's album name differing from the one
    // contributors filed the lyrics under (deluxe editions, reissues).
    return _search(query);
  }

  Future<Lyrics?> _get(LyricsQuery query) async {
    try {
      final response = await _dio.get<dynamic>(
        '/api/get',
        queryParameters: <String, dynamic>{
          'artist_name': query.artist,
          'track_name': query.title,
          if (query.album != null && query.album!.isNotEmpty)
            'album_name': query.album,
          if (query.duration != null) 'duration': query.duration!.inSeconds,
        },
      );
      if (response.statusCode == 404) return null;
      final data = response.data;
      return data is Map<String, dynamic> ? _parse(data) : null;
    } on DioException catch (error) {
      // Lyrics are an enhancement. A provider being down must never take the
      // player screen with it, so this reports and yields nothing.
      AppLogger.debug(
        'get failed: ${error.response?.statusCode ?? error.type.name}',
        scope: 'lyrics',
      );
      return null;
    }
  }

  Future<Lyrics?> _search(LyricsQuery query) async {
    try {
      final response = await _dio.get<dynamic>(
        '/api/search',
        queryParameters: <String, dynamic>{
          'track_name': query.title,
          'artist_name': query.artist,
        },
      );

      final data = response.data;
      if (data is! List || data.isEmpty) return null;

      final candidates = data.whereType<Map<String, dynamic>>().toList();
      if (candidates.isEmpty) return null;

      // Prefer the closest duration when one is known — the same title by the
      // same artist is routinely filed several times (single, album, remaster),
      // and a mismatch of even a few seconds visibly desynchronises the
      // highlight. Then prefer a hit that actually carries timestamps.
      final target = query.duration?.inSeconds;
      candidates.sort((a, b) {
        if (target != null) {
          final da = (_seconds(a['duration']) - target).abs();
          final db = (_seconds(b['duration']) - target).abs();
          if (da != db) return da.compareTo(db);
        }
        final sa = _nonEmpty(a['syncedLyrics']) ? 0 : 1;
        final sb = _nonEmpty(b['syncedLyrics']) ? 0 : 1;
        return sa.compareTo(sb);
      });

      // Better no lyrics than confidently wrong ones.
      final best = candidates.first;
      if (target != null &&
          (_seconds(best['duration']) - target).abs() > _durationToleranceSeconds) {
        return null;
      }
      return _parse(best);
    } on DioException catch (error) {
      AppLogger.debug(
        'search failed: ${error.response?.statusCode ?? error.type.name}',
        scope: 'lyrics',
      );
      return null;
    }
  }

  Lyrics? _parse(Map<String, dynamic> json) {
    if (json['instrumental'] == true) return Lyrics.instrumental(name);

    final synced = json['syncedLyrics'];
    if (synced is String && synced.trim().isNotEmpty) {
      final lines = _parseLrc(synced);
      if (lines.isNotEmpty) {
        return Lyrics(lines: lines, provider: name, isSynced: true);
      }
    }

    final plain = json['plainLyrics'];
    if (plain is String && plain.trim().isNotEmpty) {
      return Lyrics(
        lines: plain
            .split('\n')
            .map((line) => LyricLine(text: line.trimRight()))
            .toList(growable: false),
        provider: name,
      );
    }

    return null;
  }

  /// Parses LRC: `[mm:ss.xx] text`, one entry per timestamp.
  ///
  /// Tolerant on purpose — this is community-contributed data. A line whose
  /// timestamp does not parse is dropped rather than taking the file with it,
  /// and the result is sorted by time because a hand-edited file is not
  /// guaranteed to be in order and [Lyrics.lineIndexAt] binary-searches on the
  /// assumption that it is.
  static List<LyricLine> _parseLrc(String raw) {
    final pattern = RegExp(r'\[(\d{1,3}):(\d{2})(?:[.:](\d{1,3}))?\]');
    final lines = <LyricLine>[];

    for (final row in raw.split('\n')) {
      final matches = pattern.allMatches(row).toList();
      if (matches.isEmpty) continue;

      final text = row.substring(matches.last.end).trim();

      // A row may carry several timestamps when a line repeats through the
      // song — each becomes its own entry, or the repeat never highlights.
      for (final match in matches) {
        final minutes = int.tryParse(match.group(1) ?? '');
        final seconds = int.tryParse(match.group(2) ?? '');
        if (minutes == null || seconds == null) continue;

        lines.add(
          LyricLine(
            text: text,
            at: Duration(
              minutes: minutes,
              seconds: seconds,
              milliseconds: _fractionToMillis(match.group(3)),
            ),
          ),
        );
      }
    }

    lines.sort(
      (a, b) => (a.at ?? Duration.zero).compareTo(b.at ?? Duration.zero),
    );
    return lines;
  }

  /// `.5` means half a second, not five milliseconds — so the fraction is
  /// scaled by its own width rather than assumed to be hundredths.
  static int _fractionToMillis(String? fraction) {
    if (fraction == null || fraction.isEmpty) return 0;
    final value = int.tryParse(fraction) ?? 0;
    return switch (fraction.length) {
      1 => value * 100,
      2 => value * 10,
      _ => value,
    };
  }

  static bool _nonEmpty(Object? value) =>
      value is String && value.trim().isNotEmpty;

  static int _seconds(Object? value) => switch (value) {
    final int v => v,
    final double v => v.round(),
    final String v => (double.tryParse(v) ?? 0).round(),
    _ => 0,
  };
}
