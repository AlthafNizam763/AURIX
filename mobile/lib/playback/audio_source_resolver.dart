import '../data/models/media_source.dart';
import '../data/models/track.dart';

/// Where the audio for a track would legitimately come from.
///
/// Named for the *authorisation*, not for the technology, because that is the
/// property that decides whether AURIX may use it at all.
enum AudioSourceKind {
  /// A short preview the source publishes for open use, streamed by AURIX
  /// itself through `just_audio`.
  ///
  /// The only audio AURIX ever decodes. It is streamed, never written to disk.
  licensedPreview,

  /// A Spotify client — the app on this phone over App Remote, or a Connect
  /// device — asked to play the full track.
  ///
  /// AURIX sends a transport command and Spotify produces the audio. No stream
  /// reaches AURIX and none could: this is the mechanism that exists precisely
  /// *because* a third-party app may not decode Spotify's audio.
  spotifyClient,

  /// An authorised YouTube player handed the video id.
  ///
  /// Not implemented — see [AudioSourceResolver]. Declared because the resolver
  /// must be able to say "a YouTube song is playable *in principle*, by a
  /// player AURIX does not yet embed", which is a different answer from "this
  /// song cannot be played".
  youTubePlayer,

  /// A catalogue AURIX is itself licensed to stream.
  ///
  /// Nothing implements this today. It is the entry that makes the enum honest:
  /// AURIX has no music licence of its own, and the day it does, this is the
  /// value that gets a resolver and the rest of the app does not change.
  aurixLicensed,
}

/// Why a track cannot be played.
///
/// Distinguished rather than collapsed into one "unavailable", because each one
/// has a different fix and the UI should be able to say which.
enum AudioUnavailableReason {
  /// A file from the user's own device, with no id and no stream.
  localFile,

  /// The song carries no provider id and no preview — nothing addresses it.
  ///
  /// The honest resting state of a music app with no catalogue of its own, and
  /// the case a licensed source would fix.
  noAuthorisedSource,

  /// The song is addressable, but the provider that could play it is not
  /// connected right now.
  providerUnavailable,

  /// The provider exists and is connected, but this account may not use it —
  /// Spotify Connect without Premium, most often.
  accountNotEntitled;

  String get message {
    switch (this) {
      case AudioUnavailableReason.localFile:
        return 'This song is a file on your device and cannot be played here.';
      case AudioUnavailableReason.noAuthorisedSource:
        return 'AURIX has no authorised way to play this song yet.';
      case AudioUnavailableReason.providerUnavailable:
        return 'The service that can play this song is not connected.';
      case AudioUnavailableReason.accountNotEntitled:
        return 'Your account is not permitted to play full tracks.';
    }
  }
}

/// What a resolver decided about one track.
class AudioSourceDecision {
  const AudioSourceDecision.playable(this.kind)
      : reason = null,
        assert(kind != null, 'A playable decision names a source');

  const AudioSourceDecision.unavailable(this.reason)
      : kind = null,
        assert(reason != null, 'An unplayable decision names a reason');

  /// Non-null when the track can be played.
  final AudioSourceKind? kind;

  /// Non-null when it cannot.
  final AudioUnavailableReason? reason;

  bool get canPlay => kind != null;

  /// What to tell the user, or null when there is nothing to explain.
  String? get message => reason?.message;
}

/// Decides which authorised source can play a track.
///
/// ## Why this exists, and what it is not
///
/// AURIX must never be the thing that decodes audio it is not licensed to
/// decode. That is not a policy this codebase asserts once in a comment — it is
/// a decision made per track, every time something is played, and this is where
/// it is made.
///
/// The abstraction is what makes the playback *provider* replaceable. Today the
/// only sources are a licensed preview and a Spotify client; the moment AURIX
/// has a catalogue of its own, or embeds an authorised YouTube player, that is
/// a new implementation of this interface and a one-line change at the
/// composition root. No screen, no controller and no playlist code changes,
/// because none of them ask where audio comes from — they ask
/// `MusicPlaybackService` to play a track and it consults this.
///
/// ```
///            UI
///             ↓
///   MusicPlaybackService          "play this track"
///             ↓
///   AudioSourceResolver           "which authorised source, if any?"  ← here
///             ↓
///   preview stream │ Spotify client │ (future: licensed catalogue)
/// ```
///
/// ## What an implementation must never do
///
/// Resolve to a source that would require downloading, extracting, decrypting
/// or re-encoding audio from a service that has not authorised it. There is no
/// [AudioSourceKind] for that and there must not be one. An imported song's
/// `spotifyId` and `youtubeVideoId` are handles for *asking an authorised
/// player to play*, not handles for fetching a stream.
abstract interface class AudioSourceResolver {
  /// What could play [track] right now.
  AudioSourceDecision resolve(Track track);
  /// Convenience for the common question.
  bool canPlay(Track track);
}

