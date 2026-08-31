import 'package:flutter/services.dart';

import '../core/utils/app_logger.dart';

/// Where the notification permission stands.
enum NotificationPermission {
  /// Posting is allowed. The media notification and lock-screen controls will
  /// appear.
  granted,

  /// Not granted yet, and the system dialog has not been shown or was
  /// dismissed. Asking again is worthwhile.
  denied,

  /// The user said no twice, or turned notifications off in system settings.
  /// Android will never show the dialog again — only the app's settings page
  /// can change this, and only if the user goes there.
  permanentlyDenied,

  /// No runtime permission exists here: Android 12 and below, iOS, web,
  /// desktop. Nothing to ask for.
  notRequired,
}

/// The runtime grant the media notification depends on.
///
/// ## Why this exists
///
/// From Android 13 (API 33) `POST_NOTIFICATIONS` is a runtime permission, and
/// a media session with no posted notification is invisible: the foreground
/// service still runs, the lock screen still shows the session, but the
/// notification shade — the thing the user reaches for when AURIX is
/// backgrounded — stays empty. Declaring the permission in the manifest is not
/// enough, and nothing in the Flutter media stack asks for it.
///
/// ## When it asks
///
/// Once, the first time playback actually starts, and never at launch. A
/// permission dialog on first open is asking for something the user has no
/// context for yet; the same dialog the moment a song starts explains itself.
class MediaPermissions {
  MediaPermissions({MethodChannel? channel})
    : _channel = channel ?? const MethodChannel(_name);

  static const String _name = 'com.aurix.app/media_permissions';

  final MethodChannel _channel;

  /// True once [ensureNotificationPermission] has run in this process, so a
  /// queue of ten tracks does not produce ten dialogs.
  bool _asked = false;

  Future<NotificationPermission> status() =>
      _call('notificationPermissionStatus');

  /// Asks for the notification permission if it has not been asked for yet.
  ///
  /// Returns the resulting status. A refusal is not an error and nothing in the
  /// app treats it as one: playback continues, the Spotify app keeps making
  /// sound, and only AURIX's own notification is missing.
  Future<NotificationPermission> ensureNotificationPermission() async {
    if (_asked) return status();
    _asked = true;

    final current = await status();
    if (current != NotificationPermission.denied) return current;

    final result = await _call('requestNotificationPermission');
    AppLogger.info(
      'Notification permission: ${result.name}',
      scope: 'media_session',
    );
    return result;
  }

  Future<NotificationPermission> _call(String method) async {
    try {
      final raw = await _channel.invokeMethod<String>(method);
      return switch (raw) {
        'granted' => NotificationPermission.granted,
        'denied' => NotificationPermission.denied,
        'permanentlyDenied' => NotificationPermission.permanentlyDenied,
        _ => NotificationPermission.notRequired,
      };
    } on MissingPluginException {
      return NotificationPermission.notRequired;
    } on PlatformException catch (error) {
      AppLogger.warn(
        'Notification permission call failed ($method)',
        scope: 'media_session',
        error: '${error.code}: ${error.message}',
      );
      return NotificationPermission.notRequired;
    }
  }

  /// Opens AURIX's own notification settings, for the permanently-denied case
  /// where the system dialog will never appear again.
  Future<void> openNotificationSettings() async {
    try {
      await _channel.invokeMethod<void>('openNotificationSettings');
    } on MissingPluginException {
      // Nothing to open here.
    } on PlatformException catch (error) {
      AppLogger.warn(
        'Could not open notification settings',
        scope: 'media_session',
        error: error.message,
      );
    }
  }
}
