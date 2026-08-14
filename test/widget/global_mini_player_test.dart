import 'package:aurix/core/router/app_router.dart';
import 'package:aurix/core/router/route_names.dart';
import 'package:aurix/core/theme/app_theme.dart';
import 'package:aurix/features/shell/widgets/global_mini_player.dart';
import 'package:aurix/features/shell/widgets/mini_player.dart';
import 'package:aurix/playback/playback_mode.dart';
import 'package:aurix/playback/playback_queue.dart';
import 'package:aurix/playback/player_controller.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';

import '../support/fixtures.dart';
import '../support/harness.dart';

class _StubPlayerController extends PlayerController {
  _StubPlayerController(this.initial);

  final AurixPlaybackState initial;

  @override
  AurixPlaybackState build() => initial;

  @override
  Future<void> togglePlayPause() async {}

  @override
  Future<void> next({bool manual = true}) async {}
}

AurixPlaybackState _playing() => AurixPlaybackState(
  queue: PlaybackQueue.from(Fixtures.tracks(2)),
  mode: PlaybackMode.appRemote,
  isPlaying: true,
  position: const Duration(seconds: 12),
  duration: const Duration(seconds: 180),
);

/// A router shaped like the real one in the way that matters: the shell tabs
/// live under a shell route, and the detail screens are pushed onto the **root**
/// navigator, which is exactly what used to cover the mini player.
GoRouter _testRouter(GlobalKey<NavigatorState> rootKey) {
  return GoRouter(
    navigatorKey: rootKey,
    initialLocation: Routes.home,
    routes: <RouteBase>[
      GoRoute(
        path: Routes.home,
        name: RouteNames.home,
        builder: (_, _) => const Scaffold(body: Text('Home')),
      ),
      GoRoute(
        path: Routes.likedSongs,
        name: RouteNames.likedSongs,
        parentNavigatorKey: rootKey,
        builder: (_, _) => const Scaffold(body: Text('Liked Songs')),
      ),
      GoRoute(
        path: Routes.player,
        name: RouteNames.player,
        parentNavigatorKey: rootKey,
        builder: (_, _) => const Scaffold(body: Text('Player')),
      ),
    ],
  );
}

