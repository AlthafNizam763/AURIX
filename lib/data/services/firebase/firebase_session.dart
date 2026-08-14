import 'package:firebase_auth/firebase_auth.dart';
import 'package:firebase_core/firebase_core.dart';

/// Thrown when an operation needs a Firebase Authentication session and there
/// is not one that owns the path being addressed.
///
/// Carries a sentence written for a person, because that sentence is the whole
/// reason this type exists: without it the failure surfaces as
/// `[cloud_firestore/permission-denied]`, which tells the user nothing and
/// tells the developer only that *something* was refused.
class NotSignedIn implements Exception {
  const NotSignedIn(this.message);

  final String message;

  @override
  String toString() => 'NotSignedIn: $message';
}

/// Thrown when Firestore refused a read or write that the signed-in account
/// should have been allowed to make.
///
/// Distinct from [NotSignedIn]: the session is fine and the path is the user's
/// own, so the fault is on the server side of the boundary — rules that were
/// never deployed, or rules that disagree with the path the app is using.
class FirestoreAccessDenied implements Exception {
  const FirestoreAccessDenied(this.message, {this.code});

  final String message;

  /// Firestore's own code, for the log. Never shown to the user.
  final String? code;

  @override
  String toString() =>
      'FirestoreAccessDenied(${code ?? 'unknown'}): $message';
}

/// The Firebase Authentication session, as the data layer sees it.
///
/// ## Why the data layer asks at all
///
/// Every document AURIX writes lives under `/users/{uid}`, and `firestore.rules`
/// authorises those on `request.auth.uid` and nothing else. So a uid that did
/// not come from Firebase Auth — a stale one held by a provider whose session
/// expired, a placeholder, an id from some other service — addresses a path the
/// rules will refuse. Firestore reports that as `permission-denied`, several
/// layers away from the mistake and with no indication of which of the two
/// possible causes it was.
///
/// Checking here turns that into a sentence, at the point where the wrong uid
/// is still visible.
///
/// ## Why it tolerates having no Firebase app
///
/// [uid] returns null rather than throwing when `Firebase.initializeApp` has
/// not run. That state is real and reachable: a fresh clone with no `.env`, a
/// boot where initialisation failed, a unit test. Reaching for
/// `FirebaseAuth.instance` there throws a `core/no-app` error — and "there is
/// no Firebase app" is the same answer as "nobody is signed in" to every caller
/// of this class. This is the check requirement 12 asks for, made once instead
/// of at every call site.
class FirebaseSession {
  /// [currentUid] exists for tests, which have no Firebase app and no
  /// intention of starting one. Production passes nothing.
  const FirebaseSession({String? Function()? currentUid})
      : _override = currentUid;

  final String? Function()? _override;

  /// The signed-in Firebase UID, or null when nobody is signed in — or when
  /// this build has no Firebase app at all.
  String? get uid {
    final override = _override;
    if (override != null) return override();
    if (Firebase.apps.isEmpty) return null;
    return FirebaseAuth.instance.currentUser?.uid;
  }

  bool get isSignedIn => uid != null;

  /// Asserts that *somebody* is signed in, and returns their uid.
  ///
  /// The weaker of the two checks, and the right one for the shared catalogue.
  /// `/playlists` and `/catalog/songs` are readable by any signed-in account and
  /// owned by none, so there is no uid to compare against — the only question
  /// their rules ask is `request.auth != null`, and this asks exactly that and
  /// nothing more. Using [requireOwner] there would invent an ownership
  /// requirement the collection does not have.
  ///
  /// It is still a real check: the catalogue is not public. An unauthenticated
  /// read is refused by the rules, and this turns that refusal into a sentence
  /// before the round trip rather than after it.
  String requireSignedIn({required String whenSignedOut}) {
    final signedIn = uid;
    if (signedIn == null) throw NotSignedIn(whenSignedOut);
    return signedIn;
  }

  /// Asserts that [uid] is the account Firebase says is signed in, and returns
  /// it.
  ///
  /// The stronger check, for paths under `/users/{uid}` where the path itself
  /// is the ownership claim — and for the one field on a shared playlist that
  /// must match the writer, `importedByUserId`.
  ///
  /// [whenSignedOut] is the sentence the caller wants a signed-out user to
  /// read; the mismatch case has its own, because "sign in" is the wrong advice
  /// for someone who *is* signed in as somebody else.
  String requireOwner(String uid, {required String whenSignedOut}) {
    final signedIn = this.uid;
    if (signedIn == null) throw NotSignedIn(whenSignedOut);
    if (signedIn != uid) {
      // Reachable when a session changes under a screen that captured the old
      // uid — sign out on another device, a token revoked, a fast
      // sign-out/sign-in. Writing to the previous account's path would be
      // refused by the rules, which is correct; saying so is better than
      // letting it be refused.
      throw const NotSignedIn(
        'Your AURIX session changed. Sign in again and retry.',
      );
    }
    return signedIn;
  }
}
