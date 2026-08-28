import 'package:aurix/data/models/json_utils.dart';
import 'package:aurix/data/models/models.dart';
import 'package:flutter_test/flutter_test.dart';

import '../support/fixtures.dart';

/// A stand-in for `cloud_firestore`'s `Timestamp`.
///
/// `Json.timestamp` matches it structurally rather than by importing the
/// plugin, which is what lets these run under a plain `flutter test` with no
/// Firebase in the process. This class is the thing that duck-typing has to
/// accept, so it belongs in the test that proves it does.
class _FakeTimestamp {
  const _FakeTimestamp(this._value);
  final DateTime _value;
  DateTime toDate() => _value;
}

void main() {
  group('Track ↔ Firestore', () {
    test('reads a document into something the UI can render', () {
      final track = Fixtures.aurixTrack;

      expect(track.name, 'Midnight Signal');
      expect(track.artistNames, 'Neon Meridian');
      // The flat `album` and `artworkUrl` fields are synthesised into the
      // nested objects the screens read. This is what let every existing
      // screen keep working against Firestore data unchanged.
      expect(track.album?.name, 'Parallel Skies');
      expect(track.artworkUrl, 'https://cdn.example/album_640.jpg');
      expect(track.duration, const Duration(milliseconds: 214000));
    });

    test('round-trips through toDocument', () {
      final original = Fixtures.importedTrack;
      final restored = Track.fromDocument(original.id, original.toDocument());

      expect(restored.name, original.name);
      expect(restored.artistNames, original.artistNames);
      expect(restored.album?.name, original.album?.name);
      expect(restored.artworkUrl, original.artworkUrl);
      expect(restored.source, MediaSource.spotify);
      expect(restored.spotifyId, 'track_1');
      expect(restored.documentId, original.documentId);
    });

    test('toDocument does not write createdAt', () {
      // It is a server timestamp and belongs to the write path. A client clock
      // value here would let a device with the wrong time reorder a library.
      expect(Fixtures.aurixTrack.toDocument().containsKey('createdAt'), isFalse);
    });

    test('spotifyUri is null for a track AURIX owns', () {
      // The whole reason the getter became nullable. `spotify:track:aurix_slug`
      // addresses nothing, and sending it to a Connect device fails as an
      // opaque 404 several layers from the cause.
      expect(Fixtures.aurixTrack.spotifyUri, isNull);
      expect(Fixtures.aurixTrack.isConnectPlayable, isFalse);

      expect(Fixtures.importedTrack.spotifyUri, 'spotify:track:track_1');
      expect(Fixtures.importedTrack.isConnectPlayable, isTrue);
    });

    test('a Spotify payload carries its provenance from the moment it parses',
        () {
      final track = Fixtures.track;
      expect(track.source, MediaSource.spotify);
      expect(track.spotifyId, track.id);
    });

    test('a missing field degrades that field, not the document', () {
      // Documents are written by whichever build was installed at the time,
      // and old builds are still out there.
      final sparse = Track.fromDocument('aurix_x', const <String, dynamic>{
        'title': 'Just A Title',
      });
      expect(sparse.name, 'Just A Title');
      expect(sparse.artistNames, 'Unknown artist');
      expect(sparse.durationMs, 0);
      expect(sparse.album, isNull);
    });
  });

  group('Json.timestamp', () {
    test('accepts a Firestore Timestamp', () {
      final when = DateTime.utc(2026, 3, 4, 5, 6);
      expect(
        Json.timestamp(<String, dynamic>{'t': _FakeTimestamp(when)}, 't'),
        when,
      );
    });

    test('accepts null for a server timestamp that has not landed yet', () {
      // The local echo of a `FieldValue.serverTimestamp()` write carries null.
      // Throwing here would break a row on the very frame it appears.
      expect(Json.timestamp(<String, dynamic>{'t': null}, 't'), isNull);
    });

    test('accepts epoch milliseconds and ISO strings', () {
      final when = DateTime.utc(2026, 3, 4);
      expect(
        Json.timestamp(
          <String, dynamic>{'t': when.millisecondsSinceEpoch},
          't',
        )?.toUtc(),
        when,
      );
      // What the pre-Firebase MetadataCache wrote, which the migration reads.
      expect(
        Json.timestamp(<String, dynamic>{'t': when.toIso8601String()}, 't'),
        when,
      );
    });

    test('answers null rather than throwing on a shape it does not know', () {
      expect(Json.timestamp(<String, dynamic>{'t': <int>[1, 2]}, 't'), isNull);
    });
  });

  group('Playlist ↔ Firestore', () {
    test('reads a document', () {
      final playlist = Fixtures.aurixPlaylist;
      expect(playlist.name, 'Late Drive');
      expect(playlist.imageUrl, 'https://cdn.example/playlist_640.jpg');
      expect(playlist.trackCount, 2);
      expect(playlist.source, MediaSource.aurix);
    });

    test('toDocument leaves the write path its own fields', () {
      final data = Fixtures.aurixPlaylist.toDocument();
      // All three are maintained by the transaction that changes membership.
      // Carrying a stale value in from a model could overwrite a correct one.
      expect(data.containsKey('trackCount'), isFalse);
      expect(data.containsKey('createdAt'), isFalse);
      expect(data.containsKey('updatedAt'), isFalse);
    });

    test('an AURIX playlist is editable and has no Spotify URI', () {
      final playlist = Fixtures.aurixPlaylist;
      // The path is the ownership claim: everything under /users/{uid} is the
      // user's, and the rules enforce it.
      expect(playlist.isEditableBy(null), isTrue);
      expect(playlist.spotifyUri, isNull);
    });

    test('an imported playlist remembers where it came from', () {
      final imported = Playlist.fromDocument('p1', <String, dynamic>{
        ...Fixtures.aurixPlaylistData,
        'source': 'spotify',
        'sourceId': 'spotify_playlist_9',
      });
      expect(imported.source, MediaSource.spotify);
      expect(imported.sourceId, 'spotify_playlist_9');
      expect(imported.spotifyUri, 'spotify:playlist:spotify_playlist_9');
      // Which is what the "Imported from Spotify" line on the detail screen
      // and the re-import lookup both read.
      expect(imported.ownerName, 'Spotify');
    });
  });

  group('MediaSource', () {
    test('parses the wire values it writes', () {
      for (final source in MediaSource.values) {
        expect(MediaSource.parse(source.wireValue), source);
      }
    });

    test('an unknown value becomes aurix rather than null', () {
      // A document written by a newer build that knows a provider this one
      // does not must still render as the user's own data. Refusing to parse
      // it would hide their library from them after a downgrade.
      expect(MediaSource.parse('tidal'), MediaSource.aurix);
      expect(MediaSource.parse(null), MediaSource.aurix);
      expect(MediaSource.parse(42), MediaSource.aurix);
    });
  });

  group('AurixUser', () {
    test('falls back to the email local part when there is no name', () {
      const user = AurixUser(uid: 'u', name: '', email: 'alex@example.com');
      expect(user.displayName, 'alex');
      expect(user.initial, 'A');
    });

    test('sanitises an unknown avatar id on the way in', () {
      // An id with no bundled asset behind it would render as an empty circle
      // on every profile surface. The read is the last place to catch it.
      final user = AurixUser.fromDocument('u', const <String, dynamic>{
        'name': 'Test',
        'email': 't@example.com',
        'avatarId': 'avatar_999',
      });
      expect(user.avatarId, AvatarCatalog.defaultId);
      expect(user.avatarAssetPath, AvatarResolver.getAssetPath(null));
    });
  });
}
