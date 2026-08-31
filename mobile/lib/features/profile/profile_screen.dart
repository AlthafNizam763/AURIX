import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/router/navigation.dart';
import '../../core/router/route_names.dart';
import '../../core/theme/app_dimens.dart';
import '../../core/theme/app_typography.dart';
import '../../core/theme/aurix_palette.dart';
import '../../core/utils/formatters.dart';
import '../../core/utils/responsive.dart';
import '../../data/models/aurix_user.dart';
import '../../shared/widgets/feedback/state_views.dart';
import '../../shared/widgets/icons/aurix_glyphs.dart';
import '../../shared/widgets/icons/aurix_icon.dart';
import '../../shared/widgets/media/aurix_avatar.dart';
import '../../shared/widgets/sheets/bottom_sheet_menu.dart';
import '../auth/providers/auth_provider.dart';
import '../library/providers/library_provider.dart';

/// The signed-in user's profile.
class ProfileScreen extends ConsumerWidget {
  const ProfileScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final user = ref.watch(currentUserProvider);
    final library = ref.watch(librarySnapshotProvider);

    return Scaffold(
      backgroundColor: context.palette.ground,
      body: user == null
          ? const _NotSignedIn()
          : RefreshIndicator(
              onRefresh: () =>
                  ref.read(authControllerProvider.notifier).refreshProfile(),
              color: context.palette.accent,
              backgroundColor: context.palette.surfaceElevated,
              child: CustomScrollView(
                physics: const AlwaysScrollableScrollPhysics(
                  parent: BouncingScrollPhysics(),
                ),
                slivers: [
                  SliverAppBar(
                    pinned: true,
                    backgroundColor: context.palette.ground,
                    // Profile is a bottom-nav tab, not a pushed page, so it has
                    // nothing to go back *to*. `automaticallyImplyLeading`
                    // would still draw an arrow whenever the tab's own
                    // navigator happened to have a stack.
                    automaticallyImplyLeading: false,
                    title: const Text('Profile'),
                    actions: [
                      IconButton(
                        onPressed: () => context.pushDistinct(RouteNames.settings),
                        icon: const AurixIcon(AurixGlyph.settings),
                        tooltip: 'Settings',
                      ),
                      IconButton(
                        onPressed: () => _showMenu(context, ref, user),
                        icon: const AurixIcon(AurixGlyph.moreVertical),
                        tooltip: 'More options',
                      ),
                    ],
                  ),

                  SliverToBoxAdapter(child: _ProfileHeader(user: user)),

                  SliverToBoxAdapter(
                    child: library.when(
                      data: (data) => _StatsRow(
                        playlists: data.playlists.length,
                        liked: data.likedTracks.length,
                        imported: data.importedPlaylists.length,
                      ),
                      loading: () => const _StatsRow.loading(),
                      error: (_, _) => const SizedBox.shrink(),
                    ),
                  ),

                  const SliverToBoxAdapter(child: SizedBox(height: AppSpacing.xl)),

                  SliverToBoxAdapter(
                    child: _QuickLinks(
                      onEditProfile: () =>
                          context.pushDistinct(RouteNames.editProfile),
                      onLikedSongs: () => context.pushDistinct(RouteNames.likedSongs),
                      onLibrary: () => context.goNamed(RouteNames.library),
                      onSettings: () => context.pushDistinct(RouteNames.settings),
                    ),
                  ),

                  SliverToBoxAdapter(child: _AccountCard(user: user)),

                  const SliverToBoxAdapter(child: SizedBox(height: AppSpacing.huge)),
                ],
              ),
            ),
    );
  }

  void _showMenu(BuildContext context, WidgetRef ref, AurixUser user) {
    BottomSheetMenu.show(
      context,
      title: user.displayName,
      subtitle: user.email,
      leading: AurixAvatar.of(size: 52),
      actions: [
        SheetAction(
          icon: AurixGlyph.palette,
          label: 'Edit profile',
          onTap: () => context.pushDistinct(RouteNames.editProfile),
        ),
        SheetAction(
          icon: AurixGlyph.add,
          label: 'Import music',
          subtitle: 'Bring playlists in from another service',
          onTap: () => context.pushDistinct(RouteNames.importMusic),
        ),
        SheetAction(
          icon: AurixGlyph.settings,
          label: 'Settings',
          onTap: () => context.pushDistinct(RouteNames.settings),
        ),
        SheetAction(
          icon: AurixGlyph.logout,
          label: 'Log out',
          destructive: true,
          onTap: () => _confirmSignOut(context, ref),
        ),
      ],
    );
  }

  Future<void> _confirmSignOut(BuildContext context, WidgetRef ref) async {
    final confirmed = await ConfirmDialog.show(
      context,
      title: 'Log out?',
      // Deliberately reassuring about the data, because it is true: playlists,
      // likes and history live in the account, not on the device, so signing
      // out on a phone loses none of it.
      message: 'Your playlists, liked songs and listening history stay in your '
          'AURIX account. Sign back in on any device to pick them up.',
      confirmLabel: 'Log out',
      destructive: true,
    );
    if (confirmed) {
      await ref.read(authControllerProvider.notifier).signOut();
      // The router's redirect takes it from here.
    }
  }
}

