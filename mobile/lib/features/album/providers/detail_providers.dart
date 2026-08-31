import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/providers/app_providers.dart';
import '../../../core/utils/album_palette.dart';
import '../../../data/repositories/catalogue_repository.dart';
import '../../auth/providers/auth_provider.dart';

/// Album detail, with its full track list and saved state.
final albumDetailProvider =
    FutureProvider.autoDispose.family<AlbumDetail, String>((ref, id) {
  // Kept alive briefly so a back-and-forth between an album and the player
  // does not refetch. `autoDispose` still reclaims it once the user moves on.
  final link = ref.keepAlive();
  ref.onCancel(() {
    Future<void>.delayed(const Duration(minutes: 2), link.close);
  });
  return ref.watch(catalogueRepositoryProvider).album(id);
});

/// Artist detail: profile, top tracks, discography, related artists.
final artistDetailProvider =
    FutureProvider.autoDispose.family<ArtistDetail, String>((ref, id) {
  final link = ref.keepAlive();
  ref.onCancel(() {
    Future<void>.delayed(const Duration(minutes: 2), link.close);
  });
  return ref.watch(catalogueRepositoryProvider).artist(id);
});

/// Playlist detail. Depends on the current user because editability and the
/// "saved" state are both relative to who is signed in.
final playlistDetailProvider =
    FutureProvider.autoDispose.family<PlaylistDetail, String>((ref, id) {
  final userId = ref.watch(currentUserIdProvider);
  final link = ref.keepAlive();
  ref.onCancel(() {
    Future<void>.delayed(const Duration(minutes: 2), link.close);
  });
  return ref
      .watch(catalogueRepositoryProvider)
      .playlist(id, currentUserId: userId);
});

/// Artwork-derived colours for a detail screen.
///
/// Separate from the detail provider so the page renders immediately with the
/// neutral fallback and re-tints when extraction finishes — blocking the whole
/// screen on a bitmap quantisation would be a poor trade.
final artworkPaletteProvider =
    FutureProvider.autoDispose.family<AlbumPalette, String?>((ref, imageUrl) {
  return ref.watch(albumPaletteServiceProvider).resolve(imageUrl);
});

/// The palette to paint with right now: the extracted one if it has arrived,
/// the cached one if a previous visit computed it, and the neutral fallback
/// otherwise. Always non-null so headers never have to branch.
AlbumPalette watchPalette(WidgetRef ref, String? imageUrl) {
  final resolved = ref.watch(artworkPaletteProvider(imageUrl)).value;
  if (resolved != null) return resolved;
  return ref.watch(albumPaletteServiceProvider).peek(imageUrl) ??
      AlbumPalette.fallback;
}

// Which tracks are in the user's Liked Songs is *not* answered here.
//
// It used to be, as `savedTrackIdsProvider` — an `autoDispose.family` keyed on
// the joined track IDs of whatever list was on screen. That made the answer a
// property of the screen rather than of the library: the album screen and the
// player screen held two different entries for the same track, so liking a
// song in one left the other's heart empty until the screen was rebuilt from
// scratch. Every screen also refetched its whole list on `autoDispose`,
// because a key built from a different list is a different provider even when
// the tracks overlap completely.
//
// It now lives in `SavedTracksController`
// (features/library/providers/saved_tracks_provider.dart): one map for the
// whole app, batched, de-duplicated, and written through by every heart.
