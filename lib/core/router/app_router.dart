import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../data/models/media_source.dart';
import '../../data/repositories/auth_repository.dart';
import '../../features/album/album_screen.dart';
import '../../features/artist/artist_screen.dart';
import '../../features/auth/login_screen.dart';
import '../../features/auth/providers/auth_provider.dart';
import '../../features/auth/setup_required_screen.dart';
import '../../features/home/home_screen.dart';
import '../../features/import/import_flow_screen.dart';
import '../../features/import/import_music_screen.dart';
import '../../features/import/import_playlist_screen.dart';
import '../../features/library/library_screen.dart';
import '../../features/library/liked_songs_screen.dart';
import '../../features/onboarding/onboarding_screen.dart';
import '../../features/onboarding/providers/onboarding_provider.dart';
import '../../features/player/device_picker_screen.dart';
import '../../features/player/player_screen.dart';
import '../../features/player/queue_screen.dart';
import '../../features/playlist/playlist_screen.dart';
import '../../features/playlist/playlists_screen.dart';
import '../../features/profile/edit_profile_screen.dart';
import '../../features/profile/profile_screen.dart';
import '../../features/search/category_screen.dart';
import '../../features/search/search_screen.dart';
import '../../features/settings/about_screen.dart';
import '../../features/settings/settings_screen.dart';
import '../../features/shell/app_shell.dart';
import '../../features/splash/splash_screen.dart';
import '../../shared/widgets/icons/aurix_glyphs.dart';
import '../../shared/widgets/icons/aurix_icon.dart';
import '../constants/app_constants.dart';
import 'route_names.dart';

final _rootNavigatorKey = GlobalKey<NavigatorState>(debugLabel: 'root');
final _homeNavigatorKey = GlobalKey<NavigatorState>(debugLabel: 'home');
final _searchNavigatorKey = GlobalKey<NavigatorState>(debugLabel: 'search');
final _libraryNavigatorKey = GlobalKey<NavigatorState>(debugLabel: 'library');

