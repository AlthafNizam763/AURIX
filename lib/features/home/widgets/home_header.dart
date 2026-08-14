import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/router/navigation.dart';
import '../../../core/router/route_names.dart';
import '../../../core/theme/app_dimens.dart';
import '../../../core/theme/app_typography.dart';
import '../../../core/theme/aurix_palette.dart';
import '../../../core/utils/responsive.dart';
import '../../../shared/widgets/feedback/app_snackbar.dart';
import '../../../shared/widgets/icons/aurix_glyphs.dart';
import '../../../shared/widgets/icons/aurix_icon.dart';
import '../../../shared/widgets/media/aurix_avatar.dart';
import '../../auth/providers/auth_provider.dart';
import '../providers/home_provider.dart';

/// The Home greeting bar: avatar, greeting, notifications, settings.
///
/// A floating `SliverAppBar` rather than a pinned one — it gets out of the way
/// while scrolling down and returns on the first upward flick, which is the
/// right trade for a screen that is mostly content.
class HomeHeader extends ConsumerWidget {
  const HomeHeader({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final user = ref.watch(currentUserProvider);
    final greeting = ref.watch(greetingProvider);

    return SliverAppBar(
      floating: true,
      snap: true,
      backgroundColor: context.palette.ground,
      surfaceTintColor: Colors.transparent,
      elevation: 0,
      toolbarHeight: 62,
      titleSpacing: context.pageGutter,
      title: Row(
        children: [
          _AvatarButton(
            onTap: () => context.pushDistinct(RouteNames.profile),
          ),
          const SizedBox(width: AppSpacing.md),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  greeting,
                  style: AppTypography.headlineSmall,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
                if (user != null)
                  Text(
                    user.displayName,
                    style: AppTypography.bodySmall.copyWith(fontSize: 11.5),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
              ],
            ),
          ),
        ],
      ),
      actions: [
        IconButton(
          onPressed: () => _showNotifications(context),
          icon: const AurixIcon(AurixGlyph.notifications),
          tooltip: 'Notifications',
        ),
        IconButton(
          onPressed: () => context.pushDistinct(RouteNames.settings),
          icon: const AurixIcon(AurixGlyph.settings),
          tooltip: 'Settings',
        ),
        SizedBox(width: context.pageGutter - AppSpacing.sm),
      ],
    );
  }

  /// AURIX has no push-notification backend, and inventing a fake inbox
  /// would be worse than saying so. The control stays — it is a real
  /// affordance in the design — and explains itself when tapped.
  void _showNotifications(BuildContext context) {
    AppSnackbar.show(
      context,
      'No notifications. AURIX does not send push notifications yet.',
    );
  }
}

/// The user's AURIX avatar, and the way into the profile.
///
/// It takes no image argument any more. The avatar comes from the shared
/// profile state, which is what keeps this in step with the profile screen and
/// the library header without any of the three telling the others — and there
/// is no longer an initial-letter fallback, because there is no longer a state
/// in which a profile has no picture.
class _AvatarButton extends StatelessWidget {
  const _AvatarButton({required this.onTap});

  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Semantics(
      button: true,
      label: 'Open your profile',
      child: InkWell(
        onTap: onTap,
        customBorder: const CircleBorder(),
        child: AurixAvatar.of(size: AppSizes.avatarMd),
      ),
    );
  }
}
