import 'package:aurix/core/network/api_exception.dart';
import 'package:aurix/core/providers/app_providers.dart';
import 'package:aurix/data/models/artist.dart';
import 'package:aurix/data/models/saved_item.dart';
import 'package:aurix/data/models/track.dart';
import 'package:aurix/data/repositories/library_repository.dart';
import 'package:aurix/features/library/providers/library_provider.dart';
import 'package:aurix/features/library/providers/saved_tracks_provider.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';

class _MockLibrary extends Mock implements LibraryRepository {}

Track _track(String id) => Track(
  id: id,
  name: 'Song $id',
  artists: const <Artist>[Artist(id: 'a1', name: 'Artist')],
  durationMs: 180000,
);

void main() {
  late _MockLibrary library;
  late ProviderContainer container;

  setUpAll(() => registerFallbackValue(_track('fallback')));

  setUp(() {
    library = _MockLibrary();
    container = ProviderContainer(
      overrides: [libraryRepositoryProvider.overrideWithValue(library)],
    );
  });

  // A closure, not a tear-off: `container.dispose` would be evaluated at
  // registration time, before setUp has assigned it.
  tearDown(() => container.dispose());

  SavedTracksController controller() =>
      container.read(savedTracksProvider.notifier);

  group('lookups', () {
    test('batches every queued ID into one request', () async {
      when(() => library.savedTrackIds(any()))
          .thenAnswer((_) async => <String>{'t1'});

      // Three rows building one after another, as a list does.
      controller()
        ..ensureKnown(['t1'])
        ..ensureKnown(['t2'])
        ..ensureKnown(['t3']);

      await Future<void>.delayed(const Duration(milliseconds: 120));

      final captured =
          verify(() => library.savedTrackIds(captureAny())).captured.single;
      expect(
        captured,
        containsAll(<String>['t1', 't2', 't3']),
        reason: 'a 50-row list must not become 50 requests',
      );
      expect(container.read(savedTracksProvider)['t1'], isTrue);
      expect(container.read(savedTracksProvider)['t2'], isFalse);
    });

    test('never asks twice about the same track', () async {
      when(() => library.savedTrackIds(any()))
          .thenAnswer((_) async => <String>{'t1'});

      controller().ensureKnown(['t1']);
      await Future<void>.delayed(const Duration(milliseconds: 120));
      controller().ensureKnown(['t1']);
      await Future<void>.delayed(const Duration(milliseconds: 120));

      verify(() => library.savedTrackIds(any())).called(1);
    });

    test('unknown is distinct from not-saved', () async {
      when(() => library.savedTrackIds(any()))
          .thenAnswer((_) async => <String>{});

      // Nothing asked yet: the heart must render indeterminate, not empty.
      expect(container.read(savedTracksProvider)['t1'], isNull);

      controller().ensureKnown(['t1']);
      await Future<void>.delayed(const Duration(milliseconds: 120));

      expect(container.read(savedTracksProvider)['t1'], isFalse);
    });

    test('seeding answers hearts without a request', () async {
      controller().seedSaved(['t1', 't2']);
      await Future<void>.microtask(() {});

      expect(container.read(savedTracksProvider)['t1'], isTrue);
      verifyNever(() => library.savedTrackIds(any()));
    });

    test('re-seeding the same rows does not change the state object', () async {
      // Liked Songs re-seeds on every build. A new state object each time would
      // notify listeners, rebuild the screen and seed again — an infinite loop.
      controller().seedSaved(['t1']);
      await Future<void>.microtask(() {});
      final first = container.read(savedTracksProvider);

      controller().seedSaved(['t1']);
      await Future<void>.microtask(() {});

      expect(identical(container.read(savedTracksProvider), first), isTrue);
    });
  });

  group('toggling', () {
    test('flips optimistically and keeps the change when the write lands',
        () async {
      when(() => library.saveTrack(any())).thenAnswer((_) async {});
      controller().seedSaved(['t1'], saved: false);
      await Future<void>.microtask(() {});

      final pending = controller().toggle(_track('t1'));
      // Before the await completes, the heart is already full.
      expect(container.read(savedTracksProvider)['t1'], isTrue);

      await pending;
      expect(container.read(savedTracksProvider)['t1'], isTrue);
      verify(() => library.saveTrack(any())).called(1);
    });

    test('rolls back and rethrows when Spotify refuses', () async {
      when(() => library.saveTrack(any())).thenThrow(
        const ApiException(
          kind: ApiFailureKind.forbidden,
          message: 'Forbidden',
          statusCode: 403,
          endpoint: '/me/library',
        ),
      );
      controller().seedSaved(['t1'], saved: false);
      await Future<void>.microtask(() {});

      await expectLater(
        controller().toggle(_track('t1')),
        throwsA(isA<ApiException>()),
      );

      expect(
        container.read(savedTracksProvider)['t1'],
        isFalse,
        reason: 'a refused save must not leave the heart claiming success',
      );
    });

    test('rolls back to unknown when that is where it started', () async {
      when(() => library.saveTrack(any())).thenThrow(
        const ApiException(kind: ApiFailureKind.forbidden, message: 'no'),
      );

      // Never looked up, so the honest rollback target is "unknown", not false.
      await expectLater(
        controller().setSaved(_track('t1'), saved: true),
        throwsA(isA<ApiException>()),
      );

      expect(container.read(savedTracksProvider)['t1'], isNull);
    });

    test('unliking calls unsaveTrack', () async {
      when(() => library.unsaveTrack(any())).thenAnswer((_) async {});
      controller().seedSaved(['t1']);
      await Future<void>.microtask(() {});

      await controller().toggle(_track('t1'));

      expect(container.read(savedTracksProvider)['t1'], isFalse);
      verify(() => library.unsaveTrack(any())).called(1);
    });

    test('a lookup in flight cannot overwrite a toggle', () async {
      // The pre-toggle truth arrives late. Applying it would flip the heart
      // back under the user's finger.
      when(() => library.savedTrackIds(any())).thenAnswer((_) async {
        await Future<void>.delayed(const Duration(milliseconds: 80));
        return <String>{};
      });
      when(() => library.saveTrack(any())).thenAnswer((_) async {
        await Future<void>.delayed(const Duration(milliseconds: 120));
      });

      controller().ensureKnown(['t1']);
      final write = controller().setSaved(_track('t1'), saved: true);

      await Future<void>.delayed(const Duration(milliseconds: 200));
      await write;

      expect(container.read(savedTracksProvider)['t1'], isTrue);
    });

    test('ignores a track with no ID', () async {
      expect(await controller().toggle(_track('')), isNull);
      verifyNever(() => library.saveTrack(any()));
    });
  });

  group('Liked Songs stays out of it until it is alive', () {
    test('a heart tapped elsewhere does not make Liked Songs load', () async {
      when(() => library.saveTrack(any())).thenAnswer((_) async {});

      await controller().setSaved(_track('t1'), saved: true);

      // The store must not reach into likedSongsProvider: reading it would
      // *create* it, firing a network load for a screen nobody is looking at.
      verifyNever(() => library.moreLikedTracks(offset: any(named: 'offset')));
    });

    test('a liked track drops into a list that is already loaded', () async {
      when(
        () => library.moreLikedTracks(
          offset: any(named: 'offset'),
          limit: any(named: 'limit'),
        ),
      ).thenAnswer((_) async => <SavedTrack>[SavedTrack(track: _track('old'))]);
      when(() => library.saveTrack(any())).thenAnswer((_) async {});

      // Liked Songs is on screen.
      await container.read(likedSongsProvider.future);

      await controller().setSaved(_track('fresh'), saved: true);
      await Future<void>.microtask(() {});

      final rows = container.read(likedSongsProvider).value!;
      expect(rows.map((s) => s.track.id), ['fresh', 'old']);
    });

    test('unliking removes the row from a loaded list', () async {
      when(
        () => library.moreLikedTracks(
          offset: any(named: 'offset'),
          limit: any(named: 'limit'),
        ),
      ).thenAnswer(
        (_) async => <SavedTrack>[
          SavedTrack(track: _track('a')),
          SavedTrack(track: _track('b')),
        ],
      );
      when(() => library.unsaveTrack(any())).thenAnswer((_) async {});

      await container.read(likedSongsProvider.future);
      // Every row here is liked by definition — that is what the screen seeds.
      controller().seedSaved(['a', 'b']);
      await Future<void>.microtask(() {});

      await controller().setSaved(_track('a'), saved: false);
      await Future<void>.microtask(() {});

      expect(
        container.read(likedSongsProvider).value!.map((s) => s.track.id),
        ['b'],
      );
    });
  });
}
