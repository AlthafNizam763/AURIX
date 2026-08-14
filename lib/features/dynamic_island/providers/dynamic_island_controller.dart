import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/providers/app_providers.dart';
import '../../../core/providers/app_visibility.dart';
import '../../../core/router/app_router.dart';
import '../../../core/router/navigation.dart';
import '../../../core/router/route_names.dart';
import '../../../core/utils/app_logger.dart';
import '../../../playback/background_island_channel.dart';
import '../../../playback/player_controller.dart';
import '../../settings/providers/settings_provider.dart';

/// What the Dynamic Island is doing, for the Settings screen and for tests.
@immutable
class DynamicIslandStatus {
  const DynamicIslandStatus({
    this.capability = IslandCapability.unsupported,
    this.floatingVisible = false,
  });

  /// What the platform can do, as the platform reports it. Re-read whenever
  /// AURIX comes back to the foreground, because the user may have just changed
  /// the grant in system settings.
  final IslandCapability capability;

  /// Whether a floating surface is on screen outside AURIX right now.
  final bool floatingVisible;

  DynamicIslandStatus copyWith({
    IslandCapability? capability,
    bool? floatingVisible,
  }) => DynamicIslandStatus(
    capability: capability ?? this.capability,
    floatingVisible: floatingVisible ?? this.floatingVisible,
  );

  @override
  bool operator ==(Object other) =>
      other is DynamicIslandStatus &&
      other.capability == capability &&
      other.floatingVisible == floatingVisible;

  @override
  int get hashCode => Object.hash(capability, floatingVisible);
}

/// Keeps the Dynamic Island alive across the app's own lifecycle.
///
/// ## The problem this solves
///
/// [DynamicIslandLayer] draws a Flutter widget above the router. That widget is
/// part of AURIX's widget tree, and a widget tree stops being drawn the moment
/// Android moves the app off screen — no amount of care inside Flutter changes
/// that. So the pill vanishes on Home, which is exactly when a floating music
/// control is most useful.
///
/// This controller is the other half. It owns no player, no queue, no timer and
/// no Spotify connection: it watches the one [PlayerController] the whole app
/// already watches and mirrors what it says onto a surface the OS owns, which
/// keeps drawing after AURIX's own tree has stopped.
///
/// ## Three surfaces, one state
///
/// ```
///                  PlayerController  (single source of truth)
///                          │
///        ┌─────────────────┼──────────────────────┐
///        │                 │                      │
///  in-app pill      MediaSession           floating surface
///  (foreground)   (always, every mode)   (backgrounded, opt-in)
/// ```
///
/// The MediaSession leg is published by [PlayerController] itself and is not
/// touched here — turning the island off must never cost the user their lock
/// screen. This controller is responsible for the third leg only.
///
/// ## What makes it cheap
///
/// Two subscriptions, neither of which runs at tick rate:
///
///  * content changes come from [playbackStateProvider], which is the state
///    with the moving timeline removed, so a position tick does not reach here;
///  * timeline anchors come from `positionUpdatedAt`, which moves only when a
///    *real* position arrives from Spotify — a state push, a five-second
///    resync, a seek. Interpolated ticks leave it alone, so the floating
///    surface is re-anchored on truth and animates the gaps itself.
///
/// There is deliberately no timer in this file.
class DynamicIslandController extends Notifier<DynamicIslandStatus> {
  late final BackgroundIslandChannel _channel;

  StreamSubscription<IslandCommand>? _commands;

  /// The last frame handed to the native side, so an unchanged one is not
  /// republished. Cleared when the surface comes down.
  IslandFrame? _published;

  /// Set when the user swipes the floating surface away. Reset on the next
  /// track change, so dismissing hides *this* song rather than the feature.
  String? _dismissedTrackId;

  /// Guards the show/hide calls, which are async and can otherwise interleave
  /// when a track change lands in the same frame as a background transition.
  Future<void> _pending = Future<void>.value();

