import 'package:aurix/data/models/playlist.dart';
import 'package:aurix/features/playlist/playlists_screen.dart';
import 'package:flutter_test/flutter_test.dart';

/// Builds a playlist with just the fields the Playlists tab sorts and filters
/// on. Going through `fromJson` rather than a constructor keeps the test
/// honest about the shape the app actually receives.
Playlist _playlist({
  required String id,
  required String name,
  required String ownerId,
  int trackCount = 0,
}) {
  return Playlist.fromJson(<String, dynamic>{
    'id': id,
    'name': name,
    'owner': {'id': ownerId, 'display_name': ownerId, 'type': 'user'},
    'tracks': {'total': trackCount},
  });
}

void main() {
  final mine = _playlist(
    id: 'a',
    name: 'zebra sessions',
    ownerId: 'me',
    trackCount: 3,
  );
  final theirs = _playlist(
    id: 'b',
    name: 'Alpha Waves',
    ownerId: 'someone_else',
    trackCount: 90,
  );
  final alsoMine = _playlist(
    id: 'c',
    name: 'Midnight',
    ownerId: 'me',
    trackCount: 41,
  );
  final source = <Playlist>[mine, theirs, alsoMine];

  List<String> idsOf(List<Playlist> list) => list.map((p) => p.id).toList();

  group('scope', () {
    test('all keeps everything, in the order Spotify returned it', () {
      final result = arrangePlaylists(
        source,
        scope: PlaylistScope.all,
        sort: PlaylistSort.none,
        userId: 'me',
      );
      expect(idsOf(result), ['a', 'b', 'c']);
    });

    test('mine keeps only playlists the signed-in user owns', () {
      final result = arrangePlaylists(
        source,
        scope: PlaylistScope.mine,
        sort: PlaylistSort.none,
        userId: 'me',
      );
      expect(idsOf(result), ['a', 'c']);
    });

    test('mine falls back to everything when the user id is unknown', () {
      // A signed-in user whose profile has not loaded yet must not see an
      // empty screen that looks like "you have no playlists".
      final result = arrangePlaylists(
        source,
        scope: PlaylistScope.mine,
        sort: PlaylistSort.none,
      );
      expect(idsOf(result), ['a', 'b', 'c']);
    });
  });

  group('sort', () {
    test('alphabetical ignores case', () {
      // 'zebra sessions' is lower-case and 'Alpha Waves' is not; a raw string
      // compare puts every capitalised name before every lower-case one.
      final result = arrangePlaylists(
        source,
        scope: PlaylistScope.all,
        sort: PlaylistSort.alphabetical,
      );
      expect(idsOf(result), ['b', 'c', 'a']);
    });

    test('size sorts by track count, largest first', () {
      final result = arrangePlaylists(
        source,
        scope: PlaylistScope.all,
        sort: PlaylistSort.size,
      );
      expect(idsOf(result), ['b', 'c', 'a']);
    });

    test('scope and sort compose', () {
      final result = arrangePlaylists(
        source,
        scope: PlaylistScope.mine,
        sort: PlaylistSort.size,
        userId: 'me',
      );
      expect(idsOf(result), ['c', 'a']);
    });
  });

  test('never reorders the caller\'s list', () {
    // The source is the library snapshot, shared with the Library tab. Sorting
    // it in place would silently change the order that tab renders.
    final original = <Playlist>[mine, theirs, alsoMine];
    arrangePlaylists(
      original,
      scope: PlaylistScope.all,
      sort: PlaylistSort.alphabetical,
    );
    expect(idsOf(original), ['a', 'b', 'c']);
  });

  test('an empty library stays empty rather than throwing', () {
    for (final scope in PlaylistScope.values) {
      for (final sort in PlaylistSort.values) {
        expect(
          arrangePlaylists(const [], scope: scope, sort: sort, userId: 'me'),
          isEmpty,
        );
      }
    }
  });
}
