import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/router/navigation.dart';
import '../../../core/router/route_names.dart';
import '../../../core/theme/app_dimens.dart';
import '../../../core/utils/responsive.dart';
import '../../../data/models/home_feed.dart';
import '../../../data/models/track.dart';
import '../../../playback/playback_queue.dart';
import '../../../playback/player_controller.dart';
import '../../../shared/widgets/layout/section_header.dart';
import '../../../shared/widgets/media/content_cards.dart';

/// Renders one [HomeShelf] as a titled horizontal carousel.
///
/// Each shelf kind maps to its own card and its own navigation target, but the
/// header, spacing and scroll behaviour are shared — which is what keeps eight
/// visually different shelves feeling like one page.
class HomeShelfView extends ConsumerWidget {
  const HomeShelfView({required this.shelf, super.key});

  final HomeShelf shelf;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    if (!shelf.shouldRender) return const SizedBox.shrink();

    switch (shelf.kind) {
      case ShelfKind.tracks:
        return _tracks(context, ref);
      case ShelfKind.albums:
        return _albums(context);
      case ShelfKind.artists:
        return _artists(context);
      case ShelfKind.playlists:
        return _playlists(context);
      case ShelfKind.categories:
        return _categories(context);
    }
  }

  Widget _tracks(BuildContext context, WidgetRef ref) {
    final width = context.carouselCardWidth;
    return ShelfSection(
      title: shelf.title,
      subtitle: shelf.subtitle,
      itemCount: shelf.tracks.length,
      itemHeight: width + 58,
      itemBuilder: (context, index) {
        final track = shelf.tracks[index];
        return TrackCard(
          track: track,
          width: width,
          heroTag: 'shelf-${shelf.id}-${track.id}',
          onTap: () => _playFromShelf(ref, shelf.tracks, index),
        );
      },
    );
  }

  /// Tapping a track in a shelf queues the *whole shelf* from that point,
  /// not just the one song — otherwise playback stops after 30 seconds and the
  /// queue is empty, which feels broken.
  void _playFromShelf(WidgetRef ref, List<Track> tracks, int index) {
    ref.read(playerControllerProvider.notifier).playTracks(
      tracks,
      startIndex: index,
      context: PlaybackContext(title: shelf.title),
    );
  }

  Widget _albums(BuildContext context) {
    final width = context.carouselCardWidth;
    return ShelfSection(
      title: shelf.title,
      subtitle: shelf.subtitle,
      itemCount: shelf.albums.length,
      itemHeight: width + 58,
      itemBuilder: (context, index) {
        final album = shelf.albums[index];
        return AlbumCard(
          album: album,
          width: width,
          // The year is the fastest way to tell two records by the same
          // artist apart, and album shelves are the only place a full
          // discography can appear side by side.
          showYear: true,
          heroTag: 'shelf-${shelf.id}-${album.id}',
          onTap: () => context.pushDistinct(
            RouteNames.album,
            pathParameters: {'id': album.id},
          ),
        );
      },
    );
  }

  Widget _artists(BuildContext context) {
    final width = context.carouselCardWidth;
    return ShelfSection(
      title: shelf.title,
      subtitle: shelf.subtitle,
      itemCount: shelf.artists.length,
      itemHeight: width + 58,
      itemBuilder: (context, index) {
        final artist = shelf.artists[index];
        return ArtistCard(
          artist: artist,
          width: width,
          heroTag: 'shelf-${shelf.id}-${artist.id}',
          onTap: () => context.pushDistinct(
            RouteNames.artist,
            pathParameters: {'id': artist.id},
          ),
        );
      },
    );
  }

  Widget _playlists(BuildContext context) {
    final width = context.carouselCardWidth;
    return ShelfSection(
      title: shelf.title,
      subtitle: shelf.subtitle,
      itemCount: shelf.playlists.length,
      itemHeight: width + 72,
      itemBuilder: (context, index) {
        final playlist = shelf.playlists[index];
        return PlaylistCard(
          playlist: playlist,
          width: width,
          heroTag: 'shelf-${shelf.id}-${playlist.id}',
          onTap: () => context.pushDistinct(
            RouteNames.playlist,
            pathParameters: {'id': playlist.id},
          ),
        );
      },
    );
  }

  /// Moods render as a two-row wrapped grid rather than a carousel — there are
  /// a fixed dozen of them and hiding half off-screen serves nobody.
  Widget _categories(BuildContext context) {
    final columns = context.responsive(compact: 2, medium: 3, expanded: 4);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SectionHeader(title: shelf.title, subtitle: shelf.subtitle),
        Padding(
          padding: EdgeInsets.symmetric(horizontal: context.pageGutter),
          child: LayoutBuilder(
            builder: (context, constraints) {
              const gap = AppSpacing.md;
              final tileWidth =
                  (constraints.maxWidth - (gap * (columns - 1))) / columns;
              return Wrap(
                spacing: gap,
                runSpacing: gap,
                children: [
                  for (final category in shelf.categories)
                    CategoryCard(
                      category: category,
                      width: tileWidth,
                      height: tileWidth * 0.58,
                      onTap: () => context.pushDistinct(
                        RouteNames.category,
                        pathParameters: {'id': category.id},
                        queryParameters: {
                          'title': category.name,
                          'q': category.query,
                        },
                      ),
                    ),
                ],
              );
            },
          ),
        ),
      ],
    );
  }
}