  @override
  DynamicIslandStatus build() {
    _channel = ref.watch(backgroundIslandChannelProvider);

    _commands = _channel.commands.listen(_onCommand);

    // Content: track, artwork, transport, duration. Not the position — see the
    // class note. This is the same provider the in-app pill selects, so the two
    // surfaces cannot disagree about what is playing.
    ref.listen<AurixPlaybackState>(
      playbackStateProvider,
      (_, next) => _reconcile(next),
    );

    // Timeline: fires only on a real anchor, never on an interpolated tick.
    ref.listen<DateTime?>(
      playerControllerProvider.select((s) => s.positionUpdatedAt),
      (_, _) => _syncPosition(),
    );

    // Backgrounding is what swaps the in-app pill for the floating surface, and
    // foregrounding is where a permission the user just granted shows up.
    ref.listen<bool>(appVisibilityProvider, (_, visible) {
      if (visible) unawaited(refreshCapability());
      _reconcile(ref.read(playbackStateProvider));
    });

    // Both switches: the feature itself, and the separate opt-in that allows a
    // floating window outside the app.
    ref.listen<({bool island, bool floating})>(
      settingsProvider.select(
        (s) => (island: s.dynamicIsland, floating: s.dynamicIslandOverlay),
      ),
      (_, _) => _reconcile(ref.read(playbackStateProvider)),
    );

    ref.onDispose(() {
      unawaited(_commands?.cancel());
      _commands = null;
      // Leaving a floating window behind after the provider graph is gone would
      // strand a view that nothing can update or remove.
      unawaited(_channel.hide());
    });

    // Asked once at startup. Cheap — it reads a permission bit — and it is what
    // lets Settings render the right row before the user has touched anything.
    unawaited(refreshCapability());

    return const DynamicIslandStatus();
  }

  /// Re-reads what the platform can do.
  ///
  /// Called at startup, on every foreground, and immediately after the user
  /// returns from the system permission screen. It reads state; it never asks
  /// for anything.
  Future<void> refreshCapability() async {
    final capability = await _channel.capability();
    if (capability == state.capability) return;
    state = state.copyWith(capability: capability);
    AppLogger.debug('Island capability: $capability', scope: 'island');
    _reconcile(ref.read(playbackStateProvider));
  }

  /// Sends the user to the system screen where the overlay grant lives, and
  /// re-reads the answer when they come back.
  ///
  /// The only caller is the Settings row that explains the permission. Nothing
  /// reaches this from launch or from playback starting.
  Future<IslandCapability> requestFloatingPermission() async {
    AppLogger.info('Overlay permission requested by the user', scope: 'island');
    final capability = await _channel.requestPermission();
    state = state.copyWith(capability: capability);
    _reconcile(ref.read(playbackStateProvider));
    return capability;
  }

  // -----------------------------------------------------------------------
  // Deciding whether the floating surface belongs on screen
  // -----------------------------------------------------------------------

  /// Whether a floating surface should be up for [playback], right now.
  ///
  /// Every condition here is a reason *not* to draw one, and the order is the
  /// cheap checks first — a user who has never enabled the island pays for one
  /// boolean read per playback change and nothing else.
  bool _shouldFloat(AurixPlaybackState playback) {
    final settings = ref.read(settingsProvider);

    // The existing feature switch. Off by default, and it governs both the
    // in-app pill and this.
    if (!settings.dynamicIsland) return false;

    // The separate, explicit opt-in for drawing outside AURIX. Enabling the
    // island does not imply it.
    if (!settings.dynamicIslandOverlay) return false;

    // The platform must actually have a floating surface, and the grant must
    // already be in hand. This is a read, never a prompt.
    if (!state.capability.isUsable) return false;

    // While AURIX is on screen the in-app pill *is* the island. Two of them at
    // once would be the same control drawn twice, one of them over the other.
    if (ref.read(appVisibilityProvider)) return false;

    final track = playback.track;
    if (track == null) return false;

    // Swiped away for this song.
    if (_dismissedTrackId == track.id) return false;

    // Nothing is playing and nothing is paused mid-song — an idle or
    // unplayable state has no business floating over another app.
    return playback.mode.isPlayable;
  }

