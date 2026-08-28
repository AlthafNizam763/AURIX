import 'dart:async';

import 'package:aurix/data/services/api/live_query.dart';
import 'package:flutter_test/flutter_test.dart';

/// [LiveQueries] is what replaced Firestore's snapshot listeners, and it is the
/// piece of the migration most likely to fail *quietly*: a write that forgets
/// to invalidate does not throw, it just leaves a screen showing stale data
/// until the user navigates away and back. That is the bug that gets reported
/// as "sometimes it doesn't update", so the semantics are pinned here.
void main() {
  // Polling is off throughout. What is under test is invalidation, and a live
  // timer would make every test either slow or flaky.
  LiveQueries newQueries() => LiveQueries(pollInterval: null);

  test('emits once on subscribe, without waiting for an invalidation', () async {
    final live = newQueries();
    addTearDown(live.dispose);

    final values = <int>[];
    final sub = live.watch('a', () async => 1).listen(values.add);
    await pumpEventQueue();

    expect(values, <int>[1]);
    await sub.cancel();
  });

  test('re-fetches when its own key is invalidated', () async {
    final live = newQueries();
    addTearDown(live.dispose);

    var counter = 0;
    final values = <int>[];
    final sub = live.watch('library:u1:liked', () async => ++counter).listen(values.add);
    await pumpEventQueue();

    live.invalidate('library:u1:liked');
    await pumpEventQueue();

    expect(values, <int>[1, 2]);
    await sub.cancel();
  });

  test('invalidation is by prefix, so a parent key wakes its children', () async {
    // The property every write path depends on: a playlist edit says
    // "playlists:<uid>:<id>" and both the playlist document and its track list
    // refresh, without the writer enumerating the queries that read them.
    final live = newQueries();
    addTearDown(live.dispose);

    var tracks = 0;
    var playlist = 0;
    final subs = <StreamSubscription<void>>[
      live.watch('playlists:u1:p1:tracks', () async => ++tracks).listen((_) {}),
      live.watch('playlists:u1:p1', () async => ++playlist).listen((_) {}),
    ];
    await pumpEventQueue();
    expect([tracks, playlist], [1, 1]);

    live.invalidate('playlists:u1:p1');
    await pumpEventQueue();
    expect([tracks, playlist], [2, 2]);

    for (final sub in subs) {
      await sub.cancel();
    }
  });

  test('an unrelated key is left alone', () async {
    // The other half of prefix matching, and the one that keeps a like from
    // re-fetching every playlist on the device.
    final live = newQueries();
    addTearDown(live.dispose);

    var liked = 0;
    var playlists = 0;
    final subs = <StreamSubscription<void>>[
      live.watch('library:u1:liked', () async => ++liked).listen((_) {}),
      live.watch('playlists:u1', () async => ++playlists).listen((_) {}),
    ];
    await pumpEventQueue();

    live.invalidate('library:u1');
    await pumpEventQueue();

    expect(liked, 2, reason: 'the liked query is under the invalidated prefix');
    expect(playlists, 1, reason: 'playlists are not');

    for (final sub in subs) {
      await sub.cancel();
    }
  });

  test('invalidateAll wakes everything — used on sign-in and sign-out', () async {
    final live = newQueries();
    addTearDown(live.dispose);

    var a = 0;
    var b = 0;
    final subs = <StreamSubscription<void>>[
      live.watch('library:u1:liked', () async => ++a).listen((_) {}),
      live.watch('catalog', () async => ++b).listen((_) {}),
    ];
    await pumpEventQueue();

    live.invalidateAll();
    await pumpEventQueue();

    expect([a, b], [2, 2]);
    for (final sub in subs) {
      await sub.cancel();
    }
  });

  test('a burst of invalidations does not produce a burst of fetches', () async {
    // Writing twenty tracks into a playlist invalidates its key twenty times.
    // Without the in-flight guard that is twenty overlapping requests which can
    // resolve out of order and leave the *stale* one on screen last.
    final live = newQueries();
    addTearDown(live.dispose);

    var fetches = 0;
    final completers = <Completer<int>>[];

    final sub = live.watch('k', () {
      fetches++;
      final completer = Completer<int>();
      completers.add(completer);
      return completer.future;
    }).listen((_) {});

    await pumpEventQueue();
    expect(fetches, 1, reason: 'the initial fetch');

    // Ten invalidations while the first fetch is still in flight.
    for (var i = 0; i < 10; i++) {
      live.invalidate('k');
    }
    await pumpEventQueue();
    expect(fetches, 1, reason: 'nothing starts while one is running');

    completers.first.complete(1);
    await pumpEventQueue();

    // Exactly one coalesced follow-up, not ten.
    expect(fetches, 2);
    completers.last.complete(2);
    await sub.cancel();
  });

  test('a failed refresh keeps the stream alive', () async {
    // The contract the Firestore version had through `handleError`, and it
    // matters more now: a transient network failure must not permanently break
    // a screen that would work on the next attempt.
    final live = newQueries();
    addTearDown(live.dispose);

    var attempt = 0;
    final values = <int>[];
    final errors = <Object>[];

    final sub = live
        .watch('k', () async {
          attempt++;
          if (attempt == 2) throw StateError('offline');
          return attempt;
        })
        .listen(values.add, onError: errors.add);

    await pumpEventQueue();
    live.invalidate('k'); // fails
    await pumpEventQueue();
    live.invalidate('k'); // recovers
    await pumpEventQueue();

    expect(values, <int>[1, 3], reason: 'the failed refresh emitted nothing');
    expect(errors, isEmpty, reason: 'and did not close the stream');

    await sub.cancel();
  });

  test('a failed FIRST fetch is reported, so a bare screen can say why', () async {
    // The exception to the rule above. With nothing on screen yet, swallowing
    // the error leaves an empty state that looks like an empty library.
    final live = newQueries();
    addTearDown(live.dispose);

    final errors = <Object>[];
    final sub = live
        .watch('k', () async => throw StateError('offline'))
        .listen((_) {}, onError: errors.add);

    await pumpEventQueue();
    expect(errors, hasLength(1));

    await sub.cancel();
  });

  test('cancelling stops the refreshes', () async {
    final live = newQueries();
    addTearDown(live.dispose);

    var fetches = 0;
    final sub = live.watch('k', () async => ++fetches).listen((_) {});
    await pumpEventQueue();
    await sub.cancel();

    live.invalidate('k');
    await pumpEventQueue();

    expect(fetches, 1);
  });

  group('LiveKeys', () {
    test('a child key starts with its parent, which is what prefix matching needs',
        () {
      // If these ever stop nesting, invalidation silently stops reaching the
      // queries it is meant to — with no error anywhere.
      expect(LiveKeys.liked('u1'), startsWith(LiveKeys.library('u1')));
      expect(LiveKeys.history('u1'), startsWith(LiveKeys.library('u1')));
      expect(
        LiveKeys.playlist('u1', 'p1'),
        startsWith(LiveKeys.playlists('u1')),
      );
      expect(
        LiveKeys.playlistTracks('u1', 'p1'),
        startsWith(LiveKeys.playlist('u1', 'p1')),
      );
      expect(
        LiveKeys.sharedPlaylistTracks('p1'),
        startsWith(LiveKeys.sharedPlaylist('p1')),
      );
      expect(
        LiveKeys.sharedPlaylist('p1'),
        startsWith(LiveKeys.sharedPlaylists),
      );
    });

    test('two users do not share a prefix', () {
      // Otherwise one account's write would refresh another's queries — which
      // is harmless on a single-user device and wrong on a shared one.
      expect(LiveKeys.liked('u2').startsWith(LiveKeys.library('u1')), isFalse);
    });
  });
}
