import 'dart:convert';

import 'package:crypto/crypto.dart';

import 'media_source.dart';

/// How AURIX decides that two imports are the *same* imported playlist.
///
/// ## The problem this solves
///
/// The global playlist catalogue is shared. User A imports
/// `open.spotify.com/playlist/37i9dQZF1DX3lmpQSniUBH` on Monday; User B pastes
/// the same link on Friday. Both writes must land on one document, or the
/// catalogue grows a second "Love" for every user who imports it and search
/// returns the same playlist five times.
///
/// The identity is the pair (`source`, `sourcePlaylistId`) — Spotify's id means
/// nothing to YouTube, so the source has to qualify it. This class turns that
/// pair into the Firestore document id, which is what makes de-duplication
/// *structural* rather than a check that can lose a race: there is no
/// read-then-write window, because the id **is** the check. Two devices
/// importing the same playlist at the same moment address one document and the
/// second write merges into the first.
///
/// The same reasoning, and the same trade, as [TrackKey] and [SongKey].
///
/// ## The shape
///
/// `pl_<source>_<sourceId>` — `pl_spotify_37i9dQZF1DX3lmpQSniUBH`. Legible in
/// the Firestore console without a lookup table, which matters for a collection
/// every user can read and nobody owns.
///
/// A source id that is not safe as a document id falls back to
/// `pl_<source>_<sha1>`. Spotify and YouTube both issue ids from
/// `[A-Za-z0-9_-]`, so the fallback is defensive rather than routine — but
/// Firestore rejects `/` in a document id outright, and a write that fails for
/// one unlucky playlist is worse than an id nobody can read.
///
/// ## Why the `pl_` prefix earns its place
///
/// It is how the app tells a *global* playlist id from a *personal* one without
/// a probe read. `/playlist/:id` carries nothing but an id, and the screen
/// behind it has to know which collection to open. Firestore's own auto-ids are
/// 20 characters drawn from `[A-Za-z0-9]` — no underscore — so a personal
/// playlist created with `.doc()` can never begin with `pl_`, and the test is
/// exact rather than a heuristic.
abstract final class PlaylistKey {
  /// What every global playlist document id starts with. See the class comment.
  static const String prefix = 'pl_';

  /// The global catalogue document id for a playlist at [source].
  static String of({required MediaSource source, required String sourceId}) {
    final trimmed = sourceId.trim();
    final body = _isSafe(trimmed) ? trimmed : _hash(trimmed);
    return '$prefix${source.wireValue}_$body';
  }

  /// True when [id] addresses the shared catalogue rather than a user's own
  /// `/users/{uid}/playlists` collection.
  static bool isGlobal(String id) => id.startsWith(prefix);

  /// Ids Firestore accepts and a human can read back. Bounded well under
  /// Firestore's 1500-byte limit.
  static final RegExp _safe = RegExp(r'^[A-Za-z0-9._~-]{1,120}$');

  static bool _isSafe(String value) =>
      value.isNotEmpty && _safe.hasMatch(value) && !value.startsWith('__');

  /// Stable, collision-free, and never empty — the properties the id needs when
  /// the source id itself cannot supply them.
  static String _hash(String value) =>
      sha1.convert(utf8.encode(value)).toString().substring(0, 24);
}
