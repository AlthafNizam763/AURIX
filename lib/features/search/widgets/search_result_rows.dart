import 'package:flutter/material.dart';

import '../../../core/router/navigation.dart';
import '../../../core/router/route_names.dart';
import '../../../core/theme/app_dimens.dart';
import '../../../core/theme/app_typography.dart';
import '../../../core/theme/aurix_palette.dart';
import '../../../core/utils/formatters.dart';
import '../../../data/models/album.dart';
import '../../../data/models/artist.dart';
import '../../../data/models/playlist.dart';
import '../../../shared/widgets/icons/aurix_glyphs.dart';
import '../../../shared/widgets/icons/aurix_icon.dart';
import '../../../shared/widgets/media/app_artwork.dart';

/// Shared list-row layout for non-track search results.
///
/// Artists, albums and playlists differ only in artwork shape and the
/// subtitle they show, so they share one row rather than three near-copies —
/// which also guarantees the three sections align to the same grid.
class _ResultRow extends StatelessWidget {
  const _ResultRow({
    required this.title,
    required this.subtitle,
    required this.imageUrl,
    required this.seed,
    required this.onTap,
    this.shape = ArtworkShape.square,
    this.fallbackIcon,
  });

  final String title;
  final String subtitle;
  final String? imageUrl;
  final String seed;
  final VoidCallback onTap;
  final ArtworkShape shape;
  final AurixGlyph? fallbackIcon;

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onTap,
      splashColor: context.palette.hairline,
      child: Padding(
        padding: const EdgeInsets.symmetric(
          horizontal: AppSpacing.page,
          vertical: AppSpacing.sm,
        ),
        child: Row(
          children: [
            AppArtwork(
              imageUrl: imageUrl,
              size: AppSizes.tileArtworkLarge,
              shape: shape,
              seed: seed,
              fallbackIcon: fallbackIcon,
            ),
            const SizedBox(width: AppSpacing.md),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    title,
                    style: AppTypography.titleMedium,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                  const SizedBox(height: 2),
                  Text(
                    subtitle,
                    style: AppTypography.bodySmall,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                ],
              ),
            ),
            AurixIcon(
              AurixGlyph.chevronRight,
              size: 20,
              color: context.palette.textTertiary,
            ),
          ],
        ),
      ),
    );
  }
}

class ArtistRow extends StatelessWidget {
  const ArtistRow({required this.artist, super.key});

  final Artist artist;

  @override
  Widget build(BuildContext context) {
    final followers = artist.followers;
    final subtitle = followers != null && followers > 0
        ? 'Artist · ${Formatters.compactNumber(followers)} followers'
        : 'Artist';

    return _ResultRow(
      title: artist.name,
      subtitle: subtitle,
      imageUrl: artist.avatarUrl,
      seed: artist.id,
      shape: ArtworkShape.circle,
      fallbackIcon: AurixGlyph.profile,
      onTap: () => context.pushDistinct(
        RouteNames.artist,
        pathParameters: {'id': artist.id},
      ),
    );
  }
}

class AlbumRow extends StatelessWidget {
  const AlbumRow({required this.album, super.key});

  final Album album;

  @override
  Widget build(BuildContext context) {
    final year = album.releaseYear;
    final parts = <String>[
      album.albumType.label,
      if (year.isNotEmpty) year,
      album.artistNames,
    ];

    return _ResultRow(
      title: album.name,
      subtitle: parts.join(' · '),
      imageUrl: album.thumbnailUrl,
      seed: album.id,
      onTap: () => context.pushDistinct(
        RouteNames.album,
        pathParameters: {'id': album.id},
      ),
    );
  }
}

class PlaylistRow extends StatelessWidget {
  const PlaylistRow({required this.playlist, super.key});

  final Playlist playlist;

  @override
  Widget build(BuildContext context) {
    final count = playlist.trackCount;
    final parts = <String>[
      'Playlist',
      if (count > 0) '$count ${count == 1 ? 'song' : 'songs'}',
      playlist.ownerName,
    ];

    return _ResultRow(
      title: playlist.name,
      subtitle: parts.join(' · '),
      imageUrl: playlist.thumbnailUrl,
      seed: playlist.id,
      fallbackIcon: AurixGlyph.playlist,
      onTap: () => context.pushDistinct(
        RouteNames.playlist,
        pathParameters: {'id': playlist.id},
      ),
    );
  }
}
