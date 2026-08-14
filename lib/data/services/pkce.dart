import 'dart:convert';
import 'dart:math';

import 'package:crypto/crypto.dart';

/// A PKCE code verifier / challenge pair (RFC 7636).
class PkcePair {
  const PkcePair({required this.verifier, required this.challenge});

  final String verifier;
  final String challenge;

  /// Always `S256`. The `plain` method is permitted by the RFC but offers no
  /// protection against an interception attack, which is the entire point of
  /// PKCE on a mobile client.
  static const String method = 'S256';
}

/// Generates PKCE material.
///
/// PKCE is what makes a client-secret-free mobile OAuth flow safe. The app
/// sends `challenge = BASE64URL(SHA256(verifier))` when opening the browser,
/// and the `verifier` itself only when redeeming the code. An attacker who
/// intercepts the redirect gets a code they cannot exchange, because they
/// never saw the verifier.
abstract final class Pkce {
  /// RFC 7636 §4.1: unreserved characters only.
  static const String _alphabet =
      'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~';

  /// Secure RNG. `Random.secure()` is backed by the platform CSPRNG; a plain
  /// `Random()` here would make verifiers predictable and PKCE worthless.
  static final Random _random = Random.secure();

  /// Creates a verifier of [length] characters (RFC allows 43–128; Spotify
  /// documents 43–128 and the extra length is free entropy).
  static PkcePair generate({int length = 96}) {
    assert(length >= 43 && length <= 128, 'RFC 7636 requires 43–128 characters');
    final verifier = _randomString(length);
    return PkcePair(verifier: verifier, challenge: challengeFor(verifier));
  }

  /// `BASE64URL(SHA256(verifier))`, unpadded — the padding must be stripped or
  /// Spotify rejects the challenge.
  static String challengeFor(String verifier) {
    final digest = sha256.convert(utf8.encode(verifier));
    return base64UrlEncode(digest.bytes).replaceAll('=', '');
  }

  /// Opaque value echoed back in the redirect, used to detect a forged or
  /// replayed callback.
  static String generateState({int length = 24}) => _randomString(length);

  static String _randomString(int length) {
    final buffer = StringBuffer();
    for (var i = 0; i < length; i++) {
      buffer.write(_alphabet[_random.nextInt(_alphabet.length)]);
    }
    return buffer.toString();
  }
}
