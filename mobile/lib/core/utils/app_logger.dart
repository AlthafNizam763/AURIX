import 'dart:developer' as developer;

import 'package:flutter/foundation.dart';

/// Minimal structured logger.
///
/// Logging is debug-only by design: a release build of a music app should not
/// be writing request URLs (which carry track and user IDs) to the device log.
/// [redactToken] exists so that even in debug, bearer tokens never land in a
/// log line that could be pasted into a bug report.
abstract final class AppLogger {
  static const String _name = 'aurix';

  static void debug(String message, {String? scope}) {
    if (!kDebugMode) return;
    developer.log(message, name: _scoped(scope), level: 500);
  }

  static void info(String message, {String? scope}) {
    if (!kDebugMode) return;
    developer.log(message, name: _scoped(scope), level: 800);
  }

  static void warn(String message, {String? scope, Object? error}) {
    if (!kDebugMode) return;
    developer.log(message, name: _scoped(scope), level: 900, error: error);
  }

  /// Errors are logged in profile builds too, where crash reporting hooks in.
  static void error(
    String message, {
    String? scope,
    Object? error,
    StackTrace? stackTrace,
  }) {
    if (kReleaseMode) return;
    developer.log(
      message,
      name: _scoped(scope),
      level: 1000,
      error: error,
      stackTrace: stackTrace,
    );
  }

  /// Reduces a secret to a shape that is useful for debugging (does the token
  /// look present? did it change?) without being usable if leaked.
  static String redactToken(String? token) {
    if (token == null || token.isEmpty) return '<none>';
    if (token.length <= 10) return '<redacted:${token.length}>';
    return '${token.substring(0, 6)}…${token.substring(token.length - 4)}';
  }

  static String _scoped(String? scope) => scope == null ? _name : '$_name.$scope';
}
