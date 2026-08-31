import 'package:equatable/equatable.dart';

/// One line of lyrics, with a timestamp when the provider supplied one.
class LyricLine extends Equatable {
  const LyricLine({required this.text, this.at});

  /// The line itself. May be empty — an instrumental break is a real line in a
  /// synced file, and dropping it would make the highlight skip.
  final String text;

  /// Where this line starts. Null in a plain-text lyric.
  final Duration? at;

  bool get isBlank => text.trim().isEmpty;

  @override
  List<Object?> get props => [text, at];
}

/// Lyrics for one track, from one provider.
///
/// Deliberately carries [provider]: lyrics are licensed content, and a screen
/// that shows them owes the source an attribution line.
class Lyrics extends Equatable {
  const Lyrics({
    required this.lines,
    required this.provider,
    this.isSynced = false,
    this.isInstrumental = false,
  });

  /// An instrumental — the provider positively said this track has no words.
  ///
  /// Distinct from having no lyrics *available*, which is why it is a state
  /// rather than an empty result: "this song has no words" and "nobody has
  /// transcribed this song" deserve different messages.
  const Lyrics.instrumental(this.provider)
    : lines = const <LyricLine>[],
      isSynced = false,
      isInstrumental = true;

  final List<LyricLine> lines;

  /// Display name of the source, shown as attribution under the lyrics.
  final String provider;

  /// True when the lines carry timestamps and the UI may follow playback.
  final bool isSynced;

  final bool isInstrumental;

  bool get isEmpty => lines.isEmpty;

  /// The whole lyric as plain text, for the untimed view.
  String get asText => lines.map((l) => l.text).join('\n');

  /// Index of the line playing at [position], or -1 before the first one.
  ///
  /// Binary search, not a scan. This is called on every position tick from two
  /// widgets at once, and synced files for dense tracks run past 200 lines —
  /// an O(n) walk per frame is affordable until it very suddenly is not.
  /// Correct only because [LyricsProvider] implementations sort by time.
  int lineIndexAt(Duration position) {
    if (!isSynced || lines.isEmpty) return -1;

    var low = 0;
    var high = lines.length - 1;
    var found = -1;

    while (low <= high) {
      final mid = (low + high) ~/ 2;
      final at = lines[mid].at;
      if (at == null || at > position) {
        high = mid - 1;
      } else {
        found = mid;
        low = mid + 1;
      }
    }
    return found;
  }

  @override
  List<Object?> get props => [lines, provider, isSynced, isInstrumental];
}

/// What a lyrics lookup needs to identify a song.
///
/// Deliberately not a `Track`: a lyrics provider is not a Spotify client, and
/// handing it a Spotify model would be the first step toward one leaking the
/// other's identifiers. [trackId] is carried only as a cache key and is never
/// sent anywhere.
class LyricsQuery extends Equatable {
  const LyricsQuery({
    required this.trackId,
    required this.title,
    required this.artist,
    this.album,
    this.duration,
  });

  final String trackId;
  final String title;
  final String artist;
  final String? album;

  /// Track length, when known. Providers use it to tell a radio edit from the
  /// album version that shares its title and artist.
  final Duration? duration;

  bool get isUsable => title.trim().isNotEmpty && artist.trim().isNotEmpty;

  @override
  List<Object?> get props => [trackId, title, artist, album, duration];
}
