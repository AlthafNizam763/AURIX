import 'dart:async';

import 'package:firebase_auth/firebase_auth.dart';

import '../../../core/utils/app_logger.dart';

/// Why an authentication attempt failed, in terms the UI can act on.
///
/// Firebase reports failures as string codes on a [FirebaseAuthException]. They
/// are mapped to this enum rather than passed through, for two reasons: the raw
/// codes leak into UI code that then has to know Firebase's vocabulary, and
/// several distinct codes mean the same thing to a user.
enum AuthFailureKind {
  /// The email/password pair does not identify an account.
  ///
  /// Covers `user-not-found`, `wrong-password` and the newer
  /// `invalid-credential` that replaced both. Firebase collapsed them
  /// deliberately — telling an attacker which half was wrong is an account
  /// enumeration oracle — and AURIX must not undo that by reporting them
  /// separately.
  invalidCredentials,

  /// The address is already registered.
  emailAlreadyInUse,

  /// Not a valid email address.
  invalidEmail,

  /// The password does not meet Firebase's minimum strength.
  weakPassword,

  /// Disabled by an administrator.
  userDisabled,

  /// Too many attempts from this device. Firebase applies exponential backoff.
  tooManyRequests,

  /// The request could not reach Firebase.
  network,

  /// Email/password sign-in is switched off in the Firebase console. A
  /// configuration mistake rather than a user error, and worth its own case
  /// because the fix is in a different place entirely.
  operationNotAllowed,

  /// The session is too old for an operation Firebase considers sensitive —
  /// changing an email or deleting an account. Fixed by signing in again.
  requiresRecentLogin,

  /// Anything else.
  unknown;

  /// A sentence to put in front of the user.
  ///
  /// Written to say what to do next, not to restate the error. "Wrong password"
  /// tells someone nothing they had not worked out; naming the two things that
  /// could be wrong gives them somewhere to go.
  String get message {
    switch (this) {
      case AuthFailureKind.invalidCredentials:
        return 'That email and password do not match an AURIX account. '
            'Check both, or create an account if you have not yet.';
      case AuthFailureKind.emailAlreadyInUse:
        return 'An AURIX account already exists for that email. '
            'Sign in instead, or reset the password.';
      case AuthFailureKind.invalidEmail:
        return 'That does not look like an email address.';
      case AuthFailureKind.weakPassword:
        return 'Choose a longer password — at least six characters.';
      case AuthFailureKind.userDisabled:
        return 'This account has been disabled.';
      case AuthFailureKind.tooManyRequests:
        return 'Too many attempts. Wait a moment and try again.';
      case AuthFailureKind.network:
        return 'No connection. AURIX needs the network to sign in.';
      case AuthFailureKind.operationNotAllowed:
        return 'Email sign-in is not enabled for this AURIX project. '
            'Enable it in the Firebase console under Authentication → '
            'Sign-in method.';
      case AuthFailureKind.requiresRecentLogin:
        return 'For security, sign in again before making this change.';
      case AuthFailureKind.unknown:
        return 'Sign-in failed. Please try again.';
    }
  }
}

/// A failed authentication attempt.
class AuthFailure implements Exception {
  const AuthFailure(this.kind, {this.code, this.detail});

  final AuthFailureKind kind;

  /// Firebase's own code, kept for the log. Never shown to the user.
  final String? code;

  /// Firebase's own message, kept for the log.
  final String? detail;

  String get message => kind.message;

