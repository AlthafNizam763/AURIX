import 'package:flutter/widgets.dart';
import 'package:share_plus/share_plus.dart';

import '../constants/app_constants.dart';
import 'app_logger.dart';

/// What is being shared, so the message reads naturally.
enum ShareKind { track, album, artist, playlist }

/// Builds and presents share sheets.
///
/// ## Which link gets shared
///
/// AURIX shares the **Spotify** link (`open.spotify.com/...`), not an
/// `aurix://` deep link. That is deliberate: a recipient almost certainly
/// does not have AURIX installed, and a link they cannot open is a worse
/// experience than one that opens in Spotify or a browser. The `aurix://`
/// scheme is still registered and handled — see the router — so a link shared
/// between two AURIX users deep-links correctly; [deepLink] builds those.
abstract final class ShareHelper {
  static Future<void> share(
    BuildContext context, {
    required ShareKind kind,
    required String id,
    required String name,
    String? subtitle,
    String? spotifyUrl,
  }) async {
    final url = spotifyUrl ?? webUrl(kind, id);
    final subject = _subjectFor(kind, name, subtitle);

    try {
      // The origin rect matters on iPad, where the share sheet is a popover
      // anchored to the widget that launched it.
      final box = context.findRenderObject() as RenderBox?;
      await SharePlus.instance.share(
        ShareParams(
          text: '$subject\n$url',
          subject: subject,
          sharePositionOrigin: box == null
              ? null
              : box.localToGlobal(Offset.zero) & box.size,
        ),
      );
    } on Object catch (error) {
      AppLogger.warn('Share failed', scope: 'share', error: error);
    }
  }

  /// `https://open.spotify.com/track/{id}` — the canonical public link.
  static String webUrl(ShareKind kind, String id) =>
      'https://${AppConstants.webFallbackHost}/${_path(kind)}/$id';

  /// `aurix://track/{id}` — handled by this app when installed.
  static String deepLink(ShareKind kind, String id) =>
      '${AppConstants.deepLinkScheme}://${_path(kind)}/$id';

  static String _path(ShareKind kind) {
    switch (kind) {
      case ShareKind.track:
        return 'track';
      case ShareKind.album:
        return 'album';
      case ShareKind.artist:
        return 'artist';
      case ShareKind.playlist:
        return 'playlist';
    }
  }

  static String _subjectFor(ShareKind kind, String name, String? subtitle) {
    switch (kind) {
      case ShareKind.track:
        return subtitle == null ? name : '$name — $subtitle';
      case ShareKind.album:
        return subtitle == null ? name : '$name by $subtitle';
      case ShareKind.artist:
        return name;
      case ShareKind.playlist:
        return subtitle == null ? name : '$name · $subtitle';
    }
  }
}
