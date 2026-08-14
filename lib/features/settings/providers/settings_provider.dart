import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/providers/app_providers.dart';
import '../../../core/storage/preferences_store.dart';
import '../../../data/models/user_profile.dart';
import '../../../playback/playback_mode.dart';
import '../../auth/providers/auth_provider.dart';

/// Streaming quality options.
///
/// Spotify's Web API does not expose a bitrate control — the audio AURIX can
/// play is either a fixed-bitrate preview or is decoded by the Spotify client
/// on a Connect device, which uses its own quality setting. This preference
/// therefore governs what AURIX itself controls: whether to stream previews
/// on a metered connection. The Settings screen states that plainly rather
/// than implying a control that does not exist.
enum StreamingQuality {
  dataSaver('Data saver', 'Skip preview streaming on mobile data'),
  automatic('Automatic', 'Stream previews on any connection'),
  high('High', 'Always stream previews at full quality');

  const StreamingQuality(this.label, this.description);
  final String label;
  final String description;
}

@immutable
class AppSettings {
  const AppSettings({
    this.themeMode = ThemeMode.dark,
    this.playbackPreference = PlaybackPreference.connectFirst,
    this.streamingQuality = StreamingQuality.automatic,
    this.streamOverCellular = true,
    this.gaplessPlayback = true,
    this.autoplaySimilar = true,
    this.normalizeVolume = false,
    this.showExplicit = true,
    this.notifyNewReleases = true,
    this.notifyRecommendations = false,
    this.reduceMotion = false,
    this.dynamicIsland = false,
    this.dynamicIslandOverlay = false,
    this.crossfadeSeconds = 0,
  });

  /// The only appearance control AURIX exposes.
  ///
  /// There used to be a second one — a brand colourway picker. It was removed
  /// with the monochrome identity rather than reduced to greyscale options: a
  /// palette with one accent has nothing to vary, and offering "shades of black"
  /// would be a setting that does almost nothing. The stored `themeVariant` key
  /// is left orphaned in preferences on purpose; see [PrefKeys.themeVariant].
  final ThemeMode themeMode;

  final PlaybackPreference playbackPreference;
  final StreamingQuality streamingQuality;
  final bool streamOverCellular;
  final bool gaplessPlayback;
  final bool autoplaySimilar;
  final bool normalizeVolume;
  final bool showExplicit;
  final bool notifyNewReleases;
  final bool notifyRecommendations;

  /// Honours the OS "reduce motion" preference and lets the user force it.
  /// Every decorative animation checks this.
  final bool reduceMotion;

  /// Shows the floating Dynamic Island pill above the app while something is
  /// playing. Purely an AURIX surface — it simulates the interaction in-app
  /// rather than driving any hardware cutout, so it behaves identically on a
  /// notch, a punch-hole and a flat-topped screen.
  ///
  /// **Opt-in, and it must stay that way.** The default is `false` here *and*
  /// in [SettingsController._read]'s fallback, which are two different defaults
  /// doing two different jobs: this one covers a settings object built without
  /// arguments, the other covers a real install whose preferences have no such
  /// key yet — a fresh install, and a reinstall. Changing one without the other
  /// is how an opt-in feature quietly turns itself on.
  ///
  /// Nothing else in the app may write this. It moves when the user moves the
  /// switch in Settings, and at no other time — not on first launch, not on
  /// update, not from an onboarding prompt.
  final bool dynamicIsland;

  /// Whether the island may keep drawing after AURIX leaves the screen.
  ///
  /// Its own consent, deliberately not folded into [dynamicIsland]. The in-app
  /// pill is a decoration inside the user's own app; a floating window outside
  /// it needs Android's `SYSTEM_ALERT_WINDOW`, which is a system-level grant the
  /// user makes in Settings and which AURIX must never ask for as a side effect
  /// of switching on a visual preference. Turning this on does not grant
  /// anything — the Settings row explains the permission and sends the user to
  /// the system screen only when they tap it.
  ///
  /// Irrelevant to background *playback*, which continues regardless: audio
  /// belongs to Spotify and the media session belongs to the Android media
  /// service, and neither reads this.
  final bool dynamicIslandOverlay;