/// The app's router.
///
/// ## Redirect policy
///
/// Auth gating happens in one `redirect`, not scattered across screens.
/// The states it distinguishes matter:
///
///  * `unconfigured` — no Firebase project. Nothing will work, so send the
///    developer to a screen that says exactly what to add and where.
///  * `unknown` — Firebase has not yet replayed its persisted session. Hold on
///    the splash rather than bouncing to login, which would flash a sign-in
///    screen at users who are already signed in.
///  * `signedOut` / `signedIn` — the normal gate.
///
/// There used to be a fifth: `accessDenied`, for the case where a valid Spotify
/// token belonged to an account the Spotify developer dashboard refused. That
/// state has no analogue in Firebase — there is no per-account allowlist to be
/// refused by — so it and the screen behind it are gone.
///
/// Onboarding sits *in front of* the sign-in gate rather than after it: its
/// job is to explain what AURIX is to someone deciding whether to create an
/// account, which is a question they have before signing up, not after. It is
/// shown once — see [PrefKeys.onboardingComplete].
final routerProvider = Provider<GoRouter>((ref) {
  // A ValueNotifier bridges Riverpod to GoRouter's refreshListenable, so the
  // router re-evaluates its redirect the moment auth state changes.
  final refresh = ValueNotifier<int>(0);
  ref.listen<AuthState>(authControllerProvider, (_, _) => refresh.value++);
  ref.listen<bool>(onboardingCompleteProvider, (_, _) => refresh.value++);
  ref.onDispose(refresh.dispose);

  return GoRouter(
    navigatorKey: _rootNavigatorKey,
    initialLocation: Routes.splash,
    refreshListenable: refresh,
    debugLogDiagnostics: false,

    redirect: (context, state) {
      final auth = ref.read(authControllerProvider);
      final location = state.matchedLocation;

      final atSplash = location == Routes.splash;
      final atOnboarding = location == Routes.onboarding;
      final atLogin = location == Routes.login;
      final atSetup = location == Routes.setup;

      final needsOnboarding = !ref.read(onboardingCompleteProvider);

      switch (auth.status) {
        case AuthStatus.unconfigured:
          return atSetup ? null : Routes.setup;

        case AuthStatus.unknown:
          // Stay on splash while Firebase replays its session; block
          // everything else.
          return atSplash ? null : Routes.splash;

        case AuthStatus.signedOut:
          // A first-run user meets the intro before the sign-in wall.
          if (needsOnboarding) return atOnboarding ? null : Routes.onboarding;
          return (atLogin || atSetup) ? null : Routes.login;

        case AuthStatus.signedIn:
          // Bounce off the pre-auth screens once signed in.
          if (atSplash || atLogin || atSetup || atOnboarding) {
            return Routes.home;
          }
          return null;
      }
    },

    routes: <RouteBase>[
      GoRoute(
        path: Routes.splash,
        name: RouteNames.splash,
        builder: (_, _) => const SplashScreen(),
      ),
      GoRoute(
        path: Routes.onboarding,
        name: RouteNames.onboarding,
        pageBuilder: (_, state) => _fadePage(state, const OnboardingScreen()),
      ),
      GoRoute(
        path: Routes.login,
        name: RouteNames.login,
        pageBuilder: (_, state) => _fadePage(state, const LoginScreen()),
      ),
      GoRoute(
        path: Routes.setup,
        name: RouteNames.setup,
        builder: (_, _) => const SetupRequiredScreen(),
      ),

      // ---- The three tabs, each with its own navigator ------------------
      StatefulShellRoute.indexedStack(
        builder: (_, _, navigationShell) => AppShell(navigationShell: navigationShell),
        branches: <StatefulShellBranch>[
          StatefulShellBranch(
            navigatorKey: _homeNavigatorKey,
            routes: <RouteBase>[
              GoRoute(
                path: Routes.home,
                name: RouteNames.home,
                pageBuilder: (_, state) => _fadePage(state, const HomeScreen()),
              ),
            ],
          ),
          StatefulShellBranch(
            navigatorKey: _searchNavigatorKey,
            routes: <RouteBase>[
              GoRoute(
                path: Routes.search,
                name: RouteNames.search,
                pageBuilder: (_, state) => _fadePage(state, const SearchScreen()),
              ),
            ],
          ),
          StatefulShellBranch(
            navigatorKey: _libraryNavigatorKey,
            routes: <RouteBase>[
              GoRoute(
                path: Routes.library,
                name: RouteNames.library,
                pageBuilder: (_, state) => _fadePage(state, const LibraryScreen()),
              ),
            ],
          ),
        ],
      ),

      // ---- Detail routes -------------------------------------------------
      // Pushed onto the root navigator so they cover the tabs but keep the
      // mini player visible, which is what the shell's layout provides.

      // Playlists and Profile used to be shell branches — the fourth and fifth
      // tabs. They are pushed pages now, because the navigation bar is three
      // destinations and neither of them earns one:
      //
      //  * Playlists is a *filter* of the library, and the Library screen
      //    already offers it as one. A tab that shows a subset of the tab
      //    beside it is a tab that has to be explained.
      //  * Profile is reached from the avatar in the home header, which is
      //    where a user looks for it, and from the library and settings
      //    headers.
      //
      // Those call sites must **push** — `pushDistinct`, not `goNamed`.
      //
      // This note used to claim the opposite, and the claim was wrong in a way
      // that was invisible until someone pressed Back. `go` does not push over
      // anything: it rebuilds the whole stack from a location, and the stack
      // for a top-level route like these is that route and nothing else. The
      // shell was torn down, Profile became the only page in the app, and the
      // next Back press found nothing beneath it and closed AURIX from a screen
      // one tap into Home. Three call sites followed this advice.
      //
      // Pushing keeps the shell mounted underneath, which is what puts the user
      // back on the tab they came from — and it is also what these routes'
      // `_slidePage` transition has always implied.
      GoRoute(
        path: Routes.playlists,
        name: RouteNames.playlists,
        parentNavigatorKey: _rootNavigatorKey,
        pageBuilder: (_, state) => _slidePage(state, const PlaylistsScreen()),
      ),
      GoRoute(
        path: Routes.profile,
        name: RouteNames.profile,
        parentNavigatorKey: _rootNavigatorKey,
        pageBuilder: (_, state) => _slidePage(state, const ProfileScreen()),
        routes: <RouteBase>[
          GoRoute(
            path: 'edit',
            name: RouteNames.editProfile,
            parentNavigatorKey: _rootNavigatorKey,
            pageBuilder: (_, state) => _slidePage(state, const EditProfileScreen()),
          ),
        ],
      ),
      GoRoute(
        path: Routes.album,
        name: RouteNames.album,
        parentNavigatorKey: _rootNavigatorKey,
        pageBuilder: (_, state) => _slidePage(
          state,
          AlbumScreen(albumId: state.pathParameters['id'] ?? ''),
        ),
      ),
      GoRoute(
        path: Routes.artist,
        name: RouteNames.artist,
        parentNavigatorKey: _rootNavigatorKey,
        pageBuilder: (_, state) => _slidePage(
          state,
          ArtistScreen(artistId: state.pathParameters['id'] ?? ''),
        ),
      ),
      GoRoute(
        path: Routes.playlist,
        name: RouteNames.playlist,
        parentNavigatorKey: _rootNavigatorKey,
        pageBuilder: (_, state) => _slidePage(
          state,
          PlaylistScreen(playlistId: state.pathParameters['id'] ?? ''),
        ),
      ),
      GoRoute(
        path: Routes.category,
        name: RouteNames.category,
        parentNavigatorKey: _rootNavigatorKey,
        pageBuilder: (_, state) => _slidePage(
          state,
          CategoryScreen(
            categoryId: state.pathParameters['id'] ?? '',
            title: state.uri.queryParameters['title'] ?? 'Browse',
            query: state.uri.queryParameters['q'],
          ),
        ),
      ),

      // ---- Player: presented as a bottom-up modal ------------------------
      GoRoute(
        path: Routes.player,
        name: RouteNames.player,
        parentNavigatorKey: _rootNavigatorKey,
        pageBuilder: (_, state) => _modalPage(state, const PlayerScreen()),
      ),
      GoRoute(
        path: Routes.queue,
        name: RouteNames.queue,
        parentNavigatorKey: _rootNavigatorKey,
        pageBuilder: (_, state) => _modalPage(state, const QueueScreen()),
      ),
      GoRoute(
        path: Routes.devices,
        name: RouteNames.devices,
        parentNavigatorKey: _rootNavigatorKey,
        pageBuilder: (_, state) => _modalPage(state, const DevicePickerScreen()),
      ),

      // ---- Account -------------------------------------------------------
      GoRoute(
        path: Routes.settings,
        name: RouteNames.settings,
        parentNavigatorKey: _rootNavigatorKey,
        pageBuilder: (_, state) => _slidePage(state, const SettingsScreen()),
        routes: <RouteBase>[
          GoRoute(
            path: 'about',
            name: RouteNames.about,
            parentNavigatorKey: _rootNavigatorKey,
            pageBuilder: (_, state) => _slidePage(state, const AboutScreen()),
          ),
          GoRoute(
            path: 'import',
            name: RouteNames.importMusic,
            parentNavigatorKey: _rootNavigatorKey,
            pageBuilder: (_, state) =>
                _slidePage(state, const ImportMusicScreen()),
            routes: <RouteBase>[
              // Declared *before* the `:provider` route below, because a path
              // parameter matches any single segment — `/settings/import/link`
              // would otherwise resolve to the provider flow with a provider
              // named "link". go_router matches in declaration order, so
              // specific paths must come first.
              GoRoute(
                path: 'link',
                name: RouteNames.importPlaylist,
                parentNavigatorKey: _rootNavigatorKey,
                pageBuilder: (_, state) =>
                    _slidePage(state, const ImportPlaylistScreen()),
              ),
              GoRoute(
                path: ':provider',
                name: RouteNames.importProvider,
                parentNavigatorKey: _rootNavigatorKey,
                pageBuilder: (_, state) => _slidePage(
                  state,
                  ImportFlowScreen(
                    // An unrecognised provider name in a deep link resolves to
                    // `aurix`, which has no import provider registered — the
                    // flow screen then shows its idle state with a button that
                    // does nothing rather than crashing on a bad URL.
                    source: MediaSource.parse(
                      state.pathParameters['provider'],
                    ),
                  ),
                ),
              ),
            ],
          ),
        ],
      ),
      GoRoute(
        path: Routes.likedSongs,
        name: RouteNames.likedSongs,
        parentNavigatorKey: _rootNavigatorKey,
        pageBuilder: (_, state) => _slidePage(state, const LikedSongsScreen()),
      ),
    ],

    errorBuilder: (context, state) => _RouteErrorScreen(
      location: state.uri.toString(),
      onGoHome: () => context.goNamed(RouteNames.home),
    ),
  );
});

