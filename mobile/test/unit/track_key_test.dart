import 'package:aurix/data/models/models.dart';
import 'package:flutter_test/flutter_test.dart';

import '../support/fixtures.dart';

/// [TrackKey] decides what "the same song" means in Firestore.
///
/// Three behaviours depend on it and all three are silent when it is wrong —
/// which is why it is tested directly rather than through the screens:
///
///  * liking a song twice must address one document, not two;
///  * re-importing a playlist must update its rows, not duplicate them;
///  * the same song in Liked Songs and in a playlist must be one identity.
void main() {
  group('TrackKey', () {
    test('a Spotify track keys on its Spotify id', () {
      final track = Fixtures.importedTrack;
      expect(TrackKey.of(track), 'spotify_track_1');
    });

    test('keys are provider-qualified', () {
      // The same id string from two services must not collide. Unqualified
      // keys would merge two unrelated songs into one document, and the user
      // would see one of them vanish.
      expect(
        TrackKey.forProvider(MediaSource.spotify, 'abc'),
        isNot(TrackKey.forProvider(MediaSource.youtube, 'abc')),
      );
    });

    test('a track with no provider id keys on its title and artist', () {
      const key = 'aurix_midnight-signal-neon-meridian';
      expect(
        TrackKey.forMetadata(title: 'Midnight Signal', artist: 'Neon Meridian'),
        key,
      );
      expect(Fixtures.aurixTrack.documentId, key);
    });

    test('metadata keys ignore case and whitespace differences', () {
      // Two rows for the same song, typed differently by two import sources,
      // should be one row in the library.
      expect(
        TrackKey.forMetadata(title: 'Midnight  Signal', artist: 'NEON Meridian'),
        TrackKey.forMetadata(title: 'midnight signal', artist: 'neon meridian'),
      );
    });

    test('a key already ours passes through unchanged', () {
      // A track read back out of Firestore and re-saved must keep its document
      // rather than being re-derived into a near-miss.
      final fromStore = Fixtures.aurixTrack;
      expect(TrackKey.of(fromStore), fromStore.id);
    });

    test('strips characters Firestore rejects in a document id', () {
      final key = TrackKey.forMetadata(
        title: 'A/B: "Test" — Part 1',
        artist: 'Someone & Co.',
      );
      expect(key.contains('/'), isFalse);
      expect(key.contains('"'), isFalse);
      expect(key.startsWith('aurix_'), isTrue);
    });

    test('never produces an empty id', () {
      // An empty document id is rejected by Firestore at the write, which
      // would fail one row of an import with no obvious cause.
      final key = TrackKey.forMetadata(title: '   ', artist: '');
      expect(key, isNotEmpty);
      expect(key, 'aurix_untitled');
    });

    test('caps length so a long title cannot break the write', () {
      final key = TrackKey.forMetadata(
        title: 'x' * 4000,
        artist: 'y' * 4000,
      );
      // Firestore's limit is 1500 bytes; well under it with room for
      // multi-byte characters.
      expect(key.length, lessThanOrEqualTo(210));
    });

    test('providerIdIn is the inverse of forProvider', () {
      final key = TrackKey.forProvider(MediaSource.spotify, '4uLU6hMC');
      expect(TrackKey.providerIdIn(key, MediaSource.spotify), '4uLU6hMC');
      // And answers null for the wrong provider rather than a wrong id.
      expect(TrackKey.providerIdIn(key, MediaSource.youtube), isNull);
    });

    test('the same song liked and in a playlist is one identity', () {
      // The property the whole scheme exists for.
      final fromLiked = Fixtures.importedTrack;
      final fromPlaylist = Track.fromDocument('some_other_doc_id', {
        ...Fixtures.aurixTrackData,
        'source': 'spotify',
        'sourceId': 'track_1',
        'spotifyId': 'track_1',
      });
      expect(fromLiked.documentId, fromPlaylist.documentId);
    });
  });
}
