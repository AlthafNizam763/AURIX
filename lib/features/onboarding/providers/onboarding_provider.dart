import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/providers/app_providers.dart';
import '../../../core/storage/preferences_store.dart';

/// Whether the intro has been seen.
///
/// Backed by a single boolean rather than a "last seen version": onboarding
/// explains what the product *is*, which does not change per release, and
/// versioning it would mean replaying the intro at users who have already been
/// using the app for months.
///
/// The router watches this, so completing onboarding moves the app on without
/// the screen navigating itself — the same arrangement the auth gate uses, and
/// the reason neither can race the other.
class OnboardingController extends Notifier<bool> {
  late final PreferencesStore _prefs;

  @override
  bool build() {
    _prefs = ref.watch(preferencesStoreProvider);
    // Absent counts as "not seen". Writing a default of `false` on first read
    // would be indistinguishable from a user who has genuinely not finished.
    return _prefs.getBool(PrefKeys.onboardingComplete) ?? false;
  }

  Future<void> complete() async {
    if (state) return;
    state = true;
    await _prefs.setBool(PrefKeys.onboardingComplete, true);
  }

  /// Replays the intro. Exposed for the Settings screen rather than for tests,
  /// so a user who skipped it can get it back.
  Future<void> replay() async {
    state = false;
    await _prefs.setBool(PrefKeys.onboardingComplete, false);
  }
}

final onboardingCompleteProvider =
    NotifierProvider<OnboardingController, bool>(OnboardingController.new);
