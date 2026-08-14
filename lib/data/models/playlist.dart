import 'package:equatable/equatable.dart';

import 'json_utils.dart';
import 'media_source.dart';
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
/// ## AURIX's playlist, not Spotify's
///
/// The canonical copy lives at `/users/{uid}/playlists/{playlistId}` in
/// Firestore, with its rows in a `tracks` subcollection. [fromFirestore] and
/// [toFirestore] round-trip it; [fromJson] remains only so the Spotify import
/// provider can read what Spotify sends.
///
/// [items] is null on a playlist that has been listed but not opened — the
/// library screen reads playlist documents without their subcollections,
/// because pulling every track of every playlist to render a grid of covers
/// would be one read per track for data nothing on that screen displays.
/// [trackCount] is denormalised onto the document for exactly that reason.
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
    this.source = MediaSource.aurix,
    this.sourceId,
    this.createdAt,
    this.updatedAt,
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
  ///
  /// Spotify's concept, and null for an AURIX playlist: Firestore's own
  /// transactions serialise concurrent edits, so there is nothing for a
  /// client-held version token to protect against here.
  final String? snapshotId;

  final String? spotifyUrl;
  final String? uri;

  /// Where this playlist came from. [MediaSource.aurix] for one the user made
  /// here; [MediaSource.spotify] or [MediaSource.youtube] for an import.
  final MediaSource source;

  /// The playlist's id at [source]. Null for an AURIX-native playlist.
  ///
  /// This is what makes re-importing idempotent: an import looks for an
  /// existing playlist with the same (source, sourceId) pair and updates it
  /// instead of creating a second copy.
  final String? sourceId;

  final DateTime? createdAt;
  final DateTime? updatedAt;

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
      source: MediaSource.spotify,
      sourceId: Json.strOrNull(json, 'id'),
    );
  }

  // -------------------------------------------------------------------------
  // Firestore
  // -------------------------------------------------------------------------

  /// Reads a playlist document from `/users/{uid}/playlists/{playlistId}`.
  ///
  /// [items] is always null here. A playlist's tracks are a subcollection, and
  /// this reads the parent document only — see `FirestorePlaylistService
  /// .watchTracks` for the rows. That split is deliberate: the Library screen
  /// renders forty playlist covers and needs none of their contents, so joining
  /// them here would turn one query into forty-one.
  factory Playlist.fromFirestore(String id, Map<String, dynamic> data) {
    final coverUrl = Json.strOrNull(data, 'coverUrl');
    return Playlist(
      id: id,
      name: Json.str(data, 'name', fallback: 'Untitled playlist'),
      description: Json.str(data, 'description'),
      images: <SpotifyImage>[
        if (coverUrl != null && coverUrl.isNotEmpty) SpotifyImage(url: coverUrl),
      ],
      // Denormalised onto the document by every write that changes membership.
      trackCount: Json.intVal(data, 'trackCount'),
      source: MediaSource.parse(data['source']),
      sourceId: Json.strOrNull(data, 'sourceId'),
      createdAt: Json.timestamp(data, 'createdAt'),
      updatedAt: Json.timestamp(data, 'updatedAt'),
    );
  }

  /// The document body for this playlist.
  ///
  /// `createdAt`, `updatedAt` and `trackCount` are absent by design. All three
  /// are the write path's to set — the timestamps because a server clock is the
  /// only one every device agrees on, and the count because it is maintained by
  /// the same transaction that adds or removes a row, so a stale value carried
  /// in from a model instance could overwrite a correct one.
  Map<String, dynamic> toFirestore() => <String, dynamic>{
    'name': name,
    'description': description,
    'coverUrl': imageUrl ?? '',
    'source': source.wireValue,
    'sourceId': sourceId,
  };

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

  /// Who to credit under the title.
  ///
  /// Falls back to the source's name rather than to "Spotify" unconditionally,
  /// which is what it used to do — an AURIX playlist attributed to Spotify was
  /// harmless while every playlist came from there and is simply wrong now.
  String get ownerName => owner?.displayName ?? source.label;

  /// The Spotify URI for this playlist, or null when it is not Spotify's.
  ///
  /// Nullable for the same reason as `Track.spotifyUri`: an AURIX playlist's id
  /// is a Firestore document id, and `spotify:playlist:<that>` addresses
  /// nothing.
  String? get spotifyUri {
    if (uri != null && uri!.isNotEmpty) return uri;
    if (source != MediaSource.spotify) return null;
    final id = sourceId;
    return (id == null || id.isEmpty) ? null : 'spotify:playlist:$id';
  }

  /// Only the entries that can actually be queued.
  List<Track> get playableTracks =>
      items?.items.where((i) => i.isPlayable).map((i) => i.track!).toList() ??
      const [];

  /// True when the signed-in user may add, remove or reorder tracks.
  ///
  /// Every playlist under `/users/{uid}/playlists` belongs to that user by
  /// construction — the path *is* the ownership claim, and the security rules
  /// enforce it — so an AURIX playlist read from Firestore is editable and
  /// carries no `owner` object to check. The Spotify branch survives for
  /// playlists rendered during an import preview, which are not the user's to
  /// change unless Spotify says so.
  bool isEditableBy(String? userId) {
    if (source == MediaSource.aurix) return true;
    return userId != null && (owner?.id == userId || isCollaborative);
  }

  Playlist copyWith({
    String? name,
    String? description,
    List<SpotifyImage>? images,
    Paging<PlaylistItem>? items,
    String? snapshotId,
    int? trackCount,
    DateTime? updatedAt,
  }) => Playlist(
    id: id,
    name: name ?? this.name,
    description: description ?? this.description,
    owner: owner,
    images: images ?? this.images,
    trackCount: trackCount ?? this.trackCount,
    items: items ?? this.items,
    followers: followers,
    isPublic: isPublic,
    isCollaborative: isCollaborative,
    snapshotId: snapshotId ?? this.snapshotId,
    spotifyUrl: spotifyUrl,
    uri: uri,
    source: source,
    sourceId: sourceId,
    createdAt: createdAt,
    updatedAt: updatedAt ?? this.updatedAt,
  );

  @override
  List<Object?> get props => [
    id,
    name,
    description,
    owner,
    images,
    trackCount,
    items,
    snapshotId,
    source,
    sourceId,
    updatedAt,
  ];
}
