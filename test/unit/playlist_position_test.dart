import 'package:aurix/data/services/firebase/firestore_playlist_service.dart';
import 'package:flutter_test/flutter_test.dart';

/// The fractional-rank scheme that makes a reorder one write.
///
/// Tested through [FirestorePlaylistService.positionBetween] rather than
/// through a reorder, because the case that matters — the gap collapsing after
/// repeated subdivision — takes about fifty real drags to reach and is exactly
/// the one nobody would notice was broken.
void main() {
  group('positionBetween', () {
    double between(double? before, double? after) {
      final position = FirestorePlaylistService.positionBetween(before, after);
      expect(position, isNotNull, reason: 'expected room between $before and $after');
      return position!;
    }

    test('the first track in an empty playlist gets a positive position', () {
      expect(between(null, null), greaterThan(0));
    });

    test('appending goes after the last track', () {
      expect(between(1024, null), greaterThan(1024));
    });

    test('prepending goes before the first track', () {
      expect(between(null, 1024), lessThan(1024));
    });

    test('inserting between two tracks lands strictly between them', () {
      final position = between(1024, 2048);
      expect(position, greaterThan(1024));
      expect(position, lessThan(2048));
    });

    test('repeated subdivision stays ordered', () {
      // Each insert goes between the previous position and the same upper
      // neighbour — the pattern that halves the gap every time.
      var lower = 0.0;
      const upper = 1024.0;
      for (var i = 0; i < 40; i++) {
        final next = FirestorePlaylistService.positionBetween(lower, upper);
        if (next == null) break;
        expect(next, greaterThan(lower));
        expect(next, lessThan(upper));
        lower = next;
      }
    });

    test('reports no room rather than returning a duplicate position', () {
      // The signal `reorder` uses to rebalance. Returning `before` again — or
      // any value equal to a neighbour — would silently corrupt the ordering,
      // which is why this is null and not a best effort.
      expect(FirestorePlaylistService.positionBetween(1.0, 1.0), isNull);
      expect(
        FirestorePlaylistService.positionBetween(1.0, 1.0 + 1e-9),
        isNull,
      );
    });

    test('a wide gap always has room', () {
      expect(FirestorePlaylistService.positionBetween(0, 1e6), isNotNull);
    });
  });
}
