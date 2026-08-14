/// Where a track or playlist in AURIX came from.
///
/// AURIX owns its library. Everything in Firestore is an AURIX record — but a
/// record can *remember* that it was created by importing from somewhere else,
/// and that memory is worth keeping for three reasons:
///
///  * **Attribution.** A playlist the user imported from Spotify should say so
///    in the UI rather than appearing as something they built here.
///  * **Re-import and de-duplication.** Importing the same Spotify playlist
///    twice should update the existing one, not create a second copy. That
///    needs the pair ([MediaSource], `sourceId`) to be stable and comparable.
///  * **Playback resolution.** The only thing that can legally play a Spotify
///    track is Spotify. A track that remembers a `spotifyId` can be handed to
///    the Spotify playback provider; one that does not, cannot.
///
/// It is deliberately *not* a switch on which backend to read from. Every read
/// in AURIX goes to Firestore regardless of this value — see
/// `FirestoreLibraryService`. This says where the metadata originated, nothing
/// more.
enum MediaSource {
  /// Created in AURIX: a playlist the user made here, a track added by hand.
  aurix,

  /// Imported from Spotify. `sourceId` is the Spotify ID.
  spotify,

  /// Imported from YouTube / YouTube Music. `sourceId` is the video or
  /// playlist ID.
  youtube;

  /// Parses the string stored in Firestore.
  ///
  /// Anything unrecognised becomes [aurix] rather than null. A document written
  /// by a newer build that knows about a provider this one does not should
  /// still render as a playable AURIX record; refusing to parse it would hide
  /// the user's own data from them after a downgrade.
  static MediaSource parse(Object? raw) {
    if (raw is! String) return MediaSource.aurix;
    switch (raw.toLowerCase()) {
      case 'spotify':
        return MediaSource.spotify;
      case 'youtube':
      case 'youtube_music':
      case 'youtubemusic':
        return MediaSource.youtube;
      default:
        return MediaSource.aurix;
    }
  }

  /// The value written to Firestore. Matches [name] by construction — spelled
  /// out so a rename of the enum constant cannot silently change the wire
  /// format of every document already written.
  String get wireValue {
    switch (this) {
      case MediaSource.aurix:
        return 'aurix';
      case MediaSource.spotify:
        return 'spotify';
      case MediaSource.youtube:
        return 'youtube';
    }
  }

  /// How the source is named on screen.
  String get label {
    switch (this) {
      case MediaSource.aurix:
        return 'AURIX';
      case MediaSource.spotify:
        return 'Spotify';
      case MediaSource.youtube:
        return 'YouTube Music';
    }
  }

  /// True when the record originated outside AURIX.
  bool get isImported => this != MediaSource.aurix;
}
