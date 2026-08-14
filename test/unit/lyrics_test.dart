import 'dart:convert';

import 'package:aurix/data/models/artist.dart';
import 'package:aurix/data/models/track.dart';
import 'package:aurix/data/repositories/lyrics_repository.dart';
import 'package:aurix/data/services/lyrics_service.dart';
import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';

/// Serves canned LRCLIB responses and counts what was asked.
class _FakeLrcLib implements HttpClientAdapter {
  _FakeLrcLib(this.handler);

  final Object? Function(RequestOptions options) handler;
  final List<RequestOptions> requests = [];

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<List<int>>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    requests.add(options);
    final body = handler(options);
    if (body == null) {
      return ResponseBody.fromString(
        '{"code":404,"name":"TrackNotFound","message":"not found"}',
        404,
        headers: {
          Headers.contentTypeHeader: [Headers.jsonContentType],
        },
      );
    }
    return ResponseBody.fromString(
      _json(body),
      200,
      headers: {
        Headers.contentTypeHeader: [Headers.jsonContentType],
      },
    );
  }

  @override
  void close({bool force = false}) {}
}

String _json(Object value) => value is String ? value : jsonEncode(value);

Track _track({
  String id = 't1',
  String name = 'Finding Her',
  String artist = 'Kushagra',
  int durationMs = 180000,
  bool isLocal = false,
}) => Track(
  id: id,
  name: name,
  artists: <Artist>[Artist(id: 'a1', name: artist)],
  durationMs: durationMs,
  isLocal: isLocal,
);

LrcLibLyricsService _service(_FakeLrcLib adapter) {
  final dio = Dio(
    BaseOptions(
      baseUrl: 'https://lrclib.net',
      validateStatus: (s) => s != null && (s < 400 || s == 404),
    ),
  )..httpClientAdapter = adapter;
  return LrcLibLyricsService(client: dio);
}

