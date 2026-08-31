import 'package:aurix/core/network/api_exception.dart';
import 'package:aurix/core/network/error_mapper.dart';
import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  final options = RequestOptions(path: '/me/player/play');

  DioException responseError(
    int status, {
    Map<String, dynamic>? body,
    Map<String, List<String>>? headers,
  }) => DioException(
    requestOptions: options,
    type: DioExceptionType.badResponse,
    response: Response<dynamic>(
      requestOptions: options,
      statusCode: status,
      data: body,
      headers: headers == null ? null : Headers.fromMap(headers),
    ),
  );

  group('transport failures', () {
    test('connection error maps to offline', () {
      final mapped = ErrorMapper.fromDio(
        DioException(
          requestOptions: options,
          type: DioExceptionType.connectionError,
        ),
      );
      expect(mapped.kind, ApiFailureKind.offline);
      expect(mapped.isRetryable, isTrue);
      expect(mapped.message, contains('offline'));
    });

    test('every timeout variant maps to timeout', () {
      for (final type in [
        DioExceptionType.connectionTimeout,
        DioExceptionType.sendTimeout,
        DioExceptionType.receiveTimeout,
        DioExceptionType.transformTimeout,
      ]) {
        final mapped = ErrorMapper.fromDio(
          DioException(requestOptions: options, type: type),
        );
        expect(mapped.kind, ApiFailureKind.timeout, reason: '$type');
      }
    });

    test('cancellation is classified separately and is not retryable', () {
      final mapped = ErrorMapper.fromDio(
        DioException(requestOptions: options, type: DioExceptionType.cancel),
      );
      expect(mapped.kind, ApiFailureKind.cancelled);
      expect(mapped.isRetryable, isFalse);
    });
  });

  group('403 reasons', () {
    test('PREMIUM_REQUIRED is named explicitly', () {
      final mapped = ErrorMapper.fromDio(
        responseError(403, body: {
          'error': {
            'status': 403,
            'message': 'Player command failed: Premium required',
            'reason': 'PREMIUM_REQUIRED',
          },
        }),
      );

      expect(mapped.kind, ApiFailureKind.forbidden);
      expect(mapped.requiresPremium, isTrue);
      expect(mapped.message, contains('Premium'));
      expect(mapped.isCapabilityLimit, isTrue);
    });

    test('NO_ACTIVE_DEVICE tells the user what to do', () {
      final mapped = ErrorMapper.fromDio(
        responseError(403, body: {
          'error': {
            'status': 403,
            'message': 'Player command failed: No active device found',
            'reason': 'NO_ACTIVE_DEVICE',
          },
        }),
      );

      expect(mapped.requiresActiveDevice, isTrue);
      expect(mapped.message, contains('Open Spotify'));
    });

    test('a 403 with no reason still produces a usable message', () {
      // This is what a restricted endpoint returns for a new developer app.
      final mapped = ErrorMapper.fromDio(responseError(403));
      expect(mapped.kind, ApiFailureKind.forbidden);
      expect(mapped.message, isNotEmpty);
      expect(mapped.message, isNot(contains('Exception')));
    });

    test("Spotify's own wording survives into apiMessage", () {
      // The access-denied screen reports this verbatim. Paraphrasing it into
      // `message` alone loses the only thing that distinguishes a dashboard
      // allowlist problem from every other 403.
      final mapped = ErrorMapper.fromDio(
        responseError(403, body: {
          'error': {
            'status': 403,
            'message': 'User not registered in the Developer Dashboard',
          },
        }),
      );

      expect(mapped.apiMessage, 'User not registered in the Developer Dashboard');
    });

    test('apiMessage is null when the body carried no message', () {
      expect(ErrorMapper.fromDio(responseError(403)).apiMessage, isNull);
    });
  });

  group('other statuses', () {
    test('401 maps to unauthorized', () {
      final mapped = ErrorMapper.fromDio(responseError(401));
      expect(mapped.kind, ApiFailureKind.unauthorized);
      expect(mapped.message, contains('session'));
    });

    test('404 maps to notFound', () {
      expect(ErrorMapper.fromDio(responseError(404)).kind, ApiFailureKind.notFound);
    });

    test('429 carries Retry-After through to the message', () {
      final mapped = ErrorMapper.fromDio(
        responseError(429, headers: {'retry-after': ['7']}),
      );
      expect(mapped.kind, ApiFailureKind.rateLimited);
      expect(mapped.retryAfter, const Duration(seconds: 7));
      expect(mapped.message, contains('7s'));
      expect(mapped.isRetryable, isTrue);
    });

    test('429 without the header still produces a sensible message', () {
      final mapped = ErrorMapper.fromDio(responseError(429));
      expect(mapped.retryAfter, isNull);
      expect(mapped.message, contains('Too many requests'));
    });

    test('5xx maps to serverError and is retryable', () {
      for (final status in [500, 502, 503, 504]) {
        final mapped = ErrorMapper.fromDio(responseError(status));
        expect(mapped.kind, ApiFailureKind.serverError, reason: '$status');
        expect(mapped.isRetryable, isTrue);
      }
    });

    test('400 does not blame the user', () {
      // A 400 from Spotify is nearly always a malformed request from us.
      final mapped = ErrorMapper.fromDio(responseError(400));
      expect(mapped.message, isNot(contains('you')));
      expect(mapped.kind, ApiFailureKind.unknown);
    });
  });

  group('message hygiene', () {
    test('the raw API message never reaches the user-facing text', () {
      const internal = 'Invalid access token supplied for user 123';
      final mapped = ErrorMapper.fromDio(
        responseError(401, body: {
          'error': {'status': 401, 'message': internal},
        }),
      );

      expect(mapped.message, isNot(contains(internal)));
      // …but it is preserved for logs.
      expect(mapped.debugDetail, internal);
    });

    test('parses the accounts-host error shape', () {
      final mapped = ErrorMapper.fromDio(
        responseError(400, body: {
          'error': 'invalid_grant',
          'error_description': 'Invalid authorization code',
        }),
      );
      expect(mapped.reason, 'invalid_grant');
      expect(mapped.debugDetail, 'Invalid authorization code');
    });

    test('a non-map body does not crash the mapper', () {
      final mapped = ErrorMapper.fromDio(responseError(500, body: null));
      expect(mapped.message, isNotEmpty);
    });
  });

  group('fromUnknown', () {
    test('passes an ApiException through unchanged', () {
      const original = ApiException(
        kind: ApiFailureKind.notFound,
        message: 'Gone',
      );
      expect(identical(ErrorMapper.fromUnknown(original), original), isTrue);
    });

    test('classifies a FormatException as a parsing failure', () {
      final mapped = ErrorMapper.fromUnknown(const FormatException('bad json'));
      expect(mapped.kind, ApiFailureKind.parsing);
    });

    test('falls back to a generic message for anything else', () {
      final mapped = ErrorMapper.fromUnknown(StateError('boom'));
      expect(mapped.kind, ApiFailureKind.unknown);
      expect(mapped.message, 'Something went wrong. Please try again.');
      expect(mapped.debugDetail, contains('boom'));
    });
  });
}
