import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/network/api_exception.dart';
import '../../../core/providers/app_providers.dart';
import '../../../core/utils/app_logger.dart';
import '../../../data/models/track.dart';

/// Which tracks the signed-in user has liked — one answer for the whole app.
///
/// ## Why this exists
///
/// Every heart in AURIX used to answer for itself. The player screen held a
/// `bool? _isSaved` and looked its track up on mount; the album and playlist
/// screens each watched their own `savedTrackIdsProvider` family entry; Liked
/// Songs assumed everything in it was saved. So liking a song in the player
/// left the same song's heart empty in the playlist behind it, and the only
/// thing that reconciled them was leaving the screen and coming back — the
/// "requires a full page refresh" symptom.
///
/// This is the one place that knows. It is a cache, a de-duplicator and the
/// write path in one, because those three have to agree: a lookup that races a
/// toggle must not overwrite the toggle's result, and only a single owner of
/// the map can guarantee that.
///
/// ## What it costs Spotify
///
/// One `GET /me/library/contains` per batch of never-before-seen IDs. A track
/// already in [SavedTracksState.known] is never asked about again, and IDs
/// already being asked about are not asked about twice — so scrolling a
/// playlist that shares tracks with Liked Songs costs nothing after the first
/// screenful, and reopening a screen costs nothing at all.
class SavedTracksState {
  const SavedTracksState({this.known = const <String, bool>{}});

  /// Track ID → saved. Absent means "not asked yet", which is deliberately
  /// distinct from present-and-false: an unfilled heart is a claim about the
  /// user's library, and the app should not make it before it knows.
  final Map<String, bool> known;

  /// Null when the answer is not known yet — render an indeterminate heart.
  bool? operator [](String id) => known[id];

  bool contains(String id) => known[id] ?? false;

  /// Returns `this` — the *same instance* — when nothing actually changes.
  ///
  /// Load-bearing, not an optimisation. Callers seed this from `build` (Liked
  /// Songs re-seeds its rows on every frame), so an unconditional new map would
  /// be a new state object, which notifies every listener, which rebuilds the
  /// screen, which seeds again: an infinite loop. Identity here makes seeding
  /// idempotent and the loop impossible.
  SavedTracksState withAll(Map<String, bool> updates) {
    final changed = <String, bool>{
      for (final entry in updates.entries)
        if (known[entry.key] != entry.value) entry.key: entry.value,
    };
    if (changed.isEmpty) return this;
    return SavedTracksState(known: <String, bool>{...known, ...changed});
  }
}

class SavedTracksController extends Notifier<SavedTracksState> {
  /// IDs with a `contains` lookup in the air, so a list and the player asking
  /// about the same track in the same frame cost one request rather than two.
  final Set<String> _inFlight = <String>{};

  /// Tracks the user has explicitly liked or unliked in this session.
  ///
  /// The guard against a stale lookup clobbering a toggle. A `contains` request
  /// that was already in the air when the user tapped carries the *pre-toggle*
  /// truth, and applying it would flip the heart back under their finger.
  ///
  /// A "write in progress" flag is not enough, and that is worth spelling out
  /// because it is the obvious implementation and it is wrong: an 80ms
  /// `contains` racing a 120ms `PUT` lands *after* the write cleared the flag,
  /// and the stale answer is then applied with nothing to stop it. Nor is
  /// comparing timestamps around the request, because the lookup can be
  /// dispatched after the `PUT` was sent and still read pre-write state off
  /// Spotify's servers.
  ///
  /// So the rule is ownership rather than ordering: once the user has said what
  /// they want for a track, that answer holds for the session and no background
  /// lookup overrides it. Spotify is still the source of truth — it is re-read
  /// from scratch on the next launch, and the write either landed or was rolled
  /// back and reported.
  final Set<String> _userSet = <String>{};

  Timer? _batchTimer;
  final Set<String> _queued = <String>{};

  /// How long to gather IDs before asking.
  ///
  /// A list builds its rows one at a time, so a 50-row playlist would otherwise
  /// fire 50 single-URI requests. One frame of latency collapses them into one
  /// request of 40 (the endpoint's cap) plus a remainder.
  static const Duration _batchWindow = Duration(milliseconds: 60);

  @override
  SavedTracksState build() {
    ref.onDispose(() {
      _batchTimer?.cancel();
      _batchTimer = null;
    });
    return const SavedTracksState();
  }

  /// Reads the cached answer without triggering a lookup. Null = unknown.
  bool? peek(String id) => state.known[id];

  /// Makes sure [ids] will have an answer, without blocking the caller.
  ///
  /// Safe to call from `build()` — it queues rather than requesting, and it
  /// never calls `state =` synchronously, so it cannot mark the widget dirty
  /// during its own build. That property is the reason this is a queue and not
  /// a plain `await`.
  void ensureKnown(Iterable<String> ids) {
    var added = false;
    for (final id in ids) {
      if (id.isEmpty) continue;
      if (state.known.containsKey(id)) continue;
      if (_inFlight.contains(id) || _queued.contains(id)) continue;
      _queued.add(id);
      added = true;
    }
    if (!added || _batchTimer != null) return;
    _batchTimer = Timer(_batchWindow, _flush);
  }

