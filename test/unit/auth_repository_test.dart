import 'package:aurix/core/network/api_exception.dart';
import 'package:aurix/core/storage/metadata_cache.dart';
import 'package:aurix/core/storage/preferences_store.dart';
import 'package:aurix/data/models/auth_session.dart';
import 'package:aurix/data/repositories/auth_repository.dart';
import 'package:aurix/data/services/spotify_api_service.dart';
import 'package:aurix/data/services/spotify_auth_service.dart';
import 'package:aurix/data/services/spotify_user_service.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../support/fixtures.dart';

class _MockAuthService extends Mock implements SpotifyAuthService {}

class _MockUserService extends Mock implements SpotifyUserService {}

void main() {
  late _MockAuthService auth;
  late _MockUserService users;
  late PreferencesStore prefs;
  late MetadataCache cache;
  late AuthRepository repository;

  final session = AuthSession(
    accessToken: 'token',
    expiresAt: DateTime.now().add(const Duration(hours: 1)),
    refreshToken: 'refresh',
  );

  setUp(() async {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    prefs = await PreferencesStore.open();
    cache = MetadataCache(prefs);

    auth = _MockAuthService();
    users = _MockUserService();

    when(auth.restoreSession).thenAnswer((_) async => session);
    when(auth.clearSession).thenAnswer((_) async {});

    repository = AuthRepository(
      authService: auth,
      userService: users,
      preferences: prefs,
      cache: cache,
    );

    SpotifyApiService.market = 'from_token';
  });

  group('restore', () {
    test('signs in and adopts the profile market', () async {
      when(() => users.me()).thenAnswer((_) async => Fixtures.user);

      final state = await repository.restore();

      expect(state.status, AuthStatus.signedIn);
      expect(state.profile?.id, 'user_1');
      expect(SpotifyApiService.market, 'GB');
    });

    test('signs out when there is no session', () async {
      when(auth.restoreSession).thenAnswer((_) async => null);

      final state = await repository.restore();

      expect(state.status, AuthStatus.signedOut);
    });

    test('a 403 on /me becomes accessDenied, not a healthy session', () async {
      // `/me` needs no scope and is never quota-restricted, so a 403 there
      // means Spotify is refusing the app for this account entirely. Reporting
      // this as signedIn would produce an app that greets the user and then
      // fails every single request with no explanation.
      when(() => users.me()).thenThrow(
        const ApiException(
          kind: ApiFailureKind.forbidden,
          message: 'Spotify would not allow that request for this account.',
          statusCode: 403,
        ),
      );

      final state = await repository.restore();

      expect(state.status, AuthStatus.accessDenied);
      expect(state.isAccessDenied, isTrue);
      expect(state.isSignedIn, isFalse);
      expect(state.session, isNotNull, reason: 'the token itself is still valid');
      expect(state.errorMessage, isNotNull);
    });

    test("the denial carries Spotify's own explanation", () async {
      // Without this the screen can only list candidate causes, which is what
      // made this failure so hard to diagnose in the first place.
      when(() => users.me()).thenThrow(
        const ApiException(
          kind: ApiFailureKind.forbidden,
          message: 'Spotify would not allow that request for this account.',
          statusCode: 403,
          endpoint: '/me',
          apiMessage: 'User not registered in the Developer Dashboard',
        ),
      );

      final state = await repository.restore();
      final denial = state.denial;

      expect(denial, isNotNull);
      expect(denial!.cause, AccessDenialCause.userNotRegistered);
      expect(denial.spotifyMessage, 'User not registered in the Developer Dashboard');
      expect(denial.statusCode, 403);
      expect(denial.endpoint, '/me');
      expect(denial.isFixableBySigningInAgain, isFalse);
      expect(denial.summary, contains('User not registered'));
    });

    test('a 403 with no message is reported as unspecified, not guessed at', () async {
      when(() => users.me()).thenThrow(
        const ApiException(
          kind: ApiFailureKind.forbidden,
          message: 'Forbidden',
          statusCode: 403,
        ),
      );

      final denial = (await repository.restore()).denial;

      expect(denial?.cause, AccessDenialCause.unspecified);
      expect(denial?.spotifyMessage, isNull);
      expect(denial?.isFixableBySigningInAgain, isFalse);
    });

    test('a scope 403 is still denied, but marked as re-signable', () async {
      // Re-consent genuinely fixes this one — but the gate must not open on
      // its own, or a misclassification would let an unauthorised account in.
      when(() => users.me()).thenThrow(
        const ApiException(
          kind: ApiFailureKind.forbidden,
          message: 'This app is missing a permission needed for that action.',
          statusCode: 403,
          apiMessage: 'Insufficient client scope',
        ),
      );

      final state = await repository.restore();

      expect(state.status, AuthStatus.accessDenied);
      expect(state.isSignedIn, isFalse);
      expect(state.denial?.cause, AccessDenialCause.insufficientScope);
      expect(state.denial?.isFixableBySigningInAgain, isTrue);
    });

    test('a healthy session carries no denial', () async {
      when(() => users.me()).thenAnswer((_) async => Fixtures.user);
      expect((await repository.restore()).denial, isNull);
    });

    test('a 403 does NOT fall back to a cached profile', () async {
      // The cache would make the app look fine while nothing works.
      await cache.writeObject(CacheKeys.userProfile, Fixtures.user.toJson());

      when(() => users.me()).thenThrow(
        const ApiException(
          kind: ApiFailureKind.forbidden,
          message: 'Forbidden',
          statusCode: 403,
        ),
      );

      final state = await repository.restore();

      expect(state.status, AuthStatus.accessDenied);
      expect(state.profile, isNull);
    });

    test('an offline failure DOES fall back to the cached profile', () async {
      // Offline is a transient, recoverable condition — unlike a 403 — so the
      // app stays usable in read-only form.
      await cache.writeObject(CacheKeys.userProfile, Fixtures.user.toJson());

      when(() => users.me()).thenThrow(
        const ApiException(
          kind: ApiFailureKind.offline,
          message: "Can't reach Spotify.",
        ),
      );

      final state = await repository.restore();

      expect(state.status, AuthStatus.signedIn);
      expect(state.profile?.id, 'user_1');
      expect(SpotifyApiService.market, 'GB');
    });

    test('a timeout with no cache still signs in, without a profile', () async {
      when(() => users.me()).thenThrow(
        const ApiException(kind: ApiFailureKind.timeout, message: 'Too slow.'),
      );

      final state = await repository.restore();

      expect(state.status, AuthStatus.signedIn);
      expect(state.profile, isNull);
    });
  });

  group('signIn', () {
    test('a cancelled sign-in reports signedOut with no error', () async {
      when(auth.login).thenThrow(const AuthCancelledException());

      final state = await repository.signIn();

      expect(state.status, AuthStatus.signedOut);
      expect(state.errorMessage, isNull);
    });

    test('a failed sign-in carries a display-ready message', () async {
      when(auth.login).thenThrow(
        const AuthFailedException('Check the redirect URI.', debugDetail: 'x'),
      );

      final state = await repository.signIn();

      expect(state.status, AuthStatus.signedOut);
      expect(state.errorMessage, 'Check the redirect URI.');
    });

    test('a fresh sign-in also detects access denial', () async {
      when(auth.login).thenAnswer((_) async => session);
      when(() => users.me()).thenThrow(
        const ApiException(
          kind: ApiFailureKind.forbidden,
          message: 'Forbidden',
          statusCode: 403,
        ),
      );

      final state = await repository.signIn();

      expect(state.status, AuthStatus.accessDenied);
    });
  });

  group('signOut', () {
    test('clears the session, cache and market', () async {
      await cache.writeObject(CacheKeys.userProfile, Fixtures.user.toJson());
      SpotifyApiService.market = 'GB';

      await repository.signOut();

      verify(auth.clearSession).called(1);
      expect(cache.readObject(CacheKeys.userProfile), isNull);
      expect(SpotifyApiService.market, 'from_token');
    });

    test('can keep the cache when the session merely expired', () async {
      await cache.writeObject(CacheKeys.userProfile, Fixtures.user.toJson());

      await repository.signOut(clearCache: false);

      expect(cache.readObject(CacheKeys.userProfile), isNotNull);
    });
  });

  group('refreshProfile', () {
    test('returns the profile on success', () async {
      when(() => users.me()).thenAnswer((_) async => Fixtures.user);
      expect((await repository.refreshProfile())?.id, 'user_1');
    });

    test('returns null when access is denied', () async {
      when(() => users.me()).thenThrow(
        const ApiException(
          kind: ApiFailureKind.forbidden,
          message: 'Forbidden',
          statusCode: 403,
        ),
      );
      expect(await repository.refreshProfile(), isNull);
    });
  });
}
