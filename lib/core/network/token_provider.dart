/// The contract the network layer needs from authentication.
///
/// Declared here — not in the auth service — so `DioClient` depends on an
/// abstraction rather than on `SpotifyAuthService`. Without this the two would
/// be circular: the auth service needs a Dio instance to exchange tokens, and
/// Dio needs the auth service to attach them.
abstract interface class TokenProvider {
  /// A currently-valid access token, refreshing first if it is close to
  /// expiry. Returns null when there is no session at all.
  Future<String?> validAccessToken();

  /// Forces a refresh after a 401. Returns the new token, or null if the
  /// refresh token is gone or rejected — in which case the session is over.
  Future<String?> forceRefresh();

  /// Drops the session locally. Called when refresh definitively fails.
  Future<void> invalidateSession();
}
