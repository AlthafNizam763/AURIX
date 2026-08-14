import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/theme/aurix_palette.dart';
import '../../../data/models/avatar.dart';
import '../../../features/profile/providers/profile_provider.dart';

/// Draws a bundled AURIX avatar.
///
/// The counterpart to `AppArtwork`, which renders *remote* images. This one
/// never touches the network: its source is always an asset in the bundle, so
/// it has no loading state, no error state and no placeholder — the image is
/// already there on the first frame, offline included.
///
/// Use [AurixAvatar.of] for the signed-in user's avatar, which is what almost
/// every call site wants; the unnamed constructor is for drawing a *specific*
/// avatar, which in practice means the picker's own grid.
class AurixAvatar extends StatelessWidget {
  const AurixAvatar({
    required this.avatar,
    required this.size,
    this.semanticLabel,
    this.elevated = false,
    this.borderColor,
    this.borderWidth = 0,
    super.key,
  });

  final Avatar avatar;

  /// Layout edge in logical pixels. Also drives the decode size.
  final double size;

  /// Overrides the announced label. Defaults to the avatar's name, which is
  /// what makes a grid of similar tiles navigable by screen reader.
  final String? semanticLabel;

  /// Adds a soft drop shadow. Reserved for large, focal avatars.
  final bool elevated;

  /// Ring drawn just outside the image — the picker's selection state, and the
  /// hairline that separates a light avatar from a light surface.
  final Color? borderColor;
  final double borderWidth;

  @override
  Widget build(BuildContext context) {
    final dpr = MediaQuery.devicePixelRatioOf(context);

    Widget image = ClipOval(
      child: Image.asset(
        avatar.assetPath,
        width: size,
        height: size,
        fit: BoxFit.cover,
        // Right-sized decoding, the same reason AppArtwork does it: a 30px
        // library-header avatar has no business holding a 320px bitmap, and
        // there can be a dozen of these on screen at once in the picker.
        cacheWidth: (size * dpr).round().clamp(32, 640),
        filterQuality: FilterQuality.medium,
        // A missing asset is a build error, not a runtime state — but a blank
        // profile picture is the one outcome this system exists to prevent, so
        // it degrades to the brand ground rather than to Flutter's broken-image
        // glyph if a bundle is ever mis-assembled.
        errorBuilder: (context, _, _) => ColoredBox(
          color: context.palette.surfaceHighest,
          child: SizedBox(width: size, height: size),
        ),
      ),
    );

    if (borderWidth > 0 && borderColor != null) {
      image = DecoratedBox(
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          border: Border.all(color: borderColor!, width: borderWidth),
        ),
        // Inset so the ring sits *around* the avatar instead of cropping it.
        child: Padding(padding: EdgeInsets.all(borderWidth), child: image),
      );
    }

    if (elevated) {
      image = DecoratedBox(
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          boxShadow: [
            BoxShadow(
              color: Colors.black.withValues(alpha: 0.45),
              blurRadius: size * 0.12,
              offset: Offset(0, size * 0.04),
            ),
          ],
        ),
        child: image,
      );
    }

    return Semantics(
      image: true,
      label: semanticLabel ?? '${avatar.name} avatar',
      excludeSemantics: true,
      child: image,
    );
  }

  /// The signed-in user's avatar, straight from the shared profile state.
  ///
  /// Every profile-picture surface in the app is one of these, which is what
  /// makes a selection appear everywhere at once instead of on whichever screen
  /// happens to rebuild first.
  static Widget of({
    required double size,
    String? semanticLabel,
    bool elevated = false,
    Color? borderColor,
    double borderWidth = 0,
    Key? key,
  }) => _CurrentAvatar(
    size: size,
    semanticLabel: semanticLabel,
    elevated: elevated,
    borderColor: borderColor,
    borderWidth: borderWidth,
    key: key,
  );
}

class _CurrentAvatar extends ConsumerWidget {
  const _CurrentAvatar({
    required this.size,
    required this.semanticLabel,
    required this.elevated,
    required this.borderColor,
    required this.borderWidth,
    super.key,
  });

  final double size;
  final String? semanticLabel;
  final bool elevated;
  final Color? borderColor;
  final double borderWidth;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return AurixAvatar(
      avatar: ref.watch(selectedAvatarProvider),
      size: size,
      semanticLabel: semanticLabel ?? 'Your profile picture',
      elevated: elevated,
      borderColor: borderColor,
      borderWidth: borderWidth,
    );
  }
}
