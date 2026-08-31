import 'package:flutter/widgets.dart';
import 'package:go_router/go_router.dart';

/// Navigation helpers for the screens.
///
/// Deliberately its own file rather than part of `app_router.dart`. That file
/// imports every screen in AURIX in order to build the route table, so a screen
/// importing it back would put the whole feature tree behind a cycle — every
/// screen transitively depending on every other one, for the sake of a single
/// extension method. Nothing here imports a feature.

/// Index of the Home branch in the shell.
///
/// Home is the app's root destination: it is where the sign-in redirect lands,
/// and the tab Android's back button unwinds to before it will let the app
/// close. `AppShell` needs to name it to do that, and a bare `0` at that call
/// site is a number nobody can check against the router.
const int homeBranchIndex = 0;

/// Pushing that refuses to stack a screen on top of itself.
///
/// A tap on a list row starts a 300ms push transition, and a second tap lands
/// while that transition is still running — so two taps on one album row push
/// two identical `AlbumScreen`s, and Back then "returns" to the album the user
/// is already looking at before finally leaving it. It reads as the back button
/// walking through stale history, and it is the easiest duplicate in the app to
/// create by accident: every detail screen is reached from a scrolling list.
///
/// The guard compares full locations, query string included, so it only ever
/// swallows a push that would land on the screen already showing. Album A to
/// Album B, or the same category under a different search term, are different
/// locations and go through.
///
/// This is the imperative half of AURIX's navigation. The other half is
/// `goBranch`, which the shell uses for tab switches and which cannot duplicate
/// anything — see `AppShell`.
extension AurixRouterNavigation on GoRouter {
  void pushDistinct(
    String name, {
    Map<String, String> pathParameters = const <String, String>{},
    Map<String, dynamic> queryParameters = const <String, dynamic>{},
  }) {
    final target = namedLocation(
      name,
      pathParameters: pathParameters,
      queryParameters: queryParameters,
    );

    final configuration = routerDelegate.currentConfiguration;
    // `uri`, not `matchedLocation`: two pushes that differ only in their query
    // string are two different screens, and Browse is exactly that.
    final top = configuration.isEmpty ? '' : state.uri.toString();
    if (top == target) return;

    pushNamed(
      name,
      pathParameters: pathParameters,
      queryParameters: queryParameters,
    );
  }
}

/// [AurixRouterNavigation.pushDistinct] for the screens that have a `context`.
///
/// The router-level version exists for the mini player and the Dynamic Island,
/// which are mounted above the `Navigator` and have no `GoRouter` to find in
/// their context.
extension AurixNavigation on BuildContext {
  void pushDistinct(
    String name, {
    Map<String, String> pathParameters = const <String, String>{},
    Map<String, dynamic> queryParameters = const <String, dynamic>{},
  }) => GoRouter.of(this).pushDistinct(
    name,
    pathParameters: pathParameters,
    queryParameters: queryParameters,
  );
}
