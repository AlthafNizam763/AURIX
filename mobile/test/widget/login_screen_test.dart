import 'package:aurix/core/constants/app_constants.dart';
import 'package:aurix/features/auth/login_screen.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import '../support/harness.dart';

/// The sign-in screen: its layout, and what it does and does not say.
///
/// ## The layout half
///
/// The screen pushes its sign-in block to the bottom with a `Spacer` while
/// still scrolling when the content does not fit. That combination is easy to
/// get wrong: a `SingleChildScrollView` hands its child an unbounded height,
/// and `Spacer`/`Expanded` cannot lay out against infinity — the whole subtree
/// then fails its `hasSize` assertion and the screen renders nothing but a wall
/// of render-library exceptions. These pump at several viewport sizes and
/// assert that no exception escapes, which is exactly what that bug produced.
///
/// The form made this more delicate rather than less: there are now up to three
/// fields above the Spacer, and `AnimatedSize` around the name field changes the
/// content height at runtime.
///
/// ## The content half
///
/// These used to assert on the Premium caveat and the Spotify Developer Terms
/// link. Both are gone, and their replacements are the substance of the
/// refactor: this screen asks for an AURIX email and password and mentions
/// Spotify nowhere.
void main() {
  /// Switches to the registration form.
  ///
  /// Scrolls the control into view first: on a short viewport, or once
  /// validation messages have grown the form, the switch sits below the fold
  /// and a bare `tap` misses it.
  Future<void> switchToRegister(WidgetTester tester) async {
    // The button, not its label: `find.text` resolves to the RenderParagraph,
    // whose centre can sit outside the button's own hit box once the form has
    // grown, and the tap then lands on nothing.
    final target = find.widgetWithText(TextButton, 'Create an account');
    await tester.ensureVisible(target);
    await tester.pumpAndSettle();
    await tester.tap(target);
    await tester.pumpAndSettle();
  }

  /// Renders at a fixed logical size and returns any exception that escaped.
  Future<Object?> pumpAt(WidgetTester tester, Size size) async {
    tester.view.devicePixelRatio = 1.0;
    tester.view.physicalSize = size;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(
      wrapScreenForTest(const LoginScreen(), overrides: await baseOverrides()),
    );
    await tester.pumpAndSettle();

    return tester.takeException();
  }

  group('layout', () {
    testWidgets('lays out on a tall phone', (tester) async {
      expect(await pumpAt(tester, const Size(400, 900)), isNull);
      expect(find.text('Email'), findsOneWidget);
      expect(find.text('Password'), findsOneWidget);
    });

    testWidgets('lays out on a short screen without overflowing',
        (tester) async {
      // Short enough that the content cannot fit — the Spacer collapses and
      // the view scrolls instead.
      expect(await pumpAt(tester, const Size(360, 480)), isNull);
      expect(find.byType(SingleChildScrollView), findsOneWidget);
    });

    testWidgets('lays out in landscape', (tester) async {
      expect(await pumpAt(tester, const Size(800, 380)), isNull);
    });

    testWidgets('lays out on a tablet', (tester) async {
      expect(await pumpAt(tester, const Size(1024, 1366)), isNull);
    });

    testWidgets('lays out at an extreme aspect ratio', (tester) async {
      // Guards the `.clamp(0, infinity)` on minHeight: a viewport shorter than
      // the vertical padding would otherwise ask for a negative minHeight,
      // which is its own assertion failure.
      expect(await pumpAt(tester, const Size(320, 120)), isNull);
    });

    testWidgets('survives switching to registration, which adds a field',
        (tester) async {
      // The `AnimatedSize` around the name field changes the content height
      // while the Spacer is live — the exact combination the layout notes
      // above are about.
      await pumpAt(tester, const Size(360, 560));
      await switchToRegister(tester);

      expect(tester.takeException(), isNull);
      expect(find.text('Name'), findsOneWidget);
    });
  });

  group('content', () {
    testWidgets('asks for an AURIX account, not a Spotify one', (tester) async {
      await pumpAt(tester, const Size(400, 900));

      expect(find.text('Email'), findsOneWidget);
      expect(find.text('Password'), findsOneWidget);
      // The headline claim of the refactor: nothing on the sign-in path
      // touches Spotify, so nothing here names it.
      expect(find.textContaining('Spotify'), findsNothing);
    });

    testWidgets('offers a way to recover a forgotten password', (tester) async {
      await pumpAt(tester, const Size(400, 900));
      expect(find.text('Forgot password?'), findsOneWidget);
    });

    testWidgets('registration is one tap away and adds only a name',
        (tester) async {
      await pumpAt(tester, const Size(400, 900));

      expect(find.text('New to AURIX?'), findsOneWidget);
      await switchToRegister(tester);

      expect(find.text('Name'), findsOneWidget);
      expect(find.text('Already have an account?'), findsOneWidget);
    });

    testWidgets('states that the account is independent', (tester) async {
      await pumpAt(tester, const Size(400, 900));
      // Replaces the old "not affiliated with Spotify" disclaimer, which
      // belonged on a screen that ran a Spotify authorization. This one states
      // where the account lives.
      expect(find.textContaining('account is independent'), findsOneWidget);
    });
  });

  group('validation', () {
    testWidgets('refuses to submit an empty form', (tester) async {
      await pumpAt(tester, const Size(400, 900));

      await tester.tap(find.widgetWithText(FilledButton, 'Sign in'));
      await tester.pumpAndSettle();

      expect(find.text('Enter your email address.'), findsOneWidget);
      expect(find.text('Enter your password.'), findsOneWidget);
    });

    testWidgets('rejects something that is not an email address',
        (tester) async {
      await pumpAt(tester, const Size(400, 900));

      await tester.enterText(find.byType(TextFormField).first, 'not-an-email');
      await tester.tap(find.widgetWithText(FilledButton, 'Sign in'));
      await tester.pumpAndSettle();

      expect(
        find.text('That does not look like an email address.'),
        findsOneWidget,
      );
    });

    testWidgets('a short password is accepted for sign-in', (tester) async {
      // Deliberately permitted. An existing account may predate the six
      // character rule, and refusing to *submit* a correct password would lock
      // its owner out of their own library. Firebase is the authority on
      // whether it is right.
      await pumpAt(tester, const Size(400, 900));

      await tester.enterText(find.byType(TextFormField).first, 'a@b.com');
      await tester.enterText(find.byType(TextFormField).last, 'short');
      await tester.tap(find.widgetWithText(FilledButton, 'Sign in'));
      await tester.pumpAndSettle();

      expect(find.text(AppConstants.shortPasswordMessage), findsNothing);
    });

    testWidgets('a short password is rejected when registering',
        (tester) async {
      // Switched first, then filled in — the order a user takes, and the one
      // that keeps the mode control above the fold.
      await pumpAt(tester, const Size(400, 1000));
      await switchToRegister(tester);

      final fields = find.byType(TextFormField);
      await tester.enterText(fields.at(0), 'Test Listener');
      await tester.enterText(fields.at(1), 'a@b.com');
      await tester.enterText(fields.at(2), 'short');

      await tester.tap(find.widgetWithText(FilledButton, 'Create account'));
      await tester.pumpAndSettle();

      expect(find.text(AppConstants.shortPasswordMessage), findsOneWidget);
    });

    testWidgets('the password is obscured until the user asks otherwise',
        (tester) async {
      await pumpAt(tester, const Size(400, 900));

      TextField passwordField() =>
          tester.widgetList<TextField>(find.byType(TextField)).last;

      expect(passwordField().obscureText, isTrue);

      await tester.tap(find.byTooltip('Show password'));
      await tester.pumpAndSettle();

      expect(passwordField().obscureText, isFalse);
    });
  });

  testWidgets('the submit button is enabled and tappable', (tester) async {
    await pumpAt(tester, const Size(400, 900));

    final button = tester.widget<FilledButton>(
      find.widgetWithText(FilledButton, 'Sign in'),
    );
    expect(button.onPressed, isNotNull);
  });
}
