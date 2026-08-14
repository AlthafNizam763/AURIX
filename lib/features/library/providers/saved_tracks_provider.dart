import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/providers/app_providers.dart';
import '../../../core/utils/app_logger.dart';
import '../../../data/models/track.dart';
import '../../auth/providers/auth_provider.dart';
import 'library_provider.dart';

/// Likes and unlikes tracks.
///
/// ## What this replaced
///
/// The Spotify version of this file was 280 lines and most of them were
/// compensation for the library living somewhere else:
///
///  * a **map of known answers**, because `GET /me/tracks/contains` had to be
///    asked per track and the answer cached;
///  * a **60ms batching window and an in-flight set**, because a 50-row list
///    would otherwise fire 50 single-id requests;
///  * a **`_userSet` of tracks the user had toggled**, to stop a `contains`
///    lookup that was already in the air from landing after a write and
///    flipping the heart back under the user's finger;
///  * a **`_toggled` map of recent tracks**, so the Liked Songs screen could
///    rebuild a row for a track liked on a different screen.
///
/// None of that is needed against Firestore. [likedTrackIdsProvider] is a live
/// view of the collection, so "is this liked" is a set lookup with no request
/// and no unknown state, and a write is echoed back through the same stream —
/// which means there is no second source of truth to race against.
///
/// What is left is the write path and an optimistic echo.
class LikedTracksController extends Notifier<Set<String>> {
  /// Tracks whose write is still travelling.
  ///
  /// Firestore's local echo makes the stream reflect a write almost
  /// immediately, so this is usually empty within a frame. It exists for the
  /// gap before that echo, and it is *merged* with the stream rather than
  /// replacing it — see [build].
  final Map<String, bool> _pending = <String, bool>{};

  @override
  Set<String> build() {
    final confirmed = ref.watch(likedTrackIdsProvider);
    if (_pending.isEmpty) return confirmed;

    // The pending overrides win. A track the user has just tapped shows the
    // state they asked for, whatever the stream currently says.
    final merged = <String>{...confirmed};
    for (final entry in _pending.entries) {
      if (entry.value) {
        merged.add(entry.key);
      } else {
        merged.remove(entry.key);
      }
    }
    return merged;
  }

  bool isLiked(String trackId) => state.contains(trackId);

  Future<bool?> toggle(Track track) =>
      setLiked(track, liked: !state.contains(track.documentId));

  /// Likes or unlikes [track], updating every heart in the app at once.
  ///
  /// Returns the resulting state, or null when the write could not be made.
  ///
  /// Optimistic, and rolled back on failure. Note that "failure" here does not
  /// include being offline: Firestore queues the write and resolves the future
  /// against its local cache, so an offline like sticks and syncs later. Only a
  /// genuine refusal — a rules violation, a malformed document — reaches the
  /// catch.
  Future<bool?> setLiked(Track track, {required bool liked}) async {
    final uid = ref.read(currentUserIdProvider);
    if (uid == null) return null;

    // Note this is the *document* id, not `track.id`. A track that arrived from
    // the Spotify catalogue carries a Spotify id, and liking it has to address
    // the same Firestore document as liking the copy of it that came out of a
    // playlist — see `TrackKey`.
    final id = track.documentId;
    if (state.contains(id) == liked) return liked;

    _pending[id] = liked;
    ref.invalidateSelf();

    final library = ref.read(libraryRepositoryProvider);
    try {
      // Written under the document id the app will read it back by, so the
      // stored `id` and the key agree. Without this the same song liked from
      // two screens could produce a row whose document id and `sourceId` point
      // at different things.
      final row = track.copyWith(id: id);
      if (liked) {
        await library.likeTrack(uid, row);
      } else {
        await library.unlikeTrack(uid, row);
      }
      return liked;
    } on Object catch (error) {
      AppLogger.warn('Like write failed for $id', scope: 'library', error: error);
      rethrow;
    } finally {
      // Cleared either way. On success the stream now carries the same answer,
      // so dropping the override is invisible; on failure dropping it is the
      // rollback.
      _pending.remove(id);
      ref.invalidateSelf();
    }
  }
}

/// Which tracks the signed-in user has liked.
final likedTracksControllerProvider =
    NotifierProvider<LikedTracksController, Set<String>>(
      LikedTracksController.new,
    );

/// Whether one track is liked, as a rebuildable subscription.
///
/// Non-nullable, unlike the provider it replaces. The old one returned
/// `bool?` because "not asked Spotify yet" was a real state that the heart had
/// to render as indeterminate. Reading a local set has no such state: either
/// the track is in the user's liked collection or it is not.
final isTrackSavedProvider = Provider.autoDispose.family<bool, String>(
  (ref, id) => ref.watch(likedTracksControllerProvider).contains(id),
);
