import 'dart:async';

import 'package:firebase_auth/firebase_auth.dart' show User;

import '../../core/utils/app_logger.dart';
import '../models/aurix_user.dart';
import '../services/firebase/firebase_auth_service.dart';
import '../services/firebase/firestore_profile_service.dart';

/// What the app knows about the current session.
enum AuthStatus {
  /// Firebase has not yet replayed its persisted session. The router holds the
  /// splash screen here rather than flashing the login screen at someone who is
  /// already signed in.
  unknown,

  /// No Firebase project is configured for this build. Nothing will work, so
  /// the router sends the developer to a screen that says what to add.
  unconfigured,

  signedOut,
  signedIn,
}

class AuthState {
  const AuthState({required this.status, this.user, this.errorMessage});

  final AuthStatus status;
  final AurixUser? user;

  /// Display-ready message from the last failed attempt.
  final String? errorMessage;

  static const AuthState unknown = AuthState(status: AuthStatus.unknown);
  static const AuthState signedOut = AuthState(status: AuthStatus.signedOut);

  bool get isSignedIn => status == AuthStatus.signedIn && user != null;

  /// The Firebase UID, or null. Every Firestore path in AURIX is built from
  /// this, so a null here means the app must not be reading user data at all.
  String? get uid => user?.uid;

  AuthState copyWith({
    AuthStatus? status,
    AurixUser? user,
    String? errorMessage,
    bool clearError = false,
  }) => AuthState(
    status: status ?? this.status,
    user: user ?? this.user,
    errorMessage: clearError ? null : (errorMessage ?? this.errorMessage),
  );
}

/// Coordinates Firebase Authentication and the Firestore profile behind it.
///
/// ## Why the two are handled together
///
/// Being signed in and having a profile are separate facts in Firebase — the
/// Auth record and the `/users/{uid}` document are written by different calls
/// and can disagree — but they are inseparable to the app: every screen that
/// renders a name or an avatar needs the document, and every Firestore read
/// needs the uid. Loading them independently produces a frame where the user is
/// signed in and the app has no idea who they are.
///
/// So [signIn] and [register] do not return until the profile document exists,
/// and [watchSession] emits a complete [AuthState] or none at all.
///
/// ## What replaced what
///
/// This class used to hold Spotify's PKCE flow, a token refresh, a market
/// derived from `profile.country`, and an `accessDenied` state for the case
/// where Spotify's developer dashboard refused an account. None of those
/// concepts survive: Firebase persists its own session, refreshes its own
/// tokens, and has no per-account allowlist to be refused by.
class AuthRepository {
  AuthRepository({
    required FirebaseAuthService authService,
    required FirestoreProfileService profileService,
  }) : _auth = authService,
       _profiles = profileService;

  final FirebaseAuthService _auth;
  final FirestoreProfileService _profiles;

  /// The session, as a stream.
  ///
  /// This is the app's single source of truth for identity. It follows
  /// Firebase's own `authStateChanges`, which fires on launch (after the
  /// persisted session is read), on sign-in, on sign-out and on token refresh —
  /// so a session that expires or is revoked on another device lands here
  /// without AURIX polling for it.
  ///
  /// Each signed-in event is resolved to a full [AuthState] by making sure the
  /// profile document exists first. A failure to do that is reported as
  /// signed-out rather than as a half-session: an app that cannot read the
  /// user's own document cannot show them their library either, and pretending
  /// otherwise produces empty screens with no explanation.
  Stream<AuthState> watchSession() async* {
    await for (final user in _auth.authStateChanges()) {
      if (user == null) {
        yield AuthState.signedOut;
        continue;
      }
      yield await _stateFor(user);
    }
  }

  /// Live profile updates for a signed-in user.
  ///
  /// Separate from [watchSession] because they change for different reasons and
  /// at different rates: the session changes on sign-in and sign-out, the
  /// profile changes every time the user picks an avatar. Folding them into one
  /// stream would rebuild the router's redirect on an avatar change.
  Stream<AurixUser?> watchProfile(String uid) => _profiles.watch(uid);

  Future<AuthState> register({
    required String email,
    required String password,
    required String name,
  }) async {
    try {
      final user = await _auth.register(
        email: email,
        password: password,
        name: name,
      );
      return await _stateFor(user, seedName: name);
    } on AuthFailure catch (failure) {
      return AuthState(
        status: AuthStatus.signedOut,
        errorMessage: failure.message,
      );
    }
  }

  Future<AuthState> signIn({
    required String email,
    required String password,
  }) async {
    try {
      final user = await _auth.signIn(email: email, password: password);
      return await _stateFor(user);
    } on AuthFailure catch (failure) {
      return AuthState(
        status: AuthStatus.signedOut,
        errorMessage: failure.message,
      );
    }
  }

  /// Signs out.
  ///
  /// Nothing derived from the account is wiped here, and that is a change from
  /// the Spotify implementation, which cleared the metadata cache on the way
  /// out so the next user could not see the previous one's library. It no
  /// longer has to: the library is in Firestore under a uid, and Firestore's
  /// own offline cache is keyed the same way, so signing in as someone else
  /// cannot surface the previous account's data.
  ///
  /// What *is* cleared is handled by the callers that own it — the playback
  /// queue by `PlayerController`, any live import session by
  /// `MusicImportController`.
  Future<void> signOut() => _auth.signOut();

  Future<void> sendPasswordResetEmail(String email) =>
      _auth.sendPasswordResetEmail(email);

  Future<void> updatePassword({
    required String currentPassword,
    required String newPassword,
  }) async {
    // Firebase would reject this on an old session with `requires-recent-login`
    // and no way for the user to act on it. Re-authenticating first turns that
    // into "your current password is wrong", which is a question they can
    // answer.
    await _auth.reauthenticate(currentPassword);
    await _auth.updatePassword(newPassword);
  }

  Future<void> updateProfile({
    required String uid,
    String? name,
    String? avatarId,
  }) async {
    await _profiles.update(uid, name: name, avatarId: avatarId);
    // Kept in step with the Firestore document so anything reading the Auth
    // record — a Cloud Function, a future provider link — sees the same name.
    if (name != null) await _auth.updateDisplayName(name);
  }

  Future<void> setAvatar({required String uid, required String avatarId}) =>
      _profiles.setAvatar(uid, avatarId);

  /// Re-reads the profile, for pull-to-refresh on the profile screen.
  Future<AurixUser?> refreshProfile(String uid) => _profiles.read(uid);

  /// Turns a Firebase user into a complete [AuthState].
  Future<AuthState> _stateFor(User user, {String? seedName}) async {
    try {
      final profile = await _profiles.ensureProfile(
        uid: user.uid,
        email: user.email ?? '',
        // Priority order: what registration was just told, then whatever the
        // Auth record carries, then the email's local part. Only used when the
        // document does not exist yet — see `ensureProfile`.
        name: seedName?.trim().isNotEmpty == true
            ? seedName!.trim()
            : (user.displayName ?? ''),
        emailVerified: user.emailVerified,
      );
      return AuthState(status: AuthStatus.signedIn, user: profile);
    } on Object catch (error, stackTrace) {
      AppLogger.error(
        'Signed in as ${user.uid} but the profile document could not be '
        'read or created. Check the Firestore security rules allow '
        'read/write on /users/{uid} for request.auth.uid == uid.',
        scope: 'auth',
        error: error,
        stackTrace: stackTrace,
      );
      return const AuthState(
        status: AuthStatus.signedOut,
        errorMessage:
            'Signed in, but your AURIX profile could not be loaded. '
            'Check your connection and try again.',
      );
    }
  }
}
