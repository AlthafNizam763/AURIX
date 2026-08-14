import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/providers/app_providers.dart';
import '../../../data/models/avatar.dart';
import '../../../data/repositories/profile_repository.dart';
import '../../auth/providers/auth_provider.dart';

/// The profile state every AURIX surface reads its avatar from.
///
/// One object, one owner. The alternative — each screen resolving its own
/// avatar from preferences — is what produces the bug where the header updates
/// and the drawer does not, and it is why this exists as state rather than as a
/// helper function.
@immutable
class ProfileState {
  const ProfileState({required this.userId, required this.selectedAvatarId});

  /// The Spotify account this state belongs to, or null when signed out.
  ///
  /// Carried so a stale state can never be attributed to the wrong user: the
  /// controller rebuilds when the signed-in account changes, and this is what
  /// makes that visible in tests.
  final String? userId;

  /// Always a valid, currently-bundled avatar id — never null, never unknown.
  ///
  /// The resolution happens once, on the way in through [ProfileRepository], so
  /// that no widget downstream has to handle "no picture" as a case.
  final String selectedAvatarId;

  /// The avatar itself, ready to draw.
  Avatar get avatar => AvatarResolver.resolve(selectedAvatarId);

  /// What a signed-out app shows. The default avatar rather than a blank:
  /// there is no state in which AURIX draws an empty profile picture.
  static const ProfileState signedOut = ProfileState(
    userId: null,
    selectedAvatarId: AvatarCatalog.defaultId,
  );

  ProfileState copyWith({String? selectedAvatarId}) => ProfileState(
    userId: userId,
    selectedAvatarId: selectedAvatarId ?? this.selectedAvatarId,
  );

  @override
  bool operator ==(Object other) =>
      other is ProfileState &&
      other.userId == userId &&
      other.selectedAvatarId == selectedAvatarId;

  @override
  int get hashCode => Object.hash(userId, selectedAvatarId);
}

/// Reads and writes the selected avatar.
///
/// Rebuilds whenever the signed-in account changes, which is what makes the
/// sign-out/sign-in round trip work without any explicit wiring: a new account
/// re-reads *its* stored choice, and signing out falls back to [ProfileState
/// .signedOut]. The same rebuild also picks up an `avatarId` arriving on a
/// refreshed profile, if a backend ever sends one.
class ProfileController extends Notifier<ProfileState> {
  late final ProfileRepository _repository;

  @override
  ProfileState build() {
    _repository = ref.watch(profileRepositoryProvider);
    final profile = ref.watch(currentUserProvider);

    if (profile == null) return ProfileState.signedOut;

    return ProfileState(
      userId: profile.id,
      selectedAvatarId: _repository.avatarIdFor(profile),
    );
  }

  /// Applies the user's choice.
  ///
  /// State moves first and the write follows, so the preview updates on the
  /// same frame as the tap — the selection is a local decision against a
  /// bundled asset, and there is nothing to wait for. No request is made: this
  /// works identically online and offline, which is the behaviour the picker
  /// promises by opening instantly in the first place.
  ///
  /// Unknown ids are refused rather than stored; see
  /// [ProfileRepository.saveAvatarId].
  Future<void> selectAvatar(String avatarId) async {
    if (!AvatarResolver.isValid(avatarId)) return;
    if (state.selectedAvatarId == avatarId) return;

    state = state.copyWith(selectedAvatarId: avatarId);

    final userId = state.userId;
    if (userId == null) return;
    await _repository.saveAvatarId(userId, avatarId);
  }
}

final profileProvider = NotifierProvider<ProfileController, ProfileState>(
  ProfileController.new,
);

/// The avatar to draw, anywhere in the app.
///
/// Every profile-picture surface watches this one provider — the profile
/// screen, Edit Profile, the home header, the library header, sheets and user
/// rows. Because [Avatar] compares by id, a rebuild only reaches a widget when
/// the selection genuinely changed.
final selectedAvatarProvider = Provider<Avatar>(
  (ref) => ref.watch(profileProvider.select((state) => state.avatar)),
);
