import 'package:flutter/material.dart';

import '../../../core/router/navigation.dart';
import '../../../core/router/route_names.dart';
import '../../../core/theme/app_dimens.dart';
import '../../../core/theme/app_typography.dart';
import '../../../core/theme/aurix_palette.dart';
import '../../../core/utils/formatters.dart';
import '../../../data/models/artist.dart';
import '../../../data/models/playlist.dart';
import '../../../data/models/saved_item.dart';
import '../../../shared/widgets/icons/aurix_glyphs.dart';
import '../../../shared/widgets/icons/aurix_icon.dart';
import '../../../shared/widgets/media/app_artwork.dart';

/// Shared row layout for every library entry.
class _LibraryRow extends StatelessWidget {
  const _LibraryRow({
    required this.title,
    required this.subtitle,
    required this.onTap,
    this.imageUrl,
    this.seed,
    this.shape = ArtworkShape.square,
    this.fallbackIcon,
    this.leading,
    this.pinned = false,
  });

  final String title;
  final String subtitle;
  final VoidCallback onTap;
  final String? imageUrl;
  final String? seed;
  final ArtworkShape shape;
  final AurixGlyph? fallbackIcon;

  /// Replaces the artwork entirely — used by the Liked Songs gradient tile.
  final Widget? leading;

  final bool pinned;

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
            leading ??
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
                  Row(
                    children: [
                      if (pinned) ...[
                        AurixIcon(
                          AurixGlyph.pin,
                          size: 12,
                          color: context.palette.accent,
                        ),
                        const SizedBox(width: AppSpacing.xs),
                      ],
                      Flexible(
                        child: Text(
                          title,
                          style: AppTypography.titleMedium,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                    ],
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
          ],
        ),
      ),
    );
  }
}

/// The Liked Songs entry, with its own gradient tile rather than artwork.
class LikedSongsRow extends StatelessWidget {
  const LikedSongsRow({required this.count, required this.onTap, super.key});

  final int count;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return _LibraryRow(
      title: 'Liked Songs',
      subtitle: 'Playlist · ${Formatters.groupedNumber(count)} '
          '${count == 1 ? 'song' : 'songs'}',
      pinned: true,
      onTap: onTap,
      leading: Container(
        width: AppSizes.tileArtworkLarge,
        height: AppSizes.tileArtworkLarge,
        decoration: BoxDecoration(
          borderRadius: const BorderRadius.all(Radius.circular(AppRadius.xs)),
          // Liked Songs is the one collection the user did not create, and it
          // is the only tile in the app that inverts: an accent-filled square
          // with the ink-coloured heart on it, where every real cover beside it
          // is a dark photograph. In a monochrome grid that inversion is the
          // only way to make one tile unmistakable at a glance — a different
          // shade of grey would just look like another album.
          gradient: LinearGradient(
            colors: [
              context.palette.accent,
              Color.lerp(
                context.palette.accent,
                context.palette.textSecondary,
                0.5,
              )!,
            ],
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
          ),
        ),
        child: AurixIcon(
          AurixGlyph.heartFilled,
          size: 24,
          color: context.palette.textOnAccent,
        ),
      ),
    );
  }
}

class LibraryPlaylistRow extends StatelessWidget {
  const LibraryPlaylistRow({required this.playlist, super.key});

  final Playlist playlist;

  @override
  Widget build(BuildContext context) {
    return _LibraryRow(
      title: playlist.name,
      subtitle: 'Playlist · ${playlist.ownerName}',
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

class LibraryAlbumRow extends StatelessWidget {
  const LibraryAlbumRow({required this.saved, super.key});

  final SavedAlbum saved;

  @override
  Widget build(BuildContext context) {
    final album = saved.album;
    return _LibraryRow(
      title: album.name,
      subtitle: '${album.albumType.label} · ${album.artistNames}',
      imageUrl: album.thumbnailUrl,
      seed: album.id,
      onTap: () => context.pushDistinct(
        RouteNames.album,
        pathParameters: {'id': album.id},
      ),
    );
  }
}

class LibraryArtistRow extends StatelessWidget {
  const LibraryArtistRow({required this.artist, super.key});

  final Artist artist;

  @override
  Widget build(BuildContext context) {
    return _LibraryRow(
      title: artist.name,
      subtitle: 'Artist',
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

class RecentlyPlayedRow extends StatelessWidget {
  const RecentlyPlayedRow({required this.entry, required this.onTap, super.key});

  final PlayHistoryEntry entry;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final track = entry.track;
    final when = entry.playedAt;

    return _LibraryRow(
      title: track.name,
      subtitle: when == null
          ? track.artistNames
          : '${track.artistNames} · ${Formatters.relativeTime(when)}',
      imageUrl: track.thumbnailUrl,
      seed: track.id,
      onTap: onTap,
    );
  }
}
