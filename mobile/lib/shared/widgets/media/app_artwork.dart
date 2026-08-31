import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';

import '../../../core/theme/app_colors.dart';
import '../../../core/theme/app_dimens.dart';
import '../../../shared/widgets/icons/aurix_glyphs.dart';
import '../../../shared/widgets/icons/aurix_icon.dart';

/// The shape artwork takes, which differs by content type.
enum ArtworkShape {
  /// Albums, playlists, tracks.
  square,

  /// Artists and user avatars.
  circle,
}

/// Every piece of remote artwork in the app renders through this.
///
/// Centralising it buys three things that matter at scale:
///
///  * **Right-sized decoding.** [memCacheWidth] is derived from the layout
///    size and device pixel ratio, so a 48px list row decodes a 96px bitmap
///    instead of Spotify's 640px original. Across a 50-row list that is the
///    difference between a smooth scroll and a stuttering one.
///  * **A consistent placeholder.** A deterministic tint per item, so the
///    grid never flashes grey rectangles.
///  * **One error state.** A broken image looks intentional rather than
///    broken.
class AppArtwork extends StatelessWidget {
  const AppArtwork({
    required this.imageUrl,
    required this.size,
    this.shape = ArtworkShape.square,
    this.borderRadius,
    this.seed,
    this.fallbackIcon,
    this.heroTag,
    this.elevated = false,
    super.key,
  });

  final String? imageUrl;

  /// Layout edge in logical pixels. Also drives decode size.
  final double size;

  final ArtworkShape shape;
  final BorderRadius? borderRadius;

  /// Used to pick a stable placeholder tint — pass the item's ID so the same
  /// album always gets the same colour.
  final String? seed;

  final AurixGlyph? fallbackIcon;
  final Object? heroTag;

  /// Adds a soft drop shadow. Reserved for large, focal artwork.
  final bool elevated;

  @override
  Widget build(BuildContext context) {
    final radius = shape == ArtworkShape.circle
        ? BorderRadius.circular(size / 2)
        : (borderRadius ?? _radiusForSize(size));

    final dpr = MediaQuery.devicePixelRatioOf(context);
    final decodeWidth = (size * dpr).round().clamp(48, 1200);

    Widget image;
    if (imageUrl == null || imageUrl!.isEmpty) {
      image = _placeholder(showIcon: true);
    } else {
      image = CachedNetworkImage(
        imageUrl: imageUrl!,
        width: size,
        height: size,
        fit: BoxFit.cover,
        memCacheWidth: decodeWidth,
        // A short fade covers the decode without feeling sluggish.
        fadeInDuration: const Duration(milliseconds: 180),
        fadeOutDuration: const Duration(milliseconds: 80),
        placeholder: (_, _) => _placeholder(),
        errorWidget: (_, _, _) => _placeholder(showIcon: true),
      );
    }

    Widget result = ClipRRect(
      borderRadius: radius,
      child: SizedBox(width: size, height: size, child: image),
    );

    if (elevated) {
      result = DecoratedBox(
        decoration: BoxDecoration(
          borderRadius: radius,
          boxShadow: [
            BoxShadow(
              color: Colors.black.withValues(alpha: 0.45),
              blurRadius: size * 0.12,
              offset: Offset(0, size * 0.04),
            ),
          ],
        ),
        child: result,
      );
    }

    if (heroTag != null) {
      result = Hero(
        tag: heroTag!,
        // Without this the artwork briefly renders at the wrong aspect ratio
        // mid-flight, which reads as a glitch on a 300ms transition.
        flightShuttleBuilder: (_, animation, _, _, _) =>
            FadeTransition(opacity: animation, child: result),
        child: result,
      );
    }

    return result;
  }

  Widget _placeholder({bool showIcon = false}) {
    final tint = AppColors.placeholderFor(seed ?? imageUrl ?? '');
    return DecoratedBox(
      decoration: BoxDecoration(
        gradient: LinearGradient(
          colors: [
            Color.lerp(tint, AppColors.artworkPlaceholder, 0.35)!,
            AppColors.artworkPlaceholder,
          ],
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
        ),
      ),
      child: showIcon
          ? Center(
              child: AurixIcon(
                fallbackIcon ??
                    (shape == ArtworkShape.circle
                        ? AurixGlyph.profile
                        : AurixGlyph.musicNote),
                size: size * 0.36,
                color: AppColors.textTertiary,
              ),
            )
          : const SizedBox.expand(),
    );
  }

  /// Corner radius scales with artwork size — a 4px radius on a 320px cover
  /// looks like a mistake, and a 16px radius on a 40px thumbnail eats the art.
  static BorderRadius _radiusForSize(double size) {
    if (size <= 56) return const BorderRadius.all(Radius.circular(AppRadius.xs));
    if (size <= 160) return const BorderRadius.all(Radius.circular(AppRadius.sm));
    return const BorderRadius.all(Radius.circular(AppRadius.md));
  }
}
