import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/config/env.dart';
import '../../../core/providers/app_providers.dart';
import '../../../core/utils/app_logger.dart';
import '../../../data/models/aurix_user.dart';
import '../../../data/models/auth_challenge.dart';
import '../../../data/models/auth_method.dart';
import '../../../data/repositories/auth_repository.dart';
import '../../../data/services/api/api_auth_service.dart';

/// Owns the session for the whole app.
///
/// The router watches this to decide between splash, login and the shell, so
/// its state transitions are deliberately coarse: `unknown` until Firebase has
/// replayed its persisted session, then `signedIn` or `signedOut`. A
/// finer-grained state would make the router redirect mid-restore and flash the
/// login screen at users who are already signed in.
///
/// ## Session persistence
///
/// There is no restore call here. [AuthRepository.watchSession] follows
/// Firebase's own `authStateChanges`, which replays the persisted session on
/// launch — so "stay signed in across restarts" is the default behaviour rather
/// than something this class implements.
class AuthController extends Notifier<AuthState> {
  late final AuthRepository _repository;
  StreamSubscription<AuthState>? _session;
  StreamSubscription<AurixUser?>? _profile;

  @override
  AuthState build() {
    ref.onDispose(() {
      _session?.cancel();
      _profile?.cancel();
    });

    // Checked *before* the repository is read, not after.
    //
    // Reading it constructs `ApiAuthService`, which reaches for
    // `FirebaseAuth.instance` — and that throws when no Firebase app has been
    // initialised. Which is exactly the situation this branch exists to
    // handle: a build with no Firebase project configured. Getting the order
    // wrong turned "show the setup screen" into a crash on the first frame,
    // and made every widget test that touched auth need a Firebase mock.
    if (!Env.isApiConfigured) {
      return AuthState(
        status: AuthStatus.unconfigured,
        errorMessage: Env.apiConfigurationHint,
      );
    }

    _repository = ref.watch(authRepositoryProvider);

    _session = _repository.watchSession().listen(
      _onSession,
      onError: (Object error, StackTrace stackTrace) {
        AppLogger.error(
          'Session stream failed',
          scope: 'auth',
          error: error,
          stackTrace: stackTrace,
        );
        state = const AuthState(
          status: AuthStatus.signedOut,
          errorMessage: 'Could not reach Firebase. Check your connection.',
        );
      },
    );

    return AuthState.unknown;
  }

  /// Applies a session event, and re-points the profile subscription at
  /// whoever is now signed in.
  void _onSession(AuthState next) {
    final previousUid = state.uid;
    state = next;

    final uid = next.uid;
    if (uid == previousUid) return;

    _profile?.cancel();
    _profile = null;
    if (uid == null) return;

    // A pre-Firebase install has a cached library and an avatar choice sitting
    // in local storage under a Spotify account id. This is the one moment we
    // know which Firebase account they belong to.
    //
    // Fire-and-forget, and never awaited: the app must come up on this frame,
    // and a migration that takes two seconds behind the splash screen would be
    // a worse first launch than a library that fills in a moment later. It
    // deletes nothing and is idempotent, so a failure costs a retry on the
    // next launch. See [LocalDataMigration].
    unawaited(_migrateLocalData(uid));

    // Following the profile document — rather than reading it once at sign-in —
    // is what makes an avatar chosen on one device appear on another, and what
    // keeps the name in the home header correct after an edit without any
    // screen having to invalidate anything.
    _profile = _repository.watchProfile(uid).listen((profile) {
      if (profile == null) return;
      if (state.uid != profile.uid) return;
      state = state.copyWith(user: profile);
    });
  }

  Future<void> _migrateLocalData(String uid) async {
    final migration = ref.read(localDataMigrationProvider);
    if (migration.hasRun(uid)) return;
    await migration.run(uid);
  }

  Future<bool> register({
    required String email,
    required String password,
    required String name,
  }) async {
    if (!_ensureConfigured()) return false;

    state = state.copyWith(status: AuthStatus.unknown, clearError: true);
    final result = await _repository.register(
      email: email,
      password: password,
      name: name,
    );
    // On success the session stream is about to deliver the same state; setting
    // it here as well means the caller can navigate immediately rather than
    // waiting a frame for the stream to catch up.
    state = result;
    return result.isSignedIn;
  }

  Future<bool> signIn({required String email, required String password}) async {
    if (!_ensureConfigured()) return false;

    state = state.copyWith(status: AuthStatus.unknown, clearError: true);
    final result = await _repository.signIn(email: email, password: password);
    state = result;
    return result.isSignedIn;
  }

  // -------------------------------------------------------------------------
  // The other ways in
  // -------------------------------------------------------------------------