void main() {
  group('LRC parsing', () {
    test('reads timestamps and marks the result synced', () async {
      final adapter = _FakeLrcLib(
        (_) => <String, Object?>{
          'instrumental': false,
          'syncedLyrics': '[00:01.63] first\n[00:12.50] second\n[01:05.00] third',
        },
      );

      final lyrics = await _service(adapter).fetch(
        const LyricsQuery(trackId: 't1', title: 'x', artist: 'y'),
      );

      expect(lyrics, isNotNull);
      expect(lyrics!.isSynced, isTrue);
      expect(lyrics.lines.map((l) => l.text), ['first', 'second', 'third']);
      expect(lyrics.lines[0].at, const Duration(milliseconds: 1630));
      expect(lyrics.lines[1].at, const Duration(seconds: 12, milliseconds: 500));
      expect(lyrics.lines[2].at, const Duration(minutes: 1, seconds: 5));
    });

    test('scales the fraction by its own width', () async {
      // `.5` is half a second, not five milliseconds. Reading it as hundredths
      // would put every line 450ms early.
      final adapter = _FakeLrcLib(
        (_) => <String, Object?>{'syncedLyrics': '[00:10.5] a\n[00:20.250] b'},
      );

      final lyrics = await _service(adapter).fetch(
        const LyricsQuery(trackId: 't1', title: 'x', artist: 'y'),
      );

      expect(lyrics!.lines[0].at, const Duration(seconds: 10, milliseconds: 500));
      expect(lyrics.lines[1].at, const Duration(seconds: 20, milliseconds: 250));
    });

    test('sorts out-of-order lines, because lineIndexAt binary-searches',
        () async {
      final adapter = _FakeLrcLib(
        (_) => <String, Object?>{'syncedLyrics': '[00:30.00] late\n[00:10.00] early'},
      );

      final lyrics = await _service(adapter).fetch(
        const LyricsQuery(trackId: 't1', title: 'x', artist: 'y'),
      );

      expect(lyrics!.lines.map((l) => l.text), ['early', 'late']);
    });

    test('a repeated line with several timestamps becomes several entries',
        () async {
      final adapter = _FakeLrcLib(
        (_) => <String, Object?>{'syncedLyrics': '[00:10.00][01:10.00] chorus'},
      );

      final lyrics = await _service(adapter).fetch(
        const LyricsQuery(trackId: 't1', title: 'x', artist: 'y'),
      );

      expect(lyrics!.lines, hasLength(2));
      expect(lyrics.lines.every((l) => l.text == 'chorus'), isTrue);
      expect(lyrics.lines[1].at, const Duration(minutes: 1, seconds: 10));
    });

    test('falls back to plain lyrics when there are no timestamps', () async {
      final adapter = _FakeLrcLib(
        (_) => <String, Object?>{'plainLyrics': 'one\ntwo', 'syncedLyrics': null},
      );

      final lyrics = await _service(adapter).fetch(
        const LyricsQuery(trackId: 't1', title: 'x', artist: 'y'),
      );

      expect(lyrics!.isSynced, isFalse);
      expect(lyrics.asText, 'one\ntwo');
      expect(lyrics.lines.every((l) => l.at == null), isTrue);
    });

    test('an instrumental is a state, not an empty result', () async {
      final adapter = _FakeLrcLib((_) => <String, Object?>{'instrumental': true});

      final lyrics = await _service(adapter).fetch(
        const LyricsQuery(trackId: 't1', title: 'x', artist: 'y'),
      );

      expect(lyrics!.isInstrumental, isTrue);
      expect(lyrics.isEmpty, isTrue);
    });
  });

  group('lineIndexAt', () {
    const lyrics = Lyrics(
      provider: 'test',
      isSynced: true,
      lines: [
        LyricLine(text: 'a', at: Duration(seconds: 10)),
        LyricLine(text: 'b', at: Duration(seconds: 20)),
        LyricLine(text: 'c', at: Duration(seconds: 30)),
      ],
    );

    test('is -1 before the first line', () {
      expect(lyrics.lineIndexAt(const Duration(seconds: 5)), -1);
    });

    test('holds a line until the next one starts', () {
      expect(lyrics.lineIndexAt(const Duration(seconds: 10)), 0);
      expect(lyrics.lineIndexAt(const Duration(seconds: 19)), 0);
      expect(lyrics.lineIndexAt(const Duration(seconds: 20)), 1);
    });

    test('stays on the last line past the end', () {
      expect(lyrics.lineIndexAt(const Duration(minutes: 9)), 2);
    });

    test('is -1 for unsynced lyrics however far in', () {
      const plain = Lyrics(
        provider: 'test',
        lines: [LyricLine(text: 'a')],
      );
      expect(plain.lineIndexAt(const Duration(seconds: 30)), -1);
    });
  });

  group('duration matching', () {
    test('rejects a search hit whose length is nothing like the track', () async {
      // Same title and artist, wrong song. Better no lyrics than lyrics that
      // drift further out of sync the longer it plays.
      final adapter = _FakeLrcLib((options) {
        if (options.path.contains('/api/get')) return null;
        return <Object?>[
          <String, Object?>{
            'duration': 400,
            'plainLyrics': 'wrong song',
          },
        ];
      });

      final lyrics = await _service(adapter).fetch(
        const LyricsQuery(
          trackId: 't1',
          title: 'x',
          artist: 'y',
          duration: Duration(seconds: 180),
        ),
      );

      expect(lyrics, isNull);
    });

    test('accepts a hit within tolerance and prefers the closest', () async {
      final adapter = _FakeLrcLib((options) {
        if (options.path.contains('/api/get')) return null;
        return <Object?>[
          <String, Object?>{'duration': 195, 'plainLyrics': 'further'},
          <String, Object?>{'duration': 181, 'plainLyrics': 'closest'},
        ];
      });

      final lyrics = await _service(adapter).fetch(
        const LyricsQuery(
          trackId: 't1',
          title: 'x',
          artist: 'y',
          duration: Duration(seconds: 180),
        ),
      );

      expect(lyrics!.asText, 'closest');
    });
  });

  group('LyricsRepository', () {
    test('caches a hit, so reopening the sheet costs no request', () async {
      var calls = 0;
      final adapter = _FakeLrcLib((_) {
        calls++;
        return <String, Object?>{'plainLyrics': 'words'};
      });
      final repository = LyricsRepository(provider: _service(adapter));

      await repository.forTrack(_track());
      await repository.forTrack(_track());

      expect(calls, 1);
    });

    test('caches a miss too — a track with no lyrics is not re-requested',
        () async {
      var calls = 0;
      final adapter = _FakeLrcLib((_) {
        calls++;
        return null; // 404 from both /get and /search
      });
      final repository = LyricsRepository(provider: _service(adapter));

      expect(await repository.forTrack(_track()), isNull);
      expect(await repository.forTrack(_track()), isNull);

      // Two per lookup (exact then search), and only one lookup.
      expect(calls, 2);
    });

    test('de-duplicates concurrent lookups for the same track', () async {
      var calls = 0;
      final adapter = _FakeLrcLib((_) {
        calls++;
        return <String, Object?>{'plainLyrics': 'words'};
      });
      final repository = LyricsRepository(provider: _service(adapter));

      // The strip on the player and the sheet opened over it, same frame.
      await Future.wait<Lyrics?>([
        repository.forTrack(_track()),
        repository.forTrack(_track()),
      ]);

      expect(calls, 1);
    });

    test('never asks about a local file', () async {
      var calls = 0;
      final adapter = _FakeLrcLib((_) {
        calls++;
        return <String, Object?>{'plainLyrics': 'words'};
      });
      final repository = LyricsRepository(provider: _service(adapter));

      expect(await repository.forTrack(_track(isLocal: true)), isNull);
      expect(calls, 0);
    });

    test('peek never triggers a fetch', () async {
      var calls = 0;
      final adapter = _FakeLrcLib((_) {
        calls++;
        return <String, Object?>{'plainLyrics': 'words'};
      });
      final repository = LyricsRepository(provider: _service(adapter));

      expect(repository.peek('t1'), isNull);
      expect(calls, 0);
    });
  });
}
