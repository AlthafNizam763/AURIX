import 'package:aurix/data/models/models.dart';

/// Sample Spotify payloads, shaped exactly as the Web API returns them.
///
/// Hand-written from the documented response schemas rather than captured from
/// a live account, so the tests carry no real user data and no real IDs. The
/// deliberately awkward cases — a null track in a playlist, a missing
/// `preview_url`, a year-precision release date — are the ones that break
/// parsers in production, so they are represented here on purpose.
abstract final class Fixtures {
  // ---- Raw JSON ---------------------------------------------------------

  static Map<String, dynamic> get artistJson => <String, dynamic>{
    'id': 'artist_1',
    'name': 'Neon Meridian',
    'type': 'artist',
    'uri': 'spotify:artist:artist_1',
    'genres': ['synthwave', 'electronic'],
    'popularity': 74,
    'followers': {'total': 1284000},
    'images': [
      {'url': 'https://cdn.example/artist_640.jpg', 'width': 640, 'height': 640},
      {'url': 'https://cdn.example/artist_300.jpg', 'width': 300, 'height': 300},
      {'url': 'https://cdn.example/artist_64.jpg', 'width': 64, 'height': 64},
    ],
    'external_urls': {'spotify': 'https://open.spotify.com/artist/artist_1'},
  };

  static Map<String, dynamic> get simplifiedArtistJson => <String, dynamic>{
    'id': 'artist_1',
    'name': 'Neon Meridian',
    'type': 'artist',
    'uri': 'spotify:artist:artist_1',
    'external_urls': {'spotify': 'https://open.spotify.com/artist/artist_1'},
  };

  static Map<String, dynamic> get albumJson => <String, dynamic>{
    'id': 'album_1',
    'name': 'Parallel Skies',
    'album_type': 'album',
    'total_tracks': 3,
    'release_date': '2023-06-14',
    'release_date_precision': 'day',
    'uri': 'spotify:album:album_1',
    'label': 'Meridian Records',
    'popularity': 61,
    'copyrights': [
      {'text': '© 2023 Meridian Records', 'type': 'C'},
    ],
    'artists': [simplifiedArtistJson],
    'images': [
      {'url': 'https://cdn.example/album_640.jpg', 'width': 640, 'height': 640},
      {'url': 'https://cdn.example/album_300.jpg', 'width': 300, 'height': 300},
      {'url': 'https://cdn.example/album_64.jpg', 'width': 64, 'height': 64},
    ],
    'external_urls': {'spotify': 'https://open.spotify.com/album/album_1'},
    'tracks': {
      'items': [trackJson, trackWithoutPreviewJson, explicitTrackJson],
      'total': 3,
      'limit': 50,
      'offset': 0,
      'next': null,
      'previous': null,
    },
  };

  /// A release Spotify only knows the year for. Common for older catalogue.
  static Map<String, dynamic> get yearPrecisionAlbumJson => <String, dynamic>{
    ...albumJson,
    'id': 'album_old',
    'release_date': '1978',
    'release_date_precision': 'year',
    'tracks': null,
  };

  static Map<String, dynamic> get trackJson => <String, dynamic>{
    'id': 'track_1',
    'name': 'Afterglow',
    'type': 'track',
    'uri': 'spotify:track:track_1',
    'duration_ms': 213000,
    'track_number': 1,
    'disc_number': 1,
    'explicit': false,
    'popularity': 58,
    'is_local': false,
    'preview_url': 'https://cdn.example/preview/track_1.mp3',
    'artists': [simplifiedArtistJson],
    'external_urls': {'spotify': 'https://open.spotify.com/track/track_1'},
  };

  /// The common case for apps registered after 27 Nov 2024: no preview.
  static Map<String, dynamic> get trackWithoutPreviewJson => <String, dynamic>{
    ...trackJson,
    'id': 'track_2',
    'name': 'Low Orbit',
    'uri': 'spotify:track:track_2',
    'track_number': 2,
    'preview_url': null,
    'duration_ms': 187000,
  };

