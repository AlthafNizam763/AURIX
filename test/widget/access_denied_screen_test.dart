import 'package:aurix/data/repositories/auth_repository.dart';
import 'package:aurix/features/auth/access_denied_screen.dart';
import 'package:aurix/features/auth/providers/auth_provider.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import '../support/harness.dart';

/// The access-denied screen is the only place a user ever learns *why* Spotify
/// refused them, so what it prints is the whole point of it. These tests pin
/// the reporting, not the layout.
void main() {
  Future<void> pumpWith(WidgetTester tester, AccessDenial? denial) async {
    // The screen is a ListView, so anything below the fold is never built and
    // a finder would miss it. A tall surface renders the whole thing at once.
    tester.view.physicalSize = const Size(1000, 2600);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(
      wrapScreenForTest(
        const AccessDeniedScreen(),
        overrides: [accessDenialProvider.overrideWithValue(denial)],
      ),
    );
    await tester.pump();
  }

  testWidgets("reports Spotify's own message verbatim", (tester) async {
    await pumpWith(
      tester,
      const AccessDenial(
        cause: AccessDenialCause.userNotRegistered,
        statusCode: 403,
        endpoint: '/me',
        spotifyMessage: 'User not registered in the Developer Dashboard',
      ),
    );

    expect(
      find.text('User not registered in the Developer Dashboard'),
      findsOneWidget,
    );
    expect(find.text('403 Forbidden'), findsOneWidget);
    expect(find.text('/me'), findsOneWidget);
  });

  testWidgets('names the confirmed cause and rules the other one out', (tester) async {
    await pumpWith(
      tester,
      const AccessDenial(
        cause: AccessDenialCause.userNotRegistered,
        statusCode: 403,
        spotifyMessage: 'User not registered in the Developer Dashboard',
      ),
    );

    expect(find.text('Confirmed by Spotify'), findsOneWidget);
    expect(find.text('Ruled out'), findsOneWidget);
    // The guess-list wording must not survive alongside a confirmed cause.
    expect(find.text('Most likely'), findsNothing);
  });

  testWidgets('falls back to candidates when Spotify sent no reason', (tester) async {
    await pumpWith(
      tester,
      const AccessDenial(cause: AccessDenialCause.unspecified, statusCode: 403),
    );

    expect(find.text('(none — Spotify sent no reason)'), findsOneWidget);
    expect(find.text('Most likely'), findsOneWidget);
    expect(find.text('Confirmed by Spotify'), findsNothing);

    // The screen lists three candidate causes since the February 2026 Premium
    // requirement was added, so the last one starts below the fold in the
    // default test viewport. The list is lazy — which is what we want on a
    // real phone — so it has to be scrolled to before it exists.
    // The SelectableText rows in the "What Spotify returned" panel are
    // scrollables too, so the outer list has to be named explicitly.
    await tester.scrollUntilVisible(
      find.text('Also common'),
      300,
      scrollable: find.byType(Scrollable).first,
    );
    expect(find.text('Also common'), findsOneWidget);
  });

  testWidgets('a scope denial points at signing in again', (tester) async {
    await pumpWith(
      tester,
      const AccessDenial(
        cause: AccessDenialCause.insufficientScope,
        statusCode: 403,
        spotifyMessage: 'Insufficient client scope',
      ),
    );

    expect(
      find.textContaining('signing in again'),
      findsOneWidget,
      reason: 'this is the one 403 a fresh consent actually fixes',
    );
  });

  testWidgets('always names the Client ID that was refused', (tester) async {
    // Which dashboard app is refusing you is the question people get wrong
    // most often — it must be on screen even when nothing else is known.
    await pumpWith(tester, null);

    expect(find.text('Client ID'), findsOneWidget);
    expect(find.text('What Spotify returned'), findsOneWidget);
  });
}
