import 'package:aurix/core/router/navigation.dart';
import 'package:aurix/core/router/route_names.dart';
import 'package:aurix/core/theme/app_theme.dart';
import 'package:aurix/features/shell/app_shell.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';

import '../support/harness.dart';

/// Counts what actually reaches the root navigator.
///
/// The point of [AurixRouterNavigation.pushDistinct] is that a duplicate never
/// becomes a route at all, so the assertion has to be made where routes are
/// created rather than on what happens to be visible afterwards — two identical
/// pages stacked on each other look exactly like one.
class _PushCounter extends NavigatorObserver {
  final List<String> pushed = <String>[];

  @override
  void didPush(Route<dynamic> route, Route<dynamic>? previousRoute) {
    final name = route.settings.name;
    if (name != null) pushed.add(name);
  }
}

/// A router shaped like the real one where it matters.
///
/// Three branches under a `StatefulShellRoute.indexedStack` with the real
/// [AppShell] on top, and detail routes pushed onto the **root** navigator —
/// the same arrangement `app_router.dart` builds. The screens are stubs so this
/// exercises navigation rather than the feature screens, which is what lets the
/// test say something precise about the back stack.
GoRouter _testRouter(
  GlobalKey<NavigatorState> rootKey, {
  NavigatorObserver? observer,
}) {
  // Prefixed because the bottom navigation bar renders its own 'Home',
  // 'Search' and 'Library' labels — a bare `find.text('Home')` matches the tab
  // button as well as the page, so it can never be exactly one widget.
  Widget stub(String label) =>
      Scaffold(body: Center(child: Text('screen:$label')));

  return GoRouter(
    navigatorKey: rootKey,
    initialLocation: Routes.home,
    observers: observer == null ? const <NavigatorObserver>[] : [observer],
    routes: <RouteBase>[
      StatefulShellRoute.indexedStack(
        builder: (_, _, shell) => AppShell(navigationShell: shell),
        branches: <StatefulShellBranch>[
          StatefulShellBranch(
            routes: <RouteBase>[
              GoRoute(
                path: Routes.home,
                name: RouteNames.home,
                builder: (_, _) => stub('Home'),
              ),
            ],
          ),
          StatefulShellBranch(
            routes: <RouteBase>[
              GoRoute(
                path: Routes.search,
                name: RouteNames.search,
                builder: (_, _) => stub('Search'),
              ),
            ],
          ),
          StatefulShellBranch(
            routes: <RouteBase>[
              GoRoute(
                path: Routes.library,
                name: RouteNames.library,
                builder: (_, _) => stub('Library'),
              ),
            ],
          ),
        ],
      ),
      GoRoute(
        path: Routes.profile,
        name: RouteNames.profile,
        parentNavigatorKey: rootKey,
        builder: (_, _) => stub('Profile'),
      ),
      GoRoute(
        path: Routes.album,
        name: RouteNames.album,
        parentNavigatorKey: rootKey,
        builder: (_, state) => stub('Album ${state.pathParameters['id']}'),
      ),
      GoRoute(
        path: Routes.category,
        name: RouteNames.category,
        parentNavigatorKey: rootKey,
        builder: (_, state) =>
            stub('Browse ${state.uri.queryParameters['q'] ?? ''}'),
      ),
    ],
  );
}

