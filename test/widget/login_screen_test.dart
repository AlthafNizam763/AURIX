import 'package:aurix/features/auth/login_screen.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import '../support/harness.dart';

/// Layout regression tests for the sign-in screen.
///
/// The screen pushes its sign-in block to the bottom with a `Spacer` while
/// still scrolling when the content does not fit. That combination is easy to
/// get wrong: a `SingleChildScrollView` hands its child an unbounded height,
/// and `Spacer`/`Expanded` cannot lay out against infinity — the whole subtree
/// then fails its `hasSize` assertion and the screen renders nothing but a
/// wall of render-library exceptions.
///
/// These tests pump the screen at several viewport sizes and assert that no
/// exception escapes, which is exactly what the original bug produced.
void main() {
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

  testWidgets('lays out on a tall phone', (tester) async {
    expect(await pumpAt(tester, const Size(400, 900)), isNull);
    expect(find.text('Continue with Spotify'), findsOneWidget);
  });

  testWidgets('lays out on a short screen without overflowing', (tester) async {
    // Short enough that the content cannot fit — the Spacer collapses and the
    // view scrolls instead.
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

  testWidgets('states the Premium caveat before the user signs in',
      (tester) async {
    await pumpAt(tester, const Size(400, 900));

    // Discovering the Premium restriction after signing in is the most
    // frustrating way to learn it, so it is on the login screen.
    expect(find.textContaining('Premium only'), findsOneWidget);
    expect(find.textContaining('keychain'), findsOneWidget);
  });

  testWidgets('discloses that this is an independent client', (tester) async {
    await pumpAt(tester, const Size(400, 900));

    expect(find.textContaining('not affiliated'), findsOneWidget);
    expect(find.text('Spotify Developer Terms'), findsOneWidget);
  });

  testWidgets('the sign-in button is enabled and tappable', (tester) async {
    await pumpAt(tester, const Size(400, 900));

    final button = tester.widget<FilledButton>(find.byType(FilledButton));
    expect(button.onPressed, isNotNull);
  });
}