  static Map<String, dynamic> get explicitTrackJson => <String, dynamic>{
    ...trackJson,
    'id': 'track_3',
    'name': 'Static Bloom',
    'uri': 'spotify:track:track_3',
    'track_number': 3,
    'explicit': true,
    'duration_ms': 245000,
  };

  /// A file the playlist owner added from their own device. Has no usable ID.
  static Map<String, dynamic> get localTrackJson => <String, dynamic>{
    'id': null,
    'name': 'Untitled demo.mp3',
    'type': 'track',
    'uri': 'spotify:local:::Untitled+demo:0',
    'duration_ms': 0,
    'is_local': true,
    'explicit': false,
    'artists': [],
  };

  static Map<String, dynamic> get playlistJson => <String, dynamic>{
    'id': 'playlist_1',
    'name': 'Night Drive',
    'description': 'Late-night <a href="#">synth</a> &amp; more',
    'uri': 'spotify:playlist:playlist_1',
    'collaborative': false,
    'public': true,
    'snapshot_id': 'snap_abc123',
    'followers': {'total': 42150},
    'owner': {
      'id': 'user_owner',
      'display_name': 'Meridian Editorial',
      'type': 'user',
    },
    'images': [
      {'url': 'https://cdn.example/pl_640.jpg', 'width': 640, 'height': 640},
    ],
    'external_urls': {'spotify': 'https://open.spotify.com/playlist/playlist_1'},
    'tracks': {
      'items': [
        {
          'added_at': '2024-02-01T10:00:00Z',
          'added_by': {'id': 'user_owner'},
          'is_local': false,
          'track': {...trackJson, 'album': albumWithoutTracksJson},
        },
        // Spotify genuinely returns this for a track removed from the
        // catalogue. Parsers that assume `track` is non-null crash here.
        {
          'added_at': '2024-02-02T10:00:00Z',
          'added_by': {'id': 'user_owner'},
          'is_local': false,
          'track': null,
        },
        {
          'added_at': '2024-02-03T10:00:00Z',
          'added_by': {'id': 'user_owner'},
          'is_local': true,
          'track': localTrackJson,
        },
      ],
      'total': 3,
      'limit': 100,
      'offset': 0,
      'next': null,
    },
  };

  static Map<String, dynamic> get albumWithoutTracksJson {
    final json = Map<String, dynamic>.from(albumJson);
    json.remove('tracks');
    return json;
  }

  static Map<String, dynamic> get userJson => <String, dynamic>{
    'id': 'user_1',
    'display_name': 'Sam Rivers',
    'email': 'sam@example.com',
    'country': 'GB',
    'product': 'premium',
    'followers': {'total': 18},
    'images': [
      {'url': 'https://cdn.example/user_300.jpg', 'width': 300, 'height': 300},
    ],
    'external_urls': {'spotify': 'https://open.spotify.com/user/user_1'},
    'explicit_content': {'filter_enabled': false, 'filter_locked': false},
  };

  static Map<String, dynamic> get freeUserJson => <String, dynamic>{
    ...userJson,
    'id': 'user_free',
    'product': 'free',
  };

  /// An account whose explicit-content filter is on and locked — a managed or
  /// parental-controlled account, where the app must not offer a toggle.
  static Map<String, dynamic> get filterLockedUserJson => <String, dynamic>{
    ...userJson,
    'id': 'user_locked',
    'explicit_content': {'filter_enabled': true, 'filter_locked': true},
  };

  /// What `GET /me` returns to a Development Mode app after Spotify's
  /// February 2026 changes: no `explicit_content`, and no `country`, `email`,
  /// `followers` or `product` either.
  static Map<String, dynamic> get devModeUserJson => <String, dynamic>{
    'id': 'user_1',
    'display_name': 'Sam Rivers',
    'images': [
      {'url': 'https://cdn.example/user_300.jpg', 'width': 300, 'height': 300},
    ],
    'external_urls': {'spotify': 'https://open.spotify.com/user/user_1'},
  };

  static Map<String, dynamic> get deviceJson => <String, dynamic>{
    'id': 'device_1',
    'name': "Sam's MacBook",
    'type': 'Computer',
    'is_active': true,
    'is_restricted': false,
    'is_private_session': false,
    'volume_percent': 72,
  };