class _ProfileHeader extends StatelessWidget {
  const _ProfileHeader({required this.user});

  final AurixUser user;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: EdgeInsets.symmetric(
        horizontal: context.pageGutter,
        vertical: AppSpacing.lg,
      ),
      child: Column(
        children: [
          // The AURIX avatar, and the shortest route to changing it.
          //
          // There is no initial-letter fallback here any more, and no branch
          // that could produce one: a profile always has a picture, because the
          // picture is a bundled asset selected from a catalogue rather than
          // something the account may or may not have uploaded.
          Semantics(
            button: true,
            label: 'Profile picture. Open Edit Profile to choose an avatar',
            excludeSemantics: true,
            child: InkWell(
              onTap: () => context.pushDistinct(RouteNames.editProfile),
              customBorder: const CircleBorder(),
              child: AurixAvatar.of(
                size: AppSizes.avatarLg,
                elevated: true,
              ),
            ),
          ),
          const SizedBox(height: AppSpacing.lg),
          Text(
            user.displayName,
            style: AppTypography.displaySmall,
            textAlign: TextAlign.center,
          ),
          const SizedBox(height: AppSpacing.xs),
          Text(
            user.email,
            style: AppTypography.bodySmall.copyWith(
              color: context.palette.textSecondary,
            ),
            textAlign: TextAlign.center,
            overflow: TextOverflow.ellipsis,
          ),
          // The two badges here used to be the Spotify subscription tier and
          // the account's country — both Spotify's to state, and neither
          // meaningful for an AURIX account. What replaced them is what AURIX
          // actually knows: when the account was made, and whether its address
          // has been confirmed.
          const SizedBox(height: AppSpacing.md),
          Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              if (user.createdAt != null)
                _Badge(label: 'Since ${Formatters.monthYear(user.createdAt!)}'),
              if (user.createdAt != null && !user.emailVerified)
                const SizedBox(width: AppSpacing.sm),
              if (!user.emailVerified) const _Badge(label: 'Email unverified'),
            ],
          ),
        ],
      ),
    );
  }
}

/// A small pill under the display name.
///
/// The `highlight` variant this used to carry is gone with the only thing that
/// used it — the Premium badge, which rendered in the accent colour to mark the
/// account tier. Nothing on an AURIX profile earns that emphasis.
class _Badge extends StatelessWidget {
  const _Badge({required this.label});

  final String label;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(
        horizontal: AppSpacing.md,
        vertical: 4,
      ),
      decoration: BoxDecoration(
        color: context.palette.surfaceElevated,
        borderRadius: BorderRadius.circular(AppRadius.pill),
      ),
      child: Text(
        label,
        style: AppTypography.labelMedium.copyWith(
          color: context.palette.textSecondary,
          fontWeight: FontWeight.w700,
        ),
      ),
    );
  }
}

class _StatsRow extends StatelessWidget {
  const _StatsRow({
    required this.playlists,
    required this.liked,
    required this.imported,
  }) : isLoading = false;

  const _StatsRow.loading()
    : playlists = 0,
      liked = 0,
      imported = 0,
      isLoading = true;

  final int playlists;
  final int liked;

  /// Playlists that came in from another service. Replaces the old "Following"
  /// and "Albums" counts, which were Spotify library collections AURIX no
  /// longer keeps.
  final int imported;