  final int crossfadeSeconds;

  AppSettings copyWith({
    ThemeMode? themeMode,
    PlaybackPreference? playbackPreference,
    StreamingQuality? streamingQuality,
    bool? streamOverCellular,
    bool? gaplessPlayback,
    bool? autoplaySimilar,
    bool? normalizeVolume,
    bool? showExplicit,
    bool? notifyNewReleases,
    bool? notifyRecommendations,
    bool? reduceMotion,
    bool? dynamicIsland,
    bool? dynamicIslandOverlay,
    int? crossfadeSeconds,
  }) => AppSettings(
    themeMode: themeMode ?? this.themeMode,
    playbackPreference: playbackPreference ?? this.playbackPreference,
    streamingQuality: streamingQuality ?? this.streamingQuality,
    streamOverCellular: streamOverCellular ?? this.streamOverCellular,
    gaplessPlayback: gaplessPlayback ?? this.gaplessPlayback,
    autoplaySimilar: autoplaySimilar ?? this.autoplaySimilar,
    normalizeVolume: normalizeVolume ?? this.normalizeVolume,
    showExplicit: showExplicit ?? this.showExplicit,
    notifyNewReleases: notifyNewReleases ?? this.notifyNewReleases,
    notifyRecommendations: notifyRecommendations ?? this.notifyRecommendations,
    reduceMotion: reduceMotion ?? this.reduceMotion,
    dynamicIsland: dynamicIsland ?? this.dynamicIsland,
    dynamicIslandOverlay: dynamicIslandOverlay ?? this.dynamicIslandOverlay,
    crossfadeSeconds: crossfadeSeconds ?? this.crossfadeSeconds,
  );
}

class SettingsController extends Notifier<AppSettings> {
  late final PreferencesStore _prefs;

  @override
  AppSettings build() {
    _prefs = ref.watch(preferencesStoreProvider);
    return _read();
  }

  AppSettings _read() => AppSettings(
    themeMode: _themeFrom(_prefs.getString(PrefKeys.themeMode)),
    playbackPreference: _playbackFrom(_prefs.getString(PrefKeys.preferredPlaybackMode)),
    streamingQuality: _qualityFrom(_prefs.getString(PrefKeys.streamingQuality)),
    streamOverCellular: _prefs.getBool(PrefKeys.downloadOverCellular) ?? true,
    gaplessPlayback: _prefs.getBool(PrefKeys.gaplessPlayback) ?? true,
    autoplaySimilar: _prefs.getBool(PrefKeys.autoplaySimilar) ?? true,
    normalizeVolume: _prefs.getBool(PrefKeys.normalizeVolume) ?? false,
    showExplicit: _prefs.getBool(PrefKeys.showExplicit) ?? true,
    notifyNewReleases: _prefs.getBool(PrefKeys.notificationsNewReleases) ?? true,
    notifyRecommendations: _prefs.getBool(PrefKeys.notificationsRecommendations) ?? false,
    reduceMotion: _prefs.getBool(PrefKeys.reduceMotion) ?? false,
    // Absent means off. A fresh install has no key, and neither does a
    // reinstall — see the backup rules in android/app/src/main/res/xml, which
    // keep this preference out of Android's cloud restore so a reinstalled
    // AURIX genuinely starts from nothing rather than from last time.
    dynamicIsland: _prefs.getBool(PrefKeys.dynamicIsland) ?? false,
    // Absent means off, for the same reasons and with the same backup
    // exclusion. A grant the user made on a previous install must not be
    // implied by a restored preference on a new one.
    dynamicIslandOverlay: _prefs.getBool(PrefKeys.dynamicIslandOverlay) ?? false,
    crossfadeSeconds: _prefs.getInt(PrefKeys.crossfadeSeconds) ?? 0,
  );