  static Map<String, dynamic> get restrictedDeviceJson => <String, dynamic>{
    'id': 'device_2',
    'name': 'Living Room TV',
    'type': 'CastVideo',
    'is_active': false,
    'is_restricted': true,
    'is_private_session': false,
  };

  static Map<String, dynamic> get searchResponseJson => <String, dynamic>{
    'tracks': {
      'items': [trackJson, trackWithoutPreviewJson],
      'total': 2,
      'limit': 20,
      'offset': 0,
      'next': null,
    },
    'artists': {
      'items': [artistJson],
      'total': 1,
      'limit': 20,
      'offset': 0,
      'next': null,
    },
    'albums': {
      'items': [albumWithoutTracksJson],
      'total': 1,
      'limit': 20,
      'offset': 0,
      'next': null,
    },
    'playlists': {
      'items': [playlistJson],
      'total': 1,
      'limit': 20,
      'offset': 0,
      'next': null,
    },
  };

  // ---- Parsed models ----------------------------------------------------

  static Track get track => Track.fromJson(trackJson);
  static Track get trackWithoutPreview => Track.fromJson(trackWithoutPreviewJson);
  static Track get localTrack => Track.fromJson(localTrackJson);
  static Album get album => Album.fromJson(albumJson);
  static Artist get artist => Artist.fromJson(artistJson);
  static Playlist get playlist => Playlist.fromJson(playlistJson);
  static UserProfile get user => UserProfile.fromJson(userJson);
  static SpotifyDevice get device => SpotifyDevice.fromJson(deviceJson);

  // ---- AURIX's own records ----------------------------------------------
  //
  // Firestore document bodies and the models they parse to. Distinct from the
  // Spotify payloads above, which are now only what the import provider reads.

  static AurixUser get aurixUser => AurixUser(
    uid: 'uid_test',
    name: 'Test Listener',
    email: 'listener@example.com',
    avatarId: 'avatar_03',
    createdAt: DateTime.utc(2026, 1, 15),
  );

  static Map<String, dynamic> get aurixTrackData => <String, dynamic>{
    'title': 'Midnight Signal',
    'artist': 'Neon Meridian',
    'album': 'Parallel Skies',
    'durationMs': 214000,
    'artworkUrl': 'https://cdn.example/album_640.jpg',
    'explicit': false,
    'source': 'aurix',
    'sourceId': null,
    'spotifyId': null,
    'youtubeVideoId': null,
  };

  /// A track AURIX owns outright — no provider id behind it.
  static Track get aurixTrack =>
      Track.fromFirestore('aurix_midnight-signal-neon-meridian', aurixTrackData);

  /// A track imported from Spotify: same shape, with the provenance filled in.
  static Track get importedTrack => Track.fromFirestore(
    'spotify_track_1',
    <String, dynamic>{
      ...aurixTrackData,
      'source': 'spotify',
      'sourceId': 'track_1',
      'spotifyId': 'track_1',
    },
  );

  static Map<String, dynamic> get aurixPlaylistData => <String, dynamic>{
    'name': 'Late Drive',
    'description': 'For the long way home',
    'coverUrl': 'https://cdn.example/playlist_640.jpg',
    'source': 'aurix',
    'sourceId': null,
    'trackCount': 2,
  };

  static Playlist get aurixPlaylist =>
      Playlist.fromFirestore('playlist_local_1', aurixPlaylistData);

  /// [count] AURIX tracks with distinct titles, for list and queue tests.
  static List<Track> aurixTracks(int count) => List<Track>.generate(
    count,
    (i) => Track.fromFirestore('aurix_track-$i', <String, dynamic>{
      ...aurixTrackData,
      'title': 'Track $i',
    }),
  );

  /// [count] distinct tracks, for queue tests.
  static List<Track> tracks(int count) => List<Track>.generate(
    count,
    (i) => Track.fromJson(<String, dynamic>{
      ...trackJson,
      'id': 'track_$i',
      'name': 'Track $i',
      'uri': 'spotify:track:track_$i',
      'track_number': i + 1,
    }),
  );
}