  final bool isLoading;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: EdgeInsets.symmetric(horizontal: context.pageGutter),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceEvenly,
        children: [
          _Stat(value: playlists, label: 'Playlists', loading: isLoading),
          _Stat(value: liked, label: 'Liked', loading: isLoading),
          _Stat(value: imported, label: 'Imported', loading: isLoading),
        ],
      ),
    );
  }
}

class _Stat extends StatelessWidget {
  const _Stat({
    required this.value,
    required this.label,
    required this.loading,
  });

  final int value;
  final String label;
  final bool loading;

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        Text(
          loading ? '—' : Formatters.compactNumber(value),
          style: AppTypography.headlineMedium,
        ),
        const SizedBox(height: 2),
        Text(label, style: AppTypography.labelSmall),
      ],
    );
  }
}

class _QuickLinks extends StatelessWidget {
  const _QuickLinks({
    required this.onEditProfile,
    required this.onLikedSongs,
    required this.onLibrary,
    required this.onSettings,
  });

  final VoidCallback onEditProfile;
  final VoidCallback onLikedSongs;
  final VoidCallback onLibrary;
  final VoidCallback onSettings;

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        _LinkTile(
          icon: AurixGlyph.palette,
          label: 'Edit profile',
          onTap: onEditProfile,
        ),
        _LinkTile(
          icon: AurixGlyph.heartFilled,
          label: 'Liked Songs',
          onTap: onLikedSongs,
        ),
        _LinkTile(
          icon: AurixGlyph.library,
          label: 'Your library',
          onTap: onLibrary,
        ),
        _LinkTile(
          icon: AurixGlyph.settings,
          label: 'Settings',
          onTap: onSettings,
        ),
      ],
    );
  }
}

class _LinkTile extends StatelessWidget {
  const _LinkTile({
    required this.icon,
    required this.label,
    required this.onTap,
  });

  final AurixGlyph icon;
  final String label;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return ListTile(
      onTap: onTap,
      leading: AurixIcon(icon, size: 22),
      title: Text(label, style: AppTypography.bodyLarge),
      trailing: AurixIcon(
        AurixGlyph.chevronRight,
        size: 20,
        color: context.palette.textTertiary,
      ),
    );
  }
}

/// States plainly where the user's music lives.
///
/// This card used to be about Spotify Premium — whether the account could
/// control playback, and a link to subscribe if not. That is no longer a fact
/// about the *account*: playback capability belongs to whichever provider is
/// connected, and the player screen says so where it is relevant. What belongs
/// on a profile is what the profile is: an account, and the library behind it.
class _AccountCard extends StatelessWidget {
  const _AccountCard({required this.user});

  final AurixUser user;

  @override
  Widget build(BuildContext context) {
    return Container(
      margin: EdgeInsets.fromLTRB(
        context.pageGutter,
        AppSpacing.xl,
        context.pageGutter,
        0,
      ),
      padding: const EdgeInsets.all(AppSpacing.lg),
      decoration: BoxDecoration(
        color: context.palette.surface,
        borderRadius: AppRadius.card,
        border: Border.all(color: context.palette.hairline),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              AurixIcon(
                AurixGlyph.lock,
                size: 19,
                color: context.palette.accent,
              ),
              const SizedBox(width: AppSpacing.md),
              const Expanded(
                child: Text(
                  'Synced to your account',
                  style: AppTypography.titleMedium,
                ),
              ),
            ],
          ),
          const SizedBox(height: AppSpacing.sm),
          Text(
            'Your playlists, liked songs and listening history are stored '
            'against this account, so they follow you to every device you sign '
            'in on — and stay available offline on each of them.',
            style: AppTypography.bodySmall.copyWith(height: 1.55),
          ),
          const SizedBox(height: AppSpacing.md),
          const Divider(height: 1),
          const SizedBox(height: AppSpacing.md),
          Row(
            children: [
              AurixIcon(
                AurixGlyph.mail,
                size: 16,
                color: context.palette.textTertiary,
              ),
              const SizedBox(width: AppSpacing.sm),
              Expanded(
                child: Text(
                  user.email,
                  style: AppTypography.bodySmall,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

class _NotSignedIn extends StatelessWidget {
  const _NotSignedIn();

  @override
  Widget build(BuildContext context) {
    return const EmptyView(
      icon: AurixGlyph.profile,
      title: 'Not signed in',
      message: 'Sign in to see your profile.',
    );
  }
}
