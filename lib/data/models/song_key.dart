import 'dart:convert';

import 'package:crypto/crypto.dart';

/// How AURIX decides that two songs are the same song.
///
/// ## The problem this solves
///
/// Spotify calls "Blinding Lights" `0VjIjW4GlUZAMYd2vXMi3b`. YouTube calls it
/// `4NRXx6U8ABQ`. Neither id means anything to the other, so a catalogue keyed
/// on provider ids holds the same song twice the moment a user imports one
/// playlist from each service — two rows in search, two hearts to un-like, two
/// entries in history.
///
/// So the catalogue is keyed on what the song *is* rather than on where it came
/// from: a normalised title and a normalised primary artist, hashed into a
/// stable document id. Import the same song from both services and both writes
/// address one document, which then carries both provider ids and can be played
/// by whichever provider is available.
///
/// ## Why normalisation is the hard part
///
/// The two services do not describe the same song the same way:
///
/// ```
/// Spotify   Blinding Lights                        The Weeknd
/// YouTube   The Weeknd - Blinding Lights (Official Video)   The Weeknd - Topic
/// ```
///
/// [normaliseTitle] and [normaliseArtist] are the rules that collapse those
/// onto one key. They are deliberately conservative: a rule that is too
/// aggressive merges songs that are genuinely different, which is worse than
/// leaving a duplicate. The distinction drawn throughout is between *packaging*
/// and *recording* — "(Official Video)", "[4K]" and "Remastered 2011" describe
/// the upload, so they are stripped; "Live", "Acoustic", "Remix" and
/// "Instrumental" describe a different performance, so they are kept and
/// produce their own catalogue entry.
abstract final class SongKey {
  /// The catalogue document id for a song.
  ///
  /// `sng_<slug>_<hash>`. Both halves earn their place: the slug makes a
  /// Firestore console session legible without a lookup table, and the hash is
  /// what actually guarantees uniqueness once the slug has been truncated to
  /// keep document ids a sane length.
  static String of({required String title, required String artist}) {
    final normalisedTitle = normaliseTitle(title);
    final normalisedArtist = normaliseArtist(artist);

    // The hash is taken over the *full* normalised pair, before truncation, so
    // two long titles that share their first 80 characters still differ.
    final canonical = '$normalisedTitle|$normalisedArtist';
    final digest = sha1.convert(utf8.encode(canonical)).toString();

    final slug = _slug('$normalisedTitle-$normalisedArtist');
    final trimmed = slug.length <= 80 ? slug : slug.substring(0, 80);

    // An untitled, artist-less row would otherwise slug to nothing and collide
    // with every other one. The hash still separates them.
    final body = trimmed.isEmpty ? 'untitled' : trimmed;

    return 'sng_${body}_${digest.substring(0, 10)}';
  }

  /// True when [id] looks like a key this class produced.
  static bool isSongKey(String id) => id.startsWith('sng_');

  // ---- Normalisation -----------------------------------------------------

  /// Packaging noise that describes the *upload*, not the recording.
  ///
  /// Stripped wherever it appears, in brackets or not. Every entry here is a
  /// phrase that two services would disagree about for the same audio.
  static final RegExp _packaging = RegExp(
    r'\b('
    r'official\s+(music\s+)?video|official\s+audio|official\s+lyric\s+video|'
    r'official\s+visuali[sz]er|official\s+hd\s+video|official|'
    r'lyric\s+video|lyrics\s+video|with\s+lyrics|visuali[sz]er|'
    r'music\s+video|audio\s+only|full\s+audio|hq\s+audio|'
    r'remaster(ed)?(\s+\d{4})?|\d{4}\s+remaster(ed)?|'
    r'digital\s+remaster(ed)?|'
    r'explicit|clean\s+version|'
    r'4k|8k|hd|hq|uhd|'
    r'free\s+download|out\s+now'
    r')\b',
    caseSensitive: false,
  );

  /// Featured-artist credits, which the two services attach to different
  /// fields — Spotify puts them in the artist list, YouTube in the title.
  ///
  /// Removed from the title so both spellings converge. The credit is not lost:
  /// the full artist string is still stored on the document and is still
  /// searchable — this only affects the *identity* key.
  ///
  /// Note where the word boundary sits. It has to close immediately after the
  /// letters and *before* the optional period, because `\b` is a boundary
  /// between a word and a non-word character — after "feat." the next
  /// character is a space, and two non-word characters have no boundary
  /// between them. Written the other way round the pattern silently never
  /// matches the commonest spelling of all, "feat.".
  ///
  /// "with" is deliberately absent from the alternation, unlike "feat" and
  /// "ft". It is an ordinary English word in a title — "Dancing With Myself",
  /// "Stand With Me" — and treating it as a credit marker would truncate real
  /// titles at their midpoint.
  static final RegExp _featuring = RegExp(
    r'\s*[\(\[]?\s*\b(?:feat|ft|featuring)\b\.?\s+[^\)\]]*[\)\]]?',
    caseSensitive: false,
  );

