/// What each player variant actually *changes*, expressed as data.
///
/// ## Why descriptors and not three widget trees per surface
///
/// The obvious way to ship "three mini-player themes" is three copies of the
/// mini player. It is also the way that guarantees they drift: a fix to the
/// buffering state, or to the Connect-device row, or to the semantics label,
/// lands in one copy and not the other two. The full player is worse — it is
/// seven hundred lines of layout, and three of those is a maintenance problem
/// rather than a feature.
///
/// So the *logic* stays where it is — one mini player, one full player, one
/// island — and a variant supplies a small value object describing the chrome:
/// shape, fill treatment, artwork size, control arrangement. Every variant
/// therefore inherits every bug fix, and adding a fourth is a constant here
/// rather than a new file.
///
/// This is also what the brief asks for in so many words: *do not hardcode
/// individual theme styles inside every component; avoid duplicating theme code
/// in individual components.*
///
/// ## Colours are not in here
///
/// Not one field below is a `Color`. Every variant paints from the configured
/// palette — `palette.player`, `palette.accent`, `palette.surface` — so an
/// operator who changes the player colour sees it in all three variants, and a
/// variant cannot smuggle in a colour the theme did not authorise. What varies
/// here is *form*.
library;

import 'package:flutter/material.dart';

import 'app_dimens.dart';
import 'theme_config.dart';

// ---------------------------------------------------------------------------
// Mini player
// ---------------------------------------------------------------------------

/// How the mini player's chrome is drawn.
@immutable
class MiniPlayerStyle {
  const MiniPlayerStyle({
    required this.radius,
    required this.frosted,
    required this.artworkSize,
    required this.artworkRadius,
    required this.horizontalMargin,
    required this.bottomMargin,
    required this.showsNextButton,
    required this.progressPlacement,
    required this.tintsFromArtwork,
    required this.elevation,
  });

  final BorderRadius radius;

  /// Whether the bar blurs what is behind it.
  ///
  /// Expensive — a `saveLayer` plus a full-width 24-sigma blur on every frame
  /// the bar is mounted, which is every screen. Two of the three variants skip
  /// it, and that is a real performance difference rather than a stylistic one:
  /// an operator who picks the flat variant gets a cheaper app.
  final bool frosted;

  final double artworkSize;
  final BorderRadius artworkRadius;
  final double horizontalMargin;
  final double bottomMargin;

  /// Whether the skip-next control is drawn.
  ///
  /// The compact variant drops it. Play/pause is the control a mini player
  /// exists for; skip is a convenience, and it is what has to go when the bar
  /// is a pill rather than a slab.
  final bool showsNextButton;

  final MiniProgressPlacement progressPlacement;

  /// Whether the fill picks up the artwork's brightness.
  final bool tintsFromArtwork;

  final double elevation;

  /// The shipped design: a frosted slab with a hairline of progress along the
  /// bottom edge.
  static const MiniPlayerStyle theme1 = MiniPlayerStyle(
    radius: BorderRadius.all(Radius.circular(AppRadius.sm)),
    frosted: true,
    artworkSize: 44,
    artworkRadius: BorderRadius.all(Radius.circular(AppRadius.xs)),
    horizontalMargin: AppSpacing.sm,
    bottomMargin: 0,
    showsNextButton: true,
    progressPlacement: MiniProgressPlacement.hairlineBottom,
    tintsFromArtwork: true,
    elevation: 18,
  );

  /// A floating pill. Opaque, fully rounded, circular artwork, no skip.
  ///
  /// Deliberately not frosted: at this radius the blur haloes visibly along the
  /// curve, and the shape is doing the work the glass did in theme 1.
  static const MiniPlayerStyle theme2 = MiniPlayerStyle(
    radius: BorderRadius.all(Radius.circular(999)),
    frosted: false,
    artworkSize: 40,
    artworkRadius: BorderRadius.all(Radius.circular(999)),
    horizontalMargin: AppSpacing.lg,
    bottomMargin: AppSpacing.sm,
    showsNextButton: false,
    progressPlacement: MiniProgressPlacement.none,
    tintsFromArtwork: false,
    elevation: 24,
  );

