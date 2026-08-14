import 'package:aurix/data/services/spotify_playlist_service.dart';
import 'package:aurix/data/services/spotify_user_service.dart';
import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';

/// Records what was actually sent, and answers 200 with an empty body.
///
/// The assertions here are all about the *shape of the request* — which verb,
/// which path, and whether `uris` went in the query string or the body — so a
/// recorder is more direct than a mock.
class _Recorder implements HttpClientAdapter {
  final List<RequestOptions> requests = [];

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<List<int>>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    requests.add(options);
    return ResponseBody.fromString(
      '{}',
      200,
      headers: {
        Headers.contentTypeHeader: [Headers.jsonContentType],
      },
    );
  }

  @override
  void close({bool force = false}) {}
}

void main() {
  late _Recorder recorder;
  late Dio dio;

  setUp(() {
    recorder = _Recorder();
    dio = Dio(BaseOptions(baseUrl: 'https://api.spotify.com/v1'))
      ..httpClientAdapter = recorder;
  });

  /// Every one of these encodes a detail that, got wrong, reproduces the exact
  /// failure this migration fixed: `✗ 403 PUT /me/tracks — Forbidden`.
  group('library writes go to /me/library', () {
    test('saving a track PUTs /me/library with a uris query parameter', () async {
      await SpotifyUserService(dio).saveTracks(['abc123']);

      expect(recorder.requests, hasLength(1));
      final request = recorder.requests.single;

      expect(request.method, 'PUT');
      expect(
        request.path,
        '/me/library',
        reason: 'PUT /me/tracks was removed for Development Mode apps in '
            'February 2026 and answers 403 unconditionally',
      );
      expect(
        request.queryParameters['uris'],
        'spotify:track:abc123',
        reason: 'the consolidated endpoint takes Spotify URIs, not bare IDs',
      );
      expect(
        request.data,
        isNull,
        reason: 'uris is a query parameter here; the old endpoint took '
            '{"ids": [...]} as a body, and sending one now is a 400',
      );
    });

    test('unsaving a track DELETEs the same path', () async {
      await SpotifyUserService(dio).removeTracks(['abc123']);

      final request = recorder.requests.single;
      expect(request.method, 'DELETE');
      expect(request.path, '/me/library');
      expect(request.queryParameters['uris'], 'spotify:track:abc123');
      expect(request.data, isNull);
    });

    test('albums use an album URI, not a track one', () async {
      await SpotifyUserService(dio).saveAlbums(['al1']);

      expect(recorder.requests.single.path, '/me/library');
      expect(recorder.requests.single.queryParameters['uris'], 'spotify:album:al1');
    });

    test('batches at 40, not at the old per-type limits', () async {
      // 50 was the tracks limit and 20 the albums limit on the endpoints this
      // replaced. The consolidated one caps at 40, so a 50-ID save that used to
      // be one request must now be two — sending 50 would be a flat 400.
      await SpotifyUserService(dio).saveTracks([
        for (var i = 0; i < 50; i++) 't$i',
      ]);

      expect(recorder.requests, hasLength(2));
      expect(
        (recorder.requests.first.queryParameters['uris'] as String).split(',').length,
        40,
      );
      expect(
        (recorder.requests.last.queryParameters['uris'] as String).split(',').length,
        10,
      );
    });

    test('drops empty IDs rather than sending "spotify:track:"', () async {
      // Local files carry no ID and reach this path through "save this track"
      // like anything else. One malformed URI 400s the whole batch.
      await SpotifyUserService(dio).saveTracks(['', 'real']);

      expect(recorder.requests.single.queryParameters['uris'], 'spotify:track:real');
    });

    test('sends nothing at all when every ID is empty', () async {
      await SpotifyUserService(dio).saveTracks(['', '']);
      expect(recorder.requests, isEmpty);
    });

    test('passes a value that is already a URI straight through', () async {
      await SpotifyUserService(dio).saveTracks(['spotify:track:xyz']);
      expect(recorder.requests.single.queryParameters['uris'], 'spotify:track:xyz');
    });
  });

  group('playlist follow', () {
    test('saving a playlist PUTs /me/library, not /playlists/{id}/followers',
        () async {
      await SpotifyPlaylistService(dio).follow('pl1');

      final request = recorder.requests.single;
      expect(request.method, 'PUT');
      expect(request.path, '/me/library');
      expect(request.queryParameters['uris'], 'spotify:playlist:pl1');
    });

    test('unfollowing DELETEs /me/library', () async {
      await SpotifyPlaylistService(dio).unfollow('pl1');

      final request = recorder.requests.single;
      expect(request.method, 'DELETE');
      expect(request.path, '/me/library');
      expect(request.queryParameters['uris'], 'spotify:playlist:pl1');
    });
  });
}
