import 'package:aurix/data/models/auth_challenge.dart';
import 'package:aurix/data/models/auth_method.dart';
import 'package:aurix/features/auth/login_screen.dart';
import 'package:aurix/features/auth/providers/auth_provider.dart';
import 'package:aurix/features/auth/widgets/link_account_sheet.dart';
import 'package:aurix/features/auth/widgets/phone_sign_in_sheet.dart';
import 'package:aurix/features/auth/widgets/provider_mark.dart';
import 'package:aurix/features/auth/widgets/sign_in_method_button.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import '../support/harness.dart';

/// The multi-method sign-in surface.
///
/// ## What these are really guarding
///
/// Two things, and neither is cosmetic.
///
/// **That the screen offers only what the server can serve.** An "Apple"
/// button on a deployment with no Apple credentials sends the user to a
/// browser that comes back with an error from Apple. The list is therefore
/// driven by `GET /auth/methods` and nothing else, and the tests below assert
/// that an empty answer produces an empty list rather than a default set.
///
/// **That the layout still survives.** The login screen pushes its content to
/// the bottom with a `Spacer` inside a `SingleChildScrollView`, which is a
/// combination that fails loudly the moment the content grows — and five more
/// buttons is the largest growth it has ever had. `login_screen_test.dart`
/// explains that trap at length; these repeat the check with the buttons
/// present.
void main() {
  /// Overrides the deployment's method list with [methods].
  ///
  /// Overriding the provider rather than faking the HTTP call is deliberate:
  /// what the screen does with an answer is the thing under test, and going
  /// through Dio would make these tests about the API client instead.
  Override withMethods(List<AuthMethod> methods) =>
      availableAuthMethodsProvider.overrideWith((ref) async => methods);

  Future<Object?> pumpLogin(
    WidgetTester tester, {
    required List<AuthMethod> methods,
    Size size = const Size(400, 1000),
  }) async {
    tester.view.devicePixelRatio = 1.0;
    tester.view.physicalSize = size;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(
      wrapScreenForTest(
        const LoginScreen(),
        overrides: [...await baseOverrides(), withMethods(methods)],
      ),
    );
    await tester.pumpAndSettle();
    return tester.takeException();
  }

  group('what the login screen offers', () {
    testWidgets('draws every method the server reports, in the brief order',
        (tester) async {
      expect(
        await pumpLogin(tester, methods: AuthMethod.values),
        isNull,
      );

      for (final label in const [
        'with Phone',
        'Google',
        'Apple',
        'Facebook',
        'GitHub',
      ]) {
        expect(find.text(label), findsOneWidget, reason: label);
      }

      // The phrase is gone from the screen, not just from the model.
      expect(find.textContaining('Continue with'), findsNothing);
      // `password` is the form above, not a sixth button.
      expect(find.text('Email'), findsOneWidget); // the form's field label
      expect(find.byType(SignInMethodButton), findsNWidgets(5));
    });

    testWidgets('offers nothing extra when the server reports nothing extra',
        (tester) async {
      await pumpLogin(tester, methods: const [AuthMethod.password]);

      expect(find.byType(SignInMethodButton), findsNothing);
      // The screen is still a working login screen — that is the point of the
      // fallback. A deployment with no OAuth credentials loses buttons, not
      // the ability to sign in.
      expect(find.text('Email'), findsOneWidget);
      expect(find.text('Password'), findsOneWidget);
      expect(find.widgetWithText(FilledButton, 'Sign in'), findsOneWidget);
    });

    testWidgets('offers only the subset a partial deployment configured',
        (tester) async {
      await pumpLogin(
        tester,
        methods: const [AuthMethod.password, AuthMethod.phone, AuthMethod.github],
      );

      expect(find.text('with Phone'), findsOneWidget);
      expect(find.text('GitHub'), findsOneWidget);
      expect(find.text('Google'), findsNothing);
      expect(find.text('Apple'), findsNothing);
    });
  });

  group('the layout still holds with five more buttons', () {
    // A `Spacer` inside a `SingleChildScrollView` fails its `hasSize`
    // assertion rather than degrading, so "no exception escaped" is the whole
    // assertion here — see the notes in login_screen_test.dart.
    for (final size in const [
      Size(360, 480), // shorter than the content: the Spacer must collapse
      Size(320, 120), // guards the clamp on a negative minHeight
      Size(800, 380), // landscape
      Size(1024, 1366), // tablet
    ]) {
      testWidgets('lays out at ${size.width.toInt()}x${size.height.toInt()}',
          (tester) async {
        expect(
          await pumpLogin(tester, methods: AuthMethod.values, size: size),
          isNull,
        );
        expect(find.byType(SingleChildScrollView), findsOneWidget);
      });
    }
  });

  group('the phone sheet', () {
    testWidgets('asks for a number first and a code only after one is sent',
        (tester) async {
      await tester.pumpWidget(
        wrapScreenForTest(
          const Scaffold(body: PhoneSignInSheet()),
          overrides: await baseOverrides(),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.text('Sign in with your phone'), findsOneWidget);
      expect(find.text('Phone number'), findsOneWidget);
      // Nothing to type a code into until one has been sent — the second step
      // does not exist yet.
      expect(find.text('Code'), findsNothing);
      expect(find.widgetWithText(FilledButton, 'Send code'), findsOneWidget);
    });

    testWidgets('will not spend a text on something that is not a number',
        (tester) async {
      await tester.pumpWidget(
        wrapScreenForTest(
          const Scaffold(body: PhoneSignInSheet()),
          overrides: await baseOverrides(),
        ),
      );
      await tester.pumpAndSettle();

      await tester.tap(find.widgetWithText(FilledButton, 'Send code'));
      await tester.pumpAndSettle();
      expect(find.text('Enter your phone number.'), findsOneWidget);

      await tester.enterText(find.byType(TextFormField).first, '123');
      await tester.tap(find.widgetWithText(FilledButton, 'Send code'));
      await tester.pumpAndSettle();
      expect(find.text('That is too short to be a phone number.'), findsOneWidget);
    });
  });

  group('the account-link sheet', () {
    const challenge = PendingAccountLink(
      token: 'grant-abc',
      provider: AuthMethod.google,
      providerLabel: 'Google',
      maskedEmail: 'al•••@example.com',
      hasPassword: true,
      existingMethods: [AuthMethod.password],
      expiresIn: Duration(minutes: 10),
    );

    Future<void> pumpSheet(
      WidgetTester tester, {
      PendingAccountLink value = challenge,
    }) async {
      await tester.pumpWidget(
        wrapScreenForTest(
          Scaffold(body: LinkAccountSheet(challenge: value)),
          overrides: await baseOverrides(),
        ),
      );
      await tester.pumpAndSettle();
    }

    testWidgets('explains the match instead of reporting a failure',
        (tester) async {
      await pumpSheet(tester);

      // The wording matters as much as the flow: nothing failed, and telling
      // the user it did would send them to "try again", which produces the
      // identical challenge.
      expect(find.textContaining('already exists'), findsOneWidget);
      expect(find.textContaining('al•••@example.com'), findsOneWidget);
      expect(find.textContaining('instead of creating a second account'),
          findsOneWidget);
      expect(find.textContaining('failed'), findsNothing);
    });

    testWidgets('asks for the account password when the account has one',
        (tester) async {
      await pumpSheet(tester);

      expect(find.text('AURIX password'), findsOneWidget);
      expect(find.text('Confirmation code'), findsNothing);
      expect(find.widgetWithText(FilledButton, 'Link Google'), findsOneWidget);
      // The alternative proof is offered, not forced.
      expect(find.text('Email me a code instead'), findsOneWidget);
    });

    testWidgets('says how the matched account usually signs in', (tester) async {
      // Somebody who has forgotten they ever made an AURIX account will
      // remember how they made it, and being told is what keeps this from
      // reading like a phishing prompt.
      await pumpSheet(tester);
      expect(find.textContaining('signs in with Email'), findsOneWidget);
    });

    testWidgets('refuses to confirm with an empty proof', (tester) async {
      await pumpSheet(tester);

      await tester.tap(find.widgetWithText(FilledButton, 'Link Google'));
      await tester.pumpAndSettle();
      expect(find.text('Enter the account password.'), findsOneWidget);
    });

    testWidgets('offers a way out that is not the back gesture', (tester) async {
      // The sheet is deliberately not dismissible by a tap outside, so there
      // has to be an explicit refusal — and it tells the server, rather than
      // leaving a live challenge naming a stranger's account in the database.
      await pumpSheet(tester);
      expect(find.text('That is not my account'), findsOneWidget);
    });

    testWidgets('drops straight to the code for an account with no password',
        (tester) async {
      await pumpSheet(
        tester,
        value: const PendingAccountLink(
          token: 'grant-abc',
          provider: AuthMethod.apple,
          providerLabel: 'Apple',
          maskedEmail: 'al•••@example.com',
          hasPassword: false,
          existingMethods: [AuthMethod.google],
          expiresIn: Duration(minutes: 10),
        ),
      );

      expect(find.text('Confirmation code'), findsOneWidget);
      expect(find.text('AURIX password'), findsNothing);
      // Nothing to switch to, so the switch is not offered — a control that
      // led back to an empty field would be a dead end.
      expect(find.text('Use the account password instead'), findsNothing);
    });
  });

  group('the brand marks', () {
    testWidgets('every method draws at every size without failing',
        (tester) async {
      // The marks are constructed paths rather than assets, so a malformed one
      // is a paint-time exception rather than a missing file. Two sizes,
      // because `Path.combine` on a degenerate scale is the way that breaks.
      for (final size in const [16.0, 22.0, 48.0]) {
        await tester.pumpWidget(
          wrapScreenForTest(
            Scaffold(
              body: Center(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    for (final method in AuthMethod.values)
                      ProviderMark(method, size: size),
                  ],
                ),
              ),
            ),
            overrides: await baseOverrides(),
          ),
        );
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull, reason: 'at $size');
        expect(
          find.byType(ProviderMark),
          findsNWidgets(AuthMethod.values.length),
        );
      }
    });
  });
}

