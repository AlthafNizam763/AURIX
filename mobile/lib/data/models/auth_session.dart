import 'package:equatable/equatable.dart';

import '../../core/constants/app_constants.dart';
import 'json_utils.dart';

/// A live OAuth session.
///
/// Deliberately has no `toJson`: a session must never be serialised into
/// anything but `SecureStore`, and giving it a JSON encoder makes it too easy
/// to accidentally drop one into SharedPreferences or a log line. The auth
/// service writes the three fields to the keychain individually.
class AuthSession extends Equatable {
  const AuthSession({
    required this.accessToken,
    required this.expiresAt,
    this.refreshToken,
    this.scopes = const [],
  });

  final String accessToken;
  final DateTime expiresAt;

  /// Spotify issues a refresh token with the PKCE flow. It can be rotated on
  /// each refresh, so the stored value must always be replaced with whatever
  /// the latest response carried.
  final String? refreshToken;

  final List<String> scopes;

  /// Builds a session from a `/api/token` response.
  factory AuthSession.fromTokenResponse(
    Map<String, dynamic> json, {
    String? previousRefreshToken,
  }) {
    final expiresIn = Json.intVal(json, 'expires_in', fallback: 3600);
    return AuthSession(
      accessToken: Json.str(json, 'access_token'),
      expiresAt: DateTime.now().add(Duration(seconds: expiresIn)),
      // A refresh response may omit refresh_token, meaning "keep using the
      // one you have". Dropping it here would log the user out an hour later.
      refreshToken:
          Json.strOrNull(json, 'refresh_token') ?? previousRefreshToken,
      scopes: Json.str(json, 'scope').split(' ').where((s) => s.isNotEmpty).toList(),
    );
  }

  bool get isExpired => DateTime.now().isAfter(expiresAt);

  /// True once the token is close enough to expiry that a long request could
  /// outlive it. Refreshing on this rather than on hard expiry is what stops
  /// intermittent 401s under slow networks.
  bool get needsRefresh =>
      DateTime.now().isAfter(expiresAt.subtract(AppConstants.tokenRefreshLeeway));

  bool get isValid => accessToken.isNotEmpty && !isExpired;
  bool get canRefresh => refreshToken?.isNotEmpty ?? false;

  Duration get timeRemaining {
    final remaining = expiresAt.difference(DateTime.now());
    return remaining.isNegative ? Duration.zero : remaining;
  }

  bool hasScope(String scope) => scopes.contains(scope);
  bool hasAllScopes(Iterable<String> required) => required.every(hasScope);

  AuthSession copyWith({
    String? accessToken,
    DateTime? expiresAt,
    String? refreshToken,
    List<String>? scopes,
  }) => AuthSession(
    accessToken: accessToken ?? this.accessToken,
    expiresAt: expiresAt ?? this.expiresAt,
    refreshToken: refreshToken ?? this.refreshToken,
    scopes: scopes ?? this.scopes,
  );

  @override
  List<Object?> get props => [accessToken, expiresAt, refreshToken, scopes];

  @override
  String toString() =>
      'AuthSession(expiresIn: ${timeRemaining.inSeconds}s, '
      'canRefresh: $canRefresh, scopes: ${scopes.length})';
}
