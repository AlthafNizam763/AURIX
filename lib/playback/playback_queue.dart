import 'dart:math';

import 'package:equatable/equatable.dart';

import '../data/models/playback.dart';
import '../data/models/track.dart';

/// Where a queue came from, so the UI can say "Playing from *Abbey Road*".
class PlaybackContext extends Equatable {
  const PlaybackContext({
    required this.title,
    this.uri,
    this.subtitle,
    this.imageUrl,
  });

  final String title;

  /// Spotify context URI (`spotify:album:…`). Present for albums, playlists
  /// and artists; null for an ad-hoc selection such as search results.
  final String? uri;

  final String? subtitle;
  final String? imageUrl;

  static const PlaybackContext none = PlaybackContext(title: 'Queue');

  @override
  List<Object?> get props => [title, uri, subtitle, imageUrl];
}

/// The playback queue and its ordering rules.
///
/// Immutable — every mutation returns a new instance — because the queue is
/// held in Riverpod state and mutating it in place would silently skip
/// rebuilds.
///
/// ## Shuffle
///
/// Shuffle keeps [tracks] in its original order and maintains a separate
/// [_order] permutation. This is what makes toggling shuffle off restore the
/// real album order instead of leaving a scrambled list behind, and what lets
/// the Queue screen show upcoming tracks in shuffled order while the album
/// screen still shows track 1, 2, 3.
class PlaybackQueue extends Equatable {
  const PlaybackQueue({
    this.tracks = const [],
    this.order = const [],
    this.cursor = 0,
    this.shuffled = false,
    this.repeatMode = RepeatState.off,
    this.context = PlaybackContext.none,
  });

  /// Tracks in their natural order.
  final List<Track> tracks;

  /// Indices into [tracks] giving playback order.
  final List<int> order;

  /// Position within [order].
  final int cursor;

  final bool shuffled;
  final RepeatState repeatMode;
  final PlaybackContext context;

  static const PlaybackQueue empty = PlaybackQueue();

  /// Builds a queue starting at [startIndex] of [tracks].
  factory PlaybackQueue.from(
    List<Track> tracks, {
    int startIndex = 0,
    bool shuffle = false,
    RepeatState repeatMode = RepeatState.off,
    PlaybackContext context = PlaybackContext.none,
    Random? random,
  }) {
    if (tracks.isEmpty) return PlaybackQueue.empty;

    final safeStart = startIndex.clamp(0, tracks.length - 1);
    final order = shuffle
        ? _shuffledOrder(tracks.length, pinFirst: safeStart, random: random)
        : List<int>.generate(tracks.length, (i) => i);

    return PlaybackQueue(
      tracks: List<Track>.unmodifiable(tracks),
      order: List<int>.unmodifiable(order),
      cursor: shuffle ? 0 : safeStart,
      shuffled: shuffle,
      repeatMode: repeatMode,
      context: context,
    );
  }

  bool get isEmpty => tracks.isEmpty;
  bool get isNotEmpty => tracks.isNotEmpty;
  int get length => tracks.length;

  Track? get current {
    if (order.isEmpty || cursor < 0 || cursor >= order.length) return null;
    final index = order[cursor];
    if (index < 0 || index >= tracks.length) return null;
    return tracks[index];
  }

  /// Tracks after the current one, in playback order — what the Queue screen
  /// renders as "Next up".
  List<Track> get upNext {
    if (order.isEmpty) return const [];
    return order
        .skip(cursor + 1)
        .where((i) => i >= 0 && i < tracks.length)
        .map((i) => tracks[i])
        .toList(growable: false);
  }

  /// Already-played tracks, most recent first.
  List<Track> get history {
    if (order.isEmpty) return const [];
    return order
        .take(cursor)
        .where((i) => i >= 0 && i < tracks.length)
        .map((i) => tracks[i])
        .toList(growable: false)
        .reversed
        .toList(growable: false);
  }

  bool get hasNext {
    if (repeatMode != RepeatState.off) return isNotEmpty;
    return cursor < order.length - 1;
  }

  bool get hasPrevious => cursor > 0 || repeatMode == RepeatState.context;

  /// Advances.
  ///
  /// [manual] distinguishes a user pressing "next" from a track ending.
  /// With `RepeatState.track` a finished track repeats itself, but pressing
  /// next should still move on — otherwise the button appears broken.
  PlaybackQueue? next({bool manual = false}) {
    if (isEmpty) return null;

    if (repeatMode == RepeatState.track && !manual) return this;

    if (cursor < order.length - 1) return copyWith(cursor: cursor + 1);

    if (repeatMode == RepeatState.context || (repeatMode == RepeatState.track && manual)) {
      // Reshuffle on wrap so a repeated shuffled album is not the same
      // sequence forever.
      if (shuffled) {
        return copyWith(order: _shuffledOrder(tracks.length), cursor: 0);
      }
      return copyWith(cursor: 0);
    }

    return null;
  }

  /// Steps back. [atPositionStart] is false when the track has been playing
  /// long enough that "previous" should restart it instead — the convention
  /// every music player uses.
  PlaybackQueue? previous({bool atPositionStart = true}) {
    if (isEmpty) return null;
    if (!atPositionStart) return this;
    if (cursor > 0) return copyWith(cursor: cursor - 1);
    if (repeatMode == RepeatState.context) return copyWith(cursor: order.length - 1);
    return null;
  }

