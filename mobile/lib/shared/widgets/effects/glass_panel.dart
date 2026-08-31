import 'dart:ui';

import 'package:flutter/material.dart';

import '../../../core/theme/app_dimens.dart';
import '../../../core/theme/aurix_palette.dart';

/// A frosted panel.
///
/// Glassmorphism only works when there is something *behind* it worth blurring
/// — artwork, a gradient, a grained field. On a flat surface it degrades to a
/// slightly lighter card, which is why [enabled] exists: screens with no
/// backdrop pass false and get a plain surface instead of paying for a
/// `BackdropFilter` that produces nothing.
///
/// `BackdropFilter` is genuinely expensive: it forces a saveLayer and reads back
/// the framebuffer. One or two per screen is fine; one per list row is not,
/// which is why the card and tile widgets do not use this.
///
/// ## Fills resolve from the theme, not from a default argument
///
/// [fill] and [borderColor] are nullable and resolved in `build`. They used to
/// default to dark-mode constants, which is invisible in dark mode and wrong in
/// light: frosting *light* content means adding white, not shade, so the two
/// themes need opposite fills. A `const` constructor cannot read context, so the
/// null case is what makes the default correct in both.
class GlassPanel extends StatelessWidget {
  const GlassPanel({
    required this.child,
    this.blur = 24,
    this.borderRadius = AppRadius.card,
    this.padding,
    this.fill,
    this.borderColor,
    this.enabled = true,
    this.strong = false,
    super.key,
  });

  final Widget child;
  final double blur;
  final BorderRadius borderRadius;
  final EdgeInsetsGeometry? padding;

  /// Null resolves to the theme's glass fill. See the class note.
  final Color? fill;
  final Color? borderColor;

  /// False renders an opaque surface with no `BackdropFilter`.
  final bool enabled;

  /// Uses the heavier fill, for panels that carry primary controls and must
  /// stay legible over bright artwork.
  final bool strong;

  @override
  Widget build(BuildContext context) {
    final palette = context.palette;
    final resolvedFill =
        fill ?? (strong ? palette.glassFillStrong : palette.glassFill);
    final resolvedBorder = borderColor ?? palette.glassBorder;

    final content = Padding(
      padding: padding ?? const EdgeInsets.all(AppSpacing.lg),
      child: child,
    );

    if (!enabled) {
      return DecoratedBox(
        decoration: BoxDecoration(
          color: palette.surfaceElevated,
          borderRadius: borderRadius,
          border: Border.all(color: resolvedBorder),
        ),
        child: content,
      );
    }

    return ClipRRect(
      borderRadius: borderRadius,
      child: BackdropFilter(
        filter: ImageFilter.blur(sigmaX: blur, sigmaY: blur),
        child: DecoratedBox(
          decoration: BoxDecoration(
            color: resolvedFill,
            borderRadius: borderRadius,
            border: Border.all(color: resolvedBorder),
          ),
          child: content,
        ),
      ),
    );
  }
}

/// A container with a hairline border.
///
/// Replaced a gradient "neon" border. With one accent there is no second stop
/// to run a gradient to, and a white glow around a white-accented card is the
/// single fastest way to make a monochrome interface look cheap — bloom is what
/// separates a premium dark UI from a gamer one.
///
/// Emphasis here is carried by the border's *alpha* instead, which is why
/// [emphasis] exists: a resting card sits near-invisible at the theme hairline,
/// and a selected one comes up toward the accent without ever glowing.
class HairlineFrame extends StatelessWidget {
  const HairlineFrame({
    required this.child,
    this.width = 1,
    this.borderRadius = AppRadius.card,
    this.emphasis = 0,
    this.backgroundColor,
    super.key,
  });

  final Widget child;
  final double width;
  final BorderRadius borderRadius;

  /// 0 is the resting hairline; 1 is the full accent.
  final double emphasis;

  final Color? backgroundColor;

  @override
  Widget build(BuildContext context) {
    final palette = context.palette;

    return DecoratedBox(
      decoration: BoxDecoration(
        color: backgroundColor ?? palette.surface,
        borderRadius: borderRadius,
        border: Border.all(
          width: width,
          color: Color.lerp(
            palette.hairline,
            palette.accent,
            emphasis.clamp(0.0, 1.0),
          )!,
        ),
      ),
      child: child,
    );
  }
}

/// A soft radial wash, for placing behind a focal element.
///
/// Kept, but renamed from "glow" and re-tuned an order of magnitude down. It is
/// now a *lift* — it separates a focal element from the page by lightening the
/// ground behind it, rather than by emitting light. Anything above roughly 0.10
/// intensity starts to read as a bloom; see [HairlineFrame] for why that is the
/// thing to avoid.
class SoftLift extends StatelessWidget {
  const SoftLift({
    this.color,
    this.size = 240,
    this.intensity = 0.06,
    super.key,
  });

  /// Null resolves to the theme accent.
  final Color? color;
  final double size;
  final double intensity;

  @override
  Widget build(BuildContext context) {
    final resolved = color ?? context.palette.accent;

    return IgnorePointer(
      child: SizedBox.square(
        dimension: size,
        child: DecoratedBox(
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            gradient: RadialGradient(
              colors: [
                resolved.withValues(alpha: intensity),
                resolved.withValues(alpha: intensity * 0.3),
                resolved.withValues(alpha: 0),
              ],
              stops: const [0, 0.45, 1],
            ),
          ),
        ),
      ),
    );
  }
}
