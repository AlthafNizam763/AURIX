import 'aurix_session_store.dart';

/// Thrown when an operation needs a signed-in account and there is not one.
class NotSignedIn implements Exception {
  const NotSignedIn(this.message);
  final String message;

  @override
  String toString() => 'NotSignedIn: $message';
}

/// Thrown when the API refuses an operation the account is not entitled to.
///
/// The counterpart of the old `FirestoreAccessDenied`. It used to mean "the
/// security rules said no", which was a rule evaluated on Google's servers
/// against a document path. It now means the API said no — a shared playlist
/// somebody else imported, an admin route, another account's data.
///
/// Kept as its own type rather than folded into a generic failure because the
/// UI treats it differently: it is not a retry, and it is not a bug. It is an
/// answer.
class AurixAccessDenied implements Exception {
  const AurixAccessDenied(this.message, {this.code, this.operation});

  final String message;

  /// The API's own error code — `forbidden`, `admin_only`. Kept for the log and
  /// for the handful of call sites that branch on *why* access was refused
  /// rather than merely that it was.
  final String? code;

  final String? operation;

  @override
  String toString() =>
      'AurixAccessDenied${operation == null ? '' : '($operation)'}: $message';
}

/// Who the app believes is signed in.
///
/// The replacement for `FirebaseSession`, and it answers the same two questions
/// for the same reason: a write that is going to be refused should be refused
/// here, with a sentence, rather than at the far end of a round trip with a
/// status code.
///
/// ## What changed, and what did not
///
/// Under Firestore this class was a *guard in front of the real boundary* — the
/// security rules were what actually enforced ownership, and this only turned a
/// coming `permission-denied` into a legible message first.
///
/// It is now purely a client-side courtesy, and the boundary moved somewhere
/// stronger. The API resolves the uid from a signed token and splices it into
/// every per-user query itself; the client cannot phrase a request about
/// another account at all. So a bug here can no longer cause a data leak — the
/// worst it can do is let a doomed request be sent.
///
/// That is why [requireOwner] survives despite being, strictly, redundant: the
/// message it produces is the point.
class AurixSession {
  /// [currentUid] exists for tests, which have no keystore and no intention of
  /// opening one. Production passes [store] and nothing else.
  ///
  /// Both are optional so this stays `const`-constructible — which is what lets
  /// it be a default argument on [PlaylistImportService] rather than a required
  /// one threaded through every construction site.
  const AurixSession({AurixSessionStore? store, String? Function()? currentUid})
    : _store = store,
      _override = currentUid;

  final AurixSessionStore? _store;
  final String? Function()? _override;

  /// The signed-in uid, or null when nobody is — or when there is no session
  /// store at all, which is the case in a unit test.
  String? get uid {
    final override = _override;
    if (override != null) return override();
    return _store?.currentUser?.uid;
  }

  bool get isSignedIn => uid != null;

  /// True when this account may change the app's appearance.
  ///
  /// A display concern only — it decides whether the Appearance row is drawn.
  /// Every admin route re-reads the user document server-side, so a client that
  /// forced this true would see the screen and be refused by every control on
  /// it.
  bool get isAdmin => _store?.currentUser?.isAdmin ?? false;

  /// Asserts that *somebody* is signed in, and returns their uid.
  ///
  /// The weaker of the two checks, and the right one for the shared
  /// collections. The catalogue and the shared playlists are readable by any
  /// signed-in account and owned by none, so there is no uid to compare
  /// against — the only question those routes ask is "is there a valid token",
  /// and this asks exactly that and nothing more. Using [requireOwner] there
  /// would invent an ownership requirement the collection does not have.
  String requireSignedIn({required String whenSignedOut}) {
    final signedIn = uid;
    if (signedIn == null) throw NotSignedIn(whenSignedOut);
    return signedIn;
  }

  /// Asserts that [uid] is the account currently signed in, and returns it.
  ///
  /// The stronger check, for the per-user collections and for the one field on
  /// a shared playlist that must match the writer, `importedByUserId`.
  ///
  /// [whenSignedOut] is the sentence a signed-out user should read; the
  /// mismatch case has its own, because "sign in" is the wrong advice for
  /// someone who *is* signed in as somebody else.
  String requireOwner(String uid, {required String whenSignedOut}) {
    final signedIn = this.uid;
    if (signedIn == null) throw NotSignedIn(whenSignedOut);
    if (signedIn != uid) {
      // Reachable when a session changes under a screen that captured the old
      // uid — a sign-out on another device, a revoked token, a fast
      // sign-out/sign-in. The request would be answered about the *new*
      // account, which is worse than refusing it.
      throw const NotSignedIn('Your AURIX session changed. Sign in again and retry.');
    }
    return signedIn;
  }
}