  /// Artwork-led: a larger cover, a squared card edge-to-edge, and the progress
  /// line above the row rather than under it.
  static const MiniPlayerStyle theme3 = MiniPlayerStyle(
    radius: BorderRadius.zero,
    frosted: false,
    artworkSize: 52,
    artworkRadius: BorderRadius.zero,
    horizontalMargin: 0,
    bottomMargin: 0,
    showsNextButton: true,
    progressPlacement: MiniProgressPlacement.hairlineTop,
    tintsFromArtwork: true,
    elevation: 12,
  );

  /// Quiet: a squared, opaque card with no progress line and no artwork tint.
  ///
  /// The cheapest mini player of the four — no `saveLayer`, no blur, and no
  /// palette extraction from the cover — on the one surface that is mounted on
  /// every screen while audio plays. Chosen for that as much as for the look.
  static const MiniPlayerStyle theme4 = MiniPlayerStyle(
    radius: BorderRadius.all(Radius.circular(AppRadius.xs)),
    frosted: false,
    artworkSize: 40,
    artworkRadius: BorderRadius.all(Radius.circular(AppRadius.xs)),
    horizontalMargin: AppSpacing.md,
    bottomMargin: AppSpacing.xs,
    showsNextButton: true,
    progressPlacement: MiniProgressPlacement.none,
    tintsFromArtwork: false,
    elevation: 8,
  );

  static MiniPlayerStyle of(PlayerVariant variant) => switch (variant) {
    PlayerVariant.theme1 => theme1,
    PlayerVariant.theme2 => theme2,
    PlayerVariant.theme3 => theme3,
    PlayerVariant.theme4 => theme4,
  };
}

/// Where the mini player's progress indicator sits, if anywhere.
enum MiniProgressPlacement { hairlineBottom, hairlineTop, none }

// ---------------------------------------------------------------------------
// Large player
// ---------------------------------------------------------------------------

/// How the full-screen player is composed.
@immutable
class LargePlayerStyle {
  const LargePlayerStyle({
    required this.backdrop,
    required this.artworkRadius,
    required this.artworkScale,
    required this.artworkShadow,
    required this.titleAlignment,
    required this.transportSpacing,
    required this.showsBackdropGrain,
  });

  final PlayerBackdrop backdrop;

  final BorderRadius artworkRadius;

  /// A multiplier on the artwork's computed side length.
  ///
  /// A multiplier rather than an absolute size, because the base is already
  /// derived from the available height and the safe areas — an absolute value
  /// would clip on a short screen and float on a tablet. Variants scale the
  /// result; they do not replace the calculation.
  final double artworkScale;

  final bool artworkShadow;
  final CrossAxisAlignment titleAlignment;
  final double transportSpacing;

  /// Grain over the backdrop.
  ///
  /// Load-bearing rather than decorative on the gradient backdrops: they stack
  /// four translucent layers of near-black, which is exactly where 8-bit
  /// gradients band into visible steps. The flat backdrop has no gradient to
  /// band, so it switches this off.
  final bool showsBackdropGrain;

  /// The shipped design: a blurred, greyscaled wash of the artwork.
  static const LargePlayerStyle theme1 = LargePlayerStyle(
    backdrop: PlayerBackdrop.artworkWash,
    artworkRadius: BorderRadius.all(Radius.circular(AppRadius.lg)),
    artworkScale: 1,
    artworkShadow: true,
    titleAlignment: CrossAxisAlignment.start,
    transportSpacing: AppSpacing.lg,
    showsBackdropGrain: true,
  );

