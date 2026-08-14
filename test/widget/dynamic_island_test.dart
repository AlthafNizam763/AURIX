import 'package:aurix/core/providers/app_providers.dart';
import 'package:aurix/core/router/app_router.dart';
import 'package:aurix/core/storage/preferences_store.dart';
import 'package:aurix/core/theme/app_dimens.dart';
import 'package:aurix/core/theme/app_theme.dart';
import 'package:aurix/features/auth/providers/auth_provider.dart';
import 'package:aurix/features/dynamic_island/dynamic_island.dart';
import 'package:aurix/features/dynamic_island/providers/dynamic_island_provider.dart';
import 'package:aurix/features/settings/providers/settings_provider.dart';
import 'package:aurix/playback/playback_mode.dart';
import 'package:aurix/playback/playback_queue.dart';
import 'package:aurix/playback/player_controller.dart';
import 'package:aurix/shared/widgets/controls/aurix_switch.dart';
import 'package:aurix/shared/widgets/controls/music_progress_bar.dart';
import 'package:aurix/shared/widgets/icons/aurix_glyphs.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import '../support/fixtures.dart';
import '../support/harness.dart';

/// Drives the island from a fixed state, so the widget can be verified without
/// an audio engine, a network or a Spotify device.
class _StubPlayerController extends PlayerController {
  _StubPlayerController(this.initial);

  final AurixPlaybackState initial;
  int toggles = 0;
  int skips = 0;
  int rewinds = 0;

  @override
  AurixPlaybackState build() => initial;

  @override
  Future<void> togglePlayPause() async {
    toggles++;
    state = state.copyWith(isPlaying: !state.isPlaying);
  }

  @override
  Future<void> next({bool manual = true}) async => skips++;

  @override
  Future<void> previous() async => rewinds++;
}

AurixPlaybackState _playing({
  int trackCount = 3,
  bool isPlaying = true,
  PlaybackMode mode = PlaybackMode.preview,
}) {
  return AurixPlaybackState(
    queue: PlaybackQueue.from(
      Fixtures.tracks(trackCount),
      context: const PlaybackContext(title: 'Parallel Skies'),
    ),
    mode: mode,
    isPlaying: isPlaying,
    position: const Duration(seconds: 12),
    duration: const Duration(seconds: 30),
  );
}

/// Mounts a widget exactly where the island really lives: above the router's
/// `Navigator`, inside `MaterialApp`'s builder.
///
/// This is the point of the helper. Up there is no `Material` and no `Overlay`,
/// so anything reaching for an ink splash or a tooltip throws — and it throws
/// here rather than on a user's phone.
Widget wrapAboveNavigator(
  Widget child, {
  List<Override> overrides = const [],
  VoidCallback? onBackgroundTap,
}) {
  return ProviderScope(
    overrides: overrides,
    child: MaterialApp(
      theme: AppTheme.dark(),
      debugShowCheckedModeBanner: false,
      home: Scaffold(
        body: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: onBackgroundTap,
          child: const SizedBox.expand(),
        ),
      ),
      builder: (context, navigator) => Stack(
        children: <Widget>[
          navigator!,
          Positioned(
            top: 0,
            left: 0,
            right: 0,
            child: Align(alignment: Alignment.topCenter, child: child),
          ),
        ],
      ),
    ),
  );
}