/// The resolver AURIX ships with.
///
/// Reports what is true of the track itself plus what the caller says about
/// live provider availability. It is deliberately a pure function of its
/// inputs — no network, no plugin, no state — so that "can this row be played"
/// is answerable while building a list of fifty of them, and so the whole
/// decision table is testable without a device.
///
/// The live half is injected as [isSpotifyAvailable] rather than read here,
/// because whether a Spotify client is reachable is a question the playback
/// layer already answers (`PlaybackResolver`, App Remote binding, the Connect
/// snapshot) and duplicating that here would create a second answer that could
/// disagree with the first.
class DefaultAudioSourceResolver implements AudioSourceResolver {
  const DefaultAudioSourceResolver({
    this.isSpotifyAvailable = _alwaysTrue,
    this.isSpotifyEntitled = _alwaysTrue,
  });

  /// Whether a Spotify client could be commanded right now.
  final bool Function() isSpotifyAvailable;

  /// Whether this Spotify account may play full tracks. False for a free
  /// account being asked to use Connect.
  final bool Function() isSpotifyEntitled;

  static bool _alwaysTrue() => true;

  @override
  AudioSourceDecision resolve(Track track) {
    if (track.isLocal) {
      return const AudioSourceDecision.unavailable(
        AudioUnavailableReason.localFile,
      );
    }

    // A licensed preview is checked first among the things AURIX can do
    // *itself*, because it needs no third party to be connected — it works
    // offline-ish, on a free account, with no other app installed. It is only
    // thirty seconds, so the playback layer may still prefer a full track when
    // one is reachable; this reports what is possible, not what is preferred.
    final hasPreview = track.hasPreview;
    final hasSpotify = track.hasSpotifyId;

    if (hasSpotify) {
      if (!isSpotifyAvailable()) {
        // Fall through to a preview rather than failing: a disconnected
        // Spotify with a preview available is still thirty seconds of music,
        // which beats silence and an error.
        if (hasPreview) {
          return const AudioSourceDecision.playable(
            AudioSourceKind.licensedPreview,
          );
        }
        return const AudioSourceDecision.unavailable(
          AudioUnavailableReason.providerUnavailable,
        );
      }

      if (!isSpotifyEntitled()) {
        if (hasPreview) {
          return const AudioSourceDecision.playable(
            AudioSourceKind.licensedPreview,
          );
        }
        return const AudioSourceDecision.unavailable(
          AudioUnavailableReason.accountNotEntitled,
        );
      }

      return const AudioSourceDecision.playable(AudioSourceKind.spotifyClient);
    }

    if (hasPreview) {
      return const AudioSourceDecision.playable(
        AudioSourceKind.licensedPreview,
      );
    }

    // A YouTube-sourced song with no preview and no Spotify match. AURIX does
    // not embed a YouTube player, so it cannot be played — and it is reported
    // as "no authorised source" rather than as "provider unavailable", because
    // the fix is a player AURIX has yet to add rather than a connection the
    // user could make.
    //
    // Note what is *not* here: there is no branch that fetches a YouTube
    // stream. There must never be one.
    if (track.source == MediaSource.youtube || track.youtubeVideoId != null) {
      return const AudioSourceDecision.unavailable(
        AudioUnavailableReason.noAuthorisedSource,
      );
    }

    return const AudioSourceDecision.unavailable(
      AudioUnavailableReason.noAuthorisedSource,
    );
  }

  @override
  bool canPlay(Track track) => resolve(track).canPlay;
}