  /// Flat and centred. The page colour, a circular cover, centred type.
  ///
  /// The cheapest of the three to render — no blur pass, no gradient stack —
  /// and the only one that looks the same whatever the artwork is, which is
  /// what an operator with a strong brand palette usually wants.
  static const LargePlayerStyle theme2 = LargePlayerStyle(
    backdrop: PlayerBackdrop.flat,
    artworkRadius: BorderRadius.all(Radius.circular(999)),
    artworkScale: 0.86,
    artworkShadow: false,
    titleAlignment: CrossAxisAlignment.center,
    transportSpacing: AppSpacing.xl,
    showsBackdropGrain: false,
  );

  /// Edge-to-edge artwork with the controls floating over it.
  static const LargePlayerStyle theme3 = LargePlayerStyle(
    backdrop: PlayerBackdrop.gradientAccent,
    artworkRadius: BorderRadius.zero,
    artworkScale: 1.08,
    artworkShadow: true,
    titleAlignment: CrossAxisAlignment.start,
    transportSpacing: AppSpacing.md,
    showsBackdropGrain: true,
  );

  /// Quiet: the flat page colour, a softly rounded cover, type left-aligned.
  ///
  /// Theme 2 is the other flat backdrop, but it centres everything and rounds
  /// the artwork to a circle — which crops album covers hard. This keeps the
  /// square and the reading order of theme 1 while dropping the blur pass.
  static const LargePlayerStyle theme4 = LargePlayerStyle(
    backdrop: PlayerBackdrop.flat,
    artworkRadius: BorderRadius.all(Radius.circular(AppRadius.md)),
    artworkScale: 0.94,
    artworkShadow: false,
    titleAlignment: CrossAxisAlignment.start,
    transportSpacing: AppSpacing.lg,
    showsBackdropGrain: false,
  );

  static LargePlayerStyle of(PlayerVariant variant) => switch (variant) {
    PlayerVariant.theme1 => theme1,
    PlayerVariant.theme2 => theme2,
    PlayerVariant.theme3 => theme3,
    PlayerVariant.theme4 => theme4,
  };
}

/// What is painted behind the full player.
enum PlayerBackdrop {
  /// The artwork, blurred and greyscaled, under a gradient sink.
  artworkWash,

  /// The configured player colour, flat.
  flat,

  /// A gradient from the configured player colour to the page colour.
  gradientAccent,
}

// ---------------------------------------------------------------------------
// Outside player — the OS notification and lock screen
// ---------------------------------------------------------------------------

/// How the media notification presents itself.
///
/// ## What is genuinely configurable here, and what is not
///
/// This surface is drawn by Android and iOS, not by AURIX, so the honest answer
/// is: less than the other three. The system decides the typeface, the colours
/// and the layout. What an app controls is *which* transport actions exist,
/// which of them are promoted into the collapsed view, and whether artwork is
/// attached.
///
/// So these three variants are real but modest, and this comment exists so
/// nobody goes looking for the colour fields. An operator expecting the
/// notification to follow their palette should be told it will not — the OS
/// tints it from the artwork and its own theme.
@immutable
class OutsidePlayerStyle {
  const OutsidePlayerStyle({
    required this.compactActions,
    required this.showsSeekControls,
  });

  /// Indices into the action list that appear in the collapsed notification.
  /// Android shows at most three.
  final List<int> compactActions;

  /// Whether seek-forward and seek-backward actions are offered alongside
  /// track skip.
  ///
  /// `MediaAction.seek` itself is always published regardless — it is what the
  /// lock-screen scrubber uses, and withholding it would freeze the timeline
  /// rather than tidy the controls.
  final bool showsSeekControls;

  // There is deliberately no `showsArtwork` or `showsProgress` here. Both were
  // drafted and removed: artwork comes from the `MediaItem`, which every
  // variant needs anyway, and hiding progress would mean withholding the
  // track's duration — which breaks the scrubber rather than simplifying the
  // notification. A field no variant can honestly vary is worse than no field.