  /// Empty brackets left behind once the packaging inside them is gone, plus
  /// any bracket group that is now only punctuation.
  static final RegExp _emptyBrackets = RegExp(r'[\(\[\{]\s*[^A-Za-z0-9]*\s*[\)\]\}]');

  /// A trailing channel marker YouTube appends to auto-generated artist
  /// channels — "The Weeknd - Topic".
  static final RegExp _topicSuffix = RegExp(r'\s*-\s*topic\s*$', caseSensitive: false);

  static final RegExp _vevoSuffix = RegExp(r'vevo\s*$', caseSensitive: false);

  /// Normalises a song title for identity comparison.
  ///
  /// Strips packaging and featured credits, folds accents, drops punctuation
  /// and collapses whitespace. Deliberately keeps words that name a different
  /// recording — live, remix, acoustic, instrumental, radio edit — because two
  /// recordings of one song are two catalogue entries, not one.
  static String normaliseTitle(String value) {
    var out = _foldAccents(value.toLowerCase());
    out = out.replaceAll(_featuring, ' ');
    out = out.replaceAll(_packaging, ' ');
    out = out.replaceAll(_emptyBrackets, ' ');
    return _collapse(out);
  }

  /// Normalises an artist credit down to the **primary** artist.
  ///
  /// Only the first credit survives, because the services disagree about the
  /// rest: Spotify lists every collaborator on the track, YouTube names one
  /// channel. Keeping the full list would mean "Starboy" imported from each
  /// service produced two catalogue entries — one credited "The Weeknd, Daft
  /// Punk" and one credited "The Weeknd".
  static String normaliseArtist(String value) {
    var out = _foldAccents(value.toLowerCase());
    out = out.replaceAll(_topicSuffix, ' ');

    // Split on the separators that introduce a *secondary* credit. A comma or
    // an ampersand always does; " x " does in collaboration titles.
    for (final separator in <Pattern>[
      ',',
      '&',
      RegExp(r'\bfeat\.?\b'),
      RegExp(r'\bft\.?\b'),
      RegExp(r'\bfeaturing\b'),
      RegExp(r'\bvs\.?\b'),
      RegExp(r'\bwith\b'),
      RegExp(r'\s+x\s+'),
    ]) {
      final index = out.indexOf(separator);
      if (index > 0) out = out.substring(0, index);
    }

    out = out.replaceAll(_vevoSuffix, ' ');
    return _collapse(out);
  }

  /// Normalises an album name.
  ///
  /// Used as a *tie-breaker* when matching across services rather than as part
  /// of the key — see the note in `CatalogRepository`. It is not in [of]
  /// because YouTube rarely knows an album at all, so including it would stop
  /// a YouTube import from ever matching the Spotify entry for the same song.
  static String normaliseAlbum(String value) {
    var out = _foldAccents(value.toLowerCase());
    out = out.replaceAll(_packaging, ' ');
    out = out.replaceAll(_emptyBrackets, ' ');
    return _collapse(out);
  }

  /// A YouTube video title split into artist and title, where it can be.
  ///
  /// YouTube has no structured artist field — a music video is
  /// `Artist - Title (Official Video)` by convention and nothing more. This
  /// applies that convention and reports whether it held.
  ///
  /// Returns null when the title has no separator, in which case the caller
  /// should keep the raw title and credit the channel. Guessing harder than
  /// this produces confidently wrong metadata that then lives in the user's
  /// library forever.
  static ({String artist, String title})? splitVideoTitle(String raw) {
    // The en-dash and em-dash are as common as the hyphen in upload titles.
    final match = RegExp(r'^(.{1,80}?)\s+[-–—]\s+(.+)$').firstMatch(raw.trim());
    if (match == null) return null;

    final artist = match.group(1)!.trim();
    final title = match.group(2)!.trim();
    if (artist.isEmpty || title.isEmpty) return null;

    return (artist: artist, title: title);
  }

  // ---- Helpers -----------------------------------------------------------

  /// Maps accented Latin characters onto their unaccented forms.
  ///
  /// Hand-written rather than pulled from a package: this is the whole of what
  /// AURIX needs, it is a table lookup, and adding an intl dependency for
  /// twenty-odd characters is not a trade worth making. Anything outside the
  /// table passes through unchanged, so non-Latin titles are unaffected —
  /// they normalise consistently, which is all the key requires.
  static String _foldAccents(String value) {
    const from = 'àáâãäåèéêëìíîïòóôõöùúûüýÿñçšžæøåđłß';
    const to = 'aaaaaaeeeeiiiiooooouuuuyyncszaoadls';

    final buffer = StringBuffer();
    for (final rune in value.runes) {
      final char = String.fromCharCode(rune);
      final index = from.indexOf(char);
      buffer.write(index == -1 ? char : to[index]);
    }
    return buffer.toString();
  }

  /// Everything that is not a letter, digit or space becomes a space, then
  /// runs of space collapse to one.
  static String _collapse(String value) => value
      .replaceAll(RegExp(r'[^a-z0-9\s]'), ' ')
      .replaceAll(RegExp(r'\s+'), ' ')
      .trim();