  /// Signs in with Google, Apple, Facebook or GitHub.
  ///
  /// Deliberately does **not** move the status to `unknown` the way [signIn]
  /// does. That transition sends the router to the splash screen, which is
  /// right for a form submission that resolves in a moment and wrong here: the
  /// browser is open on top of the app for as long as the user takes to
  /// consent, and tearing down the screen underneath it means they come back
  /// to a spinner with no idea what happened.
  Future<SignInAttempt> continueWith(AuthMethod provider) async {
    if (!_ensureConfigured()) return SignInAttempt.failed(Env.apiConfigurationHint);
    state = state.copyWith(clearError: true);

    try {
      final result = await _repository.signInWith(provider);

      final link = result.link;
      if (link != null) return SignInAttempt.linkRequired(link);

      final next = result.state!;
      state = next;
      if (next.isSignedIn) return const SignInAttempt.signedIn();
      return SignInAttempt.failed(
        next.errorMessage ?? 'That sign-in did not complete. Try again.',
      );
    } on AuthFailure catch (failure) {
      // Backing out of a consent screen is a decision, not a failure. It
      // leaves no message and no error state — the user is looking at the
      // login screen, which is where they chose to be.
      if (failure.kind == AuthFailureKind.cancelled) {
        return const SignInAttempt.cancelled();
      }
      state = state.copyWith(errorMessage: failure.message);
      return SignInAttempt.failed(failure.message);
    }
  }

  /// Sends a one-time code to [phone]. Throws [AuthFailure] on refusal.
  ///
  /// Throws rather than folding the failure into the state, because its caller
  /// is a sheet with its own fields: "that does not look like a phone number"
  /// belongs under the number, not in a snackbar over a screen the user is no
  /// longer looking at.
  Future<PhoneCodeRequest> sendPhoneCode(
    String phone, {
    bool linkToCurrentAccount = false,
  }) {
    _requireConfigured();
    return _repository.startPhoneSignIn(
      phone,
      linkToCurrentAccount: linkToCurrentAccount,
    );
  }

  /// Redeems a code and signs in. Returns whether it worked.
  Future<bool> verifyPhoneCode({
    required String phone,
    required String code,
    String? name,
  }) async {
    _requireConfigured();
    final next = await _repository.verifyPhoneCode(
      phone: phone,
      code: code,
      name: name,
    );
    state = next;
    return next.isSignedIn;
  }

  // ---- Joining an account a provider matched -----------------------------

  Future<LinkCodeSent> sendAccountLinkCode(String linkToken) {
    _requireConfigured();
    return _repository.sendAccountLinkCode(linkToken);
  }

  /// Proves ownership of the matched account and signs in as it.
  Future<bool> confirmAccountLink({
    required String linkToken,
    String? password,
    String? code,
  }) async {
    _requireConfigured();
    final next = await _repository.confirmAccountLink(
      linkToken: linkToken,
      password: password,
      code: code,
    );
    state = next;
    return next.isSignedIn;
  }

  Future<void> cancelAccountLink(String linkToken) async {
    if (!Env.isApiConfigured) return;
    await _repository.cancelAccountLink(linkToken);
  }

  // ---- Managing the methods on the account you are signed in to ----------

  /// Attaches a phone number to the current account.
  Future<void> linkPhone({required String phone, required String code}) async {
    _requireConfigured();
    state = state.copyWith(
      user: await _repository.linkPhone(phone: phone, code: code),
    );
  }

  /// Attaches a provider to the current account.
  Future<void> linkProvider(AuthMethod provider) async {
    _requireConfigured();
    state = state.copyWith(user: await _repository.linkProvider(provider));
  }

  /// Removes a way in. The API refuses to remove the last one.
  Future<void> unlinkMethod(AuthMethod method) async {
    _requireConfigured();
    state = state.copyWith(user: await _repository.unlink(method));
  }

  /// The guard for flows that report failure by throwing.
  void _requireConfigured() {
    if (Env.isApiConfigured) return;
    state = AuthState(
      status: AuthStatus.unconfigured,
      errorMessage: Env.apiConfigurationHint,
    );
    throw const AuthFailure(AuthFailureKind.notConfigured);
  }

  Future<void> signOut() async {
    await _repository.signOut();
    // The session stream will also report this; setting it here avoids a frame
    // where the shell is still mounted over a signed-out session.
    state = AuthState.signedOut;
  }

  /// Sends a reset email. Returns null on success, or a message to show.
  ///
  /// Deliberately does not reveal whether the address is registered — see
  /// [ApiAuthService.sendPasswordResetEmail].
  Future<String?> sendPasswordReset(String email) async {
    if (!_ensureConfigured()) return Env.apiConfigurationHint;
    try {
      await _repository.sendPasswordResetEmail(email);
      return null;
    } on AuthFailure catch (failure) {
      return failure.message;
    }
  }

