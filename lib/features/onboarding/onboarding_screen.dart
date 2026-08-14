import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/constants/app_constants.dart';
import '../../core/theme/app_dimens.dart';
import '../../core/theme/app_typography.dart';
import '../../core/theme/aurix_palette.dart';
import '../../shared/widgets/brand/aurix_logo.dart';
import '../../shared/widgets/effects/grain.dart';
import '../../shared/widgets/effects/reveal.dart';
import '../../shared/widgets/icons/aurix_glyphs.dart';
import '../../shared/widgets/icons/aurix_icon.dart';
import '../settings/providers/settings_provider.dart';
import 'providers/onboarding_provider.dart';

/// One intro panel.
@immutable
class _Slide {
  const _Slide({
    required this.overline,
    required this.title,
    required this.body,
    required this.icon,
    required this.anchor,
  });

  final String overline;
  final String title;
  final String body;
  final AurixGlyph icon;

  /// Which corner this panel's grain falls away from. Rotating it between
  /// slides is what makes the four read as different rooms rather than one
  /// screen with the text swapped out — the same job the pinned web used to do,
  /// carried by the direction of the light instead of by a drawn object.
  final GrainFade anchor;
}

const List<_Slide> _slides = <_Slide>[
  _Slide(
    overline: 'WELCOME TO AURIX',
    title: 'YOUR SOUND.\nYOUR UNIVERSE.',
    body: 'A player built around the music you already have — and the artwork '
        'that comes with it.',
    icon: AurixGlyph.equalizer,
    anchor: GrainFade.topRight,
  ),
  _Slide(
    overline: 'DISCOVER YOUR SOUND',
    title: 'FIND YOUR\nFREQUENCY.',
    body: 'Search the full catalogue, follow the artists you care about, and '
        'let the app surface the rest.',
    icon: AurixGlyph.search,
    anchor: GrainFade.topLeft,
  ),
  _Slide(
    overline: 'BUILD YOUR UNIVERSE',
    title: 'COLLECT\nEVERY WORLD.',
    body: 'Liked songs, albums, artists and playlists — your whole library, '
        'in one place and readable offline.',
    icon: AurixGlyph.library,
    anchor: GrainFade.bottom,
  ),
  _Slide(
    overline: 'ENTER THE SOUNDVERSE',
    title: 'STEP\nTHROUGH.',
    body: 'Connect a Spotify account to begin. AURIX is an independent client '
        'and is not affiliated with Spotify.',
    icon: AurixGlyph.sparkle,
    anchor: GrainFade.none,
  ),
];

/// The first-run intro.
///
/// Four panels, then a single call to action. Navigation is the only thing
/// this screen owns: finishing marks [onboardingCompleteProvider] and the
/// router's redirect moves on, so the screen never pushes a route itself and
/// cannot race the auth gate.
///
/// The artwork is drawn, not shipped: webs, halftone and a glow behind a
/// glyph. That keeps the intro on the app's own visual language, adds nothing
/// to the bundle, and means it recolours with the active colourway.
class OnboardingScreen extends ConsumerStatefulWidget {
  const OnboardingScreen({super.key});

  @override
  ConsumerState<OnboardingScreen> createState() => _OnboardingScreenState();
}

class _OnboardingScreenState extends ConsumerState<OnboardingScreen> {
  final PageController _controller = PageController();

  /// Fractional page position, used for the parallax. Kept separate from
  /// [_index] because it updates every frame of a drag while the index only
  /// changes when a page settles — driving the dots from this would make them
  /// flicker mid-swipe.
  double _offset = 0;
  int _index = 0;

  @override
  void initState() {
    super.initState();
    _controller.addListener(_onScroll);
  }

  void _onScroll() {
    if (!_controller.hasClients) return;
    final page = _controller.page ?? 0;
    if ((page - _offset).abs() < 0.001) return;
    setState(() => _offset = page);
  }

  @override
  void dispose() {
    _controller
      ..removeListener(_onScroll)
      ..dispose();
    super.dispose();
  }

  bool get _isLast => _index == _slides.length - 1;

  Future<void> _finish() =>
      ref.read(onboardingCompleteProvider.notifier).complete();

  void _next(bool animate) {
    if (_isLast) {
      // `unawaited` would hide a genuine write failure; the future completes
      // fast and the router reacts to the state change, not to this call.
      _finish();
      return;
    }
    if (!animate) {
      _controller.jumpToPage(_index + 1);
      return;
    }
    _controller.nextPage(
      duration: AppConstants.medium,
      curve: Curves.easeOutCubic,
    );
  }

