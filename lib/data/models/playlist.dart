import 'package:equatable/equatable.dart';

import 'json_utils.dart';
import 'paging.dart';
import 'spotify_image.dart';
import 'track.dart';
import 'user_profile.dart';

/// One entry in a playlist's track list.
///
/// Wraps the track because the *membership* carries data the track does not:
/// when it was added, who added it, and — importantly — whether there is a
/// track there at all. Spotify returns `"track": null` for items that were
/// removed from the catalogue, and a local-file item has no usable ID.
class PlaylistItem extends Equatable {
  const PlaylistItem({
    required this.track,
    this.addedAt,
    this.addedById,
    this.isLocal = false,
  });

  /// Null when the entry is a removed or otherwise unavailable track.
  final Track? track;
  final DateTime? addedAt;
  final String? addedById;
  final bool isLocal;

  factory PlaylistItem.fromJson(Map<String, dynamic> json) {
    final trackJson = Json.obj(json, 'track');
    final addedBy = Json.obj(json, 'added_by');

    // Playlists can hold episodes as well as tracks. AURIX is a music
    // client, so an episode is treated the same as a missing track rather
    // than being rendered as something it cannot play.
    final isTrack = trackJson != null &&
        (Json.strOrNull(trackJson, 'type') ?? 'track') == 'track';

    return PlaylistItem(
      track: isTrack ? Track.fromJson(trackJson) : null,
      addedAt: Json.dateTime(json, 'added_at'),
      addedById: addedBy == null ? null : Json.strOrNull(addedBy, 'id'),
      isLocal: Json.boolVal(json, 'is_local'),
    );
  }

  Map<String, dynamic> toJson() => <String, dynamic>{
    if (track != null) 'track': track!.toJson(),
    if (addedAt != null) 'added_at': addedAt!.toIso8601String(),
    if (addedById != null) 'added_by': <String, dynamic>{'id': addedById},
    'is_local': isLocal,
  };

  bool get isPlayable => track != null && !isLocal && track!.id.isNotEmpty;

  @override
  List<Object?> get props => [track, addedAt, addedById, isLocal];
}

/// A playlist.
///
/// [items] is null on the simplified object returned by `/me/playlists` and by
/// search; only `GET /playlists/{id}` returns the first page of tracks.
class Playlist extends Equatable {
  const Playlist({
    required this.id,
    required this.name,
    this.description = '',
    this.owner,
    this.images = const [],
    this.trackCount = 0,
    this.items,
    this.followers,
    this.isPublic,
    this.isCollaborative = false,
    this.snapshotId,
    this.spotifyUrl,
    this.uri,
  });

  final String id;
  final String name;

  /// May contain HTML entities and anchor tags — render via
  /// `Formatters.plainText`, never raw.
  final String description;

  final UserProfile? owner;
  final List<SpotifyImage> images;
  final int trackCount;
  final Paging<PlaylistItem>? items;
  final int? followers;

  /// Null when the token cannot see the playlist's visibility.
  final bool? isPublic;

  final bool isCollaborative;

  /// Version token. Required by the reorder/remove endpoints so a concurrent
  /// edit from another device cannot be silently clobbered.
  final String? snapshotId;

  final String? spotifyUrl;
  final String? uri;

  factory Playlist.fromJson(Map<String, dynamic> json) {
    // Spotify's February 2026 changes renamed a playlist's contents from
    // `tracks` to `items` (matching the `/playlists/{id}/items` endpoint that
    // replaced `/playlists/{id}/tracks`). Both spellings are accepted rather
    // than one being chosen: the same app talks to an account whose responses
    // may carry either, depending on quota mode and on when the app was
    // registered, and a playlist that parses to zero tracks is
    // indistinguishable in the UI from one that failed to load.
    final tracksJson = Json.obj(json, 'tracks') ?? Json.obj(json, 'items');
    final ownerJson = Json.obj(json, 'owner');
    final followersJson = Json.obj(json, 'followers');

    // The contents object is either {href, total} on a simplified playlist or
    // a full paging object on the detail response.
    final hasItems = tracksJson != null && tracksJson['items'] is List;

    return Playlist(
      id: Json.str(json, 'id'),
      name: Json.str(json, 'name', fallback: 'Untitled playlist'),
      description: Json.str(json, 'description'),
      owner: ownerJson == null ? null : UserProfile.fromJson(ownerJson),
      images: Json.list(json, 'images', SpotifyImage.fromJson),
      trackCount: tracksJson == null ? 0 : Json.intVal(tracksJson, 'total'),
      items: hasItems
          ? Paging<PlaylistItem>.fromJson(tracksJson, PlaylistItem.fromJson)
          : null,
      followers: followersJson == null ? null : Json.intOrNull(followersJson, 'total'),
      isPublic: json['public'] as bool?,
      isCollaborative: Json.boolVal(json, 'collaborative'),
      snapshotId: Json.strOrNull(json, 'snapshot_id'),
      spotifyUrl: Json.spotifyUrl(json),
      uri: Json.strOrNull(json, 'uri'),
    );
  }

  Map<String, dynamic> toJson() => <String, dynamic>{
    'id': id,
    'name': name,
    'description': description,
    if (owner != null) 'owner': owner!.toJson(),
    'images': images.map((i) => i.toJson()).toList(),
    'tracks': <String, dynamic>{
      'total': trackCount,
      if (items != null) ...items!.toJson((i) => i.toJson()),
    },
    if (followers != null) 'followers': <String, dynamic>{'total': followers},
    if (isPublic != null) 'public': isPublic,
    'collaborative': isCollaborative,
    if (snapshotId != null) 'snapshot_id': snapshotId,
    if (spotifyUrl != null) 'external_urls': <String, dynamic>{'spotify': spotifyUrl},
    if (uri != null) 'uri': uri,
  };

  bool get isSimplified => items == null;

  String? get imageUrl => images.largestUrl;
  String? get cardImageUrl => images.cardUrl;
  String? get thumbnailUrl => images.smallestUrl;

  String get ownerName => owner?.displayName ?? 'Spotify';
  String get spotifyUri => uri ?? 'spotify:playlist:$id';

  /// Only the entries that can actually be queued.
  List<Track> get playableTracks =>
      items?.items.where((i) => i.isPlayable).map((i) => i.track!).toList() ??
      const [];

  /// True when the signed-in user may add, remove or reorder tracks.
  bool isEditableBy(String? userId) =>
      userId != null && (owner?.id == userId || isCollaborative);

  Playlist copyWith({
    Paging<PlaylistItem>? items,
    String? snapshotId,
    int? trackCount,
  }) => Playlist(
    id: id,
    name: name,
    description: description,
    owner: owner,
    images: images,
    trackCount: trackCount ?? this.trackCount,
    items: items ?? this.items,
    followers: followers,
    isPublic: isPublic,
    isCollaborative: isCollaborative,
    snapshotId: snapshotId ?? this.snapshotId,
    spotifyUrl: spotifyUrl,
    uri: uri,
  );

  @override
  List<Object?> get props => [id, name, description, owner, images, trackCount, items, snapshotId];
}
