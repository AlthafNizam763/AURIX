import 'package:aurix/core/providers/app_providers.dart';
import 'package:aurix/core/storage/preferences_store.dart';
import 'package:aurix/features/onboarding/onboarding_screen.dart';
import 'package:aurix/features/onboarding/providers/onboarding_provider.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import '../support/harness.dart';

void main() {
  group('OnboardingScreen', () {
    testWidgets('opens on the first slide with a way to skip', (tester) async {
      await tester.pumpWidget(
        wrapScreenForTest(
          const OnboardingScreen(),
          overrides: await baseOverrides(),
        ),
      );

      expect(find.text('WELCOME TO AURIX'), findsOneWidget);
      expect(find.text('NEXT'), findsOneWidget);
      expect(find.text('Skip'), findsOneWidget);
      // The final call to action must not be offered before the final slide.
      expect(find.text('START LISTENING'), findsNothing);
    });

    testWidgets('advances through every slide to the call to action',
        (tester) async {
      await tester.pumpWidget(
        wrapScreenForTest(
          const OnboardingScreen(),
          overrides: await baseOverrides(),
        ),
      );

      for (final overline in <String>[
        'DISCOVER YOUR SOUND',
        'BUILD YOUR UNIVERSE',
        'ENTER THE SOUNDVERSE',
      ]) {
        await tester.tap(find.text('NEXT'));
        await tester.pumpAndSettle();
        expect(find.text(overline), findsOneWidget);
      }

      // On the last slide the button becomes the CTA and Skip goes away —
      // skipping and finishing are the same action there, and offering both
      // would suggest they differ.
      expect(find.text('START LISTENING'), findsOneWidget);
      expect(find.text('NEXT'), findsNothing);
    });

    testWidgets('finishing marks onboarding complete and persists it',
        (tester) async {
      final overrides = await baseOverrides();
      final container = ProviderContainer(overrides: overrides);
      addTearDown(container.dispose);

      expect(container.read(onboardingCompleteProvider), isFalse);

      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: container,
          child: const MaterialApp(home: OnboardingScreen()),
        ),
      );

      for (var i = 0; i < 3; i++) {
        await tester.tap(find.text('NEXT'));
        await tester.pumpAndSettle();
      }
      await tester.tap(find.text('START LISTENING'));
      await tester.pumpAndSettle();

      expect(container.read(onboardingCompleteProvider), isTrue);
      expect(
        container
            .read(preferencesStoreProvider)
            .getBool(PrefKeys.onboardingComplete),
        isTrue,
        reason: 'a relaunch must not replay the intro',
      );
    });

    testWidgets('skipping also completes it', (tester) async {
      final overrides = await baseOverrides();
      final container = ProviderContainer(overrides: overrides);
      addTearDown(container.dispose);

      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: container,
          child: const MaterialApp(home: OnboardingScreen()),
        ),
      );

      await tester.tap(find.text('Skip'));
      await tester.pumpAndSettle();

      expect(container.read(onboardingCompleteProvider), isTrue);
    });

    testWidgets('still advances with animations disabled', (tester) async {
      // Under "reduce motion" the PageView is jumped rather than animated. If
      // that path were wrong the intro would become a dead end for exactly the
      // users least able to work around it.
      await tester.pumpWidget(
        wrapScreenForTest(
          const OnboardingScreen(),
          overrides: await baseOverrides(
            initialPreferences: {PrefKeys.reduceMotion: true},
          ),
        ),
      );

      await tester.tap(find.text('NEXT'));
      await tester.pumpAndSettle();

      expect(find.text('DISCOVER YOUR SOUND'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });
  });

  group('OnboardingController', () {
    test('an absent flag means "not seen"', () async {
      final container = ProviderContainer(overrides: await baseOverrides());
      addTearDown(container.dispose);

      expect(container.read(onboardingCompleteProvider), isFalse);
    });

    test('a stored true is honoured on a cold start', () async {
      final container = ProviderContainer(
        overrides: await baseOverrides(
          initialPreferences: {PrefKeys.onboardingComplete: true},
        ),
      );
      addTearDown(container.dispose);

      expect(container.read(onboardingCompleteProvider), isTrue);
    });

    test('replay puts the intro back', () async {
      final container = ProviderContainer(
        overrides: await baseOverrides(
          initialPreferences: {PrefKeys.onboardingComplete: true},
        ),
      );
      addTearDown(container.dispose);

      await container.read(onboardingCompleteProvider.notifier).replay();
      expect(container.read(onboardingCompleteProvider), isFalse);
    });
  });
}
