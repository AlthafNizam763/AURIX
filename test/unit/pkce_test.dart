import 'dart:convert';

import 'package:aurix/data/services/pkce.dart';
import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('Pkce', () {
    test('verifier length is within the RFC 7636 range', () {
      final pair = Pkce.generate();
      expect(pair.verifier.length, 96);
      expect(pair.verifier.length, greaterThanOrEqualTo(43));
      expect(pair.verifier.length, lessThanOrEqualTo(128));
    });

    test('verifier uses only unreserved characters', () {
      // Spotify rejects a verifier containing anything outside this set, and
      // the failure surfaces as an opaque 400 at token exchange.
      final allowed = RegExp(r'^[A-Za-z0-9\-._~]+$');
      for (var i = 0; i < 50; i++) {
        expect(allowed.hasMatch(Pkce.generate().verifier), isTrue);
      }
    });

    test('generates a different verifier every time', () {
      final verifiers = List.generate(200, (_) => Pkce.generate().verifier);
      // A collision here would mean the RNG is not seeded per call, which
      // would defeat the entire point of PKCE.
      expect(verifiers.toSet().length, 200);
    });

    test('challenge is unpadded base64url of the SHA-256 digest', () {
      const verifier = 'dBjftJeZ4CVP-mB92K27uhbUJU1p1r_wW1gFWFOEjXk';
      final expected = base64UrlEncode(
        sha256.convert(utf8.encode(verifier)).bytes,
      ).replaceAll('=', '');

      expect(Pkce.challengeFor(verifier), expected);
    });

    test('challenge carries no base64 padding', () {
      // Spotify rejects a padded challenge outright.
      for (var i = 0; i < 20; i++) {
        expect(Pkce.generate().challenge, isNot(contains('=')));
      }
    });

    test('challenge is deterministic for a given verifier', () {
      final pair = Pkce.generate();
      expect(Pkce.challengeFor(pair.verifier), pair.challenge);
      expect(Pkce.challengeFor(pair.verifier), pair.challenge);
    });

    test('method is S256, never plain', () {
      // `plain` is permitted by the RFC but offers no protection against
      // interception, which is the only reason PKCE exists on mobile.
      expect(PkcePair.method, 'S256');
    });

    test('state values are unique and non-trivial', () {
      final states = List.generate(100, (_) => Pkce.generateState());
      expect(states.toSet().length, 100);
      expect(states.every((s) => s.length == 24), isTrue);
    });
  });
}
