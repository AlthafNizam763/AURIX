import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/providers/app_providers.dart';
import '../../../data/models/track.dart';
import '../../../data/services/lyrics_service.dart';
import '../../../playback/player_controller.dart';

/// Lyrics for whatever is playing right now.
///
/// ## Why it keys on the track rather than watching the whole player
///
/// The family key is the *track*, and the only thing that reads the player is
/// [currentLyricsProvider]'s one-line `select` on `currentTrackProvider`. That
/// matters because the playback state changes twice a second while a song
/// plays: a provider that watched it directly would be torn down and rebuilt
/// at tick rate, re-requesting lyrics on every tick. Keyed this way it rebuilds
/// on track change and on nothing else.
///
/// The repository de-duplicates and caches underneath, so the strip on the
/// player and the sheet opened over it share one request, and coming back to a
/// track already looked up costs nothing.
final trackLyricsProvider = FutureProvider.family<Lyrics?, Track>((ref, track) {
  return ref.watch(lyricsRepositoryProvider).forTrack(track);
});

/// Lyrics for the current track, or null-data when nothing is playing.
///
/// This is what every lyrics surface watches.
final currentLyricsProvider = Provider<AsyncValue<Lyrics?>>((ref) {
  final track = ref.watch(currentTrackProvider);
  if (track == null) return const AsyncData<Lyrics?>(null);
  return ref.watch(trackLyricsProvider(track));
});
