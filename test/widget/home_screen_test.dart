import 'package:aurix/data/models/home_feed.dart';
import 'package:aurix/data/repositories/auth_repository.dart';
import 'package:aurix/features/auth/providers/auth_provider.dart';
import 'package:aurix/features/home/home_screen.dart';
import 'package:aurix/features/home/providers/home_provider.dart';
import 'package:aurix/shared/widgets/feedback/loading_skeleton.dart';
import 'package:aurix/shared/widgets/feedback/state_views.dart';
import 'package:aurix/shared/widgets/media/content_cards.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import '../support/fixtures.dart';
import '../support/harness.dart';

/// A signed-in auth state, so the home provider is allowed to load.
final _signedIn = AuthState(
  status: AuthStatus.signedIn,
  profile: Fixtures.user,
);

class _StubAuthController extends AuthController {
  @override
  AuthState build() => _signedIn;
}

HomeFeed _feed() => HomeFeed(
  shelves: [
    HomeShelf.tracks(
      id: ShelfIds.recentlyPlayed,
      title: 'Recently played',
      items: Fixtures.tracks(4),
    ),
    HomeShelf.albums(
      id: ShelfIds.savedAlbums,
      title: 'Your albums',
      subtitle: 'Saved to your library',
      items: [Fixtures.album],
    ),
    HomeShelf.artists(
      id: ShelfIds.popularArtists,
      title: 'Your top artists',
      items: [Fixtures.artist],
    ),
    // A shelf that failed must be dropped, not rendered as an error block.
    const HomeShelf(
      id: ShelfIds.recommended,
      title: 'Recommended for you',
      kind: ShelfKind.tracks,
      error: 'This section is unavailable right now.',
    ),
  ],
  generatedAt: DateTime.now(),
);

void main() {
  Future<List<Override>> overrides({
    required Future<HomeFeed> Function() load,
    bool offline = false,
  }) async {
    final base = await baseOverrides(offline: offline);
    return [
      ...base,
      authControllerProvider.overrideWith(_StubAuthController.new),
      homeFeedProvider.overrideWith((ref) => load()),
    ];
  }

  testWidgets('shows skeletons while the feed loads', (tester) async {
    await tester.pumpWidget(
      wrapScreenForTest(
        const Scaffold(body: HomeScreen()),
        overrides: await overrides(
          load: () => Future<HomeFeed>.delayed(
            const Duration(seconds: 1),
            _feed,
          ),
        ),
      ),
    );

    await tester.pump();

    expect(find.byType(SkeletonShelf), findsWidgets);
    expect(find.text('New releases'), findsNothing);

    // Let the delayed future resolve so the test ends cleanly.
    await tester.pump(const Duration(seconds: 2));
    await tester.pumpAndSettle();
  });

  testWidgets('renders every shelf that has content', (tester) async {
    await tester.pumpWidget(
      wrapScreenForTest(
        const Scaffold(body: HomeScreen()),
        overrides: await overrides(load: () async => _feed()),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('Recently played'), findsOneWidget);
    expect(find.text('Your albums'), findsOneWidget);

    // The third shelf is below the fold in the default test viewport — the
    // list is lazy, which is the behaviour we want on a real phone too.
    await tester.scrollUntilVisible(
      find.text('Your top artists'),
      400,
      scrollable: find.byType(Scrollable).first,
    );
    expect(find.text('Your top artists'), findsOneWidget);
  });

  testWidgets('drops a failed shelf instead of showing an apology',
      (tester) async {
    // Home is built from eight independent endpoints; a user does not need to
    // hear about each one that a developer app cannot reach.
    await tester.pumpWidget(
      wrapScreenForTest(
        const Scaffold(body: HomeScreen()),
        overrides: await overrides(load: () async => _feed()),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('Recommended for you'), findsNothing);
    expect(find.textContaining('unavailable right now'), findsNothing);
  });

  testWidgets('shows cards for the loaded content', (tester) async {
    await tester.pumpWidget(
      wrapScreenForTest(
        const Scaffold(body: HomeScreen()),
        overrides: await overrides(load: () async => _feed()),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.byType(TrackCard), findsWidgets);
    expect(find.byType(AlbumCard), findsWidgets);

    // The artist shelf is below the fold; scroll to its header, then assert
    // the cards it contains have been built.
    await tester.scrollUntilVisible(
      find.text('Your top artists'),
      400,
      scrollable: find.byType(Scrollable).first,
    );
    await tester.pumpAndSettle();
    expect(find.byType(ArtistCard), findsWidgets);
  });

  testWidgets('greets the user in the header', (tester) async {
    await tester.pumpWidget(
      wrapScreenForTest(
        const Scaffold(body: HomeScreen()),
        overrides: await overrides(load: () async => _feed()),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text(greetingForNow()), findsOneWidget);
    expect(find.text('Sam Rivers'), findsOneWidget);
  });

  testWidgets('an empty feed offers a way forward, not a blank page',
      (tester) async {
    await tester.pumpWidget(
      wrapScreenForTest(
        const Scaffold(body: HomeScreen()),
        overrides: await overrides(load: () async => HomeFeed.empty),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.byType(EmptyView), findsOneWidget);
    expect(find.text('Nothing to show yet'), findsOneWidget);
    expect(find.text('Refresh'), findsOneWidget);
  });

  testWidgets('surfaces a load failure with a retry', (tester) async {
    await tester.pumpWidget(
      wrapScreenForTest(
        const Scaffold(body: HomeScreen()),
        overrides: await overrides(
          load: () async => throw StateError('network down'),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.byType(ErrorView), findsOneWidget);
    // The raw exception text never reaches the screen.
    expect(find.textContaining('network down'), findsNothing);
    expect(find.text('Try again'), findsOneWidget);
  });

  testWidgets('marks a cached feed as stale', (tester) async {
    await tester.pumpWidget(
      wrapScreenForTest(
        const Scaffold(body: HomeScreen()),
        overrides: await overrides(
          load: () async => _feed().copyWith(isStale: true),
          offline: true,
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.textContaining('last synced feed'), findsOneWidget);
  });

  group('greetingForNow', () {
    test('changes through the day', () {
      expect(greetingForNow(DateTime(2026, 1, 1, 2)), 'Good night');
      expect(greetingForNow(DateTime(2026, 1, 1, 9)), 'Good morning');
      expect(greetingForNow(DateTime(2026, 1, 1, 14)), 'Good afternoon');
      expect(greetingForNow(DateTime(2026, 1, 1, 21)), 'Good evening');
    });
  });
}
