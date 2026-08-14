import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/network/error_mapper.dart';
import '../../core/providers/app_providers.dart';
import '../../core/router/navigation.dart';
import '../../core/router/route_names.dart';
import '../../core/theme/app_colors.dart';
import '../../core/theme/app_dimens.dart';
import '../../core/theme/app_typography.dart';
import '../../core/theme/aurix_palette.dart';
import '../../core/utils/responsive.dart';
import '../../data/models/category.dart';
import '../../data/models/playlist.dart';
import '../../shared/widgets/feedback/loading_skeleton.dart';
import '../../shared/widgets/feedback/state_views.dart';
import '../../shared/widgets/icons/aurix_glyphs.dart';
import '../../shared/widgets/icons/aurix_icon.dart';
import '../../shared/widgets/media/content_cards.dart';
import '../settings/providers/settings_provider.dart';
import '../shell/app_shell.dart';

/// Playlists for one genre or mood.
///
/// Whether these came from `/browse/categories/{id}/playlists` or from a
/// Spotify search on the category's term is decided in `SpotifyBrowseService`
/// — either way they are live Spotify playlists.
final categoryPlaylistsProvider = FutureProvider.autoDispose
    .family<List<Playlist>, ({String id, String? query})>((ref, args) {
  final browse = ref.watch(spotifyBrowseServiceProvider);
  final category = Category(
    id: args.id,
    name: args.query ?? args.id,
    searchTerm: args.query,
  );
  return browse.categoryPlaylists(category, limit: 30);
});

class CategoryScreen extends ConsumerWidget {
  const CategoryScreen({
    required this.categoryId,
    required this.title,
    this.query,
    super.key,
  });

  final String categoryId;
  final String title;
  final String? query;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final playlists = ref.watch(
      categoryPlaylistsProvider((id: categoryId, query: query)),
    );
    final columns = context.gridColumns;
    final tint = AppColors.placeholderFor(categoryId);

    return Scaffold(
      body: CustomScrollView(
        slivers: [
          SliverAppBar(
            pinned: true,
            expandedHeight: 180,
            backgroundColor: context.palette.ground,
            leading: IconButton(
              onPressed: () => context.pop(),
              icon: const AurixIcon(AurixGlyph.back),
              tooltip: 'Back',
            ),
            flexibleSpace: FlexibleSpaceBar(
              title: Text(title, style: AppTypography.headlineSmall),
              titlePadding: const EdgeInsetsDirectional.only(
                start: 56,
                end: 20,
                bottom: 16,
              ),
              background: DecoratedBox(
                decoration: BoxDecoration(
                  gradient: LinearGradient(
                    colors: [
                      tint,
                      Color.lerp(tint, context.palette.ground, 0.6)!,
                      context.palette.ground,
                    ],
                    begin: Alignment.topLeft,
                    end: Alignment.bottomCenter,
                  ),
                ),
              ),
            ),
          ),

          playlists.when(
            data: (items) => items.isEmpty
                ? const SliverFillRemaining(
                    hasScrollBody: false,
                    child: EmptyView(
                      icon: AurixGlyph.library,
                      title: 'Nothing here yet',
                      message: 'Spotify returned no playlists for this genre.',
                    ),
                  )
                : SliverPadding(
                    padding: EdgeInsets.fromLTRB(
                      context.pageGutter,
                      AppSpacing.lg,
                      context.pageGutter,
                      shellBottomInset(context, hasTrack: true),
                    ),
                    sliver: SliverGrid.builder(
                      gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
                        crossAxisCount: columns,
                        crossAxisSpacing: AppSpacing.md,
                        mainAxisSpacing: AppSpacing.xl,
                        // Artwork square plus two text lines.
                        childAspectRatio: 0.72,
                      ),
                      itemCount: items.length,
                      itemBuilder: (context, index) {
                        final playlist = items[index];
                        return LayoutBuilder(
                          builder: (context, constraints) => PlaylistCard(
                            playlist: playlist,
                            width: constraints.maxWidth,
                            onTap: () => context.pushDistinct(
                              RouteNames.playlist,
                              pathParameters: {'id': playlist.id},
                            ),
                          ),
                        );
                      },
                    ),
                  ),
            loading: () => SliverToBoxAdapter(
              child: Padding(
                padding: const EdgeInsets.only(top: AppSpacing.xl),
                child: SkeletonShelf(
                  cardWidth: context.carouselCardWidth,
                  animate: !ref.watch(reduceMotionProvider),
                ),
              ),
            ),
            error: (error, _) => SliverFillRemaining(
              hasScrollBody: false,
              child: ErrorView(
                error: ErrorMapper.fromUnknown(error),
                onRetry: () => ref.invalidate(
                  categoryPlaylistsProvider((id: categoryId, query: query)),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}
