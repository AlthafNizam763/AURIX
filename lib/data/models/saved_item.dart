import 'package:equatable/equatable.dart';

import 'album.dart';
import 'json_utils.dart';
import 'track.dart';

/// A track in the user's library, with the date it was liked.
///
/// The timestamp is what makes "Recently added" sorting possible, so it cannot
/// be flattened away into a bare [Track].
class SavedTrack extends Equatable {
  const SavedTrack({required this.track, this.addedAt});

  final Track track;
  final DateTime? addedAt;

  factory SavedTrack.fromJson(Map<String, dynamic> json) {
    final trackJson = Json.obj(json, 'track');
    if (trackJson == null) {
      throw const FormatException('Saved track entry has no track');
    }
    return SavedTrack(
      track: Track.fromJson(trackJson),
      addedAt: Json.dateTime(json, 'added_at'),
    );
  }

  Map<String, dynamic> toJson() => <String, dynamic>{
    'track': track.toJson(),
    if (addedAt != null) 'added_at': addedAt!.toIso8601String(),
  };

  @override
  List<Object?> get props => [track, addedAt];
}

/// An album in the user's library, with the date it was saved.
class SavedAlbum extends Equatable {
  const SavedAlbum({required this.album, this.addedAt});

  final Album album;
  final DateTime? addedAt;

  factory SavedAlbum.fromJson(Map<String, dynamic> json) {
    final albumJson = Json.obj(json, 'album');
    if (albumJson == null) {
      throw const FormatException('Saved album entry has no album');
    }
    return SavedAlbum(
      album: Album.fromJson(albumJson),
      addedAt: Json.dateTime(json, 'added_at'),
    );
  }

  Map<String, dynamic> toJson() => <String, dynamic>{
    'album': album.toJson(),
    if (addedAt != null) 'added_at': addedAt!.toIso8601String(),
  };

  @override
  List<Object?> get props => [album, addedAt];
}

/// An entry from `/me/player/recently-played`.
class PlayHistoryEntry extends Equatable {
  const PlayHistoryEntry({
    required this.track,
    this.playedAt,
    this.contextUri,
    this.contextType,
  });

  final Track track;
  final DateTime? playedAt;

  /// The album/playlist/artist the track was played from, when Spotify knows.
  final String? contextUri;
  final String? contextType;

  factory PlayHistoryEntry.fromJson(Map<String, dynamic> json) {
    final trackJson = Json.obj(json, 'track');
    if (trackJson == null) {
      throw const FormatException('Play history entry has no track');
    }
    final context = Json.obj(json, 'context');
    return PlayHistoryEntry(
      track: Track.fromJson(trackJson),
      playedAt: Json.dateTime(json, 'played_at'),
      contextUri: context == null ? null : Json.strOrNull(context, 'uri'),
      contextType: context == null ? null : Json.strOrNull(context, 'type'),
    );
  }

  Map<String, dynamic> toJson() => <String, dynamic>{
    'track': track.toJson(),
    if (playedAt != null) 'played_at': playedAt!.toIso8601String(),
    if (contextUri != null)
      'context': <String, dynamic>{'uri': contextUri, 'type': contextType},
  };

  @override
  List<Object?> get props => [track, playedAt, contextUri];
}