  @override
  Widget build(BuildContext context) {
    final palette = context.palette;
    final reduceMotion = ref.watch(reduceMotionProvider);
    final animate = !reduceMotion;

    return Scaffold(
      backgroundColor: context.palette.ground,
      body: DecoratedBox(
        decoration: BoxDecoration(
          gradient: RadialGradient(
            center: const Alignment(0, -0.55),
            radius: 1.25,
            colors: [
              palette.brandSurfaceHigh,
              palette.brandSurfaceLow,
              context.palette.ground,
            ],
            stops: const [0, 0.5, 1],
          ),
        ),
        child: SafeArea(
          child: Column(
            children: [
              _TopBar(
                showSkip: !_isLast,
                onSkip: _finish,
              ),

              Expanded(
                child: PageView.builder(
                  controller: _controller,
                  itemCount: _slides.length,
                  onPageChanged: (value) => setState(() => _index = value),
                  itemBuilder: (context, index) => _SlideView(
                    slide: _slides[index],
                    // Distance of this panel from the viewport centre, in
                    // pages. 0 is centred; ±1 is fully off to one side.
                    delta: index - _offset,
                    animate: animate,
                  ),
                ),
              ),

              _Dots(count: _slides.length, index: _index, offset: _offset),
              const SizedBox(height: AppSpacing.xl),

              Padding(
                padding: const EdgeInsets.symmetric(
                  horizontal: AppSpacing.xxl,
                ),
                child: SizedBox(
                  width: double.infinity,
                  child: FilledButton(
                    onPressed: () => _next(animate),
                    child: Text(_isLast ? 'START LISTENING' : 'NEXT'),
                  ),
                ),
              ),

              const SizedBox(height: AppSpacing.xxl),
            ],
          ),
        ),
      ),
    );
  }
}

class _TopBar extends StatelessWidget {
  const _TopBar({required this.showSkip, required this.onSkip});

