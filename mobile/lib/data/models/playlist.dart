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

/// Who can see a playlist — which is also which collection it came out of.
///
/// AURIX keeps playlists in two places, and the difference is *visibility*
/// rather than content:
///
///  * [private] — `/users/{uid}/playlists/{id}`. A playlist the user built
///    here. Readable by that account alone, and the path is what enforces it.
///  * [shared] — `/playlists/{id}`. A playlist imported from Spotify or YouTube
///    Music. Readable by every signed-in account, so that an import by one user
///    is discoverable by all of them.
///
/// Carried on the model because the screens need it. The detail screen has to
/// know which collection to open from a bare id, and the overflow menu has to
/// know whether "Rename" and "Delete" are this account's to offer — on a shared
/// playlist they belong to the importer alone.
///
/// Not to be confused with the `PlaylistVisibility` filter on the Playlists tab,
/// which is a UI choice between "All" and "Made by you".
enum PlaylistVisibility {
  private,
  shared;

  bool get isShared => this == PlaylistVisibility.shared;
}

/// A playlist.
///
/// ## AURIX's playlist, not Spotify's
///
/// The canonical copy lives in Firestore — at `/playlists/{playlistId}` when it
/// was imported, and at `/users/{uid}/playlists/{playlistId}` when the user
/// built it here. See [PlaylistVisibility] for why there are two. [fromDocument]
/// and [toDocument] round-trip both; [fromJson] remains only so the Spotify
/// import provider can read what Spotify sends.
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
    this.sourceUrl,
    this.createdAt,
    this.updatedAt,
    this.syncedAt,
    this.visibility = PlaylistVisibility.private,
    this.importedByUserId,
    this.importedBy,
    this.importedAt,
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

  /// The link this playlist was imported from, with tracking parameters
  /// stripped — see `PlaylistUrlParser`.
  ///
  /// Kept for two things: the "Open in Spotify" affordance on an imported
  /// playlist, and re-sync, which needs to know what to re-fetch. Null for an
  /// AURIX-native playlist and for one imported before this field existed.
  final String? sourceUrl;

  final DateTime? createdAt;
  final DateTime? updatedAt;

  /// When this playlist was last re-synced against its source. Null for one
  /// that has only ever been imported.
  final DateTime? syncedAt;

  /// Which collection this came out of. See [PlaylistVisibility].
  final PlaylistVisibility visibility;

  /// The account that first brought this playlist into the shared catalogue.
  ///
  /// **Provenance, not permission.** It says who imported the playlist; it does
  /// not say who may find it, open it or play it — every signed-in account may
  /// do all three. The one thing it does gate is destruction: only the importer
  /// may delete the shared document, because deleting it would remove the
  /// playlist for everybody. See the `/playlists` block in `firestore.rules`.
  ///
  /// Null on a personal playlist, which has no importer to record.
  final String? importedByUserId;

  /// The importer's display name, denormalised onto the document.
  ///
  /// Stored rather than joined so a page of search results can credit each
  /// importer without one profile read per row — and so it still renders when
  /// the importer's profile is not readable by the account looking at it, which
  /// is the normal case: profiles are private.
  final String? importedBy;

  /// When the playlist first entered the shared catalogue.
  ///
  /// Distinct from [createdAt] in intent and identical in practice today; kept
  /// separate because a later re-sync by a *different* account must be able to
  /// move `updatedAt` and `syncedAt` without disturbing the record of who
  /// brought the playlist in and when.
  final DateTime? importedAt;

  /// True when this playlist came from a service and can be re-synced.
  bool get canSync => source.isImported && (sourceId?.isNotEmpty ?? false);

  /// True when [userId] is the account that imported this shared playlist.
  ///
  /// False for everybody else, and false for a personal playlist, which is
  /// covered by its path instead. The distinction the UI needs: a shared
  /// playlist is *readable and playable* by anyone and *editable* by one.
  bool isImportedBy(String? userId) =>
      userId != null && userId.isNotEmpty && importedByUserId == userId;

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

  /// Reads a playlist document from either playlist collection.
  ///
  /// [visibility] says which one, and it is the caller's to supply because the
  /// document body cannot answer it: the two collections store the same fields,
  /// and it is the *path* that decides whether this is one account's private
  /// playlist or a shared catalogue entry. Passing it explicitly is what stops
  /// a global playlist being rendered with a personal playlist's edit
  /// affordances, or the reverse.
  ///
  /// [items] is always null here. A playlist's tracks are a subcollection, and
  /// this reads the parent document only — see `ApiPlaylistService
  /// .watchTracks` for the rows. That split is deliberate: the Library screen
  /// renders forty playlist covers and needs none of their contents, so joining
  /// them here would turn one query into forty-one.
  factory Playlist.fromDocument(
    String id,
    Map<String, dynamic> data, {
    PlaylistVisibility visibility = PlaylistVisibility.private,
  }) {
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
      sourceUrl: Json.strOrNull(data, 'sourceUrl'),
      createdAt: Json.timestamp(data, 'createdAt'),
      updatedAt: Json.timestamp(data, 'updatedAt'),
      syncedAt: Json.timestamp(data, 'syncedAt'),
      visibility: visibility,
      importedByUserId: Json.strOrNull(data, 'importedByUserId'),
      importedBy: Json.strOrNull(data, 'importedBy'),
      importedAt: Json.timestamp(data, 'importedAt'),
    );
  }

  /// The document body for this playlist.
  ///
  /// `createdAt`, `updatedAt` and `trackCount` are absent by design. All three
  /// are the write path's to set — the timestamps because a server clock is the
  /// only one every device agrees on, and the count because it is maintained by
  /// the same transaction that adds or removes a row, so a stale value carried
  /// in from a model instance could overwrite a correct one.
  Map<String, dynamic> toDocument() => <String, dynamic>{
    'name': name,
    'description': description,
    'coverUrl': imageUrl ?? '',
    'source': source.wireValue,
    'sourceId': sourceId,
    if (sourceUrl != null) 'sourceUrl': sourceUrl,
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

  /// Who to credit for a *shared* playlist being in AURIX at all.
  ///
  /// "Added by Sam" rather than "Spotify": on the global catalogue the
  /// interesting fact is that another AURIX listener brought this in, and the
  /// source is already shown beside it. Null when there is nobody to credit —
  /// a personal playlist, or a shared one imported before the field existed —
  /// so the caller omits the line rather than rendering "Added by null".
  String? get importCredit {
    if (visibility != PlaylistVisibility.shared) return null;
    final name = importedBy?.trim();
    return (name == null || name.isEmpty) ? null : 'Added by $name';
  }

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
  /// A playlist under `/users/{uid}/playlists` belongs to that user by
  /// construction — the path *is* the ownership claim, and the security rules
  /// enforce it — so a personal AURIX playlist is editable and carries no
  /// `owner` object to check.
  ///
  /// A [PlaylistVisibility.shared] one is different, and this is where the shared
  /// catalogue changes the answer: every signed-in account can read and play
  /// it, but only the importer may rearrange it. Anyone else editing it would
  /// be editing everybody's copy — so the affordance is withheld from them
  /// rather than offered and refused by the rules a moment later.
  ///
  /// The Spotify branch survives for playlists rendered during an import
  /// preview, which are not the user's to change unless Spotify says so.
  bool isEditableBy(String? userId) {
    if (visibility == PlaylistVisibility.shared) return isImportedBy(userId);
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
    PlaylistVisibility? visibility,
    String? importedByUserId,
    String? importedBy,
    DateTime? importedAt,
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
    sourceUrl: sourceUrl,
    createdAt: createdAt,
    updatedAt: updatedAt ?? this.updatedAt,
    syncedAt: syncedAt,
    visibility: visibility ?? this.visibility,
    importedByUserId: importedByUserId ?? this.importedByUserId,
    importedBy: importedBy ?? this.importedBy,
    importedAt: importedAt ?? this.importedAt,
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
    visibility,
    importedByUserId,
  ];
}
