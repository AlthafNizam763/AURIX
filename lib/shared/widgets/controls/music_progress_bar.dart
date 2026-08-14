import 'package:flutter/material.dart';

import '../../../core/theme/app_colors.dart';
import '../../../core/theme/app_dimens.dart';
import '../../../core/theme/app_typography.dart';
import '../../../core/theme/aurix_palette.dart';
import '../../../core/utils/formatters.dart';
import '../../../shared/widgets/icons/aurix_glyphs.dart';
import '../../../shared/widgets/icons/aurix_icon.dart';

/// Scrubber with timecodes.
///
/// The key behaviour is the local drag override: while the user is dragging,
/// the widget shows *their* position and ignores incoming position updates.
/// Without that, every stream tick during a drag yanks the thumb back and the
/// bar becomes impossible to scrub — the single most common bug in hand-rolled
/// music scrubbers.
class MusicProgressBar extends StatefulWidget {
  const MusicProgressBar({
    required this.position,
    required this.duration,
    required this.onSeek,
    this.enabled = true,
    this.showTimecodes = true,
    this.showRemaining = true,
    this.previewNotice,
    this.accentColor,
    super.key,
  });

  final Duration position;
  final Duration duration;
  final ValueChanged<Duration> onSeek;
  final bool enabled;
  final bool showTimecodes;

  /// Shows time remaining on the right rather than total duration.
  final bool showRemaining;

  /// Label rendered under the bar when only a 30-second excerpt is playing.
  /// Passing this is how the player stays honest about what the bar measures.
  final String? previewNotice;

  final Color? accentColor;

  @override
  State<MusicProgressBar> createState() => _MusicProgressBarState();
}

class _MusicProgressBarState extends State<MusicProgressBar> {
  double? _dragValue;

  @override
  Widget build(BuildContext context) {
    final totalMs = widget.duration.inMilliseconds;
    final hasDuration = totalMs > 0;

    final currentMs = _dragValue ?? widget.position.inMilliseconds.toDouble();
    final clamped = hasDuration ? currentMs.clamp(0.0, totalMs.toDouble()) : 0.0;

    final displayed = Duration(milliseconds: clamped.round());
    final accent = widget.accentColor ?? AppColors.textPrimary;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        SliderTheme(
          data: SliderTheme.of(context).copyWith(
            activeTrackColor: widget.enabled ? accent : AppColors.textTertiary,
            inactiveTrackColor: accent.withValues(alpha: 0.24),
            thumbColor: widget.enabled ? accent : AppColors.textTertiary,
            overlayColor: accent.withValues(alpha: 0.14),
            // A thicker track while dragging gives the grab some weight.
            trackHeight: _dragValue != null ? 5 : 3,
            thumbShape: RoundSliderThumbShape(
              enabledThumbRadius: _dragValue != null ? 8 : 6,
              disabledThumbRadius: 4,
            ),
          ),
          child: Slider(
            value: clamped,
            max: hasDuration ? totalMs.toDouble() : 1,
            onChanged: widget.enabled && hasDuration
                ? (value) => setState(() => _dragValue = value)
                : null,
            onChangeEnd: widget.enabled && hasDuration
                ? (value) {
                    widget.onSeek(Duration(milliseconds: value.round()));
                    // Held until the next frame so the bar does not snap back
                    // to a stale position before the seek lands.
                    WidgetsBinding.instance.addPostFrameCallback((_) {
                      if (mounted) setState(() => _dragValue = null);
                    });
                  }
                : null,
          ),
        ),
        if (widget.showTimecodes)
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: AppSpacing.sm),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Text(Formatters.duration(displayed), style: AppTypography.timecode),
                Text(
                  hasDuration
                      ? (widget.showRemaining
                            ? '-${Formatters.duration(widget.duration - displayed)}'
                            : Formatters.duration(widget.duration))
                      : '--:--',
                  style: AppTypography.timecode,
                ),
              ],
            ),
          ),
        if (widget.previewNotice != null) ...[
          const SizedBox(height: AppSpacing.sm),
          Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              const AurixIcon(AurixGlyph.info, size: 13, color: AppColors.textTertiary),
              const SizedBox(width: AppSpacing.xs + 2),
              Flexible(
                child: Text(
                  widget.previewNotice!,
                  style: AppTypography.labelMedium.copyWith(
                    color: AppColors.textTertiary,
                    fontSize: 11,
                  ),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
            ],
          ),
        ],
      ],
    );
  }
}

/// Hairline progress bar drawn under the mini player.
///
/// Deliberately not a `LinearProgressIndicator`: this must not animate its own
/// indeterminate sweep, and it needs to sit flush with no padding.
class HairlineProgress extends StatelessWidget {
  const HairlineProgress({
    required this.progress,
    this.color,
    this.height = 2,
    super.key,
  });

  final double progress;
  final Color? color;
  final double height;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: height,
      child: LayoutBuilder(
        builder: (context, constraints) => Stack(
          children: [
            Container(color: AppColors.divider),
            AnimatedContainer(
              duration: const Duration(milliseconds: 220),
              curve: Curves.linear,
              width: constraints.maxWidth * progress.clamp(0.0, 1.0),
              color: color ?? context.palette.accent,
            ),
          ],
        ),
      ),
    );
  }
}
