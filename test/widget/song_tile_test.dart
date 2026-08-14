import 'package:aurix/data/models/track.dart';
import 'package:aurix/shared/widgets/icons/aurix_glyphs.dart';
import 'package:aurix/shared/widgets/media/song_tile.dart';
import 'package:flutter_test/flutter_test.dart';

import '../support/fixtures.dart';
import '../support/harness.dart';

void main() {
  group('SongTile', () {
    testWidgets('renders the title and artist', (tester) async {
      await tester.pumpWidget(
        wrapForTest(SongTile(track: Fixtures.track, onTap: () {})),
      );

      expect(find.text('Afterglow'), findsOneWidget);
      expect(find.text('Neon Meridian'), findsOneWidget);
    });

    testWidgets('calls onTap for a playable track', (tester) async {
      var taps = 0;
      await tester.pumpWidget(
        wrapForTest(SongTile(track: Fixtures.track, onTap: () => taps++)),
      );

      await tester.tap(find.byType(SongTile));
      await tester.pump();

      expect(taps, 1);
    });

    testWidgets('does not call onTap for a local file', (tester) async {
      // Letting the user tap and silently doing nothing is worse than showing
      // the row as unavailable.
      var taps = 0;
      await tester.pumpWidget(
        wrapForTest(SongTile(track: Fixtures.localTrack, onTap: () => taps++)),
      );

      await tester.tap(find.byType(SongTile), warnIfMissed: false);
      await tester.pump();

      expect(taps, 0);
      expect(findGlyph(AurixGlyph.block), findsOneWidget);
    });

    testWidgets('marks an unavailable track as unplayable', (tester) async {
      final blocked = Track.fromJson({
        ...Fixtures.trackJson,
        'is_playable': false,
      });

      var taps = 0;
      await tester.pumpWidget(
        wrapForTest(SongTile(track: blocked, onTap: () => taps++)),
      );

      await tester.tap(find.byType(SongTile), warnIfMissed: false);
      await tester.pump();

      expect(taps, 0);
    });

    testWidgets('shows the explicit badge only for explicit tracks', (tester) async {
      await tester.pumpWidget(
        wrapForTest(SongTile(track: Fixtures.track, onTap: () {})),
      );
      expect(find.text('E'), findsNothing);

      await tester.pumpWidget(
        wrapForTest(
          SongTile(
            track: Track.fromJson(Fixtures.explicitTrackJson),
            onTap: () {},
          ),
        ),
      );
      expect(find.text('E'), findsOneWidget);
    });

    testWidgets('numbered variant shows the track number', (tester) async {
      await tester.pumpWidget(
        wrapForTest(
          SongTile(
            track: Fixtures.track,
            variant: SongTileVariant.numbered,
            index: 7,
            onTap: () {},
          ),
        ),
      );

      expect(find.text('7'), findsOneWidget);
    });

    testWidgets('the current track shows the playing indicator, not a number',
        (tester) async {
      await tester.pumpWidget(
        wrapForTest(
          SongTile(
            track: Fixtures.track,
            variant: SongTileVariant.numbered,
            index: 3,
            isCurrent: true,
            isPlaying: true,
            onTap: () {},
          ),
        ),
      );
      await tester.pump(const Duration(milliseconds: 100));

      expect(find.byType(PlayingIndicator), findsOneWidget);
      expect(find.text('3'), findsNothing);
    });

    testWidgets('the like button reflects and toggles saved state', (tester) async {
      var toggles = 0;
      await tester.pumpWidget(
        wrapForTest(
          SongTile(
            track: Fixtures.track,
            isSaved: true,
            onSaveToggle: () => toggles++,
            onTap: () {},
          ),
        ),
      );

      expect(findGlyph(AurixGlyph.heartFilled), findsOneWidget);

      await tester.tap(findGlyph(AurixGlyph.heartFilled));
      await tester.pump();
      expect(toggles, 1);
    });

    testWidgets('the like button is absent when isSaved is null', (tester) async {
      await tester.pumpWidget(
        wrapForTest(SongTile(track: Fixtures.track, onTap: () {})),
      );

      expect(findGlyph(AurixGlyph.heartFilled), findsNothing);
      expect(findGlyph(AurixGlyph.heart), findsNothing);
    });

    testWidgets('long-press opens the more menu', (tester) async {
      var more = 0;
      await tester.pumpWidget(
        wrapForTest(
          SongTile(track: Fixtures.track, onMore: () => more++, onTap: () {}),
        ),
      );

      await tester.longPress(find.byType(SongTile));
      await tester.pump();

      expect(more, 1);
    });

    testWidgets('showAlbumName appends the album to the subtitle', (tester) async {
      final track = Fixtures.track.withAlbum(Fixtures.album);

      await tester.pumpWidget(
        wrapForTest(
          SongTile(track: track, showAlbumName: true, onTap: () {}),
        ),
      );

      expect(find.text('Neon Meridian · Parallel Skies'), findsOneWidget);
    });

    testWidgets('is exposed to accessibility as a button', (tester) async {
      await tester.pumpWidget(
        wrapForTest(SongTile(track: Fixtures.track, onTap: () {})),
      );

      final semantics = tester.getSemantics(find.byType(SongTile).first);
      expect(semantics.label, contains('Afterglow'));
    });
  });

  group('PlayingIndicator', () {
    testWidgets('does not animate when playback is paused', (tester) async {
      // A bouncing equaliser over a paused track is a small lie, and it also
      // keeps a repaint running forever.
      await tester.pumpWidget(
        wrapForTest(const PlayingIndicator(animate: false)),
      );

      await tester.pump(const Duration(seconds: 1));
      // With no running animation the test framework has no pending frames.
      expect(tester.hasRunningAnimations, isFalse);
    });

    testWidgets('animates while playing', (tester) async {
      await tester.pumpWidget(
        wrapForTest(const PlayingIndicator(animate: true)),
      );
      await tester.pump(const Duration(milliseconds: 100));

      expect(tester.hasRunningAnimations, isTrue);
    });
  });
}
