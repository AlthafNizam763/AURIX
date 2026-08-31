import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/utils/app_logger.dart';
import '../../../data/models/avatar.dart';
import '../../auth/providers/auth_provider.dart';

/// The profile state every AURIX surface reads its avatar from.
///
/// One object, one owner. The alternative — each screen resolving its own
/// avatar — is what produces the bug where the header updates and the drawer
/// does not, and it is why this exists as state rather than as a helper
/// function.
@immutable
class ProfileState {
  const ProfileState({required this.userId, required this.selectedAvatarId});

  /// The Firebase UID this state belongs to, or null when signed out.
  ///
  /// Carried so a stale state can never be attributed to the wrong user: the
  /// controller rebuilds when the signed-in account changes, and this is what
  /// makes that visible in tests.
  final String? userId;

  /// Always a valid, currently-bundled avatar id — never null, never unknown.
  ///
  /// Resolved on the way in, so no widget downstream has to handle "no picture"
  /// as a case.
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
/// ## Where the avatar lives now
///
/// In the `avatarId` field of `/users/{uid}`. It used to live in
/// `SharedPreferences`, keyed by Spotify account id, which had one consequence
/// worth naming: a user who picked an avatar on their phone saw the default on
/// their tablet, because a local preference is not an account setting.
///
/// The write path is therefore a Firestore write now, and the read path is not
/// a read at all — [currentUserProvider] already follows the user document, so
/// this controller derives its state from that stream and never queries.
///
/// ## Why the local echo is still here
///
/// [selectAvatar] sets state before awaiting the write. Firestore's offline
/// cache would deliver the same optimistic update through the snapshot listener
/// a moment later anyway, but "a moment later" is one to two frames, and a
/// picker whose selection lands on the next frame feels broken. The echo makes
/// it land on the same frame as the tap, and the listener's value is identical
/// when it arrives.
class ProfileController extends Notifier<ProfileState> {
  @override
  ProfileState build() {
    final user = ref.watch(currentUserProvider);
    if (user == null) return ProfileState.signedOut;

    return ProfileState(
      userId: user.uid,
      selectedAvatarId: user.avatarId,
    );
  }

  /// Applies the user's choice.
  ///
  /// Unknown ids are refused rather than stored — an id with no bundled asset
  /// behind it would render as an empty circle on every surface.
  Future<void> selectAvatar(String avatarId) async {
    if (!AvatarResolver.isValid(avatarId)) {
      AppLogger.warn(
        'Refusing to select unknown avatar id "$avatarId"',
        scope: 'profile',
      );
      return;
    }
    if (state.selectedAvatarId == avatarId) return;

    final previous = state.selectedAvatarId;
    state = state.copyWith(selectedAvatarId: avatarId);

    final userId = state.userId;
    if (userId == null) return;

    try {
      await ref.read(authControllerProvider.notifier).setAvatar(avatarId);
    } on Object catch (error) {
      // Rolled back rather than left showing a choice that was not saved. The
      // offline case does *not* reach here — Firestore queues the write and
      // resolves the future — so anything that does is a real refusal.
      if (state.userId == userId) {
        state = state.copyWith(selectedAvatarId: previous);
      }
      AppLogger.warn('Avatar write failed', scope: 'profile', error: error);
    }
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