  Future<void> _flush() async {
    _batchTimer = null;
    if (_queued.isEmpty) return;

    final batch = _queued.toList(growable: false);
    _queued.clear();
    _inFlight.addAll(batch);

    try {
      final saved = await ref.read(libraryRepositoryProvider).savedTrackIds(batch);
      _apply(<String, bool>{for (final id in batch) id: saved.contains(id)});
    } on Object catch (error) {
      // `savedTrackIds` already degrades a refusal to an empty set, so reaching
      // here means something else went wrong. Leave the IDs unknown rather than
      // recording a false "not saved" — the next screen that needs them retries.
      AppLogger.debug('Saved-track batch failed: $error', scope: 'library');
    } finally {
      _inFlight.removeAll(batch);
    }
  }

  /// Writes lookup answers into the map, dropping any the user has since
  /// overridden by tapping — see [_userSet].
  void _apply(Map<String, bool> answers) {
    final usable = <String, bool>{
      for (final entry in answers.entries)
        if (!_userSet.contains(entry.key)) entry.key: entry.value,
    };
    if (usable.isEmpty) return;
    state = state.withAll(usable);
  }

  /// Records saved state the app already knows without asking Spotify.
  ///
  /// Liked Songs is a list of saved tracks by definition, so seeding from it
  /// means opening that screen answers every heart on it for free.
  void seedSaved(Iterable<String> ids, {bool saved = true}) {
    // A track the user has toggled is not re-asserted by a seed: Liked Songs
    // re-seeds from a list that still holds a row the user just unliked.
    final updates = <String, bool>{
      for (final id in ids)
        if (id.isNotEmpty && !_userSet.contains(id)) id: saved,
    };
    if (updates.isEmpty) return;
    // Seeds arrive from provider listeners, which can fire mid-build. Deferring
    // keeps this out of the frame that is already building.
    Future.microtask(() => state = state.withAll(updates));
  }

  /// Likes or unlikes [track], updating every heart in the app at once.
  ///
  /// Optimistic, and rolled back on failure — the heart moves on the tap, and
  /// moves back if Spotify refuses. Returns the resulting saved state, or null
  /// if the write failed.
  Future<bool?> toggle(Track track) async {
    if (track.id.isEmpty) return null;
    return setSaved(track, saved: !(state.known[track.id] ?? false));
  }

  /// Sets [track]'s saved state explicitly. See [toggle].
  Future<bool?> setSaved(Track track, {required bool saved}) async {
    final id = track.id;
    if (id.isEmpty) return null;

    final previous = state.known[id];
    if (previous == saved) return saved;

    // Claimed before anything else, so a lookup already in the air — or one
    // dispatched while this write is still travelling — cannot undo it.
    _userSet.add(id);

    // Kept so Liked Songs can rebuild a row for a track liked on another
    // screen — the state map holds IDs, and a row needs the whole track.
    _remember(track);

    state = state.withAll(<String, bool>{id: saved});

    final library = ref.read(libraryRepositoryProvider);
    try {
      if (saved) {
        await library.saveTrack(track);
      } else {
        await library.unsaveTrack(track);
      }
      AppLogger.info(
        '${saved ? 'Liked' : 'Unliked'} ${track.id}',
        scope: 'library',
      );
      return saved;
    } on ApiException catch (error) {
      // Rolled back to what was there before — including back to *unknown*,
      // which is the honest state when the app never got an answer to begin
      // with. Never silently swallowed: the caller surfaces `error.message`.
      _rollback(id, previous);
      AppLogger.warn(
        'Library write refused — ${error.statusCode} '
        '${saved ? 'PUT' : 'DELETE'} ${error.endpoint ?? '/me/library'}'
        '${error.reason == null ? '' : ' (${error.reason})'}',
        scope: 'library',
      );
      rethrow;
    } on Object catch (error) {
      _rollback(id, previous);
      AppLogger.warn('Library write failed', scope: 'library', error: error);
      rethrow;
    }
  }

  void _rollback(String id, bool? previous) {
    if (previous == null) {
      // Back to genuinely unknown, so ownership is released too — otherwise a
      // track whose very first like failed would be locked out of every future
      // lookup and its heart would stay disabled for the rest of the session.
      _userSet.remove(id);
      final next = Map<String, bool>.from(state.known)..remove(id);
      state = SavedTracksState(known: next);
      return;
    }
    state = state.withAll(<String, bool>{id: previous});
  }

  /// Tracks the user has toggled, so a row can be reconstructed for Liked
  /// Songs. Bounded — this only holds what one session's tapping produced.
  final Map<String, Track> _toggled = <String, Track>{};
  static const int _toggledLimit = 200;

  void _remember(Track track) {
    if (_toggled.length >= _toggledLimit) {
      _toggled.remove(_toggled.keys.first);
    }
    _toggled[track.id] = track;
  }

  /// The full track for an ID the user toggled, if this session has seen it.
  ///
  /// Liked Songs uses this to build a row for a track liked on another screen.
  Track? toggledTrack(String id) => _toggled[id];
}

final savedTracksProvider =
    NotifierProvider<SavedTracksController, SavedTracksState>(
      SavedTracksController.new,
    );

/// Whether one track is liked, as a rebuildable subscription.
///
/// Null means not known yet. A widget watching this rebuilds only when *its*
/// track's answer changes, not when any other heart in the app does.
final isTrackSavedProvider = Provider.family<bool?, String>(
  (ref, id) => ref.watch(savedTracksProvider.select((s) => s.known[id])),
);
