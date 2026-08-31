/// OAuth scopes requested at login.
///
/// Each scope is listed with the AURIX feature that needs it, so it is
/// obvious what breaks if one is removed — and so the list can be trimmed
/// without guesswork when a deployment does not need a feature.
abstract final class SpotifyScopes {
  // Profile
  static const String readPrivate = 'user-read-private'; // display name, product tier
  static const String readEmail = 'user-read-email'; // profile screen

  // Library
  static const String libraryRead = 'user-library-read'; // Liked Songs, Saved Albums
  static const String libraryModify = 'user-library-modify'; // save / unsave

  // Listening history & taste
  static const String topRead = 'user-top-read'; // Trending, Popular Artists
  static const String recentlyPlayed = 'user-read-recently-played'; // Recently Played

  // Follows
  static const String followRead = 'user-follow-read'; // followed artists
  static const String followModify = 'user-follow-modify'; // follow / unfollow

  // Playlists
  static const String playlistReadPrivate = 'playlist-read-private';
  static const String playlistReadCollaborative = 'playlist-read-collaborative';
  static const String playlistModifyPublic = 'playlist-modify-public';
  static const String playlistModifyPrivate = 'playlist-modify-private';

  // Playback via Spotify Connect (Premium accounts only for write operations)
  static const String playbackState = 'user-read-playback-state';
  static const String modifyPlaybackState = 'user-modify-playback-state';
  static const String currentlyPlaying = 'user-read-currently-playing';

  /// Playback via the Spotify app on this phone, over App Remote.
  ///
  /// Distinct from [modifyPlaybackState], which governs Spotify **Connect** —
  /// commanding a device registered with Spotify's servers. App Remote binds
  /// to the Spotify app installed alongside AURIX and is the only way to play
  /// a full track on a phone that has no other Spotify device signed in.
  ///
  /// Without this scope the App Remote handshake fails with
  /// `UserNotAuthorized`, which is indistinguishable at the call site from the
  /// user simply never having approved AURIX.
  static const String appRemoteControl = 'app-remote-control';

  /// The full set requested during login.
  static const List<String> all = <String>[
    readPrivate,
    readEmail,
    libraryRead,
    libraryModify,
    topRead,
    recentlyPlayed,
    followRead,
    followModify,
    playlistReadPrivate,
    playlistReadCollaborative,
    playlistModifyPublic,
    playlistModifyPrivate,
    playbackState,
    modifyPlaybackState,
    currentlyPlaying,
    appRemoteControl,
  ];

  static String get asParameter => all.join(' ');
}