  final bool showSkip;
  final VoidCallback onSkip;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(
        AppSpacing.xl,
        AppSpacing.md,
        AppSpacing.md,
        0,
      ),
      child: Row(
        children: [
          const AurixLogo(size: 26),
          const SizedBox(width: AppSpacing.sm + 2),
          Text(
            AppConstants.appName,
            style: AppTypography.wordmark.copyWith(fontSize: 15),
          ),
          const Spacer(),
          // Kept in the tree when hidden so the bar's height never changes —
          // a row that grows on the last slide shifts everything below it.
          Opacity(
            opacity: showSkip ? 1 : 0,
            child: IgnorePointer(
              ignoring: !showSkip,
              child: TextButton(
                onPressed: onSkip,
                child: const Text('Skip'),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _SlideView extends StatelessWidget {
  const _SlideView({
    required this.slide,
    required this.delta,
    required this.animate,
  });

  final _Slide slide;
  final double delta;
  final bool animate;

  @override
  Widget build(BuildContext context) {
    // Artwork trails the swipe and text leads it. The split rate is the whole
    // parallax effect; moving both by the same amount just slides the panel.
    final artShift = animate ? delta * 44 : 0.0;
    final textShift = animate ? delta * 90 : 0.0;
    final fade = (1 - delta.abs()).clamp(0.0, 1.0);

    return LayoutBuilder(
      builder: (context, constraints) {
        // The panel is the only part of a slide that can afford to give up
        // room, so it takes the hit on a short screen. The text is the payload
        // and shrinking that would defeat the point of the screen.
        final art = math.min(
          _SlideArt.maxSize,
          constraints.maxHeight * 0.4,
        );

        return SingleChildScrollView(
          // Scrolls only when it has to. This is the escape hatch for a short
          // viewport *and* for a large text scale, either of which would
          // otherwise overflow a fixed column by a few pixels — which Flutter
          // reports as an error rather than quietly clipping.
          physics: const ClampingScrollPhysics(),
          child: ConstrainedBox(
            constraints: BoxConstraints(minHeight: constraints.maxHeight),
            child: _SlideBody(
              slide: slide,
              artSize: art,
              artShift: artShift,
              textShift: textShift,
              fade: fade,
              animate: animate,
            ),
          ),
        );
      },
    );
  }
}

class _SlideBody extends StatelessWidget {
  const _SlideBody({
    required this.slide,
    required this.artSize,
    required this.artShift,
    required this.textShift,
    required this.fade,
    required this.animate,
  });

  final _Slide slide;
  final double artSize;
  final double artShift;
  final double textShift;
  final double fade;
  final bool animate;

  @override
  Widget build(BuildContext context) {
    final palette = context.palette;

    return Padding(
      padding: const EdgeInsets.symmetric(
        horizontal: AppSpacing.xxl,
        vertical: AppSpacing.lg,
      ),
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Center(
            child: Transform.translate(
              offset: Offset(artShift, 0),
              child: _SlideArt(
                icon: slide.icon,
                anchor: slide.anchor,
                animate: animate,
                size: artSize,
              ),
            ),
          ),

          const SizedBox(height: AppSpacing.xxxl),

          Transform.translate(
            offset: Offset(textShift, 0),
            child: Opacity(
              opacity: fade,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    slide.overline,
                    style: AppTypography.overline.copyWith(
                      color: palette.textTertiary,
                    ),
                  ),
                  const SizedBox(height: AppSpacing.md),
                  // Plain type. A resting chromatic split used to sit on this
                  // headline; in one colour it is just a blurred headline, and
                  // an intro screen is the worst place in the app to look like
                  // it failed to render.
                  Text(slide.title, style: AppTypography.displayMedium),
                  const SizedBox(height: AppSpacing.lg),
                  Text(
                    slide.body,
                    style: AppTypography.bodyLarge.copyWith(
                      color: palette.textSecondary,
                      height: 1.5,
                    ),
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// The drawn panel artwork: a glyph on a rotated, grained plate.
class _SlideArt extends StatelessWidget {
  const _SlideArt({
    required this.icon,
    required this.anchor,
    required this.animate,
    required this.size,
  });

  final AurixGlyph icon;
  final GrainFade anchor;
  final bool animate;
  final double size;

  /// The size the panel wants. Slides shrink it on a short viewport rather
  /// than letting the column overflow.
  static const double maxSize = 216;

  @override
  Widget build(BuildContext context) {
    final palette = context.palette;

    return SizedBox.square(
      dimension: size,
      child: Stack(
        alignment: Alignment.center,
        children: [
          // A wash behind everything, an order of magnitude down from the two
          // stacked blooms this used to be. In white, that pair lit the whole
          // panel and the plate below it stopped reading as a solid object.
          DecoratedBox(
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              gradient: RadialGradient(
                colors: [
                  palette.glow(0.08),
                  palette.glow(0.03),
                  Colors.transparent,
                ],
                stops: const [0, 0.5, 1],
              ),
            ),
            child: SizedBox.square(dimension: size),
          ),

          // The plate: a rotated square, grained, with a hairline.
          Transform.rotate(
            angle: math.pi / 4,
            child: ClipRRect(
              borderRadius: BorderRadius.circular(AppRadius.xl),
              child: SizedBox.square(
                dimension: size * 0.62,
                child: DecoratedBox(
                  decoration: BoxDecoration(
                    color: palette.brandSurfaceHigh,
                    border: Border.all(color: palette.hairlineStrong),
                    borderRadius: BorderRadius.circular(AppRadius.xl),
                  ),
                  // The grain is rotated 45° with the plate, which is the point
                  // — it belongs to the surface, so it has to turn with it. A
                  // texture that stays axis-aligned while its plate rotates is
                  // instantly readable as an overlay.
                  child: GrainOverlay(
                    spacing: 4,
                    maxRadius: 0.8,
                    color: palette.grain,
                    fade: anchor,
                    child: const SizedBox.expand(),
                  ),
                ),
              ),
            ),
          ),

          // The glyph rides upright on top of the rotated plate.
          SoftReveal(
            enabled: animate,
            maxOffset: 6,
            trigger: icon,
            child: AurixIcon(
              icon,
              size: size * 0.25,
              color: palette.textPrimary,
            ),
          ),
        ],
      ),
    );
  }
}

class _Dots extends StatelessWidget {
  const _Dots({
    required this.count,
    required this.index,
    required this.offset,
  });

  final int count;
  final int index;
  final double offset;

  @override
  Widget build(BuildContext context) {
    final accent = context.palette.accent;

    return Semantics(
      label: 'Step ${index + 1} of $count',
      excludeSemantics: true,
      child: Row(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          for (var i = 0; i < count; i++)
            AnimatedContainer(
              duration: AppConstants.fast,
              curve: Curves.easeOut,
              margin: const EdgeInsets.symmetric(horizontal: 3),
              height: 4,
              // The active dot stretches into a bar. Interpolating on the
              // fractional offset means it grows *during* the swipe rather
              // than snapping when the page settles.
              width: 4 + (18 * (1 - (offset - i).abs()).clamp(0.0, 1.0)),
              decoration: BoxDecoration(
                color: Color.lerp(
                  context.palette.textTertiary,
                  accent,
                  (1 - (offset - i).abs()).clamp(0.0, 1.0),
                ),
                borderRadius: BorderRadius.circular(AppRadius.pill),
              ),
            ),
        ],
      ),
    );
  }
}