  factory AuthFailure.from(Object error) {
    if (error is AuthFailure) return error;
    if (error is! FirebaseAuthException) {
      return AuthFailure(AuthFailureKind.unknown, detail: error.toString());
    }

    final kind = switch (error.code) {
      'invalid-credential' ||
      'wrong-password' ||
      'user-not-found' ||
      'INVALID_LOGIN_CREDENTIALS' => AuthFailureKind.invalidCredentials,
      'email-already-in-use' => AuthFailureKind.emailAlreadyInUse,
      'invalid-email' => AuthFailureKind.invalidEmail,
      'weak-password' => AuthFailureKind.weakPassword,
      'user-disabled' => AuthFailureKind.userDisabled,
      'too-many-requests' => AuthFailureKind.tooManyRequests,
      'network-request-failed' => AuthFailureKind.network,
      'operation-not-allowed' => AuthFailureKind.operationNotAllowed,
      'requires-recent-login' => AuthFailureKind.requiresRecentLogin,
      _ => AuthFailureKind.unknown,
    };

    return AuthFailure(kind, code: error.code, detail: error.message);
  }

  @override
  String toString() => 'AuthFailure(${kind.name}${code == null ? '' : ', $code'})';
}

/// AURIX's front door to Firebase Authentication.
///
/// ## Session persistence
///
/// There is no "restore session" method here, and that absence is deliberate.
/// Firebase Auth persists the session itself — to the Keychain on Apple
/// platforms, to `SharedPreferences` on Android, to IndexedDB on web — and
/// replays it through [authStateChanges] on the first frame after launch. The
/// previous Spotify implementation had to read a refresh token out of secure
/// storage and exchange it before the app knew who the user was; this one just
/// listens.
///
/// That is why [authStateChanges] is the only source of truth for "who is
/// signed in" and why nothing in AURIX caches a uid alongside it.
///
/// ## What is not here
///
/// No token handling. Firebase attaches and refreshes the ID token on every
/// Firestore call inside the SDK, so AURIX has no bearer token to store, no
/// refresh flow to write, and no `AuthInterceptor` on the Firestore path.
class FirebaseAuthService {
  FirebaseAuthService({FirebaseAuth? auth})
      : _auth = auth ?? FirebaseAuth.instance;

  final FirebaseAuth _auth;

  /// Fires on launch, sign-in, sign-out and token refresh.
  ///
  /// Emits null when signed out. The first event may arrive a frame or two
  /// after startup while the SDK reads persisted state, which is exactly the
  /// window `AuthController` holds the splash screen for.
  Stream<User?> authStateChanges() => _auth.authStateChanges();

  /// Whoever is signed in right now, or null. Synchronous.
  User? get currentUser => _auth.currentUser;

  String? get currentUid => _auth.currentUser?.uid;

  /// Registers a new account.
  ///
  /// Sets the Firebase `displayName` as well as returning the credential,
  /// because two places end up needing the name and they should not disagree:
  /// the Auth record (which is what other Firebase products read) and the
  /// Firestore user document (which is what AURIX reads). The Firestore
  /// document is written by `FirestoreProfileService`, not here — this service
  /// deliberately knows nothing about the database.
  Future<User> register({
    required String email,
    required String password,
    required String name,
  }) async {
    try {
      final credential = await _auth.createUserWithEmailAndPassword(
        email: email.trim(),
        password: password,
      );
      final user = credential.user;
      if (user == null) {
        throw const AuthFailure(AuthFailureKind.unknown);
      }

      final trimmed = name.trim();
      if (trimmed.isNotEmpty) {
        await user.updateDisplayName(trimmed);
        // The in-memory `User` still holds the pre-update name until it is
        // reloaded, and the caller is about to write a Firestore document from
        // it. Reloading here means the two agree from the first write.
        await user.reload();
      }

      AppLogger.info('Registered ${user.uid}', scope: 'auth');
      return _auth.currentUser ?? user;
    } on Object catch (error) {
      throw _reported(error, 'register');
    }
  }

  Future<User> signIn({required String email, required String password}) async {
    try {
      final credential = await _auth.signInWithEmailAndPassword(
        email: email.trim(),
        password: password,
      );
      final user = credential.user;
      if (user == null) throw const AuthFailure(AuthFailureKind.unknown);
      AppLogger.info('Signed in ${user.uid}', scope: 'auth');
      return user;
    } on Object catch (error) {
      throw _reported(error, 'signIn');
    }
  }

