import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/config/env.dart';
import '../../../core/providers/app_providers.dart';
import '../../../core/utils/app_logger.dart';
import '../../../data/models/aurix_user.dart';
import '../../../data/repositories/auth_repository.dart';
import '../../../data/services/firebase/firebase_auth_service.dart';

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
    _repository = ref.watch(authRepositoryProvider);

    ref.onDispose(() {
      _session?.cancel();
      _profile?.cancel();
    });

    if (!Env.isFirebaseConfigured) {
      return AuthState(
        status: AuthStatus.unconfigured,
        errorMessage: Env.firebaseConfigurationHint,
      );
    }

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

  Future<void> signOut() async {
    await _repository.signOut();
    // The session stream will also report this; setting it here avoids a frame
    // where the shell is still mounted over a signed-out session.
    state = AuthState.signedOut;
  }

  /// Sends a reset email. Returns null on success, or a message to show.
  ///
  /// Deliberately does not reveal whether the address is registered — see
  /// [FirebaseAuthService.sendPasswordResetEmail].
  Future<String?> sendPasswordReset(String email) async {
    if (!_ensureConfigured()) return Env.firebaseConfigurationHint;
    try {
      await _repository.sendPasswordResetEmail(email);
      return null;
    } on AuthFailure catch (failure) {
      return failure.message;
    }
  }

  /// Returns null on success, or a message to show.
  Future<String?> changePassword({
    required String currentPassword,
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
    if (Env.isFirebaseConfigured) return true;
    state = AuthState(
      status: AuthStatus.unconfigured,
      errorMessage: Env.firebaseConfigurationHint,
    );
    return false;
  }
}

final authControllerProvider = NotifierProvider<AuthController, AuthState>(
  AuthController.new,
);

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
