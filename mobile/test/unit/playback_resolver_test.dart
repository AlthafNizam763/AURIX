import 'package:aurix/data/models/playback.dart';
import 'package:aurix/data/models/track.dart';
import 'package:aurix/data/services/spotify_player_service.dart';
import 'package:aurix/playback/playback_mode.dart';
import 'package:flutter_test/flutter_test.dart';

import '../support/fixtures.dart';

/// These tests pin down the app's central honesty guarantee: a track only ever
/// reports itself as playable when one of Spotify's two authorised playback
/// mechanisms is genuinely available for it.
void main() {
  ConnectAvailabilitySnapshot ready() => ConnectAvailabilitySnapshot(
    status: ConnectStatus.ready,
    activeDevice: Fixtures.device,
    devices: [Fixtures.device],
    checkedAt: DateTime.now(),
  );

  ConnectAvailabilitySnapshot noDevices() => ConnectAvailabilitySnapshot(
    status: ConnectStatus.noDevices,
    checkedAt: DateTime.now(),
  );

  ConnectAvailabilitySnapshot notPremium() => ConnectAvailabilitySnapshot(
    status: ConnectStatus.premiumRequired,
    checkedAt: DateTime.now(),
  );

  ConnectAvailabilitySnapshot idleDevice() => ConnectAvailabilitySnapshot(
    status: ConnectStatus.deviceIdle,
    devices: [Fixtures.device],
    checkedAt: DateTime.now(),
  );

  group('App Remote', () {
    // The case AURIX previously had no answer for: a phone with Spotify
    // installed and no other device signed in anywhere. Connect has nothing to
    // command, and a 30-second preview is not the song — App Remote plays the
    // full track by driving the Spotify app next door.
    test('outranks Connect when the Spotify app is available', () {
      final resolution = PlaybackResolver.resolve(
        track: Fixtures.track,
        preference: PlaybackPreference.connectFirst,
        connect: ready(),
        isOffline: false,
        appRemoteAvailable: true,
      );

      expect(resolution.mode, PlaybackMode.appRemote);
      expect(resolution.limitation, isNull);
      expect(resolution.canPlay, isTrue);
    });

    test('outranks a preview even when the user prefers previews', () {
      // The preference is about *where* audio comes out, and App Remote is
      // still the full track on this phone.
      final resolution = PlaybackResolver.resolve(
        track: Fixtures.track,
        preference: PlaybackPreference.previewFirst,
        connect: noDevices(),
        isOffline: false,
        appRemoteAvailable: true,
      );

      expect(resolution.mode, PlaybackMode.appRemote);
    });

    test('rescues the no-device case that used to be unplayable', () {
      final track = Track.fromJson(Fixtures.trackWithoutPreviewJson);

      final without = PlaybackResolver.resolve(
        track: track,
        preference: PlaybackPreference.connectFirst,
        connect: noDevices(),
        isOffline: false,
      );
      expect(without.mode, PlaybackMode.unavailable);
      expect(without.limitation, PlaybackLimitation.noDevice);

      final with_ = PlaybackResolver.resolve(
        track: track,
        preference: PlaybackPreference.connectFirst,
        connect: noDevices(),
        isOffline: false,
        appRemoteAvailable: true,
      );
      expect(with_.mode, PlaybackMode.appRemote);
    });

    test('does not override offline or local-file refusals', () {
      // App Remote cannot help with either: there is no network, and a local
      // file has no Spotify URI to hand over.
      expect(
        PlaybackResolver.resolve(
          track: Fixtures.track,
          preference: PlaybackPreference.connectFirst,
          connect: ready(),
          isOffline: true,
          appRemoteAvailable: true,
        ).mode,
        PlaybackMode.unavailable,
      );

      expect(
        PlaybackResolver.resolve(
          track: Track.fromJson(Fixtures.localTrackJson),
          preference: PlaybackPreference.connectFirst,
          connect: ready(),
          isOffline: false,
          appRemoteAvailable: true,
        ).mode,
        PlaybackMode.unavailable,
      );
    });

    test('counts as remote and playable, not as local audio', () {
      // Progress mirroring, the device chip and transport enablement all ask
      // these questions rather than matching the enum directly.
      expect(PlaybackMode.appRemote.isPlayable, isTrue);
      expect(PlaybackMode.appRemote.isRemote, isTrue);
      expect(PlaybackMode.appRemote.isLocal, isFalse);
    });
  });

  group('connect-first preference', () {
    test('uses Connect when a device is ready', () {
      final resolution = PlaybackResolver.resolve(
        track: Fixtures.track,
        preference: PlaybackPreference.connectFirst,
        connect: ready(),
        isOffline: false,
      );

      expect(resolution.mode, PlaybackMode.connect);
      expect(resolution.limitation, isNull);
      expect(resolution.canPlay, isTrue);
    });

    test('falls back to a preview when no device is available', () {
      final resolution = PlaybackResolver.resolve(
        track: Fixtures.track,
        preference: PlaybackPreference.connectFirst,
        connect: noDevices(),
        isOffline: false,
      );

      expect(resolution.mode, PlaybackMode.preview);
      expect(resolution.canPlay, isTrue);
      // The user is told they are only getting 30 seconds, and why.
      expect(resolution.limitation, isNotNull);
      expect(resolution.limitation!.isBlocking, isFalse);
    });

    test('an idle device is still usable — it can be woken by transfer', () {
      final resolution = PlaybackResolver.resolve(
        track: Fixtures.track,
        preference: PlaybackPreference.connectFirst,
        connect: idleDevice(),
        isOffline: false,
      );
      expect(resolution.mode, PlaybackMode.connect);
    });
  });

  group('preview-first preference', () {
    test('uses the preview even when Connect is available', () {
      final resolution = PlaybackResolver.resolve(
        track: Fixtures.track,
        preference: PlaybackPreference.previewFirst,
        connect: ready(),
        isOffline: false,
      );
      expect(resolution.mode, PlaybackMode.preview);
      // No notice needed: the user chose this, and Connect is still there.
      expect(resolution.limitation, isNull);
    });

    test('falls back to Connect for a track with no preview', () {
      final resolution = PlaybackResolver.resolve(
        track: Fixtures.trackWithoutPreview,
        preference: PlaybackPreference.previewFirst,
        connect: ready(),
        isOffline: false,
      );
      expect(resolution.mode, PlaybackMode.connect);
    });
  });

  group('refuses to fake playback', () {
    test('no preview and no device means unplayable, not silently playing', () {
      final resolution = PlaybackResolver.resolve(
        track: Fixtures.trackWithoutPreview,
        preference: PlaybackPreference.connectFirst,
        connect: noDevices(),
        isOffline: false,
      );

      expect(resolution.mode, PlaybackMode.unavailable);
      expect(resolution.canPlay, isFalse);
      expect(resolution.limitation!.isBlocking, isTrue);
      expect(resolution.limitation, PlaybackLimitation.noDevice);
    });

    test('a free account with no preview gets the Premium explanation', () {
      final resolution = PlaybackResolver.resolve(
        track: Fixtures.trackWithoutPreview,
        preference: PlaybackPreference.connectFirst,
        connect: notPremium(),
        isOffline: false,
      );

      expect(resolution.mode, PlaybackMode.unavailable);
      expect(resolution.limitation, PlaybackLimitation.premiumRequired);
      expect(resolution.limitation!.action, PlaybackRemedy.learnAboutPremium);
    });

    test('a free account with a preview plays it, and says why it is short', () {
      final resolution = PlaybackResolver.resolve(
        track: Fixtures.track,
        preference: PlaybackPreference.connectFirst,
        connect: notPremium(),
        isOffline: false,
      );

      expect(resolution.mode, PlaybackMode.preview);
      expect(resolution.limitation!.isBlocking, isFalse);
      expect(resolution.limitation!.headline, contains('Premium'));
    });

    test('a local file is never playable, whatever else is available', () {
      final resolution = PlaybackResolver.resolve(
        track: Fixtures.localTrack,
        preference: PlaybackPreference.connectFirst,
        connect: ready(),
        isOffline: false,
      );

      expect(resolution.mode, PlaybackMode.unavailable);
      expect(resolution.limitation, PlaybackLimitation.localFile);
    });

    test('offline blocks playback outright', () {
      final resolution = PlaybackResolver.resolve(
        track: Fixtures.track,
        preference: PlaybackPreference.previewFirst,
        connect: ready(),
        isOffline: true,
      );

      expect(resolution.mode, PlaybackMode.unavailable);
      expect(resolution.limitation, PlaybackLimitation.offline);
      expect(resolution.limitation!.action, PlaybackRemedy.retry);
    });
  });

  group('ConnectAvailabilitySnapshot', () {
    test('goes stale after 30 seconds', () {
      final fresh = ConnectAvailabilitySnapshot(checkedAt: DateTime.now());
      expect(fresh.isStale, isFalse);

      final old = ConnectAvailabilitySnapshot(
        checkedAt: DateTime.now().subtract(const Duration(minutes: 1)),
      );
      expect(old.isStale, isTrue);
    });

    test('a never-checked snapshot is stale', () {
      expect(ConnectAvailabilitySnapshot.unknown.isStale, isTrue);
    });

    test('restricted devices are excluded from the controllable list', () {
      final snapshot = ConnectAvailabilitySnapshot(
        status: ConnectStatus.onlyRestrictedDevices,
        devices: [
          Fixtures.device,
          SpotifyDevice.fromJson(Fixtures.restrictedDeviceJson),
        ],
        checkedAt: DateTime.now(),
      );
      // Both are shown in the picker; only one is selectable.
      expect(snapshot.devices.length, 2);
      expect(snapshot.controllableDevices.length, 1);
      expect(snapshot.controllableDevices.single.id, 'device_1');
    });
  });

  group('ConnectAvailability messages', () {
    test('every blocked status explains itself', () {
      for (final status in ConnectStatus.values) {
        final availability = ConnectAvailability(status: status, devices: const []);
        if (availability.canPlay) {
          expect(availability.blockerMessage, isNull);
        } else {
          expect(
            availability.blockerMessage,
            isNotNull,
            reason: '$status must tell the user what to do',
          );
          expect(availability.blockerMessage, isNotEmpty);
        }
      }
    });
  });
}
