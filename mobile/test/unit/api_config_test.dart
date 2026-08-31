import 'package:aurix/core/config/api_config.dart';
import 'package:aurix/core/config/env.dart';
import 'package:aurix/core/constants/aurix_endpoints.dart';
import 'package:flutter_test/flutter_test.dart';

/// The API address is one setting resolved in one place, and everything below
/// is about the ways that resolution can go quietly wrong. A base URL that is
/// almost right — a trailing slash, a pasted `/api/v1`, the emulator's alias
/// used on a physical device — fails as a 404 or a connection timeout, neither
/// of which names the configuration as the cause.
void main() {
  group('ApiConfig', () {
    test('production is the deployed Vercel API, origin only', () {
      expect(ApiConfig.productionOrigin, 'https://aurix-iota-tawny.vercel.app');
      // Origin only: the version prefix is carried by every endpoint constant,
      // so an origin ending in /api/v1 would produce /api/v1/api/v1/auth/login.
      expect(ApiConfig.productionOrigin, isNot(endsWith(AurixEndpoints.prefix)));
      expect(
        ApiConfig.productionBaseUrl,
        'https://aurix-iota-tawny.vercel.app/api/v1',
      );
    });

    test('production is https — every request carries a bearer token', () {
      expect(ApiConfig.productionOrigin, startsWith('https://'));
    });

    test('development answers with the host address each platform can reach', () {
      const dev = ApiEnvironment.development;
      expect(
        ApiConfig.defaultOrigin(dev, isWeb: false, isAndroid: true),
        ApiConfig.developmentAndroidOrigin,
        reason: 'localhost on the emulator is the emulated device itself',
      );
      expect(
        ApiConfig.defaultOrigin(dev, isWeb: false, isAndroid: false),
        ApiConfig.developmentOrigin,
      );
      expect(
        ApiConfig.defaultOrigin(dev, isWeb: true, isAndroid: false),
        ApiConfig.developmentOrigin,
      );
    });

    test('production is one address for every platform', () {
      const prod = ApiEnvironment.production;
      expect(
        ApiConfig.defaultOrigin(prod, isWeb: true, isAndroid: false),
        ApiConfig.productionOrigin,
      );
      expect(
        ApiConfig.defaultOrigin(prod, isWeb: false, isAndroid: true),
        ApiConfig.productionOrigin,
      );
    });

    test('parses the spellings of each environment, and nothing else', () {
      for (final value in ['production', 'PRODUCTION', ' prod ', 'release']) {
        expect(ApiConfig.parseEnvironment(value), ApiEnvironment.production);
      }
      for (final value in ['development', 'dev', 'local', 'DEBUG']) {
        expect(ApiConfig.parseEnvironment(value), ApiEnvironment.development);
      }
      // Null rather than a guess: the caller decides what "not set" means.
      for (final value in ['', '   ', 'staging', 'true']) {
        expect(ApiConfig.parseEnvironment(value), isNull);
      }
    });

    test('normalises the two ways a base URL is usually mistyped', () {
      expect(
        ApiConfig.normaliseOrigin('https://aurix-iota-tawny.vercel.app/'),
        'https://aurix-iota-tawny.vercel.app',
      );
      expect(
        ApiConfig.normaliseOrigin('https://aurix-iota-tawny.vercel.app/api/v1'),
        'https://aurix-iota-tawny.vercel.app',
      );
      expect(
        ApiConfig.normaliseOrigin(' https://aurix-iota-tawny.vercel.app/api/v1/ '),
        'https://aurix-iota-tawny.vercel.app',
      );
    });

    test('an empty origin does not become a usable-looking API root', () {
      expect(ApiConfig.apiRootFor(''), '');
      expect(ApiConfig.apiRootFor('https://x.dev'), 'https://x.dev/api/v1');
    });
  });

  group('Env.apiEnvironment', () {
    setUp(Env.resetForTesting);
    tearDown(Env.resetForTesting);

    test('AURIX_ENV alone is enough to configure the app', () {
      Env.loadFromString('AURIX_ENV=production\n');
      expect(Env.apiEnvironment, ApiEnvironment.production);
      expect(Env.isApiConfigured, isTrue);
      expect(Env.apiBaseUrl, ApiConfig.productionOrigin);
      expect(Env.apiRoot, ApiConfig.productionBaseUrl);
      expect(Env.isProductionApi, isTrue);
      expect(Env.isApiInsecure, isFalse);
    });

    test('development points at the local Next.js server', () {
      Env.loadFromString('AURIX_ENV=development\n');
      expect(Env.apiEnvironment, ApiEnvironment.development);
      // `flutter test` reports Android as the target platform, so this is the
      // emulator's alias for the host machine rather than plain localhost —
      // which is exactly the substitution the development branch exists for.
      expect(Env.apiBaseUrl, ApiConfig.developmentAndroidOrigin);
      expect(Env.isProductionApi, isFalse);
      // http against loopback is not the insecure case the boot warning is for.
      expect(Env.isApiInsecure, isFalse);
    });

    test('an explicit base URL wins over the environment', () {
      // The one case that needs it: a development build on a physical device,
      // where loopback is the phone rather than the host machine.
      Env.loadFromString(
        'AURIX_ENV=development\n'
        'AURIX_API_BASE_URL=http://192.168.1.42:3000\n',
      );
      expect(Env.apiBaseUrl, 'http://192.168.1.42:3000');
      expect(Env.isApiInsecure, isTrue, reason: 'http to a non-loopback host');
    });

    test('a pasted API root is absorbed rather than doubled', () {
      Env.loadFromString(
        'AURIX_API_BASE_URL=https://aurix-iota-tawny.vercel.app/api/v1\n',
      );
      expect(Env.apiBaseUrl, ApiConfig.productionOrigin);
      expect(Env.apiRoot, ApiConfig.productionBaseUrl);
    });

    test('an unrecognised AURIX_ENV leaves a debug build unconfigured', () {
      // Not a silent fall back to one of the two: a build that says `staging`
      // and gets production is worse than one that says what is wrong. The
      // release-mode fallback is deliberately not exercised here — tests run
      // in debug, which is the branch this asserts.
      Env.loadFromString('AURIX_ENV=staging\n');
      expect(Env.apiEnvironment, isNull);
      expect(Env.isApiConfigured, isFalse);
      expect(Env.apiRoot, '');
      expect(Env.apiConfigurationHint, contains('AURIX_ENV'));
    });
  });
}