  /// Returns null on success, or a message to show.
  Future<String?> changePassword({
    String? currentPassword,
    required String newPassword,
  }) async {
    try {
      await _repository.updatePassword(
        currentPassword: currentPassword,
        newPassword: newPassword,
      );
      return null;
    } on AuthFailure catch (failure) {
      return failure.message;
    }
  }

  Future<void> updateName(String name) async {
    final uid = state.uid;
    if (uid == null) return;
    await _repository.updateProfile(uid: uid, name: name);
  }

  Future<void> setAvatar(String avatarId) async {
    final uid = state.uid;
    if (uid == null) return;
    await _repository.setAvatar(uid: uid, avatarId: avatarId);
  }

  Future<void> refreshProfile() async {
    final uid = state.uid;
    if (uid == null) return;
    final profile = await _repository.refreshProfile(uid);
    if (profile == null) return;
    state = state.copyWith(user: profile);
  }

  void clearError() => state = state.copyWith(clearError: true);

  bool _ensureConfigured() {
    if (Env.isApiConfigured) return true;
    state = AuthState(
      status: AuthStatus.unconfigured,
      errorMessage: Env.apiConfigurationHint,
    );
    return false;
  }
}

/// What happened when the user tapped one of the provider buttons.
///
/// Four outcomes, and the reason they are four rather than a `bool` is that
/// three of them need different treatment on screen:
///
///  * [signedIn] — the router takes over; the caller does nothing.
///  * [linkRequired] — open the link sheet. Nothing failed.
///  * [cancelled] — say nothing at all. The user chose this.
///  * [failed] — show [message].
enum SignInOutcome { signedIn, linkRequired, cancelled, failed }

class SignInAttempt {
  const SignInAttempt.signedIn()
    : outcome = SignInOutcome.signedIn,
      link = null,
      message = null;

  const SignInAttempt.linkRequired(PendingAccountLink this.link)
    : outcome = SignInOutcome.linkRequired,
      message = null;

  const SignInAttempt.cancelled()
    : outcome = SignInOutcome.cancelled,
      link = null,
      message = null;

  const SignInAttempt.failed(String this.message)
    : outcome = SignInOutcome.failed,
      link = null;

  final SignInOutcome outcome;

  /// The challenge to put in front of the user. Non-null exactly when
  /// [outcome] is [SignInOutcome.linkRequired].
  final PendingAccountLink? link;

  /// What to say. Non-null exactly when [outcome] is [SignInOutcome.failed].
  final String? message;
}

final authControllerProvider = NotifierProvider<AuthController, AuthState>(
  AuthController.new,
);

/// Which sign-in methods this deployment offers.
///
/// Asked once, before the login screen draws its buttons, and cached for the
/// life of the app: the answer is a property of the *server's* configuration,
/// which does not change while the app is open.
///
/// A build with no API configured answers "email and password" without a
/// request. That is the one method needing nothing but the database, and
/// answering it lets the login screen render its form rather than an error —
/// the setup screen is what explains the real problem, and the router is
/// already on its way there.
final availableAuthMethodsProvider = FutureProvider<List<AuthMethod>>((ref) async {
  if (!Env.isApiConfigured) return const [AuthMethod.password];
  return ref.watch(authRepositoryProvider).availableMethods();
});

/// The subset of [AuthMethod.loginOrder] this deployment can actually serve.
///
/// Synchronous, and empty until the request lands — so the login screen draws
/// its email form immediately and the provider block fades in a
/// moment later, rather than the whole screen waiting on a round trip.
final loginMethodsProvider = Provider<List<AuthMethod>>((ref) {
  final available = ref.watch(availableAuthMethodsProvider).valueOrNull;
  if (available == null) return const [];
  return [
    for (final method in AuthMethod.loginOrder)
      if (available.contains(method)) method,
  ];
});

/// The signed-in user, or null.
final currentUserProvider = Provider<AurixUser?>(
  (ref) => ref.watch(authControllerProvider.select((s) => s.user)),
);

/// The Firebase UID of the signed-in user, or null.
///
/// Every Firestore path in AURIX is rooted at this. A provider that reads user
/// data must watch it and hold off while it is null, rather than defaulting to
/// a placeholder — there is no such thing as "the current user's data" before
/// there is a current user.
final currentUserIdProvider = Provider<String?>(
  (ref) => ref.watch(authControllerProvider.select((s) => s.uid)),
);

final isSignedInProvider = Provider<bool>(
  (ref) => ref.watch(authControllerProvider.select((s) => s.isSignedIn)),
);