  void _reconcile(AurixPlaybackState playback) {
    if (!_shouldFloat(playback)) {
      if (!state.floatingVisible) return;
      _run(() async {
        await _channel.hide();
        _published = null;
        state = state.copyWith(floatingVisible: false);
        AppLogger.debug('Floating island hidden', scope: 'island');
      });
      return;
    }

    final frame = _frameFrom(playback);
    if (frame == null) return;

    // A track change clears a dismissal: the user hid one song, not the app.
    if (_dismissedTrackId != null && _dismissedTrackId != frame.trackId) {
      _dismissedTrackId = null;
    }

    final previous = _published;
    if (previous != null && previous.sameContentAs(frame)) return;

    _run(() async {
      if (state.floatingVisible) {
        await _channel.update(frame);
      } else {
        // A refusal here is normal, not exceptional: the grant can be revoked
        // in system settings while AURIX is not running. Leaving the flag false
        // is what makes the next state change try `show` again rather than
        // spending the rest of the session updating a window that was never
        // added.
        if (!await _channel.show(frame)) {
          AppLogger.info(
            'Floating island refused — re-reading the permission',
            scope: 'island',
          );
          unawaited(refreshCapability());
          return;
        }
        state = state.copyWith(floatingVisible: true);
        AppLogger.info('Floating island shown', scope: 'island');
      }
      _published = frame;
      if (previous?.trackId != frame.trackId) {
        AppLogger.info(
          'Island track: ${frame.title} — ${frame.artist}',
          scope: 'island',
        );
      }
    });
  }

  /// Re-anchors the floating surface's timeline on a real position.
  void _syncPosition() {
    if (!state.floatingVisible) return;
    final playback = ref.read(playerControllerProvider);
    _run(
      () => _channel.syncPosition(
        position: playback.position,
        playing: playback.isPlaying,
      ),
    );
  }

  IslandFrame? _frameFrom(AurixPlaybackState playback) {
    final track = playback.track;
    if (track == null) return null;
    return IslandFrame(
      trackId: track.id.isEmpty ? track.spotifyUri : track.id,
      title: track.name,
      artist: track.artistNames,
      album: track.album?.name,
      artworkUrl: track.artworkUrl,
      playing: playback.isPlaying,
      // Read live rather than taken from [playback].
      //
      // The snapshot this method is handed comes from [playbackStateProvider],
      // which is `timelineAgnostic` — the state with the moving parts removed
      // so a position tick cannot reach here. That is exactly what is wanted
      // for deciding *whether* to republish, and exactly wrong for the value
      // itself: the stripped state carries `Duration.zero`, so taking the
      // position from it would anchor every frame at the start of the track and
      // the island would restart its progress bar on every metadata change.
      position: ref.read(playerControllerProvider).position,
      duration: playback.duration > Duration.zero
          ? playback.duration
          : track.duration,
    );
  }

  // -----------------------------------------------------------------------
  // Commands coming back from the floating surface
  // -----------------------------------------------------------------------

  /// Executes a press made outside AURIX.
  ///
  /// Straight into the same controller a tap on the mini player would reach.
  /// The floating surface has no player of its own, so this is the only thing
  /// its buttons can do — which is the property that keeps a second playback
  /// engine impossible rather than merely discouraged.
  void _onCommand(IslandCommand command) {
    final player = ref.read(playerControllerProvider.notifier);
    final playback = ref.read(playerControllerProvider);

    switch (command) {
      case IslandCommand.play:
        if (!playback.isPlaying) unawaited(player.togglePlayPause());
      case IslandCommand.pause:
        if (playback.isPlaying) unawaited(player.togglePlayPause());
      case IslandCommand.next:
        unawaited(player.next());
      case IslandCommand.previous:
        unawaited(player.previous());
      case IslandCommand.open:
        // The native side has already asked Android to bring AURIX forward.
        // This puts the player screen under the user when it arrives.
        ref.read(routerProvider).pushDistinct(RouteNames.player);
      case IslandCommand.dismiss:
        _dismissedTrackId = playback.track?.id;
        _reconcile(playback);
    }
  }

  /// Serialises channel calls.
  ///
  /// `show` and `hide` are round trips to the platform, and a track change
  /// arriving while a `show` is still in flight would otherwise publish the two
  /// frames out of order — which shows up as the previous song's artwork
  /// sticking after a skip.
  void _run(Future<void> Function() action) {
    _pending = _pending.then((_) => action()).catchError((Object error) {
      AppLogger.debug('Island channel call failed: $error', scope: 'island');
    });
  }
}

final dynamicIslandControllerProvider =
    NotifierProvider<DynamicIslandController, DynamicIslandStatus>(
      DynamicIslandController.new,
    );

/// What the platform can do with a floating surface. Read by Settings.
final islandCapabilityProvider = Provider<IslandCapability>(
  (ref) => ref.watch(
    dynamicIslandControllerProvider.select((s) => s.capability),
  ),
);
