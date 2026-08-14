import 'dart:async';
import 'dart:math' as math;

import 'package:dio/dio.dart';

import '../constants/app_constants.dart';
import '../utils/app_logger.dart';

/// Retries transient failures with exponential backoff, and honours Spotify's
/// `Retry-After` header on 429.
///
/// Only idempotent verbs are retried. Replaying a `POST /me/player/queue`
/// would silently enqueue the same track twice, so writes fail fast and let
/// the caller decide.
class RetryInterceptor extends Interceptor {
  RetryInterceptor({
    this.maxRetries = AppConstants.maxRetries,
    this.baseDelay = const Duration(milliseconds: 400),
    Future<void> Function(Duration)? sleep,
  }) : _sleep = sleep ?? Future.delayed;

  final int maxRetries;
  final Duration baseDelay;
  final Future<void> Function(Duration) _sleep;

  static const String _attemptKey = 'aurix.retry_attempt';

  /// Never wait longer than this for a rate limit — beyond it, telling the
  /// user is better than an app that appears frozen.
  static const Duration _maxHonouredRetryAfter = Duration(seconds: 12);

  @override
  Future<void> onError(DioException err, ErrorInterceptorHandler handler) async {
    final options = err.requestOptions;
    final attempt = (options.extra[_attemptKey] as int?) ?? 0;

    if (!_shouldRetry(err) || attempt >= maxRetries) {
      return handler.next(err);
    }

    final delay = _delayFor(err, attempt);
    if (delay == null) return handler.next(err);

    AppLogger.debug(
      'Retry ${attempt + 1}/$maxRetries for ${options.path} in ${delay.inMilliseconds}ms',
      scope: 'net',
    );

    await _sleep(delay);

    if (options.cancelToken?.isCancelled ?? false) {
      return handler.next(err);
    }

    options.extra[_attemptKey] = attempt + 1;

    try {
      final response = await Dio(
        BaseOptions(
          baseUrl: options.baseUrl,
          connectTimeout: options.connectTimeout,
          receiveTimeout: options.receiveTimeout,
          sendTimeout: options.sendTimeout,
          validateStatus: options.validateStatus,
        ),
      ).fetch<dynamic>(options);
      handler.resolve(response);
    } on DioException catch (retryError) {
      handler.next(retryError);
    }
  }

  bool _shouldRetry(DioException err) {
    if (err.type == DioExceptionType.cancel) return false;

    const idempotent = {'GET', 'HEAD', 'OPTIONS'};
    final isIdempotent = idempotent.contains(err.requestOptions.method.toUpperCase());

    switch (err.type) {
      case DioExceptionType.connectionTimeout:
      case DioExceptionType.receiveTimeout:
      case DioExceptionType.sendTimeout:
      case DioExceptionType.connectionError:
        return isIdempotent;
      case DioExceptionType.badResponse:
        final status = err.response?.statusCode ?? 0;
        // 429 is safe to replay on any verb: the request never reached the
        // handler, so nothing was mutated.
        if (status == 429) return true;
        return isIdempotent && status >= 500 && status < 600;
      case DioExceptionType.transformTimeout:
      case DioExceptionType.badCertificate:
      case DioExceptionType.cancel:
      case DioExceptionType.unknown:
        // A transform timeout means the payload arrived but decoding stalled;
        // replaying it would just stall again on the same body.
        return false;
    }
  }

  Duration? _delayFor(DioException err, int attempt) {
    if (err.response?.statusCode == 429) {
      final header = err.response?.headers.value('retry-after');
      final seconds = header == null ? null : int.tryParse(header);
      if (seconds != null) {
        final wait = Duration(seconds: seconds);
        return wait > _maxHonouredRetryAfter ? null : wait;
      }
    }
    // Exponential backoff with jitter, so a burst of parallel home-screen
    // requests does not retry in lockstep and re-trigger the same rate limit.
    final exponential = baseDelay * math.pow(2, attempt).toDouble();
    final jitter = Duration(milliseconds: (attempt * 97) % 250);
    return exponential + jitter;
  }
}
