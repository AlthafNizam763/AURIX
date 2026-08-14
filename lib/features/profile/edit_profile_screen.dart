import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/theme/app_dimens.dart';
import '../../core/theme/app_typography.dart';
import '../../core/theme/aurix_palette.dart';
import '../../core/utils/responsive.dart';
import '../../data/models/aurix_user.dart';
import '../../data/models/avatar.dart';
import '../../shared/widgets/feedback/app_snackbar.dart';
import '../../shared/widgets/feedback/state_views.dart';
import '../../shared/widgets/icons/aurix_glyphs.dart';
import '../../shared/widgets/icons/aurix_icon.dart';
import '../../shared/widgets/media/aurix_avatar.dart';
import '../auth/providers/auth_provider.dart';
import '../auth/widgets/change_password_sheet.dart';
import '../settings/widgets/settings_widgets.dart';
import 'providers/profile_provider.dart';
import 'widgets/avatar_picker_sheet.dart';

/// Edit Profile.
///
/// The screen used to be almost entirely read-only, because a profile *was* a
/// Spotify account: the display name, country and subscription tier were
/// Spotify's record and the Web API offered no way to change any of them, so
/// they were presented as a summary rather than as text fields that would
/// silently fail to save.
///
/// An AURIX profile is AURIX's own document now, so the name and the password
/// are genuinely editable and save immediately. The email address stays
/// read-only — it is the identifier Firebase Authentication knows the account
/// by, and changing it is a re-verification flow rather than a text edit.
///
/// The picture is unchanged, because AURIX always owned it. There is no upload,
/// no gallery, no camera and no file picker — see [AvatarPickerSheet] — so
/// "editing" a profile picture means choosing from the bundled catalogue.
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
              message: 'Sign in to edit your profile.',
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

                  const SettingsGroup(title: 'Your account'),

                  // Editable now. It used to be a read-only record of what
                  // Spotify said the account was called, because Spotify does
                  // not let an app change it. The name lives in AURIX's own
                  // user document, so it is the user's to set.
                  _EditableRow(
                    icon: AurixGlyph.profile,
                    label: 'Display name',
                    value: user.displayName,
                    onTap: () => _editName(context, ref, user.name),
                  ),

                  _ReadOnlyRow(
                    icon: AurixGlyph.mail,
                    label: 'Email',
                    value: user.email,
                  ),

                  _EditableRow(
                    icon: AurixGlyph.lock,
                    label: 'Password',
                    value: '••••••••',
                    onTap: () => ChangePasswordSheet.show(context),
                  ),

                  const SettingsNote(
                    text: 'Your email address is the name your account is '
                        'known by and cannot be changed here. Everything else '
                        'on this screen saves as soon as you change it.',
                  ),

                  const SizedBox(height: AppSpacing.huge),
                ],
              ),
            ),
    );
  }

  /// Renames the account.
  ///
  /// A dialog rather than an inline field: the name is one short value, the
  /// edit is rare, and an always-live text field on a settings list is a value
  /// that saves on every keystroke or not at all.
  Future<void> _editName(
    BuildContext context,
    WidgetRef ref,
    String current,
  ) async {
    final controller = TextEditingController(text: current);
    final name = await showDialog<String>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('Display name'),
        content: TextField(
          controller: controller,
          autofocus: true,
          textCapitalization: TextCapitalization.words,
          decoration: const InputDecoration(hintText: 'What should we call you?'),
          onSubmitted: (value) => Navigator.of(dialogContext).pop(value),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(dialogContext).pop(controller.text),
            child: const Text('Save'),
          ),
        ],
      ),
    );
    controller.dispose();

    final trimmed = name?.trim();
    if (trimmed == null || trimmed.isEmpty || trimmed == current) return;

    await ref.read(authControllerProvider.notifier).updateName(trimmed);
    if (context.mounted) AppSnackbar.success(context, 'Name updated');
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

  final AurixUser user;

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
/// A row whose value opens something that can change it.
///
/// Distinct from [_ReadOnlyRow] by more than the chevron: a settings list where
/// tappable and untappable rows look identical is one where users tap the
/// untappable ones. The chevron is the difference, and it is why these are two
/// widgets rather than one with a nullable callback.
class _EditableRow extends StatelessWidget {
  const _EditableRow({
    required this.icon,
    required this.label,
    required this.value,
    required this.onTap,
  });

  final AurixGlyph icon;
  final String label;
  final String value;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return ListTile(
      onTap: onTap,
      leading: AurixIcon(icon, size: 22, color: context.palette.textSecondary),
      title: Text(label, style: AppTypography.bodySmall),
      subtitle: Text(
        value,
        style: AppTypography.bodyLarge,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
      ),
      trailing: AurixIcon(
        AurixGlyph.chevronRight,
        size: 18,
        color: context.palette.textTertiary,
      ),
    );
  }
}

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
