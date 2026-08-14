/// Why a request failed, in terms the UI can act on.
enum ApiFailureKind {
  /// Device reports no usable network.
  offline,

  /// Connect/receive/send timeout.
  timeout,

  /// 401 — token missing, expired or revoked. Triggers refresh, then logout.
  unauthorized,

  /// 403 — authenticated but not permitted. Covers three very different
  /// real-world cases, distinguished by [ApiException.reason]:
  /// missing scope, non-Premium account, or an endpoint that now requires
  /// extended quota mode.
  forbidden,

  /// 404 — the resource does not exist, or is not visible to this token.
  notFound,

  /// 429 — rate limited. [ApiException.retryAfter] carries Spotify's hint.
  rateLimited,

  /// 5xx — Spotify is having a bad day.
  serverError,

  /// The response arrived but did not have the shape the model expected.
  parsing,

  /// Request was cancelled (screen disposed, newer search superseded it).
  cancelled,

  /// Anything not otherwise classified.
  unknown,
}

/// The single error type that crosses the service → repository → UI boundary.
///
/// Nothing above the network layer ever sees a `DioException`, and no raw
/// exception text is ever shown to a user — [message] is written to be
/// displayed, and [debugDetail] holds the technical detail for logs only.
class ApiException implements Exception {
  const ApiException({
    required this.kind,
    required this.message,
    this.statusCode,
    this.reason,
    this.retryAfter,
    this.debugDetail,
    this.apiMessage,
    this.endpoint,
  });

  final ApiFailureKind kind;

  /// User-facing, already sanitised.
  final String message;

  final int? statusCode;

  /// Spotify's machine-readable `error.reason` (e.g. `PREMIUM_REQUIRED`,
  /// `NO_ACTIVE_DEVICE`), when present.
  final String? reason;

  final Duration? retryAfter;

  /// Never rendered. For logs and bug reports.
  final String? debugDetail;

  /// Spotify's own `error.message` from the response body, when there was one
  /// — e.g. "User not registered in the Developer Dashboard".
  ///
  /// Unlike [debugDetail] this is safe to show: Spotify writes it for the
  /// developer reading it, it never echoes the request, and it never contains
  /// the token. It is the difference between a screen that guesses at two
  /// possible causes and one that reports the actual one.
  final String? apiMessage;

  final String? endpoint;

  bool get isRetryable =>
      kind == ApiFailureKind.timeout ||
      kind == ApiFailureKind.serverError ||
      kind == ApiFailureKind.rateLimited ||
      kind == ApiFailureKind.offline;

  /// True when the failure means "this account cannot do that", as opposed to
  /// "something went wrong". These get a different, non-alarming UI treatment.
  bool get isCapabilityLimit =>
      kind == ApiFailureKind.forbidden &&
      (reason == 'PREMIUM_REQUIRED' ||
          reason == 'NO_ACTIVE_DEVICE' ||
          reason == 'UNKNOWN' ||
          reason == null);

  bool get requiresPremium => reason == 'PREMIUM_REQUIRED';
  bool get requiresActiveDevice => reason == 'NO_ACTIVE_DEVICE';

  ApiException copyWith({String? message, String? endpoint}) => ApiException(
    kind: kind,
    message: message ?? this.message,
    statusCode: statusCode,
    reason: reason,
    retryAfter: retryAfter,
    debugDetail: debugDetail,
    apiMessage: apiMessage,
    endpoint: endpoint ?? this.endpoint,
  );

  @override
  String toString() =>
      'ApiException(${kind.name}, status: $statusCode, reason: $reason, '
      'endpoint: $endpoint, detail: $debugDetail)';
}

/// Thrown when a call needs authentication and there is no usable session.
/// Distinct from a 401 so the router can send the user to login without first
/// making a doomed network round trip.
class NotAuthenticatedException extends ApiException {
  const NotAuthenticatedException()
    : super(
        kind: ApiFailureKind.unauthorized,
        message: 'Sign in to continue.',
        debugDetail: 'No session available',
      );
}
