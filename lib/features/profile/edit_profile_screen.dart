import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/theme/app_dimens.dart';
import '../../core/theme/app_typography.dart';
import '../../core/theme/aurix_palette.dart';
import '../../core/utils/responsive.dart';
import '../../data/models/avatar.dart';
import '../../data/models/user_profile.dart';
import '../../shared/widgets/feedback/state_views.dart';
import '../../shared/widgets/icons/aurix_glyphs.dart';
import '../../shared/widgets/icons/aurix_icon.dart';
import '../../shared/widgets/media/aurix_avatar.dart';
import '../auth/providers/auth_provider.dart';
import '../settings/widgets/settings_widgets.dart';
import 'providers/profile_provider.dart';
import 'widgets/avatar_picker_sheet.dart';

/// Edit Profile.
///
/// The name is honest about a narrow screen: exactly one thing here is
/// editable, and it is the profile picture. Everything else about an AURIX
/// profile — display name, email, country, subscription tier — is Spotify's
/// record of the account, and the Web API offers no way to change any of it.
/// Rather than presenting text fields that would silently fail to save, those
/// are shown as what they are: a read-only account summary, with a line saying
/// where they *can* be changed.
///
/// The picture is a different case, because AURIX owns it entirely. There is no
/// upload, no gallery, no camera and no file picker — see [AvatarPickerSheet]
/// — so "editing" a profile picture here means choosing from the bundled
/// catalogue, and the change is saved the moment it is made.
class EditProfileScreen extends ConsumerWidget {
  const EditProfileScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final user = ref.watch(currentUserProvider);

    return Scaffold(
      backgroundColor: context.palette.ground,
      appBar: AppBar(title: const Text('Edit Profile')),
      body: user == null
          ? const EmptyView(
              icon: AurixGlyph.profile,
              title: 'Not signed in',
              message: 'Sign in with Spotify to edit your profile.',
            )
          : ContentBounds(
              child: ListView(
                physics: const AlwaysScrollableScrollPhysics(
                  parent: BouncingScrollPhysics(),
                ),
                children: [
                  _AvatarPreview(user: user),

                  const SettingsGroup(title: 'Profile picture'),
                  const _ChooseAvatarTile(),
                  SettingsNote(
                    text: 'AURIX profile pictures come from a set of '
                        '${AvatarCatalog.count} bundled avatars. There is no '
                        'upload — AURIX never reads your photos, your camera '
                        'or your files, and asks for no permission to.',
                  ),

                  const SettingsGroup(title: 'Spotify account'),
                  _ReadOnlyRow(
                    icon: AurixGlyph.profile,
                    label: 'Display name',
                    value: user.displayName,
                  ),
                  if (user.email != null)
                    _ReadOnlyRow(
                      icon: AurixGlyph.mail,
                      label: 'Email',
                      value: user.email!,
                    ),
                  if (user.country != null)
                    _ReadOnlyRow(
                      icon: AurixGlyph.pin,
                      label: 'Country',
                      value: user.country!,
                    ),
                  _ReadOnlyRow(
                    icon: user.hasPremium
                        ? AurixGlyph.premium
                        : AurixGlyph.musicNote,
                    label: 'Plan',
                    value: user.product.label,
                  ),
                  const SettingsNote(
                    text: 'These belong to your Spotify account. Spotify does '
                        'not let an app change them, so they are shown here as '
                        'a record — change them in Spotify itself and pull to '
                        'refresh your profile.',
                  ),

                  const SizedBox(height: AppSpacing.huge),
                ],
              ),
            ),
    );
  }
}

/// The current avatar, large, with the whole thing acting as the control.
///
/// The picture *is* the button — tapping your own face is where everyone
/// reaches first — but a tap target with no visible affordance is a secret, so
/// it carries a badge and is followed by a row that says the same thing in
/// words. Both routes open the same sheet.
class _AvatarPreview extends ConsumerWidget {
  const _AvatarPreview({required this.user});

  final UserProfile user;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final avatar = ref.watch(selectedAvatarProvider);
    final palette = context.palette;

    return Padding(
      padding: EdgeInsets.fromLTRB(
        context.pageGutter,
        AppSpacing.xl,
        context.pageGutter,
        AppSpacing.sm,
      ),
      child: Column(
        children: [
          Semantics(
            button: true,
            label: 'Profile picture, ${avatar.name}. Choose a different avatar',
            excludeSemantics: true,
            child: InkWell(
              onTap: () => AvatarPickerSheet.show(context),
              customBorder: const CircleBorder(),
              child: Padding(
                padding: const EdgeInsets.all(AppSpacing.sm),
                child: Stack(
                  alignment: Alignment.center,
                  children: [
                    AurixAvatar(
                      avatar: avatar,
                      size: AppSizes.avatarLg,
                      elevated: true,
                      borderColor: palette.hairlineStrong,
                      borderWidth: 1,
                    ),
                    Positioned(
                      // Off the corner, onto the rim — see the same note in
                      // the picker's tile.
                      right: 2,
                      bottom: 2,
                      child: Container(
                        width: 30,
                        height: 30,
                        decoration: BoxDecoration(
                          color: palette.accent,
                          shape: BoxShape.circle,
                          border: Border.all(color: palette.ground, width: 2),
                        ),
                        alignment: Alignment.center,
                        // A palette glyph, deliberately not a camera. The icon
                        // is a promise about what happens next, and a camera
                        // here would promise the one thing this screen will
                        // never do.
                        child: AurixIcon(
                          AurixGlyph.palette,
                          size: 15,
                          color: palette.textOnAccent,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
          const SizedBox(height: AppSpacing.md),
          Text(
            user.displayName,
            style: AppTypography.titleMedium,
            textAlign: TextAlign.center,
          ),
          const SizedBox(height: AppSpacing.xxs),
          const Text(
            'Tap your picture to choose an avatar',
            style: AppTypography.bodySmall,
            textAlign: TextAlign.center,
          ),
        ],
      ),
    );
  }
}

/// The named route into the picker, carrying a live thumbnail of the choice.
class _ChooseAvatarTile extends ConsumerWidget {
  const _ChooseAvatarTile();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final avatar = ref.watch(selectedAvatarProvider);

    return SettingsTile(
      icon: AurixGlyph.palette,
      title: 'Choose Avatar',
      subtitle: '${avatar.name} · ${AvatarCatalog.count} to choose from',
      onTap: () => AvatarPickerSheet.show(context),
      trailing: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          AurixAvatar(avatar: avatar, size: AppSizes.avatarSm),
          const SizedBox(width: AppSpacing.sm),
          AurixIcon(
            AurixGlyph.chevronRight,
            size: 20,
            color: context.palette.textTertiary,
          ),
        ],
      ),
    );
  }
}

/// A field AURIX can show but not change.
///
/// Styled as a row rather than as a disabled text field on purpose: a greyed
/// input invites the user to try, discover it does not accept a tap, and
/// wonder whether the app is broken. This reads as information, which is what
/// it is.
class _ReadOnlyRow extends StatelessWidget {
  const _ReadOnlyRow({
    required this.icon,
    required this.label,
    required this.value,
  });

  final AurixGlyph icon;
  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    return ListTile(
      leading: AurixIcon(icon, size: 22, color: context.palette.textSecondary),
      title: Text(label, style: AppTypography.bodySmall),
      subtitle: Text(
        value,
        style: AppTypography.bodyLarge,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
      ),
    );
  }
}
