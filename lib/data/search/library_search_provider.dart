import 'dart:async';

import '../models/paging.dart';
import '../models/playlist.dart';
import '../models/search_results.dart';
import '../models/track.dart';
import 'search_provider.dart';

/// Searches what the user already has.
///
/// The default and highest-priority provider. It reads no network, needs no
/// credentials, and works offline — the user's library is a Firestore
/// collection served from the local cache — which makes it the one provider
/// that can always answer.
///
/// ## Why it takes callbacks rather than a repository
///
/// The library is already streamed into the app, and the search screen has the
/// tracks and playlists in memory before the user finishes typing. Handing this
/// class a repository would make it re-read collections it is being handed for
/// free; handing it accessors keeps searching a pure function over state that
/// already exists, and keeps the data layer out of the search layer.
class LibrarySearchProvider implements SearchProvider {
  LibrarySearchProvider({
    required List<Track> Function() likedTracks,
    required List<Playlist> Function() playlists,
    required List<Track> Function() playlistTracks,
  }) : _likedTracks = likedTracks,
       _playlists = playlists,
       _playlistTracks = playlistTracks;

  final List<Track> Function() _likedTracks;
  final List<Playlist> Function() _playlists;

  /// Tracks from every playlist the app currently has loaded.
  ///
  /// Not every track in every playlist — that would be a read of the whole
  /// library on every keystroke. This searches what is in memory, which is
  /// what the user has recently looked at, and the liked collection, which is
  /// always loaded.
  final List<Track> Function() _playlistTracks;

  @override
  String get displayName => 'Your library';

  /// Zero: the user's own copy of a song outranks any catalogue entry for it.
  @override
  int get priority => 0;

  /// Always. That is the point of it.
  @override
  bool get isAvailable => true;

  @override
  Future<SearchResults> search(String query, {int limit = 20}) async {
    final needle = query.trim().toLowerCase();
    if (needle.isEmpty) return SearchResults.empty;

    final tracks = <Track>[];
    final seen = <String>{};

    for (final track in <Track>[..._likedTracks(), ..._playlistTracks()]) {
      if (!seen.add(track.documentId)) continue;
      if (!_matchesTrack(track, needle)) continue;
      tracks.add(track);
      if (tracks.length >= limit) break;
    }

    final playlists = _playlists()
        .where((playlist) => _contains(playlist.name, needle))
        .take(limit)
        .toList(growable: false);

    return SearchResults(
      tracks: Paging<Track>(
        items: tracks,
        total: tracks.length,
        limit: limit,
        offset: 0,
      ),
      playlists: Paging<Playlist>(
        items: playlists,
        total: playlists.length,
        limit: limit,
        offset: 0,
      ),
      // Artists and albums are deliberately empty. AURIX stores an artist as a
      // display string on a track, not as a record with an id, so an "artist
      // result" here could not be tapped through to anything. Returning a row
      // that navigates nowhere is worse than returning none.
    );
  }

  bool _matchesTrack(Track track, String needle) =>
      _contains(track.name, needle) ||
      _contains(track.artistNames, needle) ||
      _contains(track.album?.name ?? '', needle);

  bool _contains(String value, String needle) =>
      value.toLowerCase().contains(needle);
}
