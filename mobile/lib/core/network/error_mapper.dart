import 'package:dio/dio.dart';

import 'api_exception.dart';

/// Translates transport-level failures into [ApiException]s carrying messages
/// that are safe and useful to show a person.
///
/// This is the only place in the app that reads a `DioException`.
abstract final class ErrorMapper {
  static ApiException fromDio(DioException error) {
    final endpoint = error.requestOptions.path;

    switch (error.type) {
      case DioExceptionType.connectionTimeout:
      case DioExceptionType.sendTimeout:
      case DioExceptionType.receiveTimeout:
      case DioExceptionType.transformTimeout:
        return ApiException(
          kind: ApiFailureKind.timeout,
          message: 'That took too long. Check your connection and try again.',
          endpoint: endpoint,
          debugDetail: error.message,
        );

      case DioExceptionType.connectionError:
        return ApiException(
          kind: ApiFailureKind.offline,
          message: "Can't reach Spotify. You appear to be offline.",
          endpoint: endpoint,
          debugDetail: error.message,
        );

      case DioExceptionType.cancel:
        return ApiException(
          kind: ApiFailureKind.cancelled,
          message: 'Request cancelled.',
          endpoint: endpoint,
          debugDetail: error.message,
        );

      case DioExceptionType.badCertificate:
        return ApiException(
          kind: ApiFailureKind.unknown,
          message: "Couldn't establish a secure connection.",
          endpoint: endpoint,
          debugDetail: 'Bad certificate',
        );

      case DioExceptionType.badResponse:
        return _fromResponse(error.response, endpoint);

      case DioExceptionType.unknown:
        if (error.error is FormatException) {
          return ApiException(
            kind: ApiFailureKind.parsing,
            message: 'Spotify sent something we could not read.',
            endpoint: endpoint,
            debugDetail: error.error.toString(),
          );
        }
        return ApiException(
          kind: ApiFailureKind.unknown,
          message: 'Something went wrong. Please try again.',
          endpoint: endpoint,
          debugDetail: error.message ?? error.error?.toString(),
        );
    }
  }

  static ApiException _fromResponse(Response<dynamic>? response, String endpoint) {
    final status = response?.statusCode ?? 0;
    final parsed = _parseErrorBody(response?.data);
    final apiMessage = parsed.$1;
    final reason = parsed.$2;

    switch (status) {
      case 400:
        return ApiException(
          kind: ApiFailureKind.unknown,
          statusCode: status,
          reason: reason,
          // 400 from Spotify is almost always a malformed request from us, not
          // something the user did. Don't blame them for it.
          message: 'That request was not valid. Please try again.',
          endpoint: endpoint,
          debugDetail: apiMessage,
        );

      case 401:
        return ApiException(
          kind: ApiFailureKind.unauthorized,
          statusCode: status,
          reason: reason,
          message: 'Your session expired. Sign in again to continue.',
          endpoint: endpoint,
          debugDetail: apiMessage,
        );

      case 403:
        return ApiException(
          kind: ApiFailureKind.forbidden,
          statusCode: status,
          reason: reason,
          message: _forbiddenMessage(reason, apiMessage),
          endpoint: endpoint,
          debugDetail: apiMessage,
          // Kept verbatim as well as folded into [message]: a 403 is the one
          // failure where Spotify's own wording names the fix ("User not
          // registered in the Developer Dashboard"), and paraphrasing it loses
          // the only clue there is.
          apiMessage: apiMessage,
        );

      case 404:
        return ApiException(
          kind: ApiFailureKind.notFound,
          statusCode: status,
          reason: reason,
          message: "We couldn't find that on Spotify.",
          endpoint: endpoint,
          debugDetail: apiMessage,
        );

      case 429:
        final retryAfter = _retryAfter(response);
        return ApiException(
          kind: ApiFailureKind.rateLimited,
          statusCode: status,
          reason: reason,
          retryAfter: retryAfter,
          message: retryAfter == null
              ? 'Too many requests. Give it a moment and try again.'
              : 'Too many requests. Try again in ${retryAfter.inSeconds}s.',
          endpoint: endpoint,
          debugDetail: apiMessage,
        );

      case 500:
      case 502:
      case 503:
      case 504:
        return ApiException(
          kind: ApiFailureKind.serverError,
          statusCode: status,
          reason: reason,
          message: 'Spotify is having trouble right now. Try again shortly.',
          endpoint: endpoint,
          debugDetail: apiMessage,
        );

      default:
        return ApiException(
          kind: ApiFailureKind.unknown,
          statusCode: status,
          reason: reason,
          message: 'Something went wrong. Please try again.',
          endpoint: endpoint,
          debugDetail: apiMessage,
        );
    }
  }

  /// A 403 means three very different things depending on the reason code,
  /// and the user needs to be told which one it is.
  static String _forbiddenMessage(String? reason, String? apiMessage) {
    switch (reason) {
      case 'PREMIUM_REQUIRED':
        return 'Spotify Premium is required to control playback.';
      case 'NO_ACTIVE_DEVICE':
        return 'No active Spotify device. Open Spotify on a device, then try again.';
      case 'ALREADY_PLAYING':
        return 'That is already playing.';
      case 'NOT_PAUSED':
        return 'Playback is already running.';
      case 'UNKNOWN':
      case null:
        // The most common cause on a fresh developer app: an endpoint that now
        // needs extended quota mode. Worth naming, because otherwise it looks
        // like a bug in the app.
        if (apiMessage != null && apiMessage.toLowerCase().contains('scope')) {
          return 'This app is missing a permission needed for that action.';
        }
        return 'Spotify would not allow that request for this account.';
      default:
        return 'Spotify would not allow that request for this account.';
    }
  }

  /// Spotify returns either `{"error": {"status", "message", "reason"}}` or,
  /// on the accounts host, `{"error": "...", "error_description": "..."}`.
  static (String?, String?) _parseErrorBody(Object? data) {
    if (data is! Map) return (null, null);

    final error = data['error'];
    if (error is Map) {
      final message = error['message'];
      final reason = error['reason'];
      return (
        message is String ? message : null,
        reason is String ? reason : null,
      );
    }
    if (error is String) {
      final description = data['error_description'];
      return (description is String ? description : error, error);
    }
    return (null, null);
  }

  static Duration? _retryAfter(Response<dynamic>? response) {
    final header = response?.headers.value('retry-after');
    final seconds = header == null ? null : int.tryParse(header);
    if (seconds == null) return null;
    return Duration(seconds: seconds);
  }

  /// Catch-all for non-Dio errors escaping a service, so repositories can
  /// funnel everything through one type.
  static ApiException fromUnknown(Object error, [StackTrace? stackTrace]) {
    if (error is ApiException) return error;
    if (error is DioException) return fromDio(error);
    if (error is FormatException || error is TypeError) {
      return ApiException(
        kind: ApiFailureKind.parsing,
        message: 'Spotify sent something we could not read.',
        debugDetail: error.toString(),
      );
    }
    return ApiException(
      kind: ApiFailureKind.unknown,
      message: 'Something went wrong. Please try again.',
      debugDetail: error.toString(),
    );
  }
}
