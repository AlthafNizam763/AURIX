import 'dart:math';

import 'package:aurix/data/models/playback.dart';
import 'package:aurix/playback/playback_queue.dart';
import 'package:flutter_test/flutter_test.dart';

import '../support/fixtures.dart';

void main() {
  /// Fixed seed so shuffle assertions are deterministic. Without this the test
  /// would pass or fail depending on the run.
  Random seeded() => Random(42);

  group('PlaybackQueue construction', () {
    test('starts at the requested index', () {
      final queue = PlaybackQueue.from(Fixtures.tracks(5), startIndex: 2);
      expect(queue.current?.id, 'track_2');
      expect(queue.cursor, 2);
      expect(queue.length, 5);
    });

    test('clamps an out-of-range start index', () {
      final queue = PlaybackQueue.from(Fixtures.tracks(3), startIndex: 99);
      expect(queue.current?.id, 'track_2');
    });

    test('an empty track list yields the empty queue', () {
      expect(PlaybackQueue.from(const []), PlaybackQueue.empty);
      expect(PlaybackQueue.empty.current, isNull);
    });

    test('shuffling pins the chosen track to the front', () {
      // Tapping track 3 then shuffling must still start on track 3.
      final queue = PlaybackQueue.from(
        Fixtures.tracks(10),
        startIndex: 3,
        shuffle: true,
        random: seeded(),
      );
      expect(queue.current?.id, 'track_3');
      expect(queue.cursor, 0);
      expect(queue.order.length, 10);
      expect(queue.order.toSet().length, 10, reason: 'no duplicated indices');
    });
  });

  group('advancing and stepping back', () {
    test('next moves forward and stops at the end', () {
      var queue = PlaybackQueue.from(Fixtures.tracks(3));
      expect(queue.current?.id, 'track_0');

      queue = queue.next()!;
      expect(queue.current?.id, 'track_1');

      queue = queue.next()!;
      expect(queue.current?.id, 'track_2');

      expect(queue.next(), isNull, reason: 'end of queue with repeat off');
    });

    test('repeat-context wraps to the start', () {
      final queue = PlaybackQueue.from(
        Fixtures.tracks(3),
        startIndex: 2,
        repeatMode: RepeatState.context,
      );
      expect(queue.next()?.current?.id, 'track_0');
    });

    test('repeat-track holds position when a track ends naturally', () {
      final queue = PlaybackQueue.from(
        Fixtures.tracks(3),
        repeatMode: RepeatState.track,
      );
      final after = queue.next(manual: false);
      expect(after?.current?.id, 'track_0');
      expect(identical(after, queue), isTrue);
    });

    test('repeat-track still advances when the user presses next', () {
      // A skip button that does nothing looks broken, even in repeat-one.
      final queue = PlaybackQueue.from(
        Fixtures.tracks(3),
        repeatMode: RepeatState.track,
      );
      expect(queue.next(manual: true)?.current?.id, 'track_1');
    });

    test('previous steps back and stops at the start', () {
      var queue = PlaybackQueue.from(Fixtures.tracks(3), startIndex: 2);
      queue = queue.previous()!;
      expect(queue.current?.id, 'track_1');
      queue = queue.previous()!;
      expect(queue.current?.id, 'track_0');
      expect(queue.previous(), isNull);
    });

    test('previous returns the same queue when mid-track', () {
      final queue = PlaybackQueue.from(Fixtures.tracks(3), startIndex: 1);
      // The controller restarts the track rather than stepping back.
      expect(queue.previous(atPositionStart: false), same(queue));
    });

    test('hasNext and hasPrevious reflect repeat mode', () {
      final atEnd = PlaybackQueue.from(Fixtures.tracks(3), startIndex: 2);
      expect(atEnd.hasNext, isFalse);

      final repeating = atEnd.setRepeat(RepeatState.context);
      expect(repeating.hasNext, isTrue);
      expect(repeating.hasPrevious, isTrue);
    });
  });

  group('shuffle', () {
    test('enabling shuffle keeps the current track playing', () {
      final ordered = PlaybackQueue.from(Fixtures.tracks(8), startIndex: 5);
      final shuffled = ordered.setShuffle(true, random: seeded());

      expect(shuffled.current?.id, 'track_5');
      expect(shuffled.shuffled, isTrue);
      expect(shuffled.order.length, 8);
    });

    test('disabling shuffle restores natural order at the current track', () {
      final shuffled = PlaybackQueue.from(
        Fixtures.tracks(8),
        startIndex: 5,
        shuffle: true,
        random: seeded(),
      );
      final restored = shuffled.setShuffle(false);

      expect(restored.current?.id, 'track_5');
      expect(restored.cursor, 5);
      expect(restored.order, List<int>.generate(8, (i) => i));
    });

    test('toggling shuffle twice is a round trip', () {
      final original = PlaybackQueue.from(Fixtures.tracks(6), startIndex: 2);
      final back = original.setShuffle(true, random: seeded()).setShuffle(false);
      expect(back.order, original.order);
      expect(back.current?.id, original.current?.id);
    });

    test('setting shuffle to its current value is a no-op', () {
      final queue = PlaybackQueue.from(Fixtures.tracks(4));
      expect(queue.setShuffle(false), same(queue));
    });
  });

  group('queue editing', () {
    test('playNext inserts immediately after the current track', () {
      final queue = PlaybackQueue.from(Fixtures.tracks(4), startIndex: 1);
      final extra = Fixtures.explicitTrackJson;
      final updated = queue.playNext(
        Fixtures.tracks(1).first.copyWith(),
      );

      expect(updated.upNext.first.id, 'track_0');
      expect(updated.length, 5);
      expect(extra, isNotNull);
    });

    test('addToQueue appends to the end', () {
      final queue = PlaybackQueue.from(Fixtures.tracks(3));
      final updated = queue.addToQueue(Fixtures.track);
      expect(updated.length, 4);
      expect(updated.upNext.last.id, 'track_1');
    });

    test('removing a track keeps the remaining order correct', () {
      // This is the case that silently breaks naive implementations: removing
      // an element shifts every later index in `order`.
      var queue = PlaybackQueue.from(Fixtures.tracks(5));
      expect(queue.upNext.map((t) => t.id), [
        'track_1',
        'track_2',
        'track_3',
        'track_4',
      ]);

      // Remove "track_2", which sits at order index 2.
      queue = queue.removeAt(2);

      expect(queue.current?.id, 'track_0');
      expect(queue.upNext.map((t) => t.id), ['track_1', 'track_3', 'track_4']);
      expect(queue.length, 4);
    });

    test('removing a track before the cursor keeps the current track playing', () {
      var queue = PlaybackQueue.from(Fixtures.tracks(5), startIndex: 3);
      expect(queue.current?.id, 'track_3');

      queue = queue.removeAt(1);

      expect(queue.current?.id, 'track_3', reason: 'playback must not jump');
      expect(queue.length, 4);
    });

    test('removing the last remaining track empties the queue', () {
      final queue = PlaybackQueue.from(Fixtures.tracks(1));
      expect(queue.removeAt(0), PlaybackQueue.empty);
    });

    test('removeAt ignores an out-of-range index', () {
      final queue = PlaybackQueue.from(Fixtures.tracks(3));
      expect(queue.removeAt(99), same(queue));
      expect(queue.removeAt(-1), same(queue));
    });

    test('reordering up-next moves the right track', () {
      final queue = PlaybackQueue.from(Fixtures.tracks(5));
      expect(queue.upNext.map((t) => t.id), [
        'track_1',
        'track_2',
        'track_3',
        'track_4',
      ]);

      // Drag the third up-next row (track_3) to the top of up-next.
      final reordered = queue.reorderUpNext(2, 0);

      expect(reordered.current?.id, 'track_0', reason: 'current is untouched');
      expect(reordered.upNext.map((t) => t.id), [
        'track_3',
        'track_1',
        'track_2',
        'track_4',
      ]);
    });

    test('reordering to the same slot changes nothing', () {
      final queue = PlaybackQueue.from(Fixtures.tracks(4));
      expect(queue.reorderUpNext(1, 1), same(queue));
    });

    test('clearUpNext keeps history and the current track', () {
      final queue = PlaybackQueue.from(Fixtures.tracks(5), startIndex: 2);
      final cleared = queue.clearUpNext();

      expect(cleared.current?.id, 'track_2');
      expect(cleared.upNext, isEmpty);
      expect(cleared.history.length, 2);
    });
  });

  group('jumping', () {
    test('jumpToTrackId finds a track through a shuffled order', () {
      final queue = PlaybackQueue.from(
        Fixtures.tracks(10),
        shuffle: true,
        random: seeded(),
      );
      final jumped = queue.jumpToTrackId('track_7');
      expect(jumped.current?.id, 'track_7');
    });

    test('jumping to an unknown id leaves the queue alone', () {
      final queue = PlaybackQueue.from(Fixtures.tracks(3));
      expect(queue.jumpToTrackId('nope'), same(queue));
    });
  });

  group('history and up-next views', () {
    test('history is most-recent first', () {
      final queue = PlaybackQueue.from(Fixtures.tracks(5), startIndex: 3);
      expect(queue.history.map((t) => t.id), ['track_2', 'track_1', 'track_0']);
    });

    test('up-next is empty at the end of the queue', () {
      final queue = PlaybackQueue.from(Fixtures.tracks(3), startIndex: 2);
      expect(queue.upNext, isEmpty);
    });
  });
}
