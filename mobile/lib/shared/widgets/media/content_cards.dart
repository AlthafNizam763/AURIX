import 'package:flutter/material.dart';

import '../../../core/constants/app_constants.dart';
import '../../../core/theme/app_colors.dart';
import '../../../core/theme/app_dimens.dart';
import '../../../core/theme/app_typography.dart';
import '../../../core/utils/formatters.dart';
import '../../../data/models/album.dart';
import '../../../data/models/artist.dart';
import '../../../data/models/category.dart';
import '../../../data/models/playlist.dart';
import '../../../data/models/track.dart';
import '../../../shared/widgets/icons/aurix_glyphs.dart';
import '../../../shared/widgets/icons/aurix_icon.dart';
import 'app_artwork.dart';

/// The press animation every card shares.
///
/// A small scale-down on press is the single micro-interaction that most makes
/// a grid feel physical. It is factored out so all four card types respond
/// identically — inconsistent feedback is more noticeable than none.
class PressableCard extends StatefulWidget {
  const PressableCard({
    required this.child,
    required this.onTap,
    this.onLongPress,
    this.semanticLabel,
    super.key,
  });

  final Widget child;
  final VoidCallback onTap;
  final VoidCallback? onLongPress;
  final String? semanticLabel;

  @override
  State<PressableCard> createState() => _PressableCardState();
}

class _PressableCardState extends State<PressableCard> {
  bool _pressed = false;

  @override
  Widget build(BuildContext context) {
    return Semantics(
      button: true,
      label: widget.semanticLabel,
      child: GestureDetector(
        onTap: widget.onTap,
        onLongPress: widget.onLongPress,
        onTapDown: (_) => setState(() => _pressed = true),
        onTapUp: (_) => setState(() => _pressed = false),
        onTapCancel: () => setState(() => _pressed = false),
        behavior: HitTestBehavior.opaque,
        child: AnimatedScale(
          scale: _pressed ? 0.96 : 1,
          duration: AppConstants.fast,
          curve: Curves.easeOut,
          child: widget.child,
        ),
      ),
    );
  }
}

/// Album card for a horizontal shelf or grid.
class AlbumCard extends StatelessWidget {
  const AlbumCard({
    required this.album,
    required this.onTap,
    this.width = AppSizes.carouselCardWidth,
    this.showYear = false,
    this.heroTag,
    super.key,
  });

  final Album album;
  final VoidCallback onTap;
  final double width;
  final bool showYear;
  final Object? heroTag;

  @override
  Widget build(BuildContext context) {
    final subtitle = showYear && album.releaseYear.isNotEmpty
        ? '${album.releaseYear} · ${album.albumType.label}'
        : album.artistNames;

    return PressableCard(
      onTap: onTap,
      semanticLabel: 'Album ${album.name} by ${album.artistNames}',
      child: SizedBox(
        width: width,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            AppArtwork(
              imageUrl: album.cardImageUrl,
              size: width,
              seed: album.id,
              heroTag: heroTag,
              elevated: true,
            ),
            const SizedBox(height: AppSpacing.sm + 2),
            Text(
              album.name,
              style: AppTypography.titleSmall,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
            const SizedBox(height: 2),
            Text(
              subtitle,
              style: AppTypography.bodySmall.copyWith(fontSize: 11.5),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
          ],
        ),
      ),
    );
  }
}

/// Artist card — circular artwork, centred label.
class ArtistCard extends StatelessWidget {
  const ArtistCard({
    required this.artist,
    required this.onTap,
    this.width = AppSizes.carouselCardWidth,
    this.heroTag,
    super.key,
  });

  final Artist artist;
  final VoidCallback onTap;
  final double width;
  final Object? heroTag;

  @override
  Widget build(BuildContext context) {
    return PressableCard(
      onTap: onTap,
      semanticLabel: 'Artist ${artist.name}',
      child: SizedBox(
        width: width,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            AppArtwork(
              imageUrl: artist.avatarUrl,
              size: width,
              shape: ArtworkShape.circle,
              seed: artist.id,
              heroTag: heroTag,
              elevated: true,
            ),
            const SizedBox(height: AppSpacing.sm + 2),
            Text(
              artist.name,
              style: AppTypography.titleSmall,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 2),
            Text(
              'Artist',
              style: AppTypography.bodySmall.copyWith(fontSize: 11.5),
              textAlign: TextAlign.center,
            ),
          ],
        ),
      ),
    );
  }
}

/// Playlist card.
class PlaylistCard extends StatelessWidget {
  const PlaylistCard({
    required this.playlist,
    required this.onTap,
    this.width = AppSizes.carouselCardWidth,
    this.heroTag,
    super.key,
  });

  final Playlist playlist;
  final VoidCallback onTap;
  final double width;
  final Object? heroTag;

