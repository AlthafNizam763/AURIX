import 'package:aurix/shared/widgets/controls/play_button.dart';
import 'package:aurix/shared/widgets/effects/reveal.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import '../support/harness.dart';

/// Regression cover for a disposal bug that only fired under "reduce motion".
///
/// Both widgets held their `AnimationController` in a lazy `late final`. With
/// animations disabled neither `initState` nor `build` ever touched it, so
/// `dispose()` became the first access — constructing a `Ticker` against an
/// element that had already been deactivated, which throws:
///
///     Looking up a deactivated widget's ancestor is unsafe.
///
/// It was invisible in normal use because every screen that carries these
/// widgets keeps them alive until the route goes away, and it never fired at
/// all with animations on. The fix is to build the controller in `initState`
/// unconditionally; these tests pin that down by mounting each widget with
/// animations off and then removing it.
void main() {
  group('disposal with animations disabled', () {
    testWidgets('SoftReveal unmounts cleanly', (tester) async {
      await tester.pumpWidget(
        wrapForTest(
          const SoftReveal(enabled: false, child: Text('AURIX')),
        ),
      );
      expect(find.text('AURIX'), findsOneWidget);

      // Replace the subtree so the widget is genuinely unmounted rather than
      // just rebuilt — the throw happened during `unmount`.
      await tester.pumpWidget(wrapForTest(const SizedBox.shrink()));
      await tester.pumpAndSettle();

      expect(tester.takeException(), isNull);
    });

    testWidgets('PlayButton unmounts cleanly', (tester) async {
      await tester.pumpWidget(
        wrapForTest(
          MediaQuery(
            // What `app.dart` sets when "reduce motion" is on.
            data: const MediaQueryData(disableAnimations: true),
            child: PlayButton(isPlaying: false, onPressed: () {}),
          ),
        ),
      );
      expect(find.byType(PlayButton), findsOneWidget);

      await tester.pumpWidget(wrapForTest(const SizedBox.shrink()));
      await tester.pumpAndSettle();

      expect(tester.takeException(), isNull);
    });

    testWidgets('PlayButton still fires its callback with motion disabled',
        (tester) async {
      // The burst is suppressed, but the button must still work — the failure
      // mode this guards against is "accessible setting makes the primary
      // action inert".
      var taps = 0;
      await tester.pumpWidget(
        wrapForTest(
          MediaQuery(
            data: const MediaQueryData(disableAnimations: true),
            child: PlayButton(isPlaying: false, onPressed: () => taps++),
          ),
        ),
      );

      await tester.tap(find.byType(PlayButton));
      await tester.pumpAndSettle();

      expect(taps, 1);
      expect(tester.takeException(), isNull);
    });
  });
}
