import 'package:aurix/data/models/aurix_user.dart';
import 'package:aurix/data/models/auth_challenge.dart';
import 'package:aurix/data/models/auth_method.dart';
import 'package:flutter_test/flutter_test.dart';

/// The client half of multi-method sign-in: how the wire is read.
///
/// Every case here is one where a wrong reading produces a *silent* mistake
/// rather than a visible one — a linked provider that does not appear in
/// Settings, a login screen offering a button the server cannot serve, an
/// account whose only sign-in method looks removable.
void main() {
  group('AuthMethod', () {
    test('the wire identifier is the contract, the label is not', () {
      // Renaming an `id` to suit the UI silently breaks linking: the server's
      // `identities` collection stores these strings.
      expect(AuthMethod.password.id, 'password');
      expect(AuthMethod.phone.id, 'phone');
      expect(AuthMethod.google.id, 'google');
      expect(AuthMethod.apple.id, 'apple');
      expect(AuthMethod.facebook.id, 'facebook');
      expect(AuthMethod.github.id, 'github');
    });

    test('renders the button copy the brief specifies', () {
      // Bare provider names, and no "Continue with" anywhere. Asserted as an
      // exact list rather than by pattern, because the whole point of the copy
      // is that it is these five strings.
      expect(
        AuthMethod.loginOrder.map((m) => m.buttonLabel).toList(),
        ['with Phone', 'Google', 'Apple', 'Facebook', 'GitHub'],
      );

      for (final method in AuthMethod.values) {
        expect(
          method.buttonLabel.contains('Continue with'),
          isFalse,
          reason: method.id,
        );
      }
    });

    test('a screen reader still hears a verb', () {
      // The visible label drops "Sign in with" because the mark beside it and
      // the "or" rule above it already establish what the row is. Someone
      // hearing "Google, button" in isolation has neither of those cues.
      expect(AuthMethod.google.signInSemanticLabel, 'Sign in with Google');
      expect(AuthMethod.phone.signInSemanticLabel, 'Sign in with Phone');
    });

    test('drops a provider this build has never heard of', () {
      // A server that grows a fifth provider must not crash an older app. The
      // unknown method is simply not offered.
      expect(
        AuthMethod.fromIds(['google', 'linkedin', 'password']),
        [AuthMethod.google, AuthMethod.password],
      );
      expect(AuthMethod.fromId('linkedin'), isNull);
      expect(AuthMethod.fromIds(null), isEmpty);
      expect(AuthMethod.fromIds('google'), isEmpty);
    });

    test('separates the browser flows from the in-app ones', () {
      expect(AuthMethod.google.isSocial, isTrue);
      expect(AuthMethod.github.isSocial, isTrue);
      expect(AuthMethod.phone.isSocial, isFalse);
      expect(AuthMethod.password.isSocial, isFalse);
    });
  });

  group('AurixUser', () {
    test('reads the linked methods the server reports', () {
      final user = AurixUser.fromDocument('u1', const {
        'name': 'Alex',
        'email': 'alex@example.com',
        'phone': '+447700900123',
        'phoneVerified': true,
        'providers': ['google', 'password', 'not-a-provider'],
      });

      expect(user.linkedMethods, [AuthMethod.google, AuthMethod.password]);
      expect(user.hasMethod(AuthMethod.google), isTrue);
      expect(user.hasMethod(AuthMethod.apple), isFalse);
      expect(user.phone, '+447700900123');
      expect(user.phoneVerified, isTrue);
    });

    test('an account with one way in is flagged as such', () {
      // What Settings consults before offering to unlink. The server refuses
      // the last method regardless, but a disabled control with a reason beats
      // a button that always fails.
      final only = AurixUser.fromDocument('u1', const {
        'providers': ['google'],
      });
      expect(only.hasSingleSignInMethod, isTrue);

      final both = AurixUser.fromDocument('u1', const {
        'providers': ['google', 'password'],
      });
      expect(both.hasSingleSignInMethod, isFalse);
    });

    test('survives the cached round trip the splash screen depends on', () {
      const original = AurixUser(
        uid: 'u1',
        name: 'Alex',
        email: 'alex@example.com',
        phone: '+447700900123',
        phoneVerified: true,
        emailVerified: true,
        linkedMethods: [AuthMethod.apple, AuthMethod.phone],
      );

      final restored = AurixUser.fromDocument('u1', original.toDocument());
      expect(restored, original);
    });

    test('names a phone-only account by its number, never by a relay address', () {
      const phoneOnly = AurixUser(uid: 'u1', name: '', email: '', phone: '+447700900123');
      expect(phoneOnly.displayName, 'AURIX 0123');

      // `k2j9x8w4` as a display name looks deliberate and is not — the generic
      // fallback is more honest than a machine-generated local part.
      const relay = AurixUser(
        uid: 'u2',
        name: '',
        email: 'k2j9x8w4@privaterelay.appleid.com',
        emailIsPrivateRelay: true,
      );
      expect(relay.displayName, 'AURIX listener');

      // An ordinary address is still a good fallback.
      const ordinary = AurixUser(uid: 'u3', name: '', email: 'alex@example.com');
      expect(ordinary.displayName, 'alex');
    });

    test('linking a provider makes the account compare as changed', () {
      // Without `linkedMethods` in `props`, Equatable would call these equal
      // and Riverpod would skip the rebuild that draws the new row.
      const before = AurixUser(uid: 'u1', name: 'Alex', email: 'a@b.com');
      final after = before.copyWith(linkedMethods: const [AuthMethod.google]);
      expect(after, isNot(before));
    });
  });

  group('the link challenge', () {
    test('reads a provider the app knows, and survives one it does not', () {
      final known = PendingAccountLink.fromJson(const {
        'linkToken': 'grant-abc',
        'provider': 'google',
        'providerLabel': 'Google',
        'email': 'al•••@example.com',
        'hasPassword': true,
        'methods': ['password'],
        'expiresInSeconds': 600,
      });
      expect(known.provider, AuthMethod.google);
      expect(known.hasPassword, isTrue);
      expect(known.existingMethods, [AuthMethod.password]);
      expect(known.expiresIn, const Duration(minutes: 10));

      final unknown = PendingAccountLink.fromJson(const {
        'linkToken': 'grant-abc',
        'provider': 'linkedin',
        'providerLabel': 'LinkedIn',
      });
      // The sheet still has something to name, which is what stops an unknown
      // provider turning a working challenge into a dead end.
      expect(unknown.provider, isNull);
      expect(unknown.providerLabel, 'LinkedIn');
      expect(unknown.hasPassword, isFalse);
    });
  });

  group('a code request', () {
    test('takes its countdown from the server, which is what enforces it', () {
      final request = PhoneCodeRequest.fromJson(const {
        'phone': '+44•••••123',
        'expiresInSeconds': 300,
        'resendInSeconds': 45,
      });
      expect(request.resendIn, const Duration(seconds: 45));
      expect(request.expiresIn, const Duration(minutes: 5));
    });

    test('has nowhere to put a code, even if a server sent one', () {
      // The API does not return the OTP. This asserts the second half of that
      // rule: were a server ever to include one — a rogue build, a proxy, a
      // future mistake — the model drops it on the floor rather than carrying
      // it into a log line, a widget's state or a crash report.
      final request = PhoneCodeRequest.fromJson(const {
        'phone': '+44•••••123',
        'devCode': '123456',
        'code': '123456',
        'otp': '123456',
      });

      final fields = request.toString();
      for (final surface in [fields, request.maskedPhone]) {
        expect(surface.contains('123456'), isFalse, reason: surface);
      }
    });

    test('falls back to sane durations when the server omits them', () {
      final request = PhoneCodeRequest.fromJson(const {});
      expect(request.expiresIn, const Duration(minutes: 5));
      expect(request.resendIn, const Duration(seconds: 30));
    });
  });
}