  /// Jumps to a position in the *playback* order (as shown in the queue UI).
  PlaybackQueue jumpToOrderIndex(int index) {
    if (index < 0 || index >= order.length) return this;
    return copyWith(cursor: index);
  }

  /// Jumps to a track by its index in the natural track list.
  PlaybackQueue jumpToTrackIndex(int trackIndex) {
    final position = order.indexOf(trackIndex);
    if (position < 0) return this;
    return copyWith(cursor: position);
  }

  PlaybackQueue jumpToTrackId(String trackId) {
    final trackIndex = tracks.indexWhere((t) => t.id == trackId);
    if (trackIndex < 0) return this;
    return jumpToTrackIndex(trackIndex);
  }

  /// Toggles shuffle while keeping the current track playing.
  ///
  /// The current track is pinned to the front of the new order so enabling
  /// shuffle never interrupts what is already playing.
  PlaybackQueue setShuffle(bool enabled, {Random? random}) {
    if (enabled == shuffled) return this;
    if (isEmpty) return copyWith(shuffled: enabled);

    final currentTrackIndex = order[cursor];

    if (enabled) {
      return copyWith(
        order: _shuffledOrder(tracks.length, pinFirst: currentTrackIndex, random: random),
        cursor: 0,
        shuffled: true,
      );
    }

    return copyWith(
      order: List<int>.generate(tracks.length, (i) => i),
      cursor: currentTrackIndex,
      shuffled: false,
    );
  }

  PlaybackQueue setRepeat(RepeatState mode) => copyWith(repeatMode: mode);

  /// Inserts [track] to play immediately after the current one.
  PlaybackQueue playNext(Track track) {
    final tracksCopy = [...tracks, track];
    final orderCopy = [...order]..insert(
      (cursor + 1).clamp(0, order.length),
      tracksCopy.length - 1,
    );
    return copyWith(tracks: tracksCopy, order: orderCopy);
  }

  /// Appends [track] to the end of the queue.
  PlaybackQueue addToQueue(Track track) => copyWith(
    tracks: [...tracks, track],
    order: [...order, tracks.length],
  );

  PlaybackQueue addAllToQueue(List<Track> newTracks) {
    if (newTracks.isEmpty) return this;
    final base = tracks.length;
    return copyWith(
      tracks: [...tracks, ...newTracks],
      order: [...order, for (var i = 0; i < newTracks.length; i++) base + i],
    );
  }

  /// Removes the entry at [orderIndex] of the playback order.
  ///
  /// Removing shifts every later track index, so [order] has to be rewritten
  /// rather than just spliced — getting this wrong makes the queue play the
  /// wrong songs after a single removal.
  PlaybackQueue removeAt(int orderIndex) {
    if (orderIndex < 0 || orderIndex >= order.length) return this;

    final removedTrackIndex = order[orderIndex];
    final newTracks = [...tracks]..removeAt(removedTrackIndex);

    final newOrder = <int>[];
    for (var i = 0; i < order.length; i++) {
      if (i == orderIndex) continue;
      final value = order[i];
      newOrder.add(value > removedTrackIndex ? value - 1 : value);
    }

    if (newTracks.isEmpty) return PlaybackQueue.empty;

    var newCursor = cursor;
    if (orderIndex < cursor) {
      newCursor = cursor - 1;
    } else if (orderIndex == cursor) {
      newCursor = cursor.clamp(0, newOrder.length - 1);
    }

    return copyWith(tracks: newTracks, order: newOrder, cursor: newCursor);
  }

  /// Drag-and-drop reorder within "Next up".
  ///
  /// [from] and [to] are indices into the *upNext* list, which starts after
  /// the cursor — translating them here keeps that offset out of the widget.
  PlaybackQueue reorderUpNext(int from, int to) {
    final base = cursor + 1;
    final fromOrder = base + from;
    var toOrder = base + to;

    if (fromOrder < 0 || fromOrder >= order.length) return this;
    if (fromOrder < toOrder) toOrder -= 1;
    toOrder = toOrder.clamp(base, order.length - 1);
    if (fromOrder == toOrder) return this;

    final newOrder = [...order];
    final moved = newOrder.removeAt(fromOrder);
    newOrder.insert(toOrder, moved);
    return copyWith(order: newOrder);
  }

  /// Empties everything after the current track.
  PlaybackQueue clearUpNext() {
    if (order.isEmpty) return this;
    return copyWith(order: order.take(cursor + 1).toList());
  }

  PlaybackQueue copyWith({
    List<Track>? tracks,
    List<int>? order,
    int? cursor,
    bool? shuffled,
    RepeatState? repeatMode,
    PlaybackContext? context,
  }) => PlaybackQueue(
    tracks: tracks ?? this.tracks,
    order: order ?? this.order,
    cursor: cursor ?? this.cursor,
    shuffled: shuffled ?? this.shuffled,
    repeatMode: repeatMode ?? this.repeatMode,
    context: context ?? this.context,
  );

  static List<int> _shuffledOrder(int length, {int? pinFirst, Random? random}) {
    final indices = List<int>.generate(length, (i) => i);
    if (pinFirst != null && pinFirst >= 0 && pinFirst < length) {
      indices.remove(pinFirst);
    }
    indices.shuffle(random ?? Random());
    if (pinFirst != null && pinFirst >= 0 && pinFirst < length) {
      indices.insert(0, pinFirst);
    }
    return indices;
  }

  @override
  List<Object?> get props => [tracks, order, cursor, shuffled, repeatMode, context];
}