  Future<void> setThemeMode(ThemeMode mode) async {
    state = state.copyWith(themeMode: mode);
    await _prefs.setString(PrefKeys.themeMode, mode.name);
  }

  Future<void> setPlaybackPreference(PlaybackPreference preference) async {
    state = state.copyWith(playbackPreference: preference);
    await _prefs.setString(PrefKeys.preferredPlaybackMode, preference.name);
  }

  Future<void> setStreamingQuality(StreamingQuality quality) async {
    state = state.copyWith(streamingQuality: quality);
    await _prefs.setString(PrefKeys.streamingQuality, quality.name);
  }

  Future<void> setStreamOverCellular(bool value) async {
    state = state.copyWith(streamOverCellular: value);
    await _prefs.setBool(PrefKeys.downloadOverCellular, value);
  }

  Future<void> setGapless(bool value) async {
    state = state.copyWith(gaplessPlayback: value);
    await _prefs.setBool(PrefKeys.gaplessPlayback, value);
  }

  Future<void> setAutoplaySimilar(bool value) async {
    state = state.copyWith(autoplaySimilar: value);
    await _prefs.setBool(PrefKeys.autoplaySimilar, value);
  }

  Future<void> setNormalizeVolume(bool value) async {
    state = state.copyWith(normalizeVolume: value);
    await _prefs.setBool(PrefKeys.normalizeVolume, value);
  }

  Future<void> setShowExplicit(bool value) async {
    state = state.copyWith(showExplicit: value);
    await _prefs.setBool(PrefKeys.showExplicit, value);
  }

  Future<void> setNotifyNewReleases(bool value) async {
    state = state.copyWith(notifyNewReleases: value);
    await _prefs.setBool(PrefKeys.notificationsNewReleases, value);
  }

  Future<void> setNotifyRecommendations(bool value) async {
    state = state.copyWith(notifyRecommendations: value);
    await _prefs.setBool(PrefKeys.notificationsRecommendations, value);
  }

  Future<void> setReduceMotion(bool value) async {
    state = state.copyWith(reduceMotion: value);
    await _prefs.setBool(PrefKeys.reduceMotion, value);
  }

  /// Switches the Dynamic Island on or off.
  ///
  /// Switching it *off* also withdraws the outside-the-app consent, so the
  /// floating window cannot survive the feature that owns it. The system
  /// permission itself is untouched — revoking a grant is the user's business
  /// and lives in system settings, not here — and neither is playback, the
  /// media session or the notification.
  Future<void> setDynamicIsland(bool value) async {
    state = state.copyWith(
      dynamicIsland: value,
      dynamicIslandOverlay: value ? null : false,
    );
    await _prefs.setBool(PrefKeys.dynamicIsland, value);
    if (!value) await _prefs.setBool(PrefKeys.dynamicIslandOverlay, false);
  }

  /// Records whether the island may draw outside AURIX.
  ///
  /// Stores a preference and nothing more. It does not request the overlay
  /// permission — [DynamicIslandController.requestFloatingPermission] does
  /// that, from the Settings row that explains it, on an explicit tap.
  Future<void> setDynamicIslandOverlay(bool value) async {
    state = state.copyWith(dynamicIslandOverlay: value);
    await _prefs.setBool(PrefKeys.dynamicIslandOverlay, value);
  }

  Future<void> setCrossfadeSeconds(int seconds) async {
    final clamped = seconds.clamp(0, 12);
    state = state.copyWith(crossfadeSeconds: clamped);
    await _prefs.setInt(PrefKeys.crossfadeSeconds, clamped);
  }

  ThemeMode _themeFrom(String? raw) => switch (raw) {
    'light' => ThemeMode.light,
    'system' => ThemeMode.system,
    _ => ThemeMode.dark,
  };

  PlaybackPreference _playbackFrom(String? raw) => switch (raw) {
    'previewFirst' => PlaybackPreference.previewFirst,
    _ => PlaybackPreference.connectFirst,
  };