void main() {
  Future<GoRouter> pump(
    WidgetTester tester, {
    NavigatorObserver? observer,
  }) async {
    final router = _testRouter(
      GlobalKey<NavigatorState>(debugLabel: 'root'),
      observer: observer,
    );
    addTearDown(router.dispose);

    await tester.pumpWidget(
      ProviderScope(
        overrides: await baseOverrides(),
        child: MaterialApp.router(
          theme: AppTheme.dark(),
          debugShowCheckedModeBanner: false,
          routerConfig: router,
        ),
      ),
    );
    await tester.pumpAndSettle();
    return router;
  }

  /// Android's back button and its back gesture both arrive as one `popRoute`
  /// platform message, which is what this sends — the same path a real press
  /// takes, rather than calling `Navigator.pop` and assuming they match.
  Future<void> pressBack(WidgetTester tester) async {
    await tester.binding.defaultBinaryMessenger.handlePlatformMessage(
      'flutter/navigation',
      const JSONMethodCodec()
          .encodeMethodCall(const MethodCall('popRoute')),
      (_) {},
    );
    await tester.pumpAndSettle();
  }

  /// Records what the app asks the platform to do, so "the app closes" can be
  /// asserted as the `SystemNavigator.pop` it really is. Without this, a back
  /// press that correctly exits and one that silently does nothing both leave
  /// the same widget tree behind.
  List<MethodCall> watchPlatform(WidgetTester tester) {
    final calls = <MethodCall>[];
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      SystemChannels.platform,
      (call) async {
        calls.add(call);
        return null;
      },
    );
    addTearDown(
      () => tester.binding.defaultBinaryMessenger
          .setMockMethodCallHandler(SystemChannels.platform, null),
    );
    return calls;
  }

  bool exited(List<MethodCall> calls) =>
      calls.any((call) => call.method == 'SystemNavigator.pop');

  group('pushDistinct', () {
    testWidgets('will not stack the screen that is already showing',
        (tester) async {
      // The double-tap case: a list row's push transition runs for 300ms, and a
      // second tap inside that window used to push an identical second page —
      // so Back appeared to walk through stale history before finally leaving.
      final observer = _PushCounter();
      final router = await pump(tester, observer: observer);

      router.pushDistinct(RouteNames.album, pathParameters: {'id': 'a1'});
      await tester.pumpAndSettle();
      router.pushDistinct(RouteNames.album, pathParameters: {'id': 'a1'});
      await tester.pumpAndSettle();

      expect(
        observer.pushed.where((name) => name == RouteNames.album).length,
        1,
      );

      // And the stack agrees: one Back is enough to be rid of it.
      await pressBack(tester);
      expect(find.text('screen:Home'), findsOneWidget);
      expect(find.text('screen:Album a1'), findsNothing);
    });

    testWidgets('still pushes a different album', (tester) async {
      final observer = _PushCounter();
      final router = await pump(tester, observer: observer);

      router.pushDistinct(RouteNames.album, pathParameters: {'id': 'a1'});
      await tester.pumpAndSettle();
      router.pushDistinct(RouteNames.album, pathParameters: {'id': 'a2'});
      await tester.pumpAndSettle();

      expect(
        observer.pushed.where((name) => name == RouteNames.album).length,
        2,
      );
      expect(find.text('screen:Album a2'), findsOneWidget);

      await pressBack(tester);
      expect(find.text('screen:Album a1'), findsOneWidget);
    });

    testWidgets('tells apart two screens that differ only by query string',
        (tester) async {
      // Browse is the same path with a different search term. Comparing matched
      // paths rather than full locations would collapse these into one and make
      // the second tap do nothing.
      final observer = _PushCounter();
      final router = await pump(tester, observer: observer);

      router.pushDistinct(
        RouteNames.category,
        pathParameters: {'id': 'c1'},
        queryParameters: {'q': 'dawn'},
      );
      await tester.pumpAndSettle();
      router.pushDistinct(
        RouteNames.category,
        pathParameters: {'id': 'c1'},
        queryParameters: {'q': 'dusk'},
      );
      await tester.pumpAndSettle();

      expect(
        observer.pushed.where((name) => name == RouteNames.category).length,
        2,
      );
      expect(find.text('screen:Browse dusk'), findsOneWidget);
    });
  });

  group('Android back on the shell', () {
    testWidgets('closes the app from Home', (tester) async {
      // TEST 1: Home is the root destination, so back from it ends the session
      // rather than reopening splash, login or a route the user already left.
      final calls = watchPlatform(tester);
      await pump(tester);

      expect(find.text('screen:Home'), findsOneWidget);
      await pressBack(tester);

      expect(exited(calls), isTrue);
    });

    testWidgets('returns to Home from another tab instead of closing',
        (tester) async {
      // TEST 2's tail: Search → Back → Home, and only then does Back close.
      final calls = watchPlatform(tester);
      final router = await pump(tester);

      router.go(Routes.search);
      await tester.pumpAndSettle();
      expect(find.text('screen:Search'), findsOneWidget);

      await pressBack(tester);
      expect(find.text('screen:Home'), findsOneWidget);
      expect(exited(calls), isFalse);

      await pressBack(tester);
      expect(exited(calls), isTrue);
    });

    testWidgets('unwinds from the Library tab too, not just Search',
        (tester) async {
      final calls = watchPlatform(tester);
      final router = await pump(tester);

      router.go(Routes.library);
      await tester.pumpAndSettle();

      await pressBack(tester);
      expect(find.text('screen:Home'), findsOneWidget);
      expect(exited(calls), isFalse);
    });

    testWidgets('pops a pushed page before it will consider the tabs',
        (tester) async {
      // Detail routes sit on the root navigator, above the shell — so the shell
      // must not see their back press. The regression this guards is a Back
      // from a detail screen that skips straight past it to the Home tab.
      final calls = watchPlatform(tester);
      final router = await pump(tester);

      router.go(Routes.search);
      await tester.pumpAndSettle();
      router.pushDistinct(RouteNames.album, pathParameters: {'id': 'a1'});
      await tester.pumpAndSettle();
      expect(find.text('screen:Album a1'), findsOneWidget);

      await pressBack(tester);
      expect(find.text('screen:Search'), findsOneWidget);
      expect(exited(calls), isFalse);
    });
  });

  group('Profile', () {
    testWidgets('is pushed over the tabs, so Back returns to them',
        (tester) async {
      // The regression that started this: Profile stopped being a shell tab,
      // but three call sites still reached it with `goNamed`. `go` sets the
      // whole stack from a location, so going to a top-level route replaced the
      // shell rather than covering it — Profile became the only page in the
      // stack and the next Back closed the app from two taps into Home.
      final calls = watchPlatform(tester);
      final router = await pump(tester);

      router.pushDistinct(RouteNames.profile);
      await tester.pumpAndSettle();
      expect(find.text('screen:Profile'), findsOneWidget);

      // The shell is still underneath — this is the part `go` destroyed.
      expect(find.byType(AppShell, skipOffstage: false), findsOneWidget);

      await pressBack(tester);
      expect(find.text('screen:Home'), findsOneWidget);
      expect(exited(calls), isFalse);
    });

    testWidgets('does not stack a second copy on a double tap', (tester) async {
      final observer = _PushCounter();
      final router = await pump(tester, observer: observer);

      router.pushDistinct(RouteNames.profile);
      await tester.pumpAndSettle();
      router.pushDistinct(RouteNames.profile);
      await tester.pumpAndSettle();

      expect(
        observer.pushed.where((name) => name == RouteNames.profile).length,
        1,
      );
    });
  });
}
