import 'package:dio/dio.dart';

import '../../core/utils/app_logger.dart';
import '../models/artist.dart';
import '../models/track.dart';
import 'spotify_api_service.dart';
import 'spotify_artist_service.dart';
import 'spotify_user_service.dart';

/// Track recommendations.
///
/// ## Why this class does not call `/recommendations`
///
/// `GET /recommendations` would be the natural endpoint, and this class used
/// to try it first. Spotify restricted it on 27 November 2024, so an
/// application registered after that date receives `403` for every call —
/// not sometimes, not for some accounts. Trying it first bought one refused
/// round trip per shelf build and per artist screen, and nothing else.
///
/// Recommendations are therefore derived from endpoints that *are* available:
/// the user's top artists, their top tracks per market, and the seed artists'
/// own discographies. Everything returned is real Spotify catalogue data
/// fetched live; nothing is hardcoded, and when there is no listening history
/// to work from the result is empty and the shelf is hidden.
class SpotifyRecommendationService extends SpotifyApiService {
  SpotifyRecommendationService(
    super.dio, {
    SpotifyUserService? userService,
    SpotifyArtistService? artistService,
  }) : _users = userService ?? SpotifyUserService(dio),
       _artists = artistService ?? SpotifyArtistService(dio);

  final SpotifyUserService _users;
  final SpotifyArtistService _artists;

  /// Recommended tracks for the signed-in user.
  Future<List<Track>> recommendedTracks({
    int limit = 20,
    CancelToken? cancelToken,
  }) async {
    final seeds = await _seedArtists(cancelToken: cancelToken);
    // No listening history and no followed artists — there is nothing honest
    // to recommend from. The caller hides the shelf rather than filling it.
    if (seeds.isEmpty) return const [];

    return _viaSeedArtistCatalogue(seeds, limit: limit, cancelToken: cancelToken);
  }

  /// "More like this" for a specific artist — used on the artist screen.
  Future<List<Track>> similarToArtist(
    Artist artist, {
    int limit = 20,
    CancelToken? cancelToken,
  }) async {
    final related = await _artists.relatedArtists(
      artist.id,
      genreHints: artist.genres,
      excludeName: artist.name,
      limit: 6,
      cancelToken: cancelToken,
    );
    if (related.isEmpty) return const [];

    return _viaSeedArtistCatalogue(related, limit: limit, cancelToken: cancelToken);
  }

  // `_viaRecommendations()` used to live here, calling `GET /recommendations`
  // with up to five seeds and falling back when it was refused.
  //
  // Removed for the same reason as the browse endpoints: Spotify restricted
  // `/recommendations` on 27 November 2024, so it answers 403 to every request
  // an app registered after that date can make. Calling it first bought
  // nothing but a round trip and a 403 in the log on every shelf build and
  // every artist screen.
  //
  // What was the fallback is now the only path, and it is unchanged: real
  // catalogue tracks, interleaved from the seed artists' own discographies.

  /// Interleave the top tracks of related/seed artists.
  ///
  /// Interleaving rather than concatenating matters — concatenating gives ten
  /// tracks by one artist followed by ten by the next, which reads as a broken
  /// shelf rather than a recommendation.
  Future<List<Track>> _viaSeedArtistCatalogue(
    List<Artist> seeds, {
    int limit = 20,
    CancelToken? cancelToken,
  }) async {
    final perArtist = <List<Track>>[];

    for (final artist in seeds.take(6)) {
      try {
        final tracks = await _artists.topTracks(artist.id, cancelToken: cancelToken);
        if (tracks.isNotEmpty) perArtist.add(tracks);
      } on Object catch (error) {
        // One artist failing must not empty the whole shelf.
        AppLogger.debug(
          'Seed artist ${artist.id} contributed nothing: $error',
          scope: 'recs',
        );
      }
    }

    if (perArtist.isEmpty) return const [];

    final out = <Track>[];
    final seen = <String>{};
    final deepest = perArtist.fold<int>(0, (max, l) => l.length > max ? l.length : max);

    for (var round = 0; round < deepest && out.length < limit; round++) {
      for (final tracks in perArtist) {
        if (out.length >= limit) break;
        if (round >= tracks.length) continue;
        final track = tracks[round];
        if (track.id.isEmpty || !seen.add(track.id)) continue;
        out.add(track);
      }
    }

    return out;
  }

  /// Seeds drawn from the user's actual listening.
  ///
  /// Falls back through short → medium → long term, because a brand-new
  /// account has no short-term history and would otherwise get nothing.
  Future<List<Artist>> _seedArtists({CancelToken? cancelToken}) async {
    for (final range in <TopItemRange>[
      TopItemRange.shortTerm,
      TopItemRange.mediumTerm,
      TopItemRange.longTerm,
    ]) {
      try {
        final page = await _users.topArtists(
          range: range,
          limit: 10,
          cancelToken: cancelToken,
        );
        if (page.isNotEmpty) return page.items;
      } on Object catch (error) {
        AppLogger.debug('Top artists (${range.apiValue}) failed: $error', scope: 'recs');
      }
    }
    return const [];
  }

  // `availableGenreSeeds()` used to live here, calling
  // `GET /recommendations/available-genre-seeds`. Removed with the rest of the
  // recommendations family — restricted since November 2024, and it had no
  // callers left once the mood catalogue stopped depending on it.
}
