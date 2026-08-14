import 'dart:async';

import 'package:audio_service/audio_service.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/router/app_router.dart';
import '../core/router/navigation.dart';
import '../core/router/route_names.dart';
import '../core/utils/app_logger.dart';
import 'player_controller.dart';

/// Sends a tap on the media notification to the player screen.
///
/// ## Why this needs code at all
///
/// `androidNotificationClickStartsActivity` gets AURIX as far as *open*: the
/// pending intent behind the notification brings `MainActivity` forward, and
/// Android's job ends there. What the user lands on is whatever screen the app
/// was last showing, which after a spell in the background is usually the list
/// they started the song from — not the song. Closing that gap is a Flutter
/// concern, because only Flutter owns the route stack.
///
/// `audio_service` reports the click as a `true` on
/// [AudioService.notificationClicked]; it is a `BehaviorSubject`, seeded false
/// and set from the launching intent's action, so subscribing is safe before
/// anything has been clicked and on platforms where nothing ever will be.
///
/// ## What it deliberately does not do
///
/// It does not start, resume or touch playback. A notification tap is a request
/// to *look* at what is playing — the transport buttons are two millimetres
/// away for anyone who meant to press one — so this navigates and nothing else.
/// It also refuses to navigate when there is no track, which is the state left
/// behind by a stale notification: pushing an empty player screen over the
/// user's place in the app would be worse than ignoring the tap.
class MediaNotificationTaps {
  MediaNotificationTaps({
    required Stream<bool> clicks,
    required bool Function() hasTrack,
    required void Function() openPlayer,
  }) : _hasTrack = hasTrack,
       _openPlayer = openPlayer {
    _subscription = clicks.listen(_onClick);
  }

  final bool Function() _hasTrack;
  final void Function() _openPlayer;

  StreamSubscription<bool>? _subscription;

  void _onClick(bool clicked) {
    if (!clicked) return;
    if (!_hasTrack()) {
      AppLogger.debug(
        'Notification tapped with nothing loaded — staying put',
        scope: 'media_session',
      );
      return;
    }
    AppLogger.info('Notification tapped — opening the player', scope: 'media_session');
    _openPlayer();
  }

  Future<void> dispose() async {
    await _subscription?.cancel();
    _subscription = null;
  }
}

/// Mounted for the life of the app from `AurixApp`, so a tap is handled whether
/// or not any particular screen happens to be on top.
///
/// `pushDistinct` rather than `push`: the user may well tap the notification
/// while already looking at the player, and stacking a second copy of it would
/// make Back "return" to the screen they are already on.
final mediaNotificationTapsProvider = Provider<MediaNotificationTaps>((ref) {
  final taps = MediaNotificationTaps(
    clicks: AudioService.notificationClicked,
    hasTrack: () => ref.read(playerControllerProvider).hasTrack,
    openPlayer: () => ref.read(routerProvider).pushDistinct(RouteNames.player),
  );
  ref.onDispose(taps.dispose);
  return taps;
});
