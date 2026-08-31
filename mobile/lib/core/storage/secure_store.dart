import 'package:flutter_secure_storage/flutter_secure_storage.dart';

import '../utils/app_logger.dart';

/// Storage for OAuth material only.
///
/// Backed by the Android Keystore / iOS Keychain. Access and refresh tokens
/// live here and nowhere else — never in SharedPreferences, never in a plain
/// file, never in a log line.
abstract interface class SecureStore {
  Future<String?> read(String key);
  Future<void> write(String key, String? value);
  Future<void> delete(String key);
  Future<void> clear();
}

class FlutterSecureStore implements SecureStore {
  FlutterSecureStore({FlutterSecureStorage? storage})
    : _storage = storage ??
          const FlutterSecureStorage(
            aOptions: AndroidOptions(
              // AES-GCM with RSA-OAEP key wrapping in the Android Keystore is
              // the plugin default in v11; these two flags decide what happens
              // when that key becomes unreadable. `resetOnError` clears the
              // entry instead of throwing on every launch — the correct
              // trade-off here, since losing a token only costs a re-login.
              resetOnError: true,
              migrateOnAlgorithmChange: true,
              preferencesKeyPrefix: 'aurix',
            ),
            iOptions: IOSOptions(
              // Tokens are useless without the device unlocked, and
              // `..._this_device` keeps them out of iCloud/iTunes backups.
              accessibility: KeychainAccessibility.first_unlock_this_device,
            ),
          );

  final FlutterSecureStorage _storage;

  @override
  Future<String?> read(String key) async {
    try {
      return await _storage.read(key: key);
    } on Object catch (error) {
      // A corrupt keystore entry (common after a restore-from-backup) should
      // log the user out, not crash the app on launch.
      AppLogger.warn('Secure read failed for "$key"', scope: 'secure', error: error);
      return null;
    }
  }

  @override
  Future<void> write(String key, String? value) async {
    try {
      if (value == null) {
        await _storage.delete(key: key);
      } else {
        await _storage.write(key: key, value: value);
      }
    } on Object catch (error) {
      AppLogger.error('Secure write failed for "$key"', scope: 'secure', error: error);
    }
  }

  @override
  Future<void> delete(String key) => write(key, null);

  @override
  Future<void> clear() async {
    try {
      await _storage.deleteAll();
    } on Object catch (error) {
      AppLogger.error('Secure clear failed', scope: 'secure', error: error);
    }
  }
}

/// Keys used in [SecureStore]. Namespaced so a future feature cannot collide.
abstract final class SecureKeys {
  static const String accessToken = 'aurix.auth.access_token';
  static const String refreshToken = 'aurix.auth.refresh_token';
  static const String expiresAt = 'aurix.auth.expires_at';
  static const String scopes = 'aurix.auth.scopes';
  static const String codeVerifier = 'aurix.auth.code_verifier';
}

/// In-memory implementation used by tests and by the widget previews, so no
/// test ever needs a real keychain.
class InMemorySecureStore implements SecureStore {
  final Map<String, String> _values = {};

  Map<String, String> get snapshot => Map.unmodifiable(_values);

  @override
  Future<String?> read(String key) async => _values[key];

  @override
  Future<void> write(String key, String? value) async {
    if (value == null) {
      _values.remove(key);
    } else {
      _values[key] = value;
    }
  }

  @override
  Future<void> delete(String key) async => _values.remove(key);

  @override
  Future<void> clear() async => _values.clear();
}
