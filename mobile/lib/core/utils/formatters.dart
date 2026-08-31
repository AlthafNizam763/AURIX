import 'package:intl/intl.dart';

/// Formatting helpers shared across screens.
///
/// Centralised so a track's duration reads identically in the album list, the
/// queue, and the full player.
abstract final class Formatters {
  /// `3:07`, or `1:02:33` once an hour is involved.
  static String duration(Duration value) {
    final negative = value.isNegative;
    final total = value.abs();
    final hours = total.inHours;
    final minutes = total.inMinutes.remainder(60);
    final seconds = total.inSeconds.remainder(60);
    final body = hours > 0
        ? '$hours:${_two(minutes)}:${_two(seconds)}'
        : '$minutes:${_two(seconds)}';
    return negative ? '-$body' : body;
  }

  static String durationMs(int milliseconds) =>
      duration(Duration(milliseconds: milliseconds));

  /// `52 min`, `1 hr 14 min` — used for album and playlist totals.
  static String longDuration(Duration value) {
    final hours = value.inHours;
    final minutes = value.inMinutes.remainder(60);
    if (hours == 0) {
      if (minutes == 0) return '${value.inSeconds} sec';
      return '$minutes min';
    }
    if (minutes == 0) return '$hours hr';
    return '$hours hr $minutes min';
  }

  /// `1,204` / `1.2K` / `3.4M` — for follower counts.
  static String compactNumber(int value) {
    if (value < 1000) return value.toString();
    return NumberFormat.compact(locale: 'en_US').format(value).toUpperCase();
  }

  static String groupedNumber(int value) =>
      NumberFormat.decimalPattern('en_US').format(value);

  /// Spotify returns release dates at year, month or day precision.
  /// Renders the most specific form the data actually supports.
  static String releaseDate(String raw, String precision) {
    if (raw.isEmpty) return '';
    try {
      switch (precision) {
        case 'day':
          return DateFormat.yMMMMd('en_US').format(DateTime.parse(raw));
        case 'month':
          final parts = raw.split('-');
          if (parts.length < 2) return raw;
          return DateFormat.yMMMM('en_US')
              .format(DateTime(int.parse(parts[0]), int.parse(parts[1])));
        default:
          return raw.split('-').first;
      }
    } on FormatException {
      return raw;
    }
  }

  /// Just the year, for compact metadata lines.
  static String releaseYear(String raw) =>
      raw.isEmpty ? '' : raw.split('-').first;

  /// `Just now`, `12 min ago`, `Yesterday`, `4 Mar`.
  static String relativeTime(DateTime time) {
    final delta = DateTime.now().difference(time);
    if (delta.inMinutes < 1) return 'Just now';
    if (delta.inMinutes < 60) return '${delta.inMinutes} min ago';
    if (delta.inHours < 24) return '${delta.inHours} hr ago';
    if (delta.inDays == 1) return 'Yesterday';
    if (delta.inDays < 7) return '${delta.inDays} days ago';
    return DateFormat.MMMd('en_US').format(time);
  }

  /// `March 2026`. For "member since" and anything else where the day is noise.
  static String monthYear(DateTime time) =>
      DateFormat.yMMMM('en_US').format(time);

  /// Joins artist names the way a credit line reads.
  static String artistNames(Iterable<String> names) => names.join(', ');

  /// Turns `hip-hop` / `r-n-b` into `Hip Hop` / `R N B` for genre chips.
  static String titleCaseGenre(String genre) {
    if (genre.isEmpty) return genre;
    return genre
        .split(RegExp(r'[-\s]+'))
        .where((word) => word.isNotEmpty)
        .map((word) => word[0].toUpperCase() + word.substring(1))
        .join(' ');
  }

  /// Strips the HTML Spotify allows in playlist descriptions. Descriptions
  /// legitimately contain `<a>` tags and entities; rendering them raw looks
  /// broken, and rendering them as HTML is a needless injection surface.
  static String plainText(String html) {
    if (html.isEmpty) return html;
    return html
        .replaceAll(RegExp(r'<[^>]*>'), '')
        .replaceAll('&amp;', '&')
        .replaceAll('&lt;', '<')
        .replaceAll('&gt;', '>')
        .replaceAll('&quot;', '"')
        .replaceAll('&#x27;', "'")
        .replaceAll('&#39;', "'")
        .replaceAll('&nbsp;', ' ')
        .trim();
  }

  static String _two(int value) => value.toString().padLeft(2, '0');
}
