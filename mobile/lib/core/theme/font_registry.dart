import 'dart:async';
import 'dart:io';

import 'package:dio/dio.dart' show Options, ResponseType;
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:path_provider/path_provider.dart';

import '../network/aurix_api_client.dart';
import '../utils/app_logger.dart';

/// Makes an administrator's chosen font family renderable.
///
/// ## The problem
///
/// Flutter resolves `TextStyle.fontFamily` against fonts declared in
/// `pubspec.yaml` at build time. A family an administrator picks *after* the app
/// shipped is not in that manifest, so naming it in a `TextStyle` silently falls
/// through to the platform default — which is not an error and looks exactly
/// like a bug.
///
/// [FontLoader] is the escape hatch: it registers a family from bytes at
/// runtime. This class is what feeds it.
///
/// ## Three sources, in order
///
///  1. **Bundled.** Manrope ships in the app. It always works, offline
///     included, and is the guaranteed fallback.
///  2. **Cached.** A font downloaded on a previous launch is written to the
///     application support directory and read from there. This is what makes a
///     custom font survive being offline, and it is why the download happens
///     once per font rather than once per launch.
///  3. **Downloaded.** Fetched from the API's asset route, registered, and
///     cached for next time.
///
/// ## What happens while a font is loading
///
/// The previous face keeps rendering. That is deliberate and is the one
/// behaviour worth defending here: swapping to the platform default for the
/// second or two a download takes would reflow every screen — different
/// metrics, different line breaks — and then reflow it back. A theme that
/// arrives one frame late is invisible; a double reflow is not.
///
/// So [ensure] returns the family the app should actually *use right now*, and
/// the controller re-renders when it later resolves to the requested one.
class FontRegistry {
  FontRegistry({required AurixApiClient client}) : _client = client;

  final AurixApiClient _client;

  /// Families that ship inside the app.
  ///
  /// Add a family here *and* to the `fonts:` block in `pubspec.yaml` — one
  /// without the other is the failure this set exists to make obvious. Anything
  /// not listed is expected to arrive from the server.
  static const Set<String> bundled = <String>{
    'Manrope',
    'Inter',
    'Roboto',
    'Montserrat',
    'Oswald',
    'Poppins',
  };

  /// The face used when nothing else is available. Always bundled.
  static const String fallbackFamily = 'Manrope';

  /// Families successfully registered this session, bundled ones included.
  final Set<String> _ready = <String>{...bundled};

  /// In-flight loads, so two widgets asking for the same family at once
  /// produce one download rather than two.
  final Map<String, Future<bool>> _loading = <String, Future<bool>>{};

  /// Families that could not be loaded, so a broken asset id is attempted once
  /// per session rather than on every rebuild.
  final Set<String> _failed = <String>{};

  bool isReady(String family) => _ready.contains(family);

  /// The family to render with, given what the theme asked for.
  ///
  /// Never returns a family that is not registered — that is the whole contract,
  /// and it is what stops the app from silently rendering in the platform
  /// default while believing it is rendering in Poppins.
  String resolve(String requested) =>
      _ready.contains(requested) ? requested : fallbackFamily;

  /// Registers [family], downloading it if required.
  ///
  /// Returns true when the family became available *as a result of this call*,
  /// which is the signal the theme controller uses to re-render. Returns false
  /// when it was already ready, or when it could not be loaded — both of which
  /// mean "nothing changed on screen".
  Future<bool> ensure(String family, {String? assetId}) {
    if (_ready.contains(family) || _failed.contains(family)) {
      return Future<bool>.value(false);
    }
    if (assetId == null || assetId.isEmpty) {
      // The theme names a family with no file behind it. Not an error — an
      // admin can select a family before uploading its file — so it is recorded
      // and the app keeps its current face.
      AppLogger.info(
        'Font "$family" has no uploaded file; keeping $fallbackFamily',
        scope: 'theme',
      );
      _failed.add(family);
      return Future<bool>.value(false);
    }

    return _loading[family] ??= _load(family, assetId).whenComplete(() {
      _loading.remove(family);
    });
  }

  Future<bool> _load(String family, String assetId) async {
    try {
      final bytes = await _bytesFor(family, assetId);
      if (bytes == null) {
        _failed.add(family);
        return false;
      }

      final loader = FontLoader(family)
        ..addFont(Future<ByteData>.value(ByteData.sublistView(bytes)));
      await loader.load();

      _ready.add(family);
      AppLogger.info('Font "$family" registered (${bytes.length ~/ 1024} KB)', scope: 'theme');
      return true;
    } on Object catch (error) {
      // A corrupt or truncated file. Recorded so it is not retried on every
      // rebuild, and the app keeps the face it already had.
      AppLogger.warn('Could not register font "$family"', scope: 'theme', error: error);
      _failed.add(family);
      return false;
    }
  }

  /// Cache first, network second, cache written on the way back.
  Future<Uint8List?> _bytesFor(String family, String assetId) async {
    final file = await _cacheFile(family, assetId);

    if (file != null) {
      try {
        if (file.existsSync()) {
          final cached = await file.readAsBytes();
          if (cached.isNotEmpty) return cached;
        }
      } on Object catch (error) {
        AppLogger.debug('Font cache read failed for "$family": $error', scope: 'theme');
      }
    }

    final downloaded = await _download(assetId);
    if (downloaded == null) return null;

    if (file != null) {
      // Best-effort. A font that renders but is not cached costs one download
      // on the next launch; failing the whole load over it would cost the font.
      unawaited(
        file.parent
            .create(recursive: true)
            .then((_) => file.writeAsBytes(downloaded, flush: true))
            .catchError((Object error) {
              AppLogger.debug('Font cache write failed for "$family": $error', scope: 'theme');
              return file;
            }),
      );
    }

    return downloaded;
  }

  Future<Uint8List?> _download(String assetId) async {
    try {
      final response = await _client.dio.get<List<int>>(
        '/api/v1/assets/$assetId',
        options: Options(responseType: ResponseType.bytes),
      );
      final data = response.data;
      if (data == null || data.isEmpty) return null;
      return Uint8List.fromList(data);
    } on Object catch (error) {
      AppLogger.warn('Could not download font asset $assetId', scope: 'theme', error: error);
      return null;
    }
  }

  /// Where a font is cached, or null where there is no filesystem.
  ///
  /// Null on web, which has no `path_provider` directory — and needs none. A
  /// browser caches the asset response itself, so the download this would have
  /// avoided is already avoided one layer down.
  ///
  /// The asset id is part of the filename, so replacing a family's file writes
  /// a new cache entry rather than serving the old bytes under the new id.
  Future<File?> _cacheFile(String family, String assetId) async {
    if (kIsWeb) return null;
    try {
      final directory = await getApplicationSupportDirectory();
      final safe = family.replaceAll(RegExp(r'[^A-Za-z0-9._-]'), '_');
      return File('${directory.path}/aurix_fonts/$safe.$assetId.ttf');
    } on Object catch (error) {
      AppLogger.debug('No font cache directory available: $error', scope: 'theme');
      return null;
    }
  }

  @visibleForTesting
  void debugMarkReady(String family) => _ready.add(family);

  @visibleForTesting
  void debugReset() {
    _ready
      ..clear()
      ..addAll(bundled);
    _failed.clear();
    _loading.clear();
  }
}
