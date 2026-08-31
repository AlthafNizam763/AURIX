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
import '../settings/providers/settings_provider.dart';

/// The launch screen.
///
/// Deliberately has no timer and no navigation of its own. The router's
/// redirect holds the app here while `AuthController` restores the session and
/// moves on the instant that finishes — so a warm start with a cached token
/// leaves almost immediately, and a slow one waits exactly as long as it needs
/// to. A fixed `Future.delayed` would either cut restore short or waste the
/// user's time on every launch.
///
/// The arrival sequence is therefore written to look right *when interrupted*:
/// every stage is a fade or a scale that reads as finished at any frame, and
/// nothing downstream depends on the animation reaching the end. On a warm
/// start the user sees the first third of it and then the app.
class SplashScreen extends ConsumerStatefulWidget {
  const SplashScreen({super.key});

  @override
  ConsumerState<SplashScreen> createState() => _SplashScreenState();
}

class _SplashScreenState extends ConsumerState<SplashScreen>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 1800),
  );

  // The sequence, as fractions of the controller. Named rather than inlined so
  // the ordering is legible in one place: web, then particles, then the mark,
  // then the glow and the words. The overlaps are deliberate — a strictly
  // sequential version reads as four separate animations.
  static const Interval _web = Interval(0, 0.42, curve: Curves.easeOutCubic);
  static const Interval _particles = Interval(0.12, 0.55, curve: Curves.easeOut);
  static const Interval _mark = Interval(0.28, 0.68, curve: Curves.easeOutBack);
  static const Interval _glow = Interval(0.5, 0.9, curve: Curves.easeOut);
  static const Interval _words = Interval(0.58, 1, curve: Curves.easeOutCubic);

  @override
  void initState() {
    super.initState();
    // Read once rather than watched: flipping "reduce motion" mid-splash
    // should not restart the sequence, and the screen is gone before the
    // setting can realistically change.
    if (ref.read(reduceMotionProvider)) {
      _controller.value = 1;
    } else {
      _controller.forward();
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final palette = context.palette;
    final reduceMotion = ref.watch(reduceMotionProvider);

    return Scaffold(
      backgroundColor: context.palette.ground,
      body: AnimatedBuilder(
        animation: _controller,
        builder: (context, _) {
          final t = _controller.value;
          final web = _web.transform(t);
          final particles = _particles.transform(t);
          final mark = _mark.transform(t).clamp(0.0, 1.0);
          final glow = _glow.transform(t);
          final words = _words.transform(t).clamp(0.0, 1.0);

          return DecoratedBox(
            decoration: BoxDecoration(
              gradient: RadialGradient(
                center: const Alignment(0, -0.25),
                radius: 1.15,
                // The bloom at the mark cools through the counterweight into
                // black at the corners. It lifts *with* the glow stage rather
                // than being present from frame one, so the screen genuinely
                // starts black the way the sequence intends.
                colors: [
                  Color.lerp(context.palette.ground, palette.brandSurfaceHigh, glow)!,
                  Color.lerp(context.palette.ground, palette.brandSurfaceLow, glow)!,
                  context.palette.ground,
                ],
                stops: const [0, 0.55, 0.95],
              ),
            ),
            child: GrainOverlay(
              fade: GrainFade.top,
              color: palette.grain,
              opacity: web,
              child: Stack(
                alignment: Alignment.center,
                children: [
                  // --- Stages 1–2: rings travel outward --------------------
                  //
                  // Three concentric rings leaving the centre, where a radial
                  // web used to expand. The web was a picture of a thing; this
                  // is a picture of *sound leaving a source*, which is the only
                  // metaphor a music app's opening frame needs — and it is
                  // three strokes, which is all a luxury splash should be.
                  Positioned.fill(
                    child: IgnorePointer(
                      child: RepaintBoundary(
                        child: CustomPaint(
                          painter: _RingField(
                            progress: web,
                            color: palette.accent,
                          ),
                        ),
                      ),
                    ),
                  ),

                  // --- Stage 3: drifting particles -------------------------
                  Positioned.fill(
                    child: IgnorePointer(
                      child: RepaintBoundary(
                        child: CustomPaint(
                          painter: _ParticleField(
                            progress: particles,
                            // Two greys rather than two hues. The field still
                            // reads as depth because the particles differ in
                            // brightness *and* in size.
                            warm: palette.accent,
                            cool: palette.textTertiary,
                          ),
                        ),
                      ),
                    ),
                  ),

                  // --- Stages 4–6: the mark lands, then the words ----------
                  Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      const Spacer(flex: 3),

                      Opacity(
                        opacity: mark,
                        child: Transform.scale(
                          // easeOutBack overshoots past 1, which is the small
                          // "landing" kick the mark wants.
                          scale: 0.82 + (_mark.transform(t) * 0.18),
                          child: SoftReveal(
                            maxOffset: 4,
                            enabled: !reduceMotion,
                            child: const AurixLogoBadge(size: 116),
                          ),
                        ),
                      ),

                      const SizedBox(height: AppSpacing.xxl),

                      Opacity(
                        opacity: words,
                        child: Transform.translate(
                          offset: Offset(0, 18 * (1 - words)),
                          child: Column(
                            children: [
                              // The wordmark proper — wide-tracked caps, not
                              // the display style. This is the one frame in the
                              // app that is purely brand, so it is the one
                              // place the logotype appears at size.
                              const AurixWordmark(fontSize: 30),
                              const SizedBox(height: AppSpacing.md),
                              Text(
                                AppConstants.appTagline,
                                style: AppTypography.bodyMedium.copyWith(
                                  letterSpacing: 0.4,
                                  color: palette.textTertiary,
                                ),
                              ),
                            ],
                          ),
                        ),
                      ),

                      const Spacer(flex: 2),

                      // A quiet indicator rather than a spinner: on a warm
                      // start this is on screen for under a second and a
                      // spinner would flash.
                      Opacity(opacity: words, child: const _LoadingPulse()),

                      const SizedBox(height: AppSpacing.huge),
                    ],
                  ),
                ],
              ),
            ),
          );
        },
      ),
    );
  }
}