  /// A normalised string as a Firestore-safe document-id fragment.
  static String _slug(String value) => value
      .replaceAll(RegExp(r'[^a-z0-9]+'), '-')
      .replaceAll(RegExp(r'-{2,}'), '-')
      .replaceAll(RegExp(r'^-+|-+$'), '');
}

/// Builds the token array that makes a catalogue document findable.
///
/// ## Why an array of prefixes and not a `>=` range query
///
/// Firestore has no full-text search. The two ways to approximate one are a
/// range scan on a sortable field (`where(title, >=, q).where(title, <, q~)`)
/// and an `array-contains` on a precomputed token set. AURIX uses the second,
/// for one reason that decides it: a range scan can only match a prefix of the
/// *whole field*, so "lights" would never find "Blinding Lights". Searching for
/// a word in the middle of a title is the normal case, not an edge case.
///
/// So every word of the title, artist and album is expanded to its prefixes at
/// write time, and a query is one indexed `array-contains` with a `limit`.
/// A keystroke costs a bounded page of reads — never a collection scan, which
/// is the requirement this exists to satisfy.
///
/// ## The costs, stated plainly
///
///  * **Write amplification.** A song document carries up to [maxTokens]
///    strings, each of which is an index entry. That is the price of the read
///    being cheap, and it is paid once per import rather than once per search.
///  * **No typo tolerance.** "blnding" matches nothing. Fuzzy ranking needs a
///    real search service; this is the point at which one would be added, and
///    `CatalogSearchProvider` is the seam for it.
abstract final class SearchTokens {
  /// The longest prefix generated per word.
  ///
  /// Beyond this the prefixes stop being useful — by twelve characters the
  /// user has effectively typed the whole word — and each one costs an index
  /// entry on every document.
  static const int maxPrefix = 12;

  /// A ceiling on the array, so a pathological title cannot bloat a document.
  static const int maxTokens = 180;

  /// Words too short to be worth indexing on their own.
  ///
  /// Stop words are excluded as *whole tokens* but their prefixes still appear
  /// via longer words, so searching "the weeknd" still works — "the" simply
  /// does not match every song in the catalogue on its own.
  static const Set<String> _stopWords = <String>{
    'the', 'a', 'an', 'and', 'or', 'of', 'in', 'on', 'at', 'to', 'for',
  };

  /// The token set for one song.
  static List<String> forSong({
    required String title,
    required String artist,
    String album = '',
  }) {
    final tokens = <String>{};

    for (final field in <String>[
      SongKey.normaliseTitle(title),
      SongKey.normaliseArtist(artist),
      // The *full* artist credit as well as the primary one, so a search for a
      // featured artist finds the track they are on.
      SongKey._collapse(SongKey._foldAccents(artist.toLowerCase())),
      SongKey.normaliseAlbum(album),
    ]) {
      _addPrefixes(field, tokens);
      if (tokens.length >= maxTokens) break;
    }

    return tokens.take(maxTokens).toList(growable: false);
  }

  /// The token set for a playlist name.
  static List<String> forPlaylist(String name) {
    final tokens = <String>{};
    _addPrefixes(SongKey.normaliseAlbum(name), tokens);
    return tokens.take(maxTokens).toList(growable: false);
  }

  /// The single token a query should be matched on.
  ///
  /// A multi-word query cannot be one `array-contains` — Firestore allows only
  /// one per query — so the *longest* word is sent to the index and the rest
  /// are applied client-side over the bounded result page. Longest because it
  /// is the most selective: "blinding lights" queries on "blinding", which
  /// returns few documents, rather than on "lights", which returns many.
  ///
  /// Returns an empty string when the query has nothing indexable in it.
  static String queryToken(String query) {
    final words = SongKey.normaliseAlbum(query)
        .split(' ')
        .where((word) => word.isNotEmpty)
        .toList()
      ..sort((a, b) => b.length.compareTo(a.length));

    if (words.isEmpty) return '';
    final longest = words.first;
    return longest.length <= maxPrefix
        ? longest
        : longest.substring(0, maxPrefix);
  }

  /// The words a result must contain, beyond [queryToken].
  ///
  /// Applied in memory over the page the index returned — see the note there.
  static List<String> residualWords(String query) {
    final words = SongKey.normaliseAlbum(query)
        .split(' ')
        .where((word) => word.isNotEmpty)
        .toList()
      ..sort((a, b) => b.length.compareTo(a.length));

    return words.length <= 1
        ? const <String>[]
        : words.sublist(1).toList(growable: false);
  }

  static void _addPrefixes(String field, Set<String> into) {
    for (final word in field.split(' ')) {
      if (word.isEmpty) continue;
      if (into.length >= maxTokens) return;

      // A stop word is still indexed in full when it is the entire field —
      // a playlist genuinely called "The" should be findable.
      final skipWhole = _stopWords.contains(word) && field != word;

      final limit = word.length < maxPrefix ? word.length : maxPrefix;
      for (var length = 1; length <= limit; length++) {
        if (skipWhole && length == word.length) continue;
        into.add(word.substring(0, length));
        if (into.length >= maxTokens) return;
      }
    }
  }
}
