import 'package:aurix/data/models/models.dart';
import 'package:aurix/features/home/home_screen.dart';
import 'package:aurix/features/home/providers/home_provider.dart';
import 'package:aurix/shared/widgets/feedback/state_views.dart';
import 'package:aurix/shared/widgets/media/content_cards.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import '../support/fixtures.dart';
import '../support/harness.dart';

/// The Home screen, driven through the real derivation.
///
/// These used to override `homeFeedProvider` with a canned `HomeFeed`, because
/// the feed was a fetch of eight Spotify endpoints and there was no way to
/// stand those up in a widget test. The feed is a pure function of three
/// Firestore streams now, so the streams are what is overridden and the shelf
/// assembly is exercised rather than bypassed — which is the more useful test:
/// it is where "which shelves does Home show" actually lives.
void main() {
  Future<List<Override>> overrides({
    List<Track> likedTracks = const [],
    List<Playlist> playlists = const [],
    List<PlayHistoryEntry> recentlyPlayed = const [],
    bool offline = false,
  }) async => <Override>[
    ...await baseOverrides(offline: offline),
    ...signedInOverrides(
      likedTracks: likedTracks,
      playlists: playlists,
      recentlyPlayed: recentlyPlayed,
    ),
  ];

  List<PlayHistoryEntry> history(int count) => <PlayHistoryEntry>[
    for (final track in Fixtures.aurixTracks(count))
      PlayHistoryEntry(track: track, playedAt: DateTime.utc(2026, 5, 1)),
  ];

  Playlist ownPlaylist(String id, String name) => Playlist.fromFirestore(
    id,
    <String, dynamic>{...Fixtures.aurixPlaylistData, 'name': name},
  );

  Playlist importedPlaylist(String id, String name) => Playlist.fromFirestore(
    id,
    <String, dynamic>{
      ...Fixtures.aurixPlaylistData,
      'name': name,
      'source': 'spotify',
      'sourceId': 'sp_$id',
    },
  );

  testWidgets('renders a shelf for each part of the library', (tester) async {
    await tester.pumpWidget(
      wrapScreenForTest(
        const Scaffold(body: HomeScreen()),
        overrides: await overrides(
          recentlyPlayed: history(4),
          likedTracks: Fixtures.aurixTracks(3),
          playlists: [ownPlaylist('p1', 'Late Drive')],
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('Recently played'), findsOneWidget);

    // The rest are below the fold in the default test viewport — the list is
    // lazy, which is the behaviour we want on a real phone too.
    await tester.scrollUntilVisible(
      find.text('Liked songs'),
      400,
      scrollable: find.byType(Scrollable).first,
    );
    expect(find.text('Liked songs'), findsOneWidget);
  });

  testWidgets('an imported playlist gets its own shelf', (tester) async {
    // Separate from "Your playlists" because the distinction is one the user
    // made and can act on: these are the ones re-importing will refresh.
    await tester.pumpWidget(
      wrapScreenForTest(
        const Scaffold(body: HomeScreen()),
        overrides: await overrides(
          playlists: [
            ownPlaylist('p1', 'Mine'),
            importedPlaylist('p2', 'From Spotify'),
          ],
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('Your playlists'), findsOneWidget);
    await tester.scrollUntilVisible(
      find.text('Imported playlists'),
      400,
      scrollable: find.byType(Scrollable).first,
    );
    expect(find.text('Imported playlists'), findsOneWidget);
  });

  testWidgets('drops an empty shelf rather than rendering a placeholder',
      (tester) async {
    // A new account has recently-played and nothing else. It should see one
    // section, not four headings over empty rows.
    await tester.pumpWidget(
      wrapScreenForTest(
        const Scaffold(body: HomeScreen()),
        overrides: await overrides(recentlyPlayed: history(2)),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('Recently played'), findsOneWidget);
    expect(find.text('Liked songs'), findsNothing);
    expect(find.text('Your playlists'), findsNothing);
    expect(find.text('Imported playlists'), findsNothing);
  });

  testWidgets('shows cards for the loaded content', (tester) async {
    await tester.pumpWidget(
      wrapScreenForTest(
        const Scaffold(body: HomeScreen()),
        overrides: await overrides(
          recentlyPlayed: history(4),
          playlists: [ownPlaylist('p1', 'Late Drive')],
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.byType(TrackCard), findsWidgets);

    await tester.scrollUntilVisible(
      find.text('Your playlists'),
      400,
      scrollable: find.byType(Scrollable).first,
    );
    await tester.pumpAndSettle();
    expect(find.byType(PlaylistCard), findsWidgets);
  });

  testWidgets('greets the user by their AURIX name', (tester) async {
    await tester.pumpWidget(
      wrapScreenForTest(
        const Scaffold(body: HomeScreen()),
        overrides: await overrides(recentlyPlayed: history(2)),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text(greetingForNow()), findsOneWidget);
    // From the Firestore user document, not from Spotify's `/me`.
    expect(find.text(Fixtures.aurixUser.displayName), findsOneWidget);
  });

  testWidgets('an empty library offers a way forward, not a blank page',
      (tester) async {
    await tester.pumpWidget(
      wrapScreenForTest(
        const Scaffold(body: HomeScreen()),
        overrides: await overrides(),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.byType(EmptyView), findsOneWidget);
  });
}