  StreamingQuality _qualityFrom(String? raw) => switch (raw) {
    'dataSaver' => StreamingQuality.dataSaver,
    'high' => StreamingQuality.high,
    _ => StreamingQuality.automatic,
  };
}

final settingsProvider = NotifierProvider<SettingsController, AppSettings>(
  SettingsController.new,
);

/// Convenience: true when animations should be suppressed, honouring both the
/// in-app setting and the OS accessibility preference.
final reduceMotionProvider = Provider<bool>((ref) {
  return ref.watch(settingsProvider.select((s) => s.reduceMotion));
});

/// Where the decision about explicit content came from.
///
/// The distinction drives what the UI is allowed to offer, not just what it
/// says: only [localPreference] is something the user can change here.
enum ExplicitContentAuthority {
  /// Spotify enforces the filter and the account cannot switch it off —
  /// a managed or parental-controlled account.
  accountLocked,

  /// The Spotify account filters explicit content, but the account holder
  /// could change that in Spotify's own settings.
  accountFiltered,

  /// Spotify allows explicit content; the in-app preference decides whether
  /// the "E" marker is shown.
  localPreference,

  /// Spotify did not report a filter at all. Development Mode apps no longer
  /// receive `explicit_content` on `/me`, and it is absent for a token
  /// without `user-read-private`, so this is a normal state — not an error.
  unknown,
}

/// The app's effective explicit-content policy.
///
/// Combines what Spotify says about the account with the local display
/// preference, and keeps the two distinguishable. Collapsing them into one
/// boolean would lose the case that matters most: a filter Spotify has locked,
/// where showing an enabled switch would promise a change the app cannot make.
///
/// Deliberately independent of the sign-in flow — it reads the profile that
/// authentication already produced and nothing else.
@immutable
class ExplicitContentPolicy {
  const ExplicitContentPolicy({
    required this.account,
    required this.showExplicitPreference,
  });

  /// What Spotify reported, or null when it reported nothing.
  final ExplicitContentSettings? account;

  /// The in-app "Show explicit content" preference.
  final bool showExplicitPreference;

  ExplicitContentAuthority get authority {
    final settings = account;
    if (settings == null) return ExplicitContentAuthority.unknown;
    if (settings.filterLocked) return ExplicitContentAuthority.accountLocked;
    if (settings.filterEnabled) return ExplicitContentAuthority.accountFiltered;
    return ExplicitContentAuthority.localPreference;
  }

  /// True when explicit content may be surfaced.
  ///
  /// The account filter always wins when Spotify has stated one; the local
  /// preference only decides when Spotify permits explicit content.
  bool get allowsExplicit {
    final settings = account;
    if (settings != null && settings.filterEnabled) return false;
    return showExplicitPreference;
  }

  /// True when Spotify's filter is on, whether or not it is locked.
  bool get filteredBySpotify => account?.filterEnabled ?? false;

  /// True when the in-app toggle must be disabled, because Spotify owns this
  /// decision for this account.
  bool get isLockedByAccount => account?.filterLocked ?? false;

  /// The line shown under the settings row.
  String get description => switch (authority) {
    ExplicitContentAuthority.accountLocked =>
      'Your Spotify account filters explicit content and has this locked',
    ExplicitContentAuthority.accountFiltered =>
      'Filtered by your Spotify account — change it in Spotify settings',
    ExplicitContentAuthority.localPreference =>
      'Display the explicit marker on tracks',
    ExplicitContentAuthority.unknown =>
      'Display the explicit marker on tracks',
  };
}

/// The effective explicit-content policy for the signed-in account.
final explicitContentPolicyProvider = Provider<ExplicitContentPolicy>((ref) {
  final profile = ref.watch(currentUserProvider);
  final showExplicit = ref.watch(settingsProvider.select((s) => s.showExplicit));
  return ExplicitContentPolicy(
    account: profile?.explicitContent,
    showExplicitPreference: showExplicit,
  );
});