void main() {
  Future<List<Override>> withState(AurixPlaybackState state) async {
    final base = await baseOverrides();
    return [
      ...base,
      playerControllerProvider.overrideWith(() => _StubPlayerController(state)),
    ];
  }

  /// A phone-shaped viewport, so the pill's fixed boxes are not clamped by the
  /// default 800×600 test surface and the numbers below mean something.
  void usePhoneViewport(WidgetTester tester) {
    tester.view.physicalSize = const Size(400, 844);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
  }

  /// Advances past an animation without `pumpAndSettle`, which would time out:
  /// the island's ambient clock repeats for as long as it is on screen.
  Future<void> advance(WidgetTester tester, Duration duration) async {
    for (var elapsed = Duration.zero; elapsed < duration;) {
      const step = Duration(milliseconds: 50);
      await tester.pump(step);
      elapsed += step;
    }
  }

  /// Mounts and then waits out the entrance.
  ///
  /// The island glitches its title when it appears, and a glitch draws the
  /// child once per colour channel — so asserting on the title before the burst
  /// finishes finds three of everything.
  Future<void> settle(WidgetTester tester) =>
      advance(tester, const Duration(milliseconds: 400));

  group('DynamicIslandPill', () {
    testWidgets('renders above the Navigator, with no Material to lean on',
        (tester) async {
      usePhoneViewport(tester);
      await tester.pumpWidget(
        wrapAboveNavigator(
          const DynamicIslandPill(),
          overrides: await withState(_playing()),
        ),
      );
      await settle(tester);

      // An `IconButton` or a `Tooltip` in the island would have thrown by now.
      expect(tester.takeException(), isNull);
      expect(find.text('Track 0'), findsOneWidget);

      await tester.pumpWidget(const SizedBox.shrink());
    });

    testWidgets('its labels are not rendered with the unstyled-text warning',
        (tester) async {
      // Above the Navigator there is no inherited `DefaultTextStyle`, so text
      // picks up Flutter's yellow double underline. Setting an explicit style
      // does not clear it — `TextStyle.merge` keeps a `decoration` that came
      // from the ambient style — so this survives looking correct in code and
      // only shows up on a running device.
      usePhoneViewport(tester);
      await tester.pumpWidget(
        wrapAboveNavigator(
          const DynamicIslandSlot(visible: true),
          overrides: await withState(_playing()),
        ),
      );
      await settle(tester);

      final title = find.text('Track 0');
      final resolved = DefaultTextStyle.of(tester.element(title))
          .style
          .merge(tester.widget<Text>(title).style);

      expect(resolved.decoration, anyOf(isNull, TextDecoration.none));

      await tester.pumpWidget(const SizedBox.shrink());
    });

    testWidgets('collapsed, it shows the title, the equaliser and one control',
        (tester) async {
      usePhoneViewport(tester);
      await tester.pumpWidget(
        wrapAboveNavigator(
          const DynamicIslandPill(),
          overrides: await withState(_playing()),
        ),
      );
      await settle(tester);

      expect(find.text('Track 0'), findsOneWidget);
      // The artist belongs to the expanded card only.
      expect(find.text('Neon Meridian'), findsNothing);
      expect(findGlyph(AurixGlyph.pause), findsOneWidget);
      // Skip controls are part of the transport row, which is not built yet.
      expect(findGlyph(AurixGlyph.skipNext), findsNothing);
      expect(findGlyph(AurixGlyph.skipPrevious), findsNothing);

      expect(
        tester.getSize(find.byType(DynamicIslandPill)),
        const Size(
          AppSizes.islandCollapsedWidth,
          AppSizes.islandCollapsedHeight,
        ),
      );

      await tester.pumpWidget(const SizedBox.shrink());
    });

    testWidgets('a tap expands it into the full transport, a second collapses it',
        (tester) async {
      usePhoneViewport(tester);
      await tester.pumpWidget(
        wrapAboveNavigator(
          const DynamicIslandPill(),
          overrides: await withState(_playing()),
        ),
      );
      await settle(tester);

      await tester.tap(find.byType(DynamicIslandPill));
      await advance(tester, const Duration(milliseconds: 600));

      final expanded = tester.getSize(find.byType(DynamicIslandPill));
      expect(expanded.height, AppSizes.islandExpandedHeight);
      expect(expanded.width, greaterThan(AppSizes.islandCollapsedWidth));

      expect(find.text('Neon Meridian'), findsOneWidget);
      expect(findGlyph(AurixGlyph.skipPrevious), findsOneWidget);
      expect(findGlyph(AurixGlyph.skipNext), findsOneWidget);
      // Exactly one play control, not the inline one plus the transport one.
      expect(findGlyph(AurixGlyph.pause), findsOneWidget);

      await tester.tap(find.byType(DynamicIslandPill));
      await advance(tester, const Duration(milliseconds: 600));

      expect(
        tester.getSize(find.byType(DynamicIslandPill)),
        const Size(
          AppSizes.islandCollapsedWidth,
          AppSizes.islandCollapsedHeight,
        ),
      );
      expect(findGlyph(AurixGlyph.skipNext), findsNothing);

      await tester.pumpWidget(const SizedBox.shrink());
    });

    testWidgets('shows how far through the track it is, once expanded',
        (tester) async {
      // Progress is the one thing on the island that moves with the timeline,
      // and it is deliberately absent while collapsed: a 46px pill has nowhere
      // to put it, and mounting it there would subscribe the island to the
      // position for a line nobody can see.
      usePhoneViewport(tester);
      await tester.pumpWidget(
        wrapAboveNavigator(
          const DynamicIslandPill(),
          // 12 seconds into a 30-second preview.
          overrides: await withState(_playing()),
        ),
      );
      await settle(tester);

      expect(find.byType(HairlineProgress), findsNothing);

      await tester.tap(find.byType(DynamicIslandPill));
      await advance(tester, const Duration(milliseconds: 600));

      final bar = tester.widget<HairlineProgress>(
        find.byType(HairlineProgress),
      );
      expect(bar.progress, closeTo(12 / 30, 0.001));

      // And it goes away again with the controls it sits above.
      await tester.tap(find.byType(DynamicIslandPill));
      await advance(tester, const Duration(milliseconds: 600));
      expect(find.byType(HairlineProgress), findsNothing);

      await tester.pumpWidget(const SizedBox.shrink());
    });

    testWidgets('reversing part-way through the morph is continuous',
        (tester) async {
      // A direction-dependent easing curve is the obvious way to write this
      // animation and is discontinuous at exactly this moment: the two curves
      // are ~75 points apart at their midpoint, so a second tap would snap the
      // pill most of the way shut before starting to animate.
      usePhoneViewport(tester);
      await tester.pumpWidget(
        wrapAboveNavigator(
          const DynamicIslandPill(),
          overrides: await withState(_playing()),
        ),
      );
      await settle(tester);

      await tester.tap(find.byType(DynamicIslandPill));
      // The first pump only starts the ticker — it reports zero elapsed time,
      // so the animation has not moved yet.
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 210));

      final midway = tester.getSize(find.byType(DynamicIslandPill)).width;
      expect(midway, greaterThan(AppSizes.islandCollapsedWidth + 40));

      await tester.tap(find.byType(DynamicIslandPill));
      await tester.pump(const Duration(milliseconds: 16));

      // One frame of travel, not a leap back toward the collapsed width.
      expect((midway - tester.getSize(find.byType(DynamicIslandPill)).width).abs(),
          lessThan(20));

      await tester.pumpWidget(const SizedBox.shrink());
    });

    testWidgets('folds itself away after a spell with no interaction',
        (tester) async {
      usePhoneViewport(tester);
      await tester.pumpWidget(
        wrapAboveNavigator(
          const DynamicIslandPill(),
          overrides: await withState(_playing()),
        ),
      );
      await settle(tester);

      await tester.tap(find.byType(DynamicIslandPill));
      await advance(tester, const Duration(milliseconds: 600));
      expect(findGlyph(AurixGlyph.skipNext), findsOneWidget);

      await advance(tester, const Duration(seconds: 5));

      expect(findGlyph(AurixGlyph.skipNext), findsNothing);
      expect(
        tester.getSize(find.byType(DynamicIslandPill)).height,
        AppSizes.islandCollapsedHeight,
      );

      await tester.pumpWidget(const SizedBox.shrink());
    });

    testWidgets('using a control buys the island more time', (tester) async {
      usePhoneViewport(tester);
      await tester.pumpWidget(
        wrapAboveNavigator(
          const DynamicIslandPill(),
          overrides: await withState(_playing()),
        ),
      );
      await settle(tester);

      await tester.tap(find.byType(DynamicIslandPill));
      await advance(tester, const Duration(milliseconds: 600));

      // Three seconds in — inside the four-second window — press a control.
      await advance(tester, const Duration(seconds: 3));
      await tester.tap(findGlyph(AurixGlyph.pause));
      await advance(tester, const Duration(milliseconds: 200));

      // Three more seconds. Without the reset the island would already have
      // folded up under the finger that was using it.
      await advance(tester, const Duration(seconds: 3));
      expect(findGlyph(AurixGlyph.skipNext), findsOneWidget);

      await tester.pumpWidget(const SizedBox.shrink());
    });

    testWidgets('play/pause goes through the player controller', (tester) async {
      final overrides = await withState(_playing());
      usePhoneViewport(tester);
      await tester.pumpWidget(
        wrapAboveNavigator(const DynamicIslandPill(), overrides: overrides),
      );
      await settle(tester);

      expect(findGlyph(AurixGlyph.pause), findsOneWidget);
      await tester.tap(findGlyph(AurixGlyph.pause));
      await advance(tester, const Duration(milliseconds: 300));

      expect(findGlyph(AurixGlyph.play), findsOneWidget);

      await tester.pumpWidget(const SizedBox.shrink());
    });

    testWidgets('skip forward is inert at the end of the queue', (tester) async {
      final overrides = await withState(_playing(trackCount: 1));
      usePhoneViewport(tester);
      await tester.pumpWidget(
        wrapAboveNavigator(const DynamicIslandPill(), overrides: overrides),
      );
      await settle(tester);

      await tester.tap(find.byType(DynamicIslandPill));
      await advance(tester, const Duration(milliseconds: 600));

      await tester.tap(findGlyph(AurixGlyph.skipNext));
      await tester.pump();

      final container = ProviderScope.containerOf(
        tester.element(find.byType(DynamicIslandPill)),
      );
      final controller =
          container.read(playerControllerProvider.notifier) as _StubPlayerController;
      expect(controller.skips, 0);

      // The same tap on a queue that has somewhere to go does fire.
      expect(findGlyph(AurixGlyph.skipPrevious), findsOneWidget);
      await tester.tap(findGlyph(AurixGlyph.skipPrevious));
      await tester.pump();
      expect(controller.rewinds, 1);

      await tester.pumpWidget(const SizedBox.shrink());
    });

    testWidgets('keeps the pill up, dimmed, while playback is paused',
        (tester) async {
      usePhoneViewport(tester);
      await tester.pumpWidget(
        wrapAboveNavigator(
          const DynamicIslandPill(),
          overrides: await withState(_playing(isPlaying: false)),
        ),
      );
      await settle(tester);

      expect(find.text('Track 0'), findsOneWidget);
      expect(findGlyph(AurixGlyph.play), findsOneWidget);

      await tester.pumpWidget(const SizedBox.shrink());
    });

    testWidgets('describes itself to screen readers', (tester) async {
      usePhoneViewport(tester);
      await tester.pumpWidget(
        wrapAboveNavigator(
          const DynamicIslandPill(),
          overrides: await withState(_playing()),
        ),
      );
      await settle(tester);

      final semantics = tester.getSemantics(
        find.byType(DynamicIslandPill).first,
      );
      expect(semantics.label, contains('Now playing'));
      expect(semantics.label, contains('Track 0'));

      await tester.pumpWidget(const SizedBox.shrink());
    });

    testWidgets('unmounts cleanly while expanded and animating', (tester) async {
      // Timers and three tickers are live at this point, which is exactly when
      // a disposal bug bites.
      usePhoneViewport(tester);
      await tester.pumpWidget(
        wrapAboveNavigator(
          const DynamicIslandPill(),
          overrides: await withState(_playing()),
        ),
      );
      await settle(tester);
      await tester.tap(find.text('Track 0'));
      await tester.pump(const Duration(milliseconds: 80));

      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump();

      expect(tester.takeException(), isNull);
    });
  });

  group('DynamicIslandSlot', () {
    /// Every top-of-screen arrangement AURIX has to survive. The island is not
    /// allowed to know which one it is on.
    const insets = <String, double>{
      'flat-topped screen': 0,
      'status bar only': 24,
      'punch-hole': 34,
      'notch': 47,
      'hardware Dynamic Island': 59,
    };

    for (final entry in insets.entries) {
      testWidgets('hangs below the safe area on a ${entry.key}', (tester) async {
        await tester.pumpWidget(
          wrapAboveNavigator(
            MediaQuery(
              data: MediaQueryData(
                size: const Size(400, 844),
                padding: EdgeInsets.only(top: entry.value),
              ),
              child: const DynamicIslandSlot(visible: true),
            ),
            overrides: await withState(_playing()),
          ),
        );
        await tester.pump(const Duration(milliseconds: 400));

        final top = tester.getTopLeft(find.byType(DynamicIslandPill)).dy;

        // Clear of whatever the device reserves, and never flush to the edge
        // when it reserves nothing.
        expect(top, greaterThanOrEqualTo(entry.value), reason: entry.key);
        expect(top, greaterThan(0), reason: entry.key);

        await tester.pumpWidget(const SizedBox.shrink());
      });
    }

    testWidgets('takes only its own taps and lets the rest through',
        (tester) async {
      // The island spans the full width of the layer so it can centre itself.
      // If that box swallowed taps, every screen underneath would lose its top
      // strip — the most damaging way this feature could fail.
      var background = 0;
      await tester.pumpWidget(
        wrapAboveNavigator(
          const MediaQuery(
            data: MediaQueryData(
              size: Size(400, 844),
              padding: EdgeInsets.only(top: 47),
            ),
            child: DynamicIslandSlot(visible: true),
          ),
          overrides: await withState(_playing()),
          onBackgroundTap: () => background++,
        ),
      );
      await tester.pump(const Duration(milliseconds: 400));

      // Beside the pill, at its own vertical centre.
      final centre = tester.getCenter(find.byType(DynamicIslandPill));
      await tester.tapAt(Offset(12, centre.dy));
      await tester.pump();
      expect(background, 1);

      // And above it, where the notch would be.
      await tester.tapAt(const Offset(200, 8));
      await tester.pump();
      expect(background, 2);

      await tester.pumpWidget(const SizedBox.shrink());
    });

    testWidgets('shows nothing when it is not meant to be visible',
        (tester) async {
      await tester.pumpWidget(
        wrapAboveNavigator(
          const DynamicIslandSlot(visible: false),
          overrides: await withState(_playing()),
        ),
      );
      await tester.pump(const Duration(milliseconds: 400));

      expect(find.byType(DynamicIslandPill), findsNothing);
      expect(find.text('Track 0'), findsNothing);
    });
  });

  group('dynamicIslandActiveProvider', () {
    Future<ProviderContainer> containerWith({
      required bool enabled,
      required bool signedIn,
      required AurixPlaybackState playback,
    }) async {
      final base = await baseOverrides(
        initialPreferences: <String, Object>{
          PrefKeys.dynamicIsland: enabled,
        },
      );
      final container = ProviderContainer(
        overrides: [
          ...base,
          isSignedInProvider.overrideWithValue(signedIn),
          playerControllerProvider
              .overrideWith(() => _StubPlayerController(playback)),
        ],
      );
      addTearDown(container.dispose);
      return container;
    }

    test('is on when the setting is on, a track is loaded and we are signed in',
        () async {
      final container = await containerWith(
        enabled: true,
        signedIn: true,
        playback: _playing(),
      );
      expect(container.read(dynamicIslandActiveProvider), isTrue);
    });

    test('is off when the user has switched it off', () async {
      final container = await containerWith(
        enabled: false,
        signedIn: true,
        playback: _playing(),
      );
      expect(container.read(dynamicIslandActiveProvider), isFalse);
    });

    test('is off before sign-in, even with a restored track', () async {
      // AURIX restores the last played track on launch, so a track exists
      // while the splash and login screens are up.
      final container = await containerWith(
        enabled: true,
        signedIn: false,
        playback: _playing(isPlaying: false),
      );
      expect(container.read(dynamicIslandActiveProvider), isFalse);
    });

    test('is off when nothing is loaded', () async {
      final container = await containerWith(
        enabled: true,
        signedIn: true,
        playback: AurixPlaybackState.initial,
      );
      expect(container.read(dynamicIslandActiveProvider), isFalse);
    });

    test('stays on while paused', () async {
      final container = await containerWith(
        enabled: true,
        signedIn: true,
        playback: _playing(isPlaying: false),
      );
      expect(container.read(dynamicIslandActiveProvider), isTrue);
    });

    test('the player and its satellites suppress it', () {
      // The island is a shortcut to the player; over the player it would be
      // a second set of transport controls sitting on that screen's header.
      expect(islandSuppressingRoutes, contains('/player'));
      expect(islandSuppressingRoutes, contains('/queue'));
      expect(islandSuppressingRoutes.contains('/home'), isFalse);
    });
  });

  group('AurixSwitch', () {
    testWidgets('reports the value it is being moved to', (tester) async {
      bool? reported;
      await tester.pumpWidget(
        wrapForTest(
          AurixSwitch(value: false, onChanged: (value) => reported = value),
        ),
      );

      await tester.tap(find.byType(AurixSwitch));
      await tester.pumpAndSettle();
      expect(reported, isTrue);
    });

    testWidgets('does not fire when disabled', (tester) async {
      var changes = 0;
      await tester.pumpWidget(
        wrapForTest(
          AurixSwitch(
            value: false,
            enabled: false,
            onChanged: (_) => changes++,
          ),
        ),
      );

      await tester.tap(find.byType(AurixSwitch));
      await tester.pumpAndSettle();
      expect(changes, 0);
    });

    testWidgets('clears the minimum tap target', (tester) async {
      await tester.pumpWidget(
        wrapForTest(AurixSwitch(value: true, onChanged: (_) {})),
      );

      final size = tester.getSize(find.byType(AurixSwitch));
      expect(size.height, greaterThanOrEqualTo(AppSizes.minTapTarget));
      expect(size.width, greaterThanOrEqualTo(AurixSwitch.trackWidth));
    });

    testWidgets('announces its state rather than only colouring it',
        (tester) async {
      // Two switches side by side: `isToggled` is a Tristate, so comparing the
      // on and off nodes is both simpler and a stronger assertion than pinning
      // one of them to a particular enum value.
      await tester.pumpWidget(
        wrapForTest(
          Column(
            children: [
              AurixSwitch(
                value: true,
                onChanged: (_) {},
                semanticLabel: 'Dynamic Island',
              ),
              AurixSwitch(
                value: false,
                onChanged: (_) {},
                semanticLabel: 'Reduce motion',
              ),
            ],
          ),
        ),
      );
      await tester.pumpAndSettle();

      final on = tester.getSemantics(find.bySemanticsLabel('Dynamic Island'));
      final off = tester.getSemantics(find.bySemanticsLabel('Reduce motion'));

      expect(on.label, 'Dynamic Island');
      expect(on.flagsCollection.isToggled, isNot(off.flagsCollection.isToggled));
    });
  });

  group('the Dynamic Island preference', () {
    /// A launch. Each call is a separate [ProviderContainer] over the same
    /// mock preference store, which is what "restart the app" amounts to here:
    /// every provider is rebuilt from scratch and storage is all that carries
    /// across.
    Future<ProviderContainer> launch({
      Map<String, Object> stored = const {},
    }) async {
      final container = ProviderContainer(
        overrides: await baseOverrides(initialPreferences: stored),
      );
      addTearDown(container.dispose);
      return container;
    }

    test('is off on a fresh install', () async {
      final container = await launch();
      expect(container.read(settingsProvider).dynamicIsland, isFalse);
    });

    test('is off in a settings object built with no arguments', () {
      // The other half of the default, and the one a container never reaches:
      // this is what a bare `AppSettings()` gives a caller. Both have to say
      // off, or the feature is opt-in by one route and opt-out by the other.
      expect(const AppSettings().dynamicIsland, isFalse);
    });

    test('writes nothing to storage merely by being read', () async {
      // Reading the settings must not materialise the key. If a first launch
      // wrote `false`, that would be indistinguishable from a user who chose
      // false — and a later change of default could never reach them.
      final container = await launch();
      container.read(settingsProvider);

      final store = container.read(preferencesStoreProvider);
      expect(store.contains(PrefKeys.dynamicIsland), isFalse);
    });

    test('stays off across a restart when the user never touched it', () async {
      final first = await launch();
      expect(first.read(settingsProvider).dynamicIsland, isFalse);

      final second = await launch();
      expect(second.read(settingsProvider).dynamicIsland, isFalse);
    });

    test('turning it on persists, and is restored at the next launch',
        () async {
      final container = await launch();
      await container.read(settingsProvider.notifier).setDynamicIsland(true);
      expect(container.read(settingsProvider).dynamicIsland, isTrue);

      // Written through to storage rather than only held in memory.
      final store = container.read(preferencesStoreProvider);
      expect(store.getBool(PrefKeys.dynamicIsland), isTrue);

      final relaunched = await launch(
        stored: <String, Object>{PrefKeys.dynamicIsland: true},
      );
      expect(relaunched.read(settingsProvider).dynamicIsland, isTrue);
    });

    test('turning it off persists, and stays off at the next launch', () async {
      final container = await launch(
        stored: <String, Object>{PrefKeys.dynamicIsland: true},
      );
      await container.read(settingsProvider.notifier).setDynamicIsland(false);

      final store = container.read(preferencesStoreProvider);
      expect(store.getBool(PrefKeys.dynamicIsland), isFalse);

      final relaunched = await launch(
        stored: <String, Object>{PrefKeys.dynamicIsland: false},
      );
      expect(relaunched.read(settingsProvider).dynamicIsland, isFalse);
    });

    test('comes back off after a reinstall', () async {
      // A reinstall is a launch with empty storage — the state the Android
      // backup rules in android/app/src/main/res/xml exist to guarantee, by
      // keeping AURIX's preferences out of cloud restore. Without them the
      // stored `true` below would survive the uninstall and the island would
      // be on before the app had ever been opened.
      final before = await launch(
        stored: <String, Object>{PrefKeys.dynamicIsland: true},
      );
      expect(before.read(settingsProvider).dynamicIsland, isTrue);

      final reinstalled = await launch();
      expect(reinstalled.read(settingsProvider).dynamicIsland, isFalse);
    });
  });

  group('DynamicIslandLayer', () {
    /// A router that fails the test if anything reads it.
    ///
    /// The point of the disabled path is not only that no island is drawn, but
    /// that nothing is *subscribed* — and the router listener is the one
    /// subscription that would otherwise survive, rebuilding the layer on every
    /// push and pop to keep deciding that a switched-off island stays hidden.
    /// A provider that throws turns that from an invisible cost into a failure.
    final hostileRouter = routerProvider.overrideWith(
      (ref) => throw StateError(
        'DynamicIslandLayer read the router while the island was switched off',
      ),
    );

    testWidgets('passes the app through untouched when the island is off',
        (tester) async {
      final base = await baseOverrides(
        initialPreferences: <String, Object>{PrefKeys.dynamicIsland: false},
      );

      await tester.pumpWidget(
        ProviderScope(
          overrides: [...base, hostileRouter],
          child: const MaterialApp(
            home: DynamicIslandLayer(child: Text('app')),
          ),
        ),
      );
      await tester.pump();

      expect(find.text('app'), findsOneWidget);
      expect(find.byType(DynamicIslandSlot), findsNothing);
      expect(find.byType(DynamicIslandPill), findsNothing);
    });

    testWidgets('adds no Stack of its own when the island is off',
        (tester) async {
      // The child is returned as-is, not wrapped in a one-child Stack that
      // happens to look the same. Asserting on the element tree keeps the
      // early return honest: a future edit that "just" wraps the child would
      // reintroduce the layer this test exists to prove is absent.
      final base = await baseOverrides(
        initialPreferences: <String, Object>{PrefKeys.dynamicIsland: false},
      );

      const child = SizedBox.shrink(key: ValueKey<String>('app'));
      await tester.pumpWidget(
        ProviderScope(
          overrides: [...base, hostileRouter],
          child: const MaterialApp(home: DynamicIslandLayer(child: child)),
        ),
      );
      await tester.pump();

      final layer = tester.element(find.byType(DynamicIslandLayer));
      Element? firstChild;
      layer.visitChildren((element) => firstChild ??= element);
      expect(firstChild!.widget, same(child));
    });
  });
}