  @override
  Widget build(BuildContext context) {
    final description = Formatters.plainText(playlist.description);
    final subtitle = description.isNotEmpty
        ? description
        : 'By ${playlist.ownerName}';

    return PressableCard(
      onTap: onTap,
      semanticLabel: 'Playlist ${playlist.name}',
      child: SizedBox(
        width: width,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            AppArtwork(
              imageUrl: playlist.cardImageUrl,
              size: width,
              seed: playlist.id,
              fallbackIcon: AurixGlyph.playlist,
              heroTag: heroTag,
              elevated: true,
            ),
            const SizedBox(height: AppSpacing.sm + 2),
            Text(
              playlist.name,
              style: AppTypography.titleSmall,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
            const SizedBox(height: 2),
            Text(
              subtitle,
              style: AppTypography.bodySmall.copyWith(fontSize: 11.5),
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
            ),
          ],
        ),
      ),
    );
  }
}

/// Track card, for shelves that show songs rather than albums.
class TrackCard extends StatelessWidget {
  const TrackCard({
    required this.track,
    required this.onTap,
    this.width = AppSizes.carouselCardWidth,
    this.heroTag,
    super.key,
  });

  final Track track;
  final VoidCallback onTap;
  final double width;
  final Object? heroTag;

  @override
  Widget build(BuildContext context) {
    return PressableCard(
      onTap: onTap,
      semanticLabel: 'Song ${track.name} by ${track.artistNames}',
      child: SizedBox(
        width: width,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            AppArtwork(
              imageUrl: track.cardArtworkUrl,
              size: width,
              seed: track.id,
              heroTag: heroTag,
              elevated: true,
            ),
            const SizedBox(height: AppSpacing.sm + 2),
            Row(
              children: [
                if (track.isExplicit) ...[
                  const _ExplicitBadge(),
                  const SizedBox(width: AppSpacing.xs + 1),
                ],
                Expanded(
                  child: Text(
                    track.name,
                    style: AppTypography.titleSmall,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 2),
            Text(
              track.artistNames,
              style: AppTypography.bodySmall.copyWith(fontSize: 11.5),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
          ],
        ),
      ),
    );
  }
}

/// Genre / mood tile — a coloured card with a title, no artwork required.
class CategoryCard extends StatelessWidget {
  const CategoryCard({
    required this.category,
    required this.onTap,
    this.width = 156,
    this.height = 92,
    super.key,
  });

  final Category category;
  final VoidCallback onTap;
  final double width;
  final double height;

  @override
  Widget build(BuildContext context) {
    final tint = AppColors.placeholderFor(category.id);

    return PressableCard(
      onTap: onTap,
      semanticLabel: 'Browse ${category.name}',
      child: Container(
        width: width,
        height: height,
        clipBehavior: Clip.antiAlias,
        decoration: BoxDecoration(
          borderRadius: AppRadius.card,
          gradient: LinearGradient(
            colors: [tint, Color.lerp(tint, Colors.black, 0.45)!],
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
          ),
        ),
        child: Stack(
          children: [
            // Icon bleeding off the corner, rotated — reads as a label rather
            // than an illustration, and needs no network request.
            Positioned(
              right: -12,
              bottom: -14,
              child: Transform.rotate(
                angle: 0.42,
                child: AurixIcon(
                  _iconFor(category.id),
                  size: 62,
                  color: Colors.black.withValues(alpha: 0.24),
                ),
              ),
            ),
            Padding(
              padding: const EdgeInsets.all(AppSpacing.md),
              child: Text(
                category.name,
                style: AppTypography.titleMedium.copyWith(
                  fontWeight: FontWeight.w800,
                ),
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
              ),
            ),
          ],
        ),
      ),
    );
  }

  AurixGlyph _iconFor(String id) {
    switch (id) {
      case 'chill':
        return AurixGlyph.leaf;
      case 'workout':
        return AurixGlyph.dumbbell;
      case 'focus':
        return AurixGlyph.target;
      case 'sleep':
        return AurixGlyph.moon;
      case 'party':
        return AurixGlyph.sparkle;
      case 'rock':
        return AurixGlyph.bolt;
      case 'hiphop':
        return AurixGlyph.mic;
      case 'edm_dance':
        return AurixGlyph.equalizer;
      case 'jazz':
        return AurixGlyph.piano;
      default:
        return AurixGlyph.library;
    }
  }
}

/// The small "E" marker Spotify requires beside explicit content.
class _ExplicitBadge extends StatelessWidget {
  const _ExplicitBadge();

  @override
  Widget build(BuildContext context) {
    return Semantics(
      label: 'Explicit',
      child: Container(
        width: 14,
        height: 14,
        decoration: BoxDecoration(
          color: AppColors.textTertiary,
          borderRadius: BorderRadius.circular(2.5),
        ),
        alignment: Alignment.center,
        child: const Text(
          'E',
          style: TextStyle(
            fontSize: 9,
            height: 1,
            fontWeight: FontWeight.w800,
            color: AppColors.background,
          ),
        ),
      ),
    );
  }
}

/// Public alias — used by track rows as well as cards.
class ExplicitBadge extends StatelessWidget {
  const ExplicitBadge({super.key});

  @override
  Widget build(BuildContext context) => const _ExplicitBadge();
}