void main() {
  /// Advances without `pumpAndSettle`, which never returns here: the mini
  /// player carries `SpiderVerseAmbience`, and that animates for as long as it
  /// is on screen by design.
  Future<void> settle(WidgetTester tester) async {
    for (var i = 0; i < 12; i++) {
      await tester.pump(const Duration(milliseconds: 50));
    }
  }

  Future<(Widget, GoRouter)> build(AurixPlaybackState state) async {
    final rootKey = GlobalKey<NavigatorState>(debugLabel: 'root');
    final router = _testRouter(rootKey);
    final base = await baseOverrides();

    final app = ProviderScope(
      overrides: [
        ...base,
        routerProvider.overrideWithValue(router),
        playerControllerProvider.overrideWith(() => _StubPlayerController(state)),
      ],
      child: MaterialApp.router(
        theme: AppTheme.dark(),
        debugShowCheckedModeBanner: false,
        routerConfig: router,
        // The production mounting point: above the Navigator, inside the
        // builder — which is the whole point of the widget.
        builder: (context, child) => GlobalMiniPlayer(child: child!),
      ),
    );

    return (app, router);
  }

  testWidgets('shows above the shell while something is playing', (tester) async {
    final (app, _) = await build(_playing());
    await tester.pumpWidget(app);
    await settle(tester);

    expect(find.text('Home'), findsOneWidget);
    expect(find.byType(MiniPlayer), findsOneWidget);
    expect(find.text('Track 0'), findsOneWidget);
  });

  testWidgets('survives a detail route pushed onto the root navigator',
      (tester) async {
    // The reported bug, and the exact reason for it: Liked Songs is a
    // root-navigator push, so it covers the shell — and used to cover the mini
    // player with it.
    final (app, router) = await build(_playing());
    await tester.pumpWidget(app);
    await settle(tester);

    router.pushNamed(RouteNames.likedSongs);
    await settle(tester);

    expect(find.text('Liked Songs'), findsOneWidget);
    expect(find.byType(MiniPlayer), findsOneWidget);
    expect(find.text('Track 0'), findsOneWidget);
  });

  testWidgets('is still there after going back to the shell', (tester) async {
    final (app, router) = await build(_playing());
    await tester.pumpWidget(app);
    await settle(tester);

    router.pushNamed(RouteNames.likedSongs);
    await settle(tester);
    router.pop();
    await settle(tester);

    expect(find.text('Home'), findsOneWidget);
    expect(find.byType(MiniPlayer), findsOneWidget);
  });

  testWidgets('sits higher on a shell tab than on a pushed route',
      (tester) async {
    // On a tab the navigation bar is underneath it; on a pushed route there is
    // none, so it drops to the safe area.
    final (app, router) = await build(_playing());
    await tester.pumpWidget(app);
    await settle(tester);

    final onShell = tester.getTopLeft(find.byType(MiniPlayer)).dy;

    router.pushNamed(RouteNames.likedSongs);
    await settle(tester);

    final onDetail = tester.getTopLeft(find.byType(MiniPlayer)).dy;
    expect(onDetail, greaterThan(onShell));
  });

  testWidgets('gets out of the way on the full player', (tester) async {
    final (app, router) = await build(_playing());
    await tester.pumpWidget(app);
    await settle(tester);

    router.pushNamed(RouteNames.player);
    await settle(tester);

    // Still mounted — it animates out rather than being torn down — but pushed
    // off-screen and refusing taps.
    final ignorer = tester.widget<IgnorePointer>(
      find.ancestor(
        of: find.byType(MiniPlayer),
        matching: find.byType(IgnorePointer),
      ).first,
    );
    expect(ignorer.ignoring, isTrue);

    final screenHeight = tester.view.physicalSize.height / tester.view.devicePixelRatio;
    expect(tester.getTopLeft(find.byType(MiniPlayer)).dy,
        greaterThanOrEqualTo(screenHeight));
  });

  testWidgets('stays hidden when nothing is loaded', (tester) async {
    final (app, _) = await build(AurixPlaybackState.initial);
    await tester.pumpWidget(app);
    await settle(tester);

    // The bar renders nothing without a track, and the layer keeps it out of
    // reach besides.
    expect(find.text('Track 0'), findsNothing);
  });

  testWidgets('route detection follows an imperative push', (tester) async {
    // `RouteMatchList.uri` reports only non-imperative matches, so it stays on
    // the tab the user pushed from. Reading it — rather than the top match's
    // own state — left both root-level layers believing the shell was still on
    // top for the entire session.
    final rootKey = GlobalKey<NavigatorState>(debugLabel: 'root');
    final router = _testRouter(rootKey);
    await tester.pumpWidget(
      MaterialApp.router(routerConfig: router, theme: AppTheme.dark()),
    );
    await tester.pumpAndSettle();

    expect(currentTopLocation(router), Routes.home);
    expect(router.routerDelegate.currentConfiguration.uri.path, Routes.home);

    router.pushNamed(RouteNames.player);
    await tester.pumpAndSettle();

    expect(currentTopLocation(router), Routes.player);
    expect(
      router.routerDelegate.currentConfiguration.uri.path,
      Routes.home,
      reason: 'the property that made this wrong, pinned so it stays avoided',
    );
  });

  testWidgets('a paused track keeps the bar on screen', (tester) async {
    final (app, router) = await build(
      _playing().copyWith(isPlaying: false),
    );
    await tester.pumpWidget(app);
    await settle(tester);

    router.pushNamed(RouteNames.likedSongs);
    await settle(tester);

    expect(find.byType(MiniPlayer), findsOneWidget);
    expect(find.text('Track 0'), findsOneWidget);
  });
}