/// Dimensional debris: small squares that drift outward and fade.
///
/// Three rings leaving the centre, staggered so they read as a sequence rather
/// than as a single thick stroke.
///
/// Each ring fades on a curve ahead of its own expansion — see the matching
/// note on the play button's press ring, which uses the same rule for the same
/// reason: a ring still solid at full radius reads as a boundary the interface
/// drew, not as something that left.
class _RingField extends CustomPainter {
  const _RingField({required this.progress, required this.color});

  /// 0 → 1 across the opening stage.
  final double progress;
  final Color color;

  static const int _count = 3;

  /// Fraction of the animation each successive ring waits before starting.
  static const double _stagger = 0.16;

  @override
  void paint(Canvas canvas, Size size) {
    if (progress <= 0.001 || size.isEmpty) return;

    final origin = Offset(size.width / 2, size.height * 0.375);
    // Far corner distance, so the last ring genuinely clears the screen rather
    // than stopping just inside it.
    final reach = math.sqrt(
      math.pow(size.width / 2, 2) + math.pow(size.height * 0.625, 2),
    );

    final paint = Paint()
      ..style = PaintingStyle.stroke
      ..isAntiAlias = true;

    for (var i = 0; i < _count; i++) {
      final local = ((progress - (i * _stagger)) / (1 - (_count * _stagger)))
          .clamp(0.0, 1.0);
      if (local <= 0.001) continue;

      final eased = Curves.easeOutCubic.transform(local);
      final alpha = (1 - Curves.easeInQuad.transform(local)) * 0.30;
      if (alpha <= 0.004) continue;

      canvas.drawCircle(
        origin,
        reach * eased,
        paint
          ..strokeWidth = 1.1
          ..color = color.withValues(alpha: alpha),
      );
    }
  }

  @override
  bool shouldRepaint(_RingField oldDelegate) =>
      oldDelegate.progress != progress || oldDelegate.color != color;
}

/// Positions come from an RNG rebuilt on every paint with the *same* seed, so
/// the field is identical frame to frame and only [progress] moves it. A field
/// that re-randomised each frame would read as static noise.
class _ParticleField extends CustomPainter {
  const _ParticleField({
    required this.progress,
    required this.warm,
    required this.cool,
  });

  final double progress;
  final Color warm;
  final Color cool;

  /// Enough to read as debris, few enough that the field costs one cheap
  /// `drawRect` loop per frame on a screen that is already animating.
  static const int _count = 26;

  @override
  void paint(Canvas canvas, Size size) {
    if (progress <= 0.01 || size.isEmpty) return;

    final random = math.Random(41);
    final centre = Offset(size.width / 2, size.height / 2);
    final reach = math.max(size.width, size.height) * 0.5;
    final paint = Paint()..style = PaintingStyle.fill;

    // In over the first third, then out — particles that linger at full
    // strength compete with the mark landing on top of them.
    final visibility = progress < 0.33
        ? progress / 0.33
        : 1 - ((progress - 0.33) / 0.67);

    for (var i = 0; i < _count; i++) {
      final angle = random.nextDouble() * math.pi * 2;
      final distance = (0.25 + (random.nextDouble() * 0.75)) * reach;
      final travel = 0.45 + (random.nextDouble() * 0.55);
      final side = 1.5 + (random.nextDouble() * 2.5);
      final warmChip = random.nextBool();

      final radius = distance * (0.35 + (progress * travel));
      final point = Offset(
        centre.dx + (math.cos(angle) * radius),
        centre.dy + (math.sin(angle) * radius),
      );

      paint.color = (warmChip ? warm : cool)
          .withValues(alpha: (visibility * 0.55).clamp(0.0, 1.0));

      // Squares, not circles: at this size a square reads as a chip of
      // shattered panel, which is the comic reference. A circle reads as dust.
      canvas.drawRect(
        Rect.fromCenter(center: point, width: side, height: side),
        paint,
      );
    }
  }

  @override
  bool shouldRepaint(_ParticleField oldDelegate) =>
      oldDelegate.progress != progress ||
      oldDelegate.warm != warm ||
      oldDelegate.cool != cool;
}

/// Three dots breathing in sequence.
class _LoadingPulse extends StatefulWidget {
  const _LoadingPulse();

  @override
  State<_LoadingPulse> createState() => _LoadingPulseState();
}

class _LoadingPulseState extends State<_LoadingPulse>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 1200),
  )..repeat();

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final accent = context.palette.accent;

    return AnimatedBuilder(
      animation: _controller,
      builder: (context, _) => Row(
        mainAxisAlignment: MainAxisAlignment.center,
        children: List.generate(3, (i) {
          final phase = (_controller.value + (i * 0.22)) % 1.0;
          final opacity = 0.25 + (0.65 * (1 - (phase - 0.5).abs() * 2));
          return Container(
            width: 6,
            height: 6,
            margin: const EdgeInsets.symmetric(horizontal: 3.5),
            decoration: BoxDecoration(
              color: accent.withValues(alpha: opacity),
              shape: BoxShape.circle,
            ),
          );
        }),
      ),
    );
  }
}
