import 'package:aurix/core/network/api_exception.dart';
import 'package:aurix/shared/widgets/controls/music_progress_bar.dart';
import 'package:aurix/shared/widgets/controls/play_button.dart';
import 'package:aurix/shared/widgets/feedback/state_views.dart';
import 'package:aurix/shared/widgets/icons/aurix_glyphs.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import '../support/harness.dart';

void main() {
  group('ErrorView', () {
    testWidgets('shows the user-facing message, never the debug detail',
        (tester) async {
      const error = ApiException(
        kind: ApiFailureKind.serverError,
        message: 'Spotify is having trouble right now. Try again shortly.',
        debugDetail: 'HTTP 503 upstream connect error at edge-node-17',
      );

      await tester.pumpWidget(wrapForTest(const ErrorView(error: error)));
      await tester.pumpAndSettle();

      // The headline and the message both mention Spotify; what matters is
      // that the message itself is rendered verbatim.
      expect(
        find.text('Spotify is having trouble right now. Try again shortly.'),
        findsOneWidget,
      );
      expect(find.textContaining('edge-node-17'), findsNothing);
      expect(find.textContaining('HTTP 503'), findsNothing);
    });

    testWidgets('offers a retry button when a retry handler is given',
        (tester) async {
      var retries = 0;
      await tester.pumpWidget(
        wrapForTest(
          ErrorView(
            error: const ApiException(
              kind: ApiFailureKind.timeout,
              message: 'Too slow.',
            ),
            onRetry: () => retries++,
          ),
        ),
      );
      await tester.pumpAndSettle();

      await tester.tap(find.text('Try again'));
      await tester.pump();
      expect(retries, 1);
    });

    testWidgets('has no retry button for a cancelled request', (tester) async {
      // Retrying a request the app itself cancelled makes no sense.
      await tester.pumpWidget(
        wrapForTest(
          ErrorView(
            error: const ApiException(
              kind: ApiFailureKind.cancelled,
              message: 'Cancelled.',
            ),
            onRetry: () {},
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.text('Try again'), findsNothing);
    });

    testWidgets('picks an icon that matches the failure', (tester) async {
      await tester.pumpWidget(
        wrapForTest(
          const ErrorView(
            error: ApiException(
              kind: ApiFailureKind.offline,
              message: 'Offline.',
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(findGlyph(AurixGlyph.offline), findsOneWidget);
      expect(find.text("You're offline"), findsOneWidget);
    });

    testWidgets('compact variant fits inline without a headline', (tester) async {
      await tester.pumpWidget(
        wrapForTest(
          const ErrorView(
            error: ApiException(
              kind: ApiFailureKind.forbidden,
              message: 'Not available.',
            ),
            compact: true,
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.text('Not available.'), findsOneWidget);
      expect(find.text('Not found'), findsNothing);
    });
  });

  group('EmptyView', () {
    testWidgets('renders title, message and action', (tester) async {
      var actions = 0;
      await tester.pumpWidget(
        wrapForTest(
          EmptyView(
            icon: AurixGlyph.heart,
            title: 'No liked songs yet',
            message: 'Tap the heart on any song.',
            actionLabel: 'Browse',
            onAction: () => actions++,
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.text('No liked songs yet'), findsOneWidget);
      expect(find.text('Tap the heart on any song.'), findsOneWidget);

      await tester.tap(find.text('Browse'));
      await tester.pump();
      expect(actions, 1);
    });

    testWidgets('omits the action when no handler is supplied', (tester) async {
      await tester.pumpWidget(
        wrapForTest(
          const EmptyView(icon: AurixGlyph.search, title: 'No results'),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.byType(OutlinedButton), findsNothing);
    });
  });

  group('OfflineBanner', () {
    testWidgets('explains the state and offers a retry', (tester) async {
      var retries = 0;
      await tester.pumpWidget(
        wrapForTest(OfflineBanner(onRetry: () => retries++)),
      );
      await tester.pumpAndSettle();

      expect(find.textContaining("You're offline"), findsOneWidget);
      await tester.tap(find.text('Retry'));
      await tester.pump();
      expect(retries, 1);
    });
  });

  group('PlayButton', () {
    testWidgets('shows play then pause as state changes', (tester) async {
      await tester.pumpWidget(
        wrapForTest(PlayButton(isPlaying: false, onPressed: () {})),
      );
      expect(findGlyph(AurixGlyph.play), findsOneWidget);

      await tester.pumpWidget(
        wrapForTest(PlayButton(isPlaying: true, onPressed: () {})),
      );
      // Fixed pumps, not `pumpAndSettle`: a playing button runs a resting
      // pulse forever by design, so there is nothing to settle to.
      await tester.pump(const Duration(milliseconds: 250));
      expect(findGlyph(AurixGlyph.pause), findsOneWidget);
    });

    testWidgets('does not fire when disabled', (tester) async {
      var taps = 0;
      await tester.pumpWidget(
        wrapForTest(
          PlayButton(isPlaying: false, enabled: false, onPressed: () => taps++),
        ),
      );

      await tester.tap(find.byType(PlayButton), warnIfMissed: false);
      await tester.pump();
      expect(taps, 0);
    });

    testWidgets('shows a spinner while buffering', (tester) async {
      await tester.pumpWidget(
        wrapForTest(
          PlayButton(isPlaying: true, isLoading: true, onPressed: () {}),
        ),
      );

      expect(find.byType(CircularProgressIndicator), findsOneWidget);
      expect(findGlyph(AurixGlyph.pause), findsNothing);
    });
  });

  group('MusicProgressBar', () {
    testWidgets('renders elapsed and remaining timecodes', (tester) async {
      await tester.pumpWidget(
        wrapForTest(
          MusicProgressBar(
            position: const Duration(seconds: 65),
            duration: const Duration(seconds: 200),
            onSeek: (_) {},
          ),
        ),
      );

      expect(find.text('1:05'), findsOneWidget);
      expect(find.text('-2:15'), findsOneWidget);
    });

    testWidgets('reports a seek only when the drag ends', (tester) async {
      // Seeking on every drag frame would fire dozens of Connect requests.
      final seeks = <Duration>[];
      await tester.pumpWidget(
        wrapForTest(
          MusicProgressBar(
            position: Duration.zero,
            duration: const Duration(seconds: 100),
            onSeek: seeks.add,
          ),
        ),
      );

      final slider = find.byType(Slider);
      await tester.drag(slider, const Offset(120, 0));
      await tester.pumpAndSettle();

      expect(seeks.length, 1);
      expect(seeks.single, greaterThan(Duration.zero));
    });

    testWidgets('states plainly when only a preview is playing', (tester) async {
      await tester.pumpWidget(
        wrapForTest(
          MusicProgressBar(
            position: const Duration(seconds: 5),
            duration: const Duration(seconds: 30),
            onSeek: (_) {},
            previewNotice: 'Spotify preview — 30 seconds of 3:33',
          ),
        ),
      );

      expect(find.textContaining('Spotify preview'), findsOneWidget);
    });

    testWidgets('handles an unknown duration without dividing by zero',
        (tester) async {
      await tester.pumpWidget(
        wrapForTest(
          MusicProgressBar(
            position: Duration.zero,
            duration: Duration.zero,
            onSeek: (_) {},
          ),
        ),
      );

      expect(find.text('--:--'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });
  });
}
