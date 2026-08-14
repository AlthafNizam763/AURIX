import 'package:flutter/widgets.dart' show AppLifecycleListener;
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../utils/app_logger.dart';

/// Whether AURIX's own UI is on screen.
///
/// ## Why one shared answer
///
/// Three things need to know: the player controller downshifts its interpolation
/// ticker when nothing is watching it, the Dynamic Island swaps between its
/// in-app pill and its floating surface, and the App Remote binding is
/// re-read on the way back. Each of them growing its own
/// `AppLifecycleListener` would mean three observers, three sets of callbacks
/// and three chances for them to disagree about what "backgrounded" means at
/// the moment a track changes.
///
/// This is deliberately *not* a proxy for whether playback continues. Playback
/// belongs to the Spotify app and to the Android media service, and neither of
/// them cares whether AURIX is visible. Nothing in this file may stop, pause or
/// dispose anything — it reports a fact, and the surfaces decide what to do
/// with it.
class AppVisibilityController extends Notifier<bool> {
  AppLifecycleListener? _listener;

  @override
  bool build() {
    _listener = AppLifecycleListener(
      // `show`/`hide` rather than `resume`/`pause`: hide fires the moment the
      // app stops being visible, including the split second before Android
      // finishes the transition to the home screen. Waiting for `pause` leaves
      // the in-app island drawing over a screenshot of itself.
      onShow: () => _set(true),
      onHide: () => _set(false),
      // A resume with no preceding show happens after an interruption the
      // framework does not report as a hide — a permission dialog, the Spotify
      // authorization screen. Without this the app would be stuck reporting
      // itself invisible.
      onResume: () => _set(true),
      onPause: () => _set(false),
    );

    ref.onDispose(() {
      _listener?.dispose();
      _listener = null;
    });

    // Something is building widgets, so AURIX is on screen.
    return true;
  }

  void _set(bool visible) {
    if (state == visible) return;
    state = visible;
    AppLogger.debug(
      visible ? 'AURIX foregrounded' : 'AURIX backgrounded',
      scope: 'lifecycle',
    );
  }
}

/// True while AURIX's UI is on screen. See [AppVisibilityController].
final appVisibilityProvider =
    NotifierProvider<AppVisibilityController, bool>(AppVisibilityController.new);