  Future<void> signOut() async {
    final uid = currentUid;
    await _auth.signOut();
    AppLogger.info('Signed out ${uid ?? '(nobody)'}', scope: 'auth');
  }

  /// Sends a password-reset email.
  ///
  /// Note that this does **not** report whether an account exists for the
  /// address. Firebase can be configured to, and AURIX does not ask it to: a
  /// reset form that answers "no such account" is an account enumeration
  /// endpoint that needs no authentication at all. The UI says the mail has
  /// been sent if the address is valid, which is the honest thing it can say.
  Future<void> sendPasswordResetEmail(String email) async {
    try {
      await _auth.sendPasswordResetEmail(email: email.trim());
      AppLogger.info('Password reset requested', scope: 'auth');
    } on Object catch (error) {
      final failure = AuthFailure.from(error);
      // A `user-not-found` here would tell the caller the address is not
      // registered, which is the disclosure this method exists to avoid. It is
      // logged and swallowed; every other failure is real and is reported.
      if (failure.kind == AuthFailureKind.invalidCredentials) {
        AppLogger.info(
          'Password reset requested for an unregistered address',
          scope: 'auth',
        );
        return;
      }
      throw _reported(error, 'sendPasswordResetEmail');
    }
  }

  /// Changes the password of the signed-in account.
  ///
  /// Firebase requires a recent sign-in for this; an older session fails with
  /// [AuthFailureKind.requiresRecentLogin], which the UI turns into a prompt to
  /// sign in again rather than a dead end.
  Future<void> updatePassword(String newPassword) async {
    final user = _auth.currentUser;
    if (user == null) throw const AuthFailure(AuthFailureKind.invalidCredentials);
    try {
      await user.updatePassword(newPassword);
    } on Object catch (error) {
      throw _reported(error, 'updatePassword');
    }
  }

  /// Re-authenticates with the current password, for operations Firebase
  /// considers sensitive.
  Future<void> reauthenticate(String password) async {
    final user = _auth.currentUser;
    final email = user?.email;
    if (user == null || email == null) {
      throw const AuthFailure(AuthFailureKind.invalidCredentials);
    }
    try {
      await user.reauthenticateWithCredential(
        EmailAuthProvider.credential(email: email, password: password),
      );
    } on Object catch (error) {
      throw _reported(error, 'reauthenticate');
    }
  }

  Future<void> sendEmailVerification() async {
    final user = _auth.currentUser;
    if (user == null || user.emailVerified) return;
    try {
      await user.sendEmailVerification();
    } on Object catch (error) {
      throw _reported(error, 'sendEmailVerification');
    }
  }

  /// Re-reads the Auth record, e.g. after the user follows a verification link.
  Future<User?> reload() async {
    final user = _auth.currentUser;
    if (user == null) return null;
    await user.reload();
    return _auth.currentUser;
  }

  /// Updates the display name on the Auth record.
  Future<void> updateDisplayName(String name) async {
    final user = _auth.currentUser;
    if (user == null) return;
    try {
      await user.updateDisplayName(name.trim());
      await user.reload();
    } on Object catch (error) {
      throw _reported(error, 'updateDisplayName');
    }
  }

  /// Logs the underlying failure and returns the mapped one to throw.
  ///
  /// The log carries Firebase's code and message; the thrown value carries the
  /// sentence for the user. Keeping them apart is what stops a raw
  /// `[firebase_auth/invalid-credential]` string ending up in a snackbar.
  AuthFailure _reported(Object error, String operation) {
    final failure = AuthFailure.from(error);
    AppLogger.warn(
      'Auth $operation failed — ${failure.kind.name}'
      '${failure.code == null ? '' : ' (${failure.code})'}',
      scope: 'auth',
      error: failure.detail,
    );
    return failure;
  }
}