  /// Previous / play / next in the collapsed view.
  static const OutsidePlayerStyle theme1 = OutsidePlayerStyle(
    compactActions: <int>[0, 1, 2],
    showsSeekControls: false,
  );

  /// Minimal: play/pause alone in the collapsed view.
  static const OutsidePlayerStyle theme2 = OutsidePlayerStyle(
    compactActions: <int>[1],
    showsSeekControls: false,
  );

  /// Everything: track skip in the collapsed view, plus seek controls.
  static const OutsidePlayerStyle theme3 = OutsidePlayerStyle(
    compactActions: <int>[0, 1, 2],
    showsSeekControls: true,
  );

  /// Forward-only: play/pause and skip-next collapsed, no seek controls.
  ///
  /// For a listener working through a queue rather than scrubbing within a
  /// track. Dropping "previous" is what buys skip-next a place in a collapsed
  /// notification that Android limits to three actions.
  static const OutsidePlayerStyle theme4 = OutsidePlayerStyle(
    compactActions: <int>[1, 2],
    showsSeekControls: false,
  );

  static OutsidePlayerStyle of(PlayerVariant variant) => switch (variant) {
    PlayerVariant.theme1 => theme1,
    PlayerVariant.theme2 => theme2,
    PlayerVariant.theme3 => theme3,
    PlayerVariant.theme4 => theme4,
  };
}

// ---------------------------------------------------------------------------
// Dynamic player — the floating island
// ---------------------------------------------------------------------------

/// How the Dynamic Island pill is shaped and what it shows.
@immutable
class DynamicPlayerStyle {
  const DynamicPlayerStyle({
    required this.collapsedHeight,
    required this.cornerRadius,
    required this.showsWaveform,
    required this.expandOnTrackChange,
    required this.glowIntensity,
  });

  final double collapsedHeight;
  final double cornerRadius;

  /// The animated bars beside the title.
  ///
  /// The most expensive thing the island draws — a repainting custom painter on
  /// a surface that can be up while the app is backgrounded — so switching it
  /// off is a battery decision as much as a visual one.
  final bool showsWaveform;

  /// Whether the pill flashes when the track changes.
  final bool expandOnTrackChange;

  /// Scales the ambient glow, 0–1.
  final double glowIntensity;

  /// The shipped island: a waveform, artwork, and a flash on track change.
  static const DynamicPlayerStyle theme1 = DynamicPlayerStyle(
    collapsedHeight: 46,
    cornerRadius: 23,
    showsWaveform: true,
    expandOnTrackChange: true,
    glowIntensity: 1,
  );

  /// Quiet: a slimmer pill, no waveform, no flash.
  static const DynamicPlayerStyle theme2 = DynamicPlayerStyle(
    collapsedHeight: 38,
    cornerRadius: 19,
    showsWaveform: false,
    expandOnTrackChange: false,
    glowIntensity: 0.4,
  );

  /// Expressive: taller, squarer, and it announces every track change.
  static const DynamicPlayerStyle theme3 = DynamicPlayerStyle(
    collapsedHeight: 54,
    cornerRadius: 18,
    showsWaveform: true,
    expandOnTrackChange: true,
    glowIntensity: 1,
  );

  /// Quiet: a short, squared tab with no waveform, no flash and no glow.
  ///
  /// The only variant that repaints nothing while a track plays — the waveform
  /// painter is the island's whole running cost, and this is the option for a
  /// device where that matters.
  static const DynamicPlayerStyle theme4 = DynamicPlayerStyle(
    collapsedHeight: 40,
    cornerRadius: 10,
    showsWaveform: false,
    expandOnTrackChange: false,
    glowIntensity: 0,
  );

  static DynamicPlayerStyle of(PlayerVariant variant) => switch (variant) {
    PlayerVariant.theme1 => theme1,
    PlayerVariant.theme2 => theme2,
    PlayerVariant.theme3 => theme3,
    PlayerVariant.theme4 => theme4,
  };
}
