import 'dart:async';

import '../../core/storage/preferences_store.dart';
import '../../core/utils/app_logger.dart';
import '../models/avatar.dart';
import '../models/user_profile.dart';

/// Owns the one part of a profile AURIX itself decides: which bundled avatar
/// the account shows.
///
/// Everything else on a [UserProfile] belongs to Spotify — display name, tier,
/// country, follower count — and this repository does not touch any of it.
///
/// ## What is stored
///
/// A string like `avatar_05`, and nothing else. Never image bytes, never a
/// base64 blob, never a device file path, never a remote URL. That is the whole
/// point of the design: the picture itself is already in the bundle, so the
/// preference is a pointer into a catalogue the app ships rather than
/// user-supplied content the app would have to accept, validate, store and
/// serve. See the rule stated in `avatar.dart`.
///
/// ## Why it is keyed by user
///
/// One device can see more than one Spotify account over its life. A single
/// global key would show the previous user's avatar to the next one, which is
/// the profile-picture equivalent of leaking their library. Keying by
/// `profile.id` also makes the sign-out round trip work correctly: the key is
/// not among those `AuthRepository.signOut` clears, so signing back in restores
/// the same person's choice instead of resetting them to the default.
///
/// ## Reads never fail
///
/// [avatarIdFor] always returns a valid, currently-bundled id. A value written
/// by a newer build, a hand-edited preference and a fresh install with no key
/// at all all resolve to [AvatarCatalog.defaultId] rather than to null, so no
/// caller downstream has to defend against an empty profile picture.
class ProfileRepository {
  ProfileRepository({required PreferencesStore preferences})
      : _prefs = preferences;

  final PreferencesStore _prefs;

  /// The avatar id to display for [profile].
  ///
  /// Reconciles the two places an avatar can come from, in priority order:
  ///
  ///  1. **The profile payload.** [UserProfile.avatarId] is populated only by a
  ///     backend that knows about avatars. Spotify does not, so this is null
  ///     today — but when it is set it is authoritative, because the server is
  ///     the one place two devices can agree.
  ///  2. **Local preferences.** The user's choice on this device.
  ///  3. **The default.** A fresh account, an unrecognised id, or both.
  ///
  /// A remote id that wins is written through to local storage, so the next
  /// launch renders the right avatar from the first frame instead of showing
  /// the default until the profile request comes back.
  String avatarIdFor(UserProfile profile) {
    final remote = profile.avatarId;
    if (AvatarResolver.isValid(remote)) {
      final id = remote!;
      if (_storedId(profile.id) != id) {
        // Fire-and-forget: the value is already being returned, and a failed
        // write costs a re-sync on the next profile load rather than anything
        // the user can see.
        unawaited(_write(profile.id, id));
      }
      return id;
    }

    if (remote != null && remote.isNotEmpty) {
      AppLogger.warn(
        'Profile carried an unknown avatar id "$remote"; '
        'falling back to the local choice',
        scope: 'profile',
      );
    }

    return AvatarResolver.sanitize(_storedId(profile.id));
  }

  /// The stored avatar id for a user id, resolved to something drawable.
  ///
  /// For the callers that have an id but no profile object.
  String avatarIdForUser(String? userId) {
    if (userId == null || userId.isEmpty) return AvatarCatalog.defaultId;
    return AvatarResolver.sanitize(_storedId(userId));
  }

  /// Records the user's choice.
  ///
  /// Rejects anything not in the catalogue rather than storing it: an id that
  /// is not bundled has no image behind it, and writing one would mean a later
  /// read silently falls back to the default with no trace of why.
  Future<void> saveAvatarId(String userId, String avatarId) async {
    if (userId.isEmpty) return;
    if (!AvatarResolver.isValid(avatarId)) {
      AppLogger.warn(
        'Refusing to store unknown avatar id "$avatarId"',
        scope: 'profile',
      );
      return;
    }
    await _write(userId, avatarId);
  }

  /// Whether this user has ever chosen an avatar.
  ///
  /// Distinguishes "chose avatar_01" from "has never opened the picker", which
  /// [avatarIdFor] cannot — both return the default id. Only the picker's
  /// wording uses this; nothing about rendering depends on it.
  bool hasChosenAvatar(String userId) => _storedId(userId) != null;

  String? _storedId(String userId) =>
      userId.isEmpty ? null : _prefs.getString(PrefKeys.profileAvatar(userId));

  Future<void> _write(String userId, String avatarId) =>
      _prefs.setString(PrefKeys.profileAvatar(userId), avatarId);
}
