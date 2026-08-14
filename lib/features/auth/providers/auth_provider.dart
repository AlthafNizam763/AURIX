import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/config/env.dart';
import '../../../core/providers/app_providers.dart';
import '../../../core/utils/app_logger.dart';
import '../../../data/models/user_profile.dart';
import '../../../data/repositories/auth_repository.dart';

/// Owns the session for the whole app.
///
/// The router watches this to decide between splash, login and the shell, so
/// its state transitions are deliberately coarse: `unknown` until restore
/// finishes, then `signedIn` or `signedOut`. A finer-grained state would make
/// the router redirect mid-restore and flash the login screen at users who are
/// already signed in.
class AuthController extends Notifier<AuthState> {
  late final AuthRepository _repository;
  Timer? _sessionWatch;

  @override
  AuthState build() {
    _repository = ref.watch(authRepositoryProvider);

    // The network layer signals an unrecoverable 401 by bumping this counter.
    ref.listen<int>(sessionExpiredProvider, (previous, next) {
      if (previous == null || next <= previous) return;
      AppLogger.info('Session expired signal received', scope: 'auth');
      unawaited(_onSessionExpired());
    });

    ref.onDispose(() => _sessionWatch?.cancel());

    if (!Env.isConfigured) {
      return AuthState(
        status: AuthStatus.unconfigured,
        errorMessage: Env.configurationHint,
      );
    }

    unawaited(_restore());
    return AuthState.unknown;
  }

  Future<void> _restore() async {
    final restored = await _repository.restore();
    state = restored;
  }

  /// Runs the interactive sign-in.
  Future<bool> signIn() async {
    if (!Env.isConfigured) {
      state = AuthState(
        status: AuthStatus.unconfigured,
        errorMessage: Env.configurationHint,
      );
      return false;
    }

    state = state.copyWith(status: AuthStatus.unknown, clearError: true);
    final result = await _repository.signIn();
    state = result;
    return result.isSignedIn;
  }

  Future<void> signOut() async {
    await _repository.signOut();
    state = AuthState.signedOut;
  }

  /// Re-checks whether Spotify now permits this account, after the user has
  /// changed something in the developer dashboard.
  ///
  /// Deliberately does not pass through [AuthStatus.unknown] on the way — that
  /// would bounce the router to the splash screen and back for a check that
  /// usually takes under a second.
  ///
  /// Returns true once access is granted.
  Future<bool> recheckAccess() async {
    final result = await _repository.restore();
    state = result;
    return result.isSignedIn;
  }

  Future<void> refreshProfile() async {
    final profile = await _repository.refreshProfile();
    if (profile == null) return;
    state = state.copyWith(profile: profile);
  }

  Future<void> _onSessionExpired() async {
    if (state.status == AuthStatus.signedOut) return;
    // Keep cached metadata: the user is very likely signing straight back in,
    // and wiping their library cache would make the return trip feel broken.
    await _repository.signOut(clearCache: false);
    state = const AuthState(
      status: AuthStatus.signedOut,
      errorMessage: 'Your Spotify session ended. Sign in again to continue.',
    );
  }

  void clearError() => state = state.copyWith(clearError: true);
}

final authControllerProvider = NotifierProvider<AuthController, AuthState>(
  AuthController.new,
);

/// The signed-in user, or null.
final currentUserProvider = Provider<UserProfile?>(
  (ref) => ref.watch(authControllerProvider.select((s) => s.profile)),
);

/// Spotify's reason for refusing this account, or null when it has not.
final accessDenialProvider = Provider<AccessDenial?>(
  (ref) => ref.watch(authControllerProvider.select((s) => s.denial)),
);

final currentUserIdProvider = Provider<String?>(
  (ref) => ref.watch(currentUserProvider)?.id,
);

/// True when Spotify Connect playback control is possible for this account.
final hasPremiumProvider = Provider<bool>(
  (ref) => ref.watch(authControllerProvider.select((s) => s.hasPremium)),
);

/// True only when Spotify has positively reported a non-Premium account.
///
/// Use this — not `!hasPremium` — to decide whether to tell the user Premium
/// is the obstacle. Development Mode apps no longer receive `product` on
/// `/me`, so `hasPremium` is false for Premium subscribers too, and gating a
/// "Premium required" message on it states the wrong cause with confidence
/// while suppressing the real one.
final knownNonPremiumProvider = Provider<bool>(
  (ref) => ref.watch(
    authControllerProvider.select((s) => s.profile?.knownNonPremium ?? false),
  ),
);

final isSignedInProvider = Provider<bool>(
  (ref) => ref.watch(authControllerProvider.select((s) => s.isSignedIn)),
);