/// The location of whatever route is on top right now.
///
/// For the layers mounted *above* the `Navigator` — the Dynamic Island and the
/// global mini player — which need to know which screen is showing without
/// being able to read it from `context`.
///
/// Deliberately not `currentConfiguration.uri`. That property documents itself
/// as reflecting only non-imperative matches, and every detail screen in AURIX
/// is reached with `pushNamed` — so it reports the *tab* the user pushed from
/// and never changes as they navigate. Reading the top match's own state is
/// what follows an imperative push.
String currentTopLocation(GoRouter router) {
  final configuration = router.routerDelegate.currentConfiguration;
  if (configuration.isEmpty) return '';
  return router.state.matchedLocation;
}

// ---------------------------------------------------------------------------
// Transitions
// ---------------------------------------------------------------------------

/// Cross-fade — used for tab switches, where a slide would imply hierarchy
/// that does not exist between peers.
CustomTransitionPage<void> _fadePage(GoRouterState state, Widget child) =>
    CustomTransitionPage<void>(
      key: state.pageKey,
      child: child,
      transitionDuration: AppConstants.medium,
      reverseTransitionDuration: AppConstants.fast,
      transitionsBuilder: (_, animation, _, child) => FadeTransition(
        opacity: CurvedAnimation(parent: animation, curve: Curves.easeOut),
        child: child,
      ),
    );

