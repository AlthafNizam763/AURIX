import 'package:aurix/features/shell/widgets/app_bottom_navigation.dart';
import 'package:aurix/features/shell/widgets/mini_player.dart';
import 'package:aurix/playback/playback_mode.dart';
import 'package:aurix/playback/playback_queue.dart';
import 'package:aurix/playback/player_controller.dart';
import 'package:aurix/shared/widgets/icons/aurix_glyphs.dart';
import 'package:aurix/shared/widgets/icons/aurix_icon.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import '../support/fixtures.dart';
import '../support/harness.dart';

/// Drives the mini player from a fixed state, so the widget can be verified
/// without a real audio engine or network.
class _StubPlayerController extends PlayerController {
  _StubPlayerController(this.initial);

  final AurixPlaybackState initial;
  int toggles = 0;
  int skips = 0;

  @override
  AurixPlaybackState build() => initial;

  @override
  Future<void> togglePlayPause() async {
    toggles++;
    state = state.copyWith(isPlaying: !state.isPlaying);
  }

  @override
  Future<void> next({bool manual = true}) async => skips++;
}

AurixPlaybackState _playing({
  PlaybackMode mode = PlaybackMode.preview,
  bool isPlaying = true,
}) {
  final tracks = Fixtures.tracks(3);
  return AurixPlaybackState(
    queue: PlaybackQueue.from(
      tracks,
      context: const PlaybackContext(title: 'Parallel Skies'),
    ),
    mode: mode,
    isPlaying: isPlaying,
    position: const Duration(seconds: 12),
    duration: const Duration(seconds: 30),
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

  testWidgets('renders nothing when no track is loaded', (tester) async {
    await tester.pumpWidget(
      wrapForTest(
        const MiniPlayer(),
        overrides: await withState(AurixPlaybackState.initial),
      ),
    );

    expect(find.byType(MiniPlayer), findsOneWidget);
    // The bar is absent from the layout entirely, not merely invisible.
    expect(find.text('Track 0'), findsNothing);
    expect(tester.getSize(find.byType(MiniPlayer)), Size.zero);
  });

  testWidgets('shows the current track and artist', (tester) async {
    await tester.pumpWidget(
      wrapForTest(const MiniPlayer(), overrides: await withState(_playing())),
    );
    await tester.pump();

    expect(find.text('Track 0'), findsOneWidget);
    expect(find.text('Neon Meridian'), findsOneWidget);
  });

  testWidgets('marks preview-only playback with a 0:30 chip', (tester) async {
    // The user must be able to tell a 30-second excerpt from the real track.
    await tester.pumpWidget(
      wrapForTest(
        const MiniPlayer(),
        overrides: await withState(_playing(mode: PlaybackMode.preview)),
      ),
    );
    await tester.pump();

    expect(find.text('0:30'), findsOneWidget);
  });

  testWidgets('shows the device name when playing over Connect', (tester) async {
    final state = _playing(mode: PlaybackMode.connect).copyWith(
      connect: ConnectAvailabilitySnapshot(
        activeDevice: Fixtures.device,
        devices: [Fixtures.device],
        checkedAt: DateTime.now(),
      ),
    );

    await tester.pumpWidget(
      wrapForTest(const MiniPlayer(), overrides: await withState(state)),
    );
    await tester.pump();

    expect(find.text("Sam's MacBook"), findsOneWidget);
    expect(find.text('0:30'), findsNothing);
  });

  testWidgets('play/pause toggles through the controller', (tester) async {
    final overrides = await withState(_playing());
    await tester.pumpWidget(wrapForTest(const MiniPlayer(), overrides: overrides));
    await tester.pump();

    expect(findGlyph(AurixGlyph.pause), findsOneWidget);

    await tester.tap(findGlyph(AurixGlyph.pause));
    // Fixed pumps, not `pumpAndSettle`: the bar's Spider-Verse ambience is a
    // continuous animation, so the tree never reaches a settled state.
    await tester.pump(const Duration(milliseconds: 250));

    expect(findGlyph(AurixGlyph.play), findsOneWidget);
  });

  testWidgets('next is enabled while the queue has more tracks', (tester) async {
    await tester.pumpWidget(
      wrapForTest(const MiniPlayer(), overrides: await withState(_playing())),
    );
    await tester.pump();

    final next = tester.widget<IconButton>(
      find.ancestor(
        of: findGlyph(AurixGlyph.skipNext),
        matching: find.byType(IconButton),
      ),
    );
    expect(next.onPressed, isNotNull);
  });

  testWidgets('next is disabled at the end of the queue', (tester) async {
    final atEnd = AurixPlaybackState(
      queue: PlaybackQueue.from(Fixtures.tracks(1)),
      mode: PlaybackMode.preview,
      isPlaying: true,
    );

    await tester.pumpWidget(
      wrapForTest(const MiniPlayer(), overrides: await withState(atEnd)),
    );
    await tester.pump();

    final next = tester.widget<IconButton>(
      find.ancestor(
        of: findGlyph(AurixGlyph.skipNext),
        matching: find.byType(IconButton),
      ),
    );
    expect(next.onPressed, isNull);
  });

  testWidgets('describes itself to screen readers', (tester) async {
    await tester.pumpWidget(
      wrapForTest(const MiniPlayer(), overrides: await withState(_playing())),
    );
    await tester.pump();

    final semantics = tester.getSemantics(
      find.byType(MiniPlayer).first,
    );
    expect(semantics.label, contains('Now playing'));
  });

  group('AppBottomNavigation', () {
    testWidgets('renders exactly three destinations', (tester) async {
      await tester.pumpWidget(
        wrapForTest(
          AppBottomNavigation(currentIndex: 0, onDestinationSelected: (_) {}),
        ),
      );

      expect(find.text('Home'), findsOneWidget);
      expect(find.text('Search'), findsOneWidget);
      expect(find.text('Library'), findsOneWidget);

      // Playlists and Profile are pushed pages, not tabs. Asserted as an
      // absence rather than just counting: they are still reachable, and the
      // easiest way to regress this is to quietly add the tab back.
      expect(find.text('Playlists'), findsNothing);
      expect(find.text('Profile'), findsNothing);
      expect(
        AppBottomNavigation.defaultDestinations,
        hasLength(3),
        reason: 'the bar reports an index straight into the router shell '
            'branches — a fourth destination here needs a fourth branch there',
      );
    });

    testWidgets('no label is clipped at the largest supported text scale',
        (tester) async {
      // "Library" is the longest of the three, and the app caps scaling at 1.3
      // — so that is the case that has to fit.
      tester.view.physicalSize = const Size(360, 800);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);

      await tester.pumpWidget(
        wrapForTest(
          MediaQuery(
            data: const MediaQueryData(textScaler: TextScaler.linear(1.3)),
            child: AppBottomNavigation(
              currentIndex: 0,
              onDestinationSelected: (_) {},
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(tester.takeException(), isNull);
      for (final label in ['Home', 'Search', 'Library']) {
        final text = tester.widget<Text>(find.text(label));
        expect(text.overflow, TextOverflow.ellipsis, reason: label);
      }
    });

    testWidgets('reports the tapped index', (tester) async {
      var selected = -1;
      await tester.pumpWidget(
        wrapForTest(
          AppBottomNavigation(
            currentIndex: 0,
            onDestinationSelected: (index) => selected = index,
          ),
        ),
      );

      await tester.tap(find.text('Library'));
      await tester.pump();
      expect(selected, 2);
    });

    testWidgets('marks the active destination as selected', (tester) async {
      await tester.pumpWidget(
        wrapForTest(
          AppBottomNavigation(currentIndex: 1, onDestinationSelected: (_) {}),
        ),
      );
      await tester.pumpAndSettle();

      // Selection now reads through the icon set's emphasis treatment — bloom,
      // web hub and chromatic fringe — rather than through an outline/filled
      // glyph swap. Exactly one tab may carry it; more than one and the bar is
      // lying about where the user is.
      final lit = tester
          .widgetList<AurixIcon>(find.byType(AurixIcon))
          .where((icon) => icon.emphasis)
          .toList();

      expect(lit, hasLength(1));
      expect(lit.single.glyph, AurixGlyph.searchActive);

      // Search is the one tab with a distinct selected drawing; the rest keep
      // one shape and let emphasis do the work.
      expect(findGlyph(AurixGlyph.search), findsNothing);
      expect(findGlyph(AurixGlyph.home), findsOneWidget);
      expect(findGlyph(AurixGlyph.library), findsOneWidget);
    });

    testWidgets('exposes the selected state to screen readers', (tester) async {
      await tester.pumpWidget(
        wrapForTest(
          AppBottomNavigation(currentIndex: 1, onDestinationSelected: (_) {}),
        ),
      );
      await tester.pumpAndSettle();

      // Each tab is one merged node announcing its label and selected state.
      // `isSelected` is a Tristate, not a bool — comparing the two nodes is
      // both simpler and a stronger assertion than checking one in isolation.
      final selected = tester.getSemantics(find.bySemanticsLabel('Search'));
      final unselected = tester.getSemantics(find.bySemanticsLabel('Home'));

      expect(selected.label, 'Search');
      expect(unselected.label, 'Home');
      expect(
        selected.flagsCollection.isSelected,
        isNot(unselected.flagsCollection.isSelected),
      );
    });
  });
}
