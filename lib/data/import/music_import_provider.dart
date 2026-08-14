import '../models/media_source.dart';
import 'imported_models.dart';

/// Why an import could not proceed.
enum ImportFailureKind {
  /// The user closed the authorization page, or backed out.
  cancelled,

  /// The service refused the credentials or the app.
  authFailed,

  /// The connected account is not permitted to read what was asked for.
  forbidden,

  /// The request could not reach the service.
  network,

  /// The service is rate-limiting. [ImportFailure.retryAfter] may say when.
  rateLimited,

  /// This build has no credentials configured for the provider.
  notConfigured,

  /// The provider exists but is not implemented yet.
  unavailable,

  unknown;

  String get message {
    switch (this) {
      case ImportFailureKind.cancelled:
        return 'Import cancelled.';
      case ImportFailureKind.authFailed:
        return 'Could not sign in to that service. Try again.';
      case ImportFailureKind.forbidden:
        return 'That account is not allowed to share its playlists with '
            'AURIX.';
      case ImportFailureKind.network:
        return 'No connection. Importing needs the network.';
      case ImportFailureKind.rateLimited:
        return 'That service is asking AURIX to slow down. Try again shortly.';
      case ImportFailureKind.notConfigured:
        return 'This build has no credentials for that service.';
      case ImportFailureKind.unavailable:
        return 'That import provider is not available yet.';
      case ImportFailureKind.unknown:
        return 'The import failed. Please try again.';
    }
  }
}

class ImportFailure implements Exception {
  const ImportFailure(this.kind, {this.detail, this.retryAfter});

  final ImportFailureKind kind;

  /// The underlying error, for the log. Never shown to the user.
  final String? detail;

  final Duration? retryAfter;

  String get message => kind.message;

  @override
  String toString() =>
      'ImportFailure(${kind.name}${detail == null ? '' : ': $detail'})';
}

/// A service AURIX can bring playlists in from.
///
/// ## The contract
///
/// Four methods, in the order they are called:
///
/// ```
/// authenticate()        // once, interactively
/// getPlaylists()        // what is there
/// getPlaylistTracks()   // per playlist the user chose
/// disconnect()          // always, when the import ends
/// ```
///
/// ## What an implementation may and may not do
///
/// It **produces descriptions**: [ImportedPlaylist] and [ImportedTrack], and
/// nothing else. It does not touch Firestore, does not know a document id, and
/// does not decide what an AURIX playlist looks like — [MusicImportService]
/// owns all of that. A provider that needed to know AURIX's storage layout
/// would be a provider that could get it wrong, and there will be several.
///
/// It **must not fetch audio**. Importing is metadata and references. No
/// downloading of streams, no caching of audio files, no circumvention of any
/// protection, and nothing written to Firebase Storage. See the note on
/// [ImportedTrack].
///
/// ## Session lifetime
///
/// The credential a provider obtains in [authenticate] belongs to the import,
/// not to the app. AURIX's own session is Firebase's, and a user who never
/// opens this screen never authenticates with anything else. [disconnect] must
/// therefore actually revoke and erase what [authenticate] stored — see the
/// note there.
abstract interface class MusicImportProvider {
  /// Which source this provider imports from. Stamped onto everything it
  /// produces, so an AURIX record remembers where it came from.
  MediaSource get source;

  /// The provider's name, as shown on the import screen.
  String get displayName;

  /// One line describing what importing from here brings in.
  String get description;

  /// False when this build has no credentials for the provider, or when it is
  /// a placeholder for a service not yet implemented. The import screen shows
  /// it as unavailable with a reason rather than hiding it — a missing option
  /// with no explanation is the harder thing to debug.
  bool get isAvailable;

  /// Why [isAvailable] is false, or null when it is true.
  String? get unavailableReason;

  /// Whether a session obtained by [authenticate] is currently live.
  bool get isConnected;

  /// Runs the provider's interactive sign-in.
  ///
  /// Throws [ImportFailure] with [ImportFailureKind.cancelled] when the user
  /// backs out, which callers should treat as a non-event rather than an error.
  Future<void> authenticate();

  /// The playlists the connected account can see.
  Future<List<ImportedPlaylist>> getPlaylists();

  /// The tracks in one playlist, in playlist order.
  ///
  /// [onProgress] is called with (fetched, total) as pages arrive, so a long
  /// playlist can show progress rather than an indeterminate spinner. Total is
  /// the source's own count and may be approximate.
  Future<List<ImportedTrack>> getPlaylistTracks(
    String playlistId, {
    void Function(int fetched, int total)? onProgress,
  });

  /// Ends the session and erases every credential it created.
  ///
  /// Not optional and not best-effort. The point of the import model is that
  /// AURIX holds no standing relationship with another service: after an
  /// import, the app must be exactly as it was before, minus the playlists it
  /// gained. An implementation that leaves a refresh token in secure storage
  /// has quietly turned an import into a connected account.
  Future<void> disconnect();
}
