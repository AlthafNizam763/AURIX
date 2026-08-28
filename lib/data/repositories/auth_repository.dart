import 'dart:async';

import '../../core/utils/app_logger.dart';
import '../models/aurix_user.dart';
import '../models/auth_challenge.dart';
import '../models/auth_method.dart';
import '../services/api/api_auth_service.dart';
import '../services/api/api_profile_service.dart';

/// What the app knows about the current session.
enum AuthStatus {
  /// The persisted session has not been read back yet. The router holds the
  /// splash screen here rather than flashing the login screen at someone who is
  /// already signed in.
  unknown,

  /// No AURIX API is configured for this build. Nothing will work, so the
  /// router sends the developer to a screen that says what to add.
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
    required ApiAuthService authService,
    required ApiProfileService profileService,
  }) : _auth = authService,
       _profiles = profileService;

  final ApiAuthService _auth;
  final ApiProfileService _profiles;

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

  /// Confirms the session against the server and refreshes the profile.
  ///
  /// Called once after launch, behind the splash screen. The restored session
  /// is *believed* on the first frame — that is what stops the login screen
  /// flashing at a signed-in user — and this is what makes it true: a session
  /// revoked while the app was closed is discovered here and signs the user out
  /// a moment later, rather than failing the first library read with a 401.
  Future<void> confirmSession() async {
    if (_auth.currentUser == null) return;
    await _auth.reload();
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

  // -------------------------------------------------------------------------
  // The other ways in
  // -------------------------------------------------------------------------
  //
  // These differ from [signIn] and [register] in one respect worth naming:
  // they **throw** [AuthFailure] rather than folding it into a signed-out
  // [AuthState]. The two older methods answer a whole-screen form, where the
  // only sensible response to a failure is "stay here and show a message" —
  // which is exactly what a signed-out state with an `errorMessage` says.
  //
  // The new flows answer sheets with their own fields. "That code is not
  // correct" belongs under the code field, and the sheet has to stay open to
  // put it there. Returning a signed-out state would tell the router the user
  // had been signed out, which is both untrue and, mid-flow, disruptive.

  /// Which sign-in methods this deployment offers.
  Future<List<AuthMethod>> availableMethods() => _auth.availableMethods();

  /// Sends a one-time code to [phone].
  Future<PhoneCodeRequest> startPhoneSignIn(
    String phone, {
    bool linkToCurrentAccount = false,
  }) => _auth.startPhoneSignIn(phone, linkToCurrentAccount: linkToCurrentAccount);

  /// Redeems the code and resolves a full session, creating the account if the
  /// number is new.
  Future<AuthState> verifyPhoneCode({
    required String phone,
    required String code,
    String? name,
  }) async {
    final user = await _auth.verifyPhoneCode(phone: phone, code: code, name: name);
    return _stateFor(user, seedName: name);
  }

  /// Attaches a number to the account already signed in.
  Future<AurixUser> linkPhone({required String phone, required String code}) =>
      _auth.linkPhone(phone: phone, code: code);

  /// Runs a provider sign-in, and resolves the profile when it produces a
  /// session.
  ///
  /// Returns the [AuthResult] shape unchanged when a link is required, because
  /// there is no session to resolve a profile against yet — the caller has not
  /// proved anything about the account that was matched.
  Future<({AuthState? state, PendingAccountLink? link})> signInWith(
    AuthMethod provider,
  ) async {
    final result = await _auth.signInWith(provider);
    if (result.needsLink) return (state: null, link: result.link);
    return (state: await _stateFor(result.user!), link: null);
  }

  /// Sends the confirmation code for a pending account link.
  Future<LinkCodeSent> sendAccountLinkCode(String linkToken) =>
      _auth.sendAccountLinkCode(linkToken);

  /// Proves ownership of the matched account and joins the two.
  Future<AuthState> confirmAccountLink({
    required String linkToken,
    String? password,
    String? code,
  }) async {
    final user = await _auth.confirmAccountLink(
      linkToken: linkToken,
      password: password,
      code: code,
    );
    return _stateFor(user);
  }

  Future<void> cancelAccountLink(String linkToken) =>
      _auth.cancelAccountLink(linkToken);

  /// Adds a provider to the account already signed in.
  Future<AurixUser> linkProvider(AuthMethod provider) =>
      _auth.linkProvider(provider);

  /// Removes a way in. The API refuses to remove the last one.
  Future<AurixUser> unlink(AuthMethod method) => _auth.unlink(method);

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

  /// Changes the password.
  ///
  /// One call, where Firebase needed two — a re-authentication followed by an
  /// update, because it would otherwise reject the change on an old session
  /// with `requires-recent-login` and no way for the user to act on it. The API
  /// checks the current password and rotates the session in the same request,
  /// which removes both the extra round trip and the window in between.
  ///
  /// [currentPassword] is null only when the account has never had one — see
  /// [ApiAuthService.updatePassword], which is where the rule is enforced.
  Future<void> updatePassword({
    String? currentPassword,
    required String newPassword,
  }) => _auth.updatePassword(
    currentPassword: currentPassword,
    newPassword: newPassword,
  );

  Future<void> updateProfile({
    required String uid,
    String? name,
    String? avatarId,
  }) async {
    // One document holds the account and the profile, so there is no second
    // store to keep in step. The Firebase version had to mirror the name into
    // the Auth record as well, and the two could drift; that whole class of bug
    // went away with the split.
    await _profiles.update(uid, name: name, avatarId: avatarId);
  }

  Future<void> setAvatar({required String uid, required String avatarId}) =>
      _profiles.setAvatar(uid, avatarId);

  /// Re-reads the profile, for pull-to-refresh on the profile screen.
  Future<AurixUser?> refreshProfile(String uid) => _profiles.read(uid);

  /// Completes an [AurixUser] into a full [AuthState].
  ///
  /// Still calls `ensureProfile` even though the account and the profile are
  /// one document now, and it still earns its place: it is what fills in a
  /// field an older record predates, and it is the one call that runs on every
  /// sign-in regardless of how the session began.
  Future<AuthState> _stateFor(AurixUser user, {String? seedName}) async {
    try {
      final profile = await _profiles.ensureProfile(
        uid: user.uid,
        email: user.email,
        // Priority order: what registration was just told, then whatever the
        // account record carries. Only used when the field is *empty* — see
        // `ensureProfile`, which never overwrites a name the user has set.
        name: seedName?.trim().isNotEmpty == true ? seedName!.trim() : user.name,
        emailVerified: user.emailVerified,
      );
      return AuthState(status: AuthStatus.signedIn, user: profile);
    } on Object catch (error, stackTrace) {
      // Reachable when the API is unreachable on the frame after sign-in. The
      // session itself is intact and the tokens are stored; reporting
      // signed-out is still right, because an app that cannot read the user's
      // own account cannot show them their library either, and pretending
      // otherwise produces empty screens with no explanation.
      AppLogger.error(
        'Signed in as ${user.uid} but the profile could not be read. '
        'Check that the AURIX API is running and reachable at the configured '
        'AURIX_API_BASE_URL.',
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
