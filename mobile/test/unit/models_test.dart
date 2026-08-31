import 'package:aurix/data/models/models.dart';
import 'package:flutter_test/flutter_test.dart';

import '../support/fixtures.dart';

void main() {
  group('Track', () {
    test('parses a full track', () {
      final track = Fixtures.track;
      expect(track.id, 'track_1');
      expect(track.name, 'Afterglow');
      expect(track.duration, const Duration(milliseconds: 213000));
      expect(track.artistNames, 'Neon Meridian');
      expect(track.hasPreview, isTrue);
      expect(track.spotifyUri, 'spotify:track:track_1');
    });

    test('treats a null preview_url as "no preview", not an error', () {
      final track = Fixtures.trackWithoutPreview;
      expect(track.previewUrl, isNull);
      expect(track.hasPreview, isFalse);
      // It is still addressable through Spotify Connect.
      expect(track.isConnectPlayable, isTrue);
    });

    test('a local file is neither previewable nor Connect-playable', () {
      final track = Fixtures.localTrack;
      expect(track.isLocal, isTrue);
      expect(track.hasPreview, isFalse);
      expect(track.isConnectPlayable, isFalse);
    });

    test('withAlbum fills a missing album but never overwrites one', () {
      final album = Fixtures.album;
      // Tracks from /albums/{id}/tracks arrive with no album field.
      final bare = Track.fromJson(Fixtures.trackJson);
      expect(bare.album, isNull);
      expect(bare.withAlbum(album).album?.id, 'album_1');

      final withAlbum = bare.withAlbum(album);
      final other = Album.fromJson(Fixtures.yearPrecisionAlbumJson);
      expect(withAlbum.withAlbum(other).album?.id, 'album_1');
    });

    test('survives a response missing every optional field', () {
      final track = Track.fromJson(const <String, dynamic>{'id': 'x', 'name': 'y'});
      expect(track.durationMs, 0);
      expect(track.artists, isEmpty);
      expect(track.artistNames, '');
      expect(track.album, isNull);
      expect(track.spotifyUri, 'spotify:track:x');
    });

    test('round-trips through toJson', () {
      final restored = Track.fromJson(Fixtures.track.toJson());
      expect(restored.id, Fixtures.track.id);
      expect(restored.durationMs, Fixtures.track.durationMs);
      expect(restored.previewUrl, Fixtures.track.previewUrl);
    });
  });

  group('Album', () {
    test('parses a full album with its first track page', () {
      final album = Fixtures.album;
      expect(album.name, 'Parallel Skies');
      expect(album.totalTracks, 3);
      expect(album.tracks?.items.length, 3);
      expect(album.isSimplified, isFalse);
      expect(album.label, 'Meridian Records');
      expect(album.copyrights.single, '© 2023 Meridian Records');
    });

    test('a simplified album reports itself as such', () {
      final album = Album.fromJson(Fixtures.albumWithoutTracksJson);
      expect(album.tracks, isNull);
      expect(album.isSimplified, isTrue);
    });

    test('album_group beats album_type when both are present', () {
      // The artist discography endpoint uses album_group to mark "appears on";
      // reading album_type there mislabels compilations.
      final album = Album.fromJson(<String, dynamic>{
        ...Fixtures.albumJson,
        'album_type': 'album',
        'album_group': 'appears_on',
      });
      expect(album.albumType, AlbumType.appearsOn);
    });

    test('totalDuration is null until every track is loaded', () {
      final partial = Album.fromJson(<String, dynamic>{
        ...Fixtures.albumJson,
        'total_tracks': 12,
      });
      expect(partial.totalDuration, isNull);

      expect(Fixtures.album.totalDuration, isNotNull);
      expect(
        Fixtures.album.totalDuration,
        const Duration(milliseconds: 213000 + 187000 + 245000),
      );
    });

    test('releaseYear works at year precision', () {
      final album = Album.fromJson(Fixtures.yearPrecisionAlbumJson);
      expect(album.releaseYear, '1978');
      expect(album.releaseDatePrecision, 'year');
    });
  });

  group('Playlist', () {
    test('parses items and keeps the snapshot id', () {
      final playlist = Fixtures.playlist;
      expect(playlist.name, 'Night Drive');
      expect(playlist.snapshotId, 'snap_abc123');
      expect(playlist.followers, 42150);
      expect(playlist.items?.items.length, 3);
    });

    test('a null track becomes an unplayable item rather than a crash', () {
      final items = Fixtures.playlist.items!.items;
      expect(items[1].track, isNull);
      expect(items[1].isPlayable, isFalse);
    });

    test('playableTracks excludes null and local entries', () {
      // Three items: one real, one null, one local file.
      expect(Fixtures.playlist.playableTracks.length, 1);
      expect(Fixtures.playlist.playableTracks.single.id, 'track_1');
    });

    test('isEditableBy is true for the owner and for collaborative lists', () {
      expect(Fixtures.playlist.isEditableBy('user_owner'), isTrue);
      expect(Fixtures.playlist.isEditableBy('someone_else'), isFalse);
      expect(Fixtures.playlist.isEditableBy(null), isFalse);

      final collaborative = Playlist.fromJson(<String, dynamic>{
        ...Fixtures.playlistJson,
        'collaborative': true,
      });
      expect(collaborative.isEditableBy('someone_else'), isTrue);
    });

    test('a simplified playlist has a track count but no items', () {
      final simplified = Playlist.fromJson(<String, dynamic>{
        ...Fixtures.playlistJson,
        'tracks': const {'href': 'https://api.spotify.com/…', 'total': 87},
      });
      expect(simplified.trackCount, 87);
      expect(simplified.items, isNull);
      expect(simplified.isSimplified, isTrue);
    });
  });

  group('Artist', () {
    test('parses a full artist', () {
      final artist = Fixtures.artist;
      expect(artist.followers, 1284000);
      expect(artist.genres, contains('synthwave'));
      expect(artist.isSimplified, isFalse);
      expect(artist.isHighProfile, isTrue);
    });

    test('a nested artist reference is flagged as simplified', () {
      final artist = Artist.fromJson(Fixtures.simplifiedArtistJson);
      expect(artist.isSimplified, isTrue);
      expect(artist.popularity, isNull);
      expect(artist.imageUrl, isNull);
    });
  });

  group('UserProfile', () {
    test('parses product tier and market', () {
      final user = Fixtures.user;
      expect(user.product, SpotifyProduct.premium);
      expect(user.hasPremium, isTrue);
      expect(user.country, 'GB');
      expect(user.initial, 'S');
    });

    test('a free account cannot control playback', () {
      final user = UserProfile.fromJson(Fixtures.freeUserJson);
      expect(user.product, SpotifyProduct.free);
      expect(user.hasPremium, isFalse);
      // Spotify said so, so naming Premium as the obstacle is accurate.
      expect(user.knownNonPremium, isTrue);
    });

    group('an unreported product tier', () {
      // Development Mode apps stopped receiving `product` on /me in February
      // 2026. "Spotify did not say" must not be read as "not Premium", or the
      // device picker tells Premium subscribers that Premium is the problem
      // and hides the "open Spotify on a device" step that actually helps.
      test('is unknown, not free', () {
        final user = UserProfile.fromJson(Fixtures.devModeUserJson);
        expect(user.product, SpotifyProduct.unknown);
        expect(user.product.isKnown, isFalse);
      });

      test('does not claim Connect is available', () {
        final user = UserProfile.fromJson(Fixtures.devModeUserJson);
        expect(user.hasPremium, isFalse);
      });

      test('does not blame Premium either', () {
        final user = UserProfile.fromJson(Fixtures.devModeUserJson);
        expect(user.knownNonPremium, isFalse);
      });

      test('a premium account is still recognised when reported', () {
        final user = Fixtures.user;
        expect(user.product.isKnown, isTrue);
        expect(user.hasPremium, isTrue);
        expect(user.knownNonPremium, isFalse);
      });
    });

    test('falls back to the user id when display_name is absent', () {
      // Playlist owners frequently have no display name.
      final user = UserProfile.fromJson(const <String, dynamic>{'id': 'abc123'});
      expect(user.displayName, 'abc123');
    });

    group('explicit_content', () {
      test('parses an unfiltered account', () {
        final user = Fixtures.user;
        expect(user.explicitContent, isNotNull);
        expect(user.explicitContent!.filterEnabled, isFalse);
        expect(user.explicitContent!.filterLocked, isFalse);
        expect(user.explicitContent!.allowsExplicit, isTrue);
        expect(user.explicitContent!.isUserChangeable, isTrue);
        expect(user.filtersExplicitContent, isFalse);
        expect(user.explicitFilterLocked, isFalse);
      });

      test('parses a filtered and locked account', () {
        final user = UserProfile.fromJson(Fixtures.filterLockedUserJson);
        expect(user.filtersExplicitContent, isTrue);
        expect(user.explicitFilterLocked, isTrue);
        expect(user.explicitContent!.allowsExplicit, isFalse);
        expect(user.explicitContent!.isUserChangeable, isFalse);
      });

      test(
        'is null when Spotify omits it, and is not mistaken for "filtered"',
        () {
          // Development Mode apps stopped receiving explicit_content on /me in
          // February 2026. Defaulting that to "filtered" would hide explicit
          // tracks from every such user.
          final user = UserProfile.fromJson(Fixtures.devModeUserJson);
          expect(user.explicitContent, isNull);
          expect(user.filtersExplicitContent, isFalse);
          expect(user.explicitFilterLocked, isFalse);
        },
      );

      test('survives a round trip through the cache', () {
        final original = UserProfile.fromJson(Fixtures.filterLockedUserJson);
        final restored = UserProfile.fromJson(original.toJson());
        expect(restored.explicitContent, original.explicitContent);
      });

      test('omits the key entirely when absent, preserving "unknown"', () {
        final user = UserProfile.fromJson(Fixtures.devModeUserJson);
        expect(user.toJson().containsKey('explicit_content'), isFalse);
        expect(UserProfile.fromJson(user.toJson()).explicitContent, isNull);
      });
    });
  });

  group('SpotifyImage selection', () {
    test('picks the smallest rendition that meets the requested size', () {
      final images = Fixtures.artist.images;
      expect(images.bestFor(300), contains('artist_300'));
      expect(images.bestFor(64), contains('artist_64'));
      expect(images.largestUrl, contains('artist_640'));
      expect(images.smallestUrl, contains('artist_64'));
    });

    test('falls back to the largest when nothing is big enough', () {
      expect(Fixtures.artist.images.bestFor(2000), contains('artist_640'));
    });

    test('handles an empty image list', () {
      expect(const <SpotifyImage>[].largestUrl, isNull);
      expect(const <SpotifyImage>[].bestFor(300), isNull);
    });
  });

  group('Paging', () {
    test('append merges items and adopts the newer page metadata', () {
      const first = Paging<String>(
        items: ['a', 'b'],
        total: 4,
        limit: 2,
        offset: 0,
        next: 'https://api.spotify.com/next',
      );
      const second = Paging<String>(
        items: ['c', 'd'],
        total: 4,
        limit: 2,
        offset: 2,
      );

      final merged = first.append(second);
      expect(merged.items, ['a', 'b', 'c', 'd']);
      expect(merged.offset, 2);
      expect(merged.hasMore, isFalse);
    });

    test('drops malformed rows instead of failing the page', () {
      final page = Paging<Track>.fromJson(<String, dynamic>{
        'items': [
          Fixtures.trackJson,
          'not an object',
          null,
          Fixtures.explicitTrackJson,
        ],
        'total': 4,
        'limit': 20,
        'offset': 0,
      }, Track.fromJson);

      expect(page.items.length, 2);
      expect(page.total, 4);
    });
  });

  group('RemotePlaybackState', () {
    test('extrapolates progress between polls', () {
      final now = DateTime.now();
      final state = RemotePlaybackState(
        isPlaying: true,
        track: Fixtures.track,
        progressMs: 10000,
        timestamp: now.subtract(const Duration(seconds: 3)),
      );

      final progress = state.progressAt(now);
      expect(progress.inSeconds, closeTo(13, 1));
    });

    test('does not advance while paused', () {
      final now = DateTime.now();
      final state = RemotePlaybackState(
        track: Fixtures.track,
        progressMs: 10000,
        timestamp: now.subtract(const Duration(seconds: 30)),
      );
      expect(state.progressAt(now), const Duration(seconds: 10));
    });

    test('never extrapolates past the track length', () {
      final now = DateTime.now();
      final state = RemotePlaybackState(
        isPlaying: true,
        track: Fixtures.track,
        progressMs: 210000,
        timestamp: now.subtract(const Duration(minutes: 5)),
      );
      expect(state.progressAt(now), Fixtures.track.duration);
    });

    test('a podcast episode is treated as nothing to display', () {
      final state = RemotePlaybackState.fromJson(const <String, dynamic>{
        'is_playing': true,
        'item': {'id': 'ep_1', 'name': 'Episode 1', 'type': 'episode'},
      });
      expect(state.track, isNull);
    });
  });

  group('SpotifyDevice', () {
    test('a restricted device is not controllable', () {
      final device = SpotifyDevice.fromJson(Fixtures.restrictedDeviceJson);
      expect(device.isRestricted, isTrue);
      expect(device.isControllable, isFalse);
    });

    test('a device with no id cannot be addressed', () {
      final device = SpotifyDevice.fromJson(const <String, dynamic>{
        'id': null,
        'name': 'Unknown',
        'type': 'Speaker',
      });
      expect(device.isControllable, isFalse);
    });
  });

  group('SearchResults', () {
    test('parses every section', () {
      final results = SearchResults.fromJson(Fixtures.searchResponseJson);
      expect(results.tracks.items.length, 2);
      expect(results.artists.items.length, 1);
      expect(results.albums.items.length, 1);
      expect(results.playlists.items.length, 1);
      expect(results.populatedTypes.length, 4);
    });

    test('prefers a popular artist as the top result', () {
      final results = SearchResults.fromJson(Fixtures.searchResponseJson);
      expect(results.topResult, isA<Artist>());
    });

    test('appendPage extends only the matching section', () {
      final results = SearchResults.fromJson(Fixtures.searchResponseJson);
      final page = SearchResults.fromJson(<String, dynamic>{
        'tracks': {
          'items': [Fixtures.explicitTrackJson],
          'total': 3,
          'limit': 20,
          'offset': 2,
        },
      });

      final merged = results.appendPage(SearchType.track, page);
      expect(merged.tracks.items.length, 3);
      expect(merged.artists.items.length, 1);
    });

    test('an all-empty response is reported as empty', () {
      expect(SearchResults.fromJson(const <String, dynamic>{}).isEmpty, isTrue);
    });
  });

  group('AuthSession', () {
    test('keeps the previous refresh token when a refresh omits one', () {
      // Spotify's refresh response may leave out refresh_token, meaning "keep
      // the one you have". Dropping it logs the user out an hour later.
      final session = AuthSession.fromTokenResponse(
        const <String, dynamic>{
          'access_token': 'new_access',
          'expires_in': 3600,
          'scope': 'user-read-private user-library-read',
        },
        previousRefreshToken: 'original_refresh',
      );

      expect(session.refreshToken, 'original_refresh');
      expect(session.accessToken, 'new_access');
      expect(session.scopes.length, 2);
    });

    test('a rotated refresh token replaces the old one', () {
      final session = AuthSession.fromTokenResponse(
        const <String, dynamic>{
          'access_token': 'a',
          'refresh_token': 'rotated',
          'expires_in': 3600,
          'scope': '',
        },
        previousRefreshToken: 'original',
      );
      expect(session.refreshToken, 'rotated');
    });

    test('needsRefresh fires before hard expiry', () {
      final almostExpired = AuthSession(
        accessToken: 'a',
        expiresAt: DateTime.now().add(const Duration(seconds: 30)),
        refreshToken: 'r',
      );
      expect(almostExpired.isExpired, isFalse);
      // Still valid, but close enough that a slow request could outlive it.
      expect(almostExpired.needsRefresh, isTrue);
    });

    test('a fresh session does not need refreshing', () {
      final fresh = AuthSession(
        accessToken: 'a',
        expiresAt: DateTime.now().add(const Duration(minutes: 55)),
      );
      expect(fresh.needsRefresh, isFalse);
      expect(fresh.isValid, isTrue);
      expect(fresh.canRefresh, isFalse);
    });
  });
}