/// Slide from the right with a slight fade — the standard push.
CustomTransitionPage<void> _slidePage(GoRouterState state, Widget child) =>
    CustomTransitionPage<void>(
      key: state.pageKey,
      child: child,
      transitionDuration: AppConstants.medium,
      reverseTransitionDuration: AppConstants.fast,
      transitionsBuilder: (_, animation, _, child) {
        final curved = CurvedAnimation(
          parent: animation,
          curve: Curves.easeOutCubic,
          reverseCurve: Curves.easeInCubic,
        );
        return SlideTransition(
          position: Tween<Offset>(
            begin: const Offset(0.06, 0),
            end: Offset.zero,
          ).animate(curved),
          child: FadeTransition(opacity: curved, child: child),
        );
      },
    );

/// Rise from the bottom — the full player and its satellites, which read as
/// modal surfaces rather than destinations.
CustomTransitionPage<void> _modalPage(GoRouterState state, Widget child) =>
    CustomTransitionPage<void>(
      key: state.pageKey,
      child: child,
      opaque: false,
      barrierColor: Colors.transparent,
      transitionDuration: const Duration(milliseconds: 340),
      reverseTransitionDuration: const Duration(milliseconds: 260),
      transitionsBuilder: (_, animation, _, child) => SlideTransition(
        position: Tween<Offset>(
          begin: const Offset(0, 1),
          end: Offset.zero,
        ).animate(
          CurvedAnimation(
            parent: animation,
            curve: Curves.easeOutCubic,
            reverseCurve: Curves.easeInCubic,
          ),
        ),
        child: child,
      ),
    );

class _RouteErrorScreen extends StatelessWidget {
  const _RouteErrorScreen({required this.location, required this.onGoHome});

  final String location;
  final VoidCallback onGoHome;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Center(
        child: Padding(
          padding: const EdgeInsets.all(32),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const AurixIcon(AurixGlyph.search, size: 48),
              const SizedBox(height: 20),
              Text(
                "That link doesn't lead anywhere",
                style: Theme.of(context).textTheme.headlineSmall,
                textAlign: TextAlign.center,
              ),
              const SizedBox(height: 8),
              Text(
                location,
                style: Theme.of(context).textTheme.bodySmall,
                textAlign: TextAlign.center,
              ),
              const SizedBox(height: 24),
              FilledButton(onPressed: onGoHome, child: const Text('Go home')),
            ],
          ),
        ),
      ),
    );
  }
}
