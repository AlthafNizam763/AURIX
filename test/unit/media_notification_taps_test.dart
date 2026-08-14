import 'dart:async';

import 'package:aurix/playback/media_notification_taps.dart';
import 'package:flutter_test/flutter_test.dart';

/// Tapping the media notification has to land on the player screen.
///
/// The Android side only gets as far as bringing AURIX forward; which route the
/// user arrives on is Flutter's decision, and it is the difference between
/// "AURIX opened" and "AURIX opened on the song you tapped".
void main() {
  late StreamController<bool> clicks;
  late int opened;
  late bool hasTrack;

  MediaNotificationTaps build() {
    final taps = MediaNotificationTaps(
      clicks: clicks.stream,
      hasTrack: () => hasTrack,
      openPlayer: () => opened++,
    );
    addTearDown(taps.dispose);
    return taps;
  }

  setUp(() {
    clicks = StreamController<bool>.broadcast();
    opened = 0;
    hasTrack = true;
    addTearDown(clicks.close);
  });

  test('a tap opens the player', () async {
    build();
    clicks.add(true);
    await pumpEventQueue();

    expect(opened, 1);
  });

  test('an ordinary launch does not', () async {
    // `AudioService.notificationClicked` is seeded false and re-reports false
    // whenever the activity attaches for any other reason. Acting on that would
    // push the player screen every time the app opened.
    build();
    clicks.add(false);
    await pumpEventQueue();

    expect(opened, 0);
  });

  test('a stale notification with nothing loaded is ignored', () async {
    // Pushing an empty player over wherever the user was is worse than doing
    // nothing at all.
    hasTrack = false;
    build();
    clicks.add(true);
    await pumpEventQueue();

    expect(opened, 0);
  });

  test('two taps are two navigations, not one', () async {
    build();
    clicks
      ..add(true)
      ..add(false)
      ..add(true);
    await pumpEventQueue();

    expect(opened, 2);
  });

  test('disposing stops listening', () async {
    final taps = build();
    await taps.dispose();

    clicks.add(true);
    await pumpEventQueue();

    expect(opened, 0);
  });
}
