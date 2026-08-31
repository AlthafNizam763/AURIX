import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/theme/app_dimens.dart';
import '../../../core/theme/app_typography.dart';
import '../../../core/theme/aurix_palette.dart';
import '../../../data/services/lyrics_service.dart';
import '../../../playback/player_controller.dart';
import '../../../shared/widgets/effects/glass_panel.dart';
import '../../../shared/widgets/icons/aurix_glyphs.dart';
import '../../../shared/widgets/icons/aurix_icon.dart';
import '../providers/lyrics_provider.dart';

/// The lyrics section on the Now Playing screen.
///
/// ## Why it is a strip rather than a panel
///
/// The player is a fixed column — top bar, artwork, title, scrubber, transport,
/// bottom bar — with two `Spacer`s absorbing whatever is left. A lyrics block
/// with a height of its own would have to come out of that budget, and on a
/// short viewport it takes the artwork with it. So this occupies *existing*
/// flexible space instead of adding any: it is dropped into the second
/// `Spacer`'s slot and shrinks to nothing when there is nothing to show. The
/// layout is identical to before on a track with no lyrics.
///
/// The full text lives one tap away in [LyricsSheet], where it has a whole
/// screen to use.
///
/// ## What rebuilds
///
/// Only [_SyncedStrip] watches the playback position, and only when the lyrics
/// are timestamped. The strip itself watches [currentLyricsProvider], which
/// changes on track change and on nothing else — so a plain-lyrics track costs
/// zero rebuilds per second, and a synced one repaints three lines.
class LyricsStrip extends ConsumerWidget {
  const LyricsStrip({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final lyrics = ref.watch(currentLyricsProvider);

    return lyrics.when(
      loading: () => const _StripFrame(child: _Muted('Loading lyrics…')),
      // A provider failure is not something to put in front of someone
      // listening to music. It reads the same as having no transcription,
      // because from here the two are the same thing.
      error: (_, _) => const _StripFrame(child: _Muted('Lyrics unavailable')),
      data: (data) {
        if (data == null) {
          return const _StripFrame(child: _Muted('Lyrics unavailable'));
        }
        if (data.isInstrumental) {
          return const _StripFrame(child: _Muted('Instrumental'));
        }
        return _StripFrame(
          onTap: () => LyricsSheet.show(context),
          child: data.isSynced
              ? _SyncedStrip(lyrics: data)
              : _PlainStrip(lyrics: data),
        );
      },
    );
  }
}

/// The tap target and the fade that keeps the strip from fighting the artwork.
class _StripFrame extends StatelessWidget {
  const _StripFrame({required this.child, this.onTap});

  final Widget child;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    return Semantics(
      button: onTap != null,
      label: onTap == null ? null : 'Lyrics. Tap to expand.',
      child: GestureDetector(
        onTap: onTap,
        behavior: HitTestBehavior.opaque,
        // The strip is handed whatever the player's flexible gap happens to be,
        // and on a short viewport that can be less than three lines of text.
        // `OverflowBox` lets the content keep its natural height, centred, and
        // `ClipRect` trims what does not fit — so a cramped screen shows fewer
        // lines instead of Flutter's overflow stripes. The fade below makes the
        // trim read as intentional.
        child: ClipRect(
          child: OverflowBox(
            minHeight: 0,
            maxHeight: double.infinity,
            alignment: Alignment.center,
            child: Padding(
              padding: const EdgeInsets.symmetric(vertical: AppSpacing.sm),
              // The strip sits directly over the blurred artwork, and text at
              // this size needs the edges softened or it reads as a caption
              // pasted onto the cover.
              child: ShaderMask(
                shaderCallback: (bounds) => const LinearGradient(
                  begin: Alignment.topCenter,
                  end: Alignment.bottomCenter,
                  colors: <Color>[
                    Color(0x00FFFFFF),
                    Color(0xFFFFFFFF),
                    Color(0xFFFFFFFF),
                    Color(0x00FFFFFF),
                  ],
                  stops: <double>[0, 0.22, 0.78, 1],
                ).createShader(bounds),
                blendMode: BlendMode.dstIn,
                child: child,
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _Muted extends StatelessWidget {
  const _Muted(this.text);

  final String text;

  @override
  Widget build(BuildContext context) {
    return Text(
      text,
      textAlign: TextAlign.center,
      style: AppTypography.labelMedium.copyWith(
        color: context.palette.textTertiary,
      ),
    );
  }
}

/// Three lines around the one being sung, the middle one lit.
///
/// The only widget in the player besides the scrubber that follows the position,
/// and it takes it from [playbackTimelineProvider] directly rather than from the
/// screen's state — so the backdrop above it does not rebuild for a lyric to
/// advance.
class _SyncedStrip extends ConsumerWidget {
  const _SyncedStrip({required this.lyrics});

  final Lyrics lyrics;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final position = ref.watch(playbackTimelineProvider).position;
    final index = lyrics.lineIndexAt(position);
    final palette = context.palette;

    String lineAt(int i) =>
        (i < 0 || i >= lyrics.lines.length) ? '' : lyrics.lines[i].text;

    // Before the first timestamp there is nothing to highlight, so the intro
    // shows the opening line waiting rather than an empty box.
    final active = index < 0 ? 0 : index;

    return Column(
      mainAxisSize: MainAxisSize.min,
      children: <Widget>[
        _Line(text: lineAt(active - 1), color: palette.textTertiary, size: 13),
        const SizedBox(height: AppSpacing.xxs),
        AnimatedDefaultTextStyle(
          duration: const Duration(milliseconds: 220),
          curve: Curves.easeOut,
          style: AppTypography.titleSmall.copyWith(
            color: index < 0 ? palette.textSecondary : palette.textPrimary,
            height: 1.3,
          ),
          child: Text(
            lineAt(active),
            textAlign: TextAlign.center,
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
          ),
        ),
        const SizedBox(height: AppSpacing.xxs),
        _Line(text: lineAt(active + 1), color: palette.textTertiary, size: 13),
      ],
    );
  }
}

/// Untimed lyrics: the opening lines, as a legible invitation to expand.
class _PlainStrip extends StatelessWidget {
  const _PlainStrip({required this.lyrics});

  final Lyrics lyrics;

  @override
  Widget build(BuildContext context) {
    final palette = context.palette;
    final preview = lyrics.lines
        .where((line) => !line.isBlank)
        .take(3)
        .toList(growable: false);

    return Column(
      mainAxisSize: MainAxisSize.min,
      children: <Widget>[
        for (final (i, line) in preview.indexed) ...<Widget>[
          if (i > 0) const SizedBox(height: AppSpacing.xxs),
          _Line(
            text: line.text,
            color: i == 0 ? palette.textSecondary : palette.textTertiary,
            size: i == 0 ? 15 : 13,
          ),
        ],
      ],
    );
  }
}

class _Line extends StatelessWidget {
  const _Line({required this.text, required this.color, required this.size});

  final String text;
  final Color color;
  final double size;

  @override
  Widget build(BuildContext context) {
    return Text(
      text,
      textAlign: TextAlign.center,
      maxLines: 1,
      overflow: TextOverflow.ellipsis,
      style: AppTypography.bodyMedium.copyWith(
        color: color,
        fontSize: size,
        height: 1.3,
      ),
    );
  }
}

/// The full lyric, over the player.
///
/// A sheet rather than a route: the player's artwork-derived backdrop stays
/// visible behind it, which is the whole reason the screen feels like it
/// belongs to the song. Pushing a page would replace that with a flat surface.
class LyricsSheet extends ConsumerStatefulWidget {
  const LyricsSheet({super.key});

  static Future<void> show(BuildContext context) => showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    backgroundColor: Colors.transparent,
    barrierColor: Colors.black.withValues(alpha: 0.35),
    builder: (_) => const LyricsSheet(),
  );

  @override
  ConsumerState<LyricsSheet> createState() => _LyricsSheetState();
}

class _LyricsSheetState extends ConsumerState<LyricsSheet> {
  /// Attached to the line currently being sung, so it can be scrolled to
  /// without knowing how tall any line rendered.
  ///
  /// Measuring by index would need a fixed row height, and lyric lines wrap to
  /// one, two or three rows unpredictably — an estimate drifts further down the
  /// song, which is exactly where accuracy matters most.
  final GlobalKey _activeLineKey = GlobalKey();

  int _lastScrolledTo = -1;
  bool _userScrolled = false;

  @override
  Widget build(BuildContext context) {
    final lyrics = ref.watch(currentLyricsProvider);
    final track = ref.watch(currentTrackProvider);

    return DraggableScrollableSheet(
      initialChildSize: 0.82,
      minChildSize: 0.5,
      maxChildSize: 0.95,
      expand: false,
      builder: (context, scrollController) => GlassPanel(
        blur: 32,
        strong: true,
        borderRadius: const BorderRadius.vertical(
          top: Radius.circular(AppRadius.xl),
        ),
        child: Column(
          children: <Widget>[
            const _SheetGrabHandle(),
            _SheetHeader(
              title: track?.name ?? 'Lyrics',
              subtitle: track?.artistNames,
            ),
            Expanded(
              child: lyrics.when(
                loading: () => const Center(child: _Muted('Loading lyrics…')),
                error: (_, _) => const Center(child: _Muted('Lyrics unavailable')),
                data: (data) => _body(data, scrollController),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _body(Lyrics? data, ScrollController controller) {
    if (data == null) {
      return const _SheetNotice(
        glyph: AurixGlyph.mic,
        headline: 'Lyrics unavailable',
        detail: 'No lyrics provider has this track. Nothing is guessed — '
            'AURIX shows the words it can source, or none at all.',
      );
    }
    if (data.isInstrumental) {
      return const _SheetNotice(
        glyph: AurixGlyph.musicNote,
        headline: 'Instrumental',
        detail: 'This track has no words.',
      );
    }
    return data.isSynced
        ? _SyncedList(
            lyrics: data,
            controller: controller,
            activeKey: _activeLineKey,
            onActiveChanged: _scrollToActive,
            onUserScroll: () => _userScrolled = true,
          )
        : _PlainList(lyrics: data, controller: controller);
  }

  /// Keeps the sung line in view, unless the reader has taken over.
  ///
  /// Scrolling by hand disables the follow for the rest of the sheet: fighting
  /// someone who is reading ahead is worse than not following at all.
  void _scrollToActive(int index) {
    if (_userScrolled || index == _lastScrolledTo) return;
    _lastScrolledTo = index;

    WidgetsBinding.instance.addPostFrameCallback((_) {
      final target = _activeLineKey.currentContext;
      if (target == null || !mounted) return;
      unawaited(
        Scrollable.ensureVisible(
          target,
          alignment: 0.4,
          duration: const Duration(milliseconds: 420),
          curve: Curves.easeOutCubic,
        ),
      );
    });
  }
}

class _SyncedList extends ConsumerWidget {
  const _SyncedList({
    required this.lyrics,
    required this.controller,
    required this.activeKey,
    required this.onActiveChanged,
    required this.onUserScroll,
  });

  final Lyrics lyrics;
  final ScrollController controller;
  final GlobalKey activeKey;
  final ValueChanged<int> onActiveChanged;
  final VoidCallback onUserScroll;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final position = ref.watch(playbackTimelineProvider).position;
    final active = lyrics.lineIndexAt(position);
    final palette = context.palette;

    onActiveChanged(active);

    return NotificationListener<UserScrollNotification>(
      onNotification: (_) {
        onUserScroll();
        return false;
      },
      child: ListView.builder(
        controller: controller,
        padding: const EdgeInsets.fromLTRB(
          AppSpacing.xxl,
          AppSpacing.md,
          AppSpacing.xxl,
          AppSpacing.huge,
        ),
        itemCount: lyrics.lines.length + 1,
        itemBuilder: (context, index) {
          if (index == lyrics.lines.length) {
            return _Attribution(provider: lyrics.provider);
          }

          final line = lyrics.lines[index];
          if (line.isBlank) return const SizedBox(height: AppSpacing.lg);

          final isActive = index == active;
          final isPast = index < active;

          return Padding(
            key: isActive ? activeKey : null,
            padding: const EdgeInsets.symmetric(vertical: AppSpacing.sm),
            child: GestureDetector(
              // Tapping a timestamped line seeks to it — the one genuinely
              // useful thing synced lyrics enable beyond reading along, and it
              // goes through the same seek path as the scrubber, so Spotify
              // moves and every other surface follows.
              onTap: line.at == null
                  ? null
                  : () => ref
                        .read(playerControllerProvider.notifier)
                        .seek(line.at!),
              behavior: HitTestBehavior.opaque,
              child: AnimatedDefaultTextStyle(
                duration: const Duration(milliseconds: 240),
                curve: Curves.easeOut,
                style: AppTypography.headlineSmall.copyWith(
                  height: 1.35,
                  color: isActive
                      ? palette.textPrimary
                      : isPast
                      ? palette.textTertiary
                      : palette.textSecondary,
                ),
                child: Text(line.text),
              ),
            ),
          );
        },
      ),
    );
  }
}

class _PlainList extends StatelessWidget {
  const _PlainList({required this.lyrics, required this.controller});

  final Lyrics lyrics;
  final ScrollController controller;

  @override
  Widget build(BuildContext context) {
    return ListView(
      controller: controller,
      padding: const EdgeInsets.fromLTRB(
        AppSpacing.xxl,
        AppSpacing.md,
        AppSpacing.xxl,
        AppSpacing.huge,
      ),
      children: <Widget>[
        SelectableText(
          lyrics.asText,
          style: AppTypography.bodyLarge.copyWith(
            height: 1.7,
            color: context.palette.textSecondary,
          ),
        ),
        const SizedBox(height: AppSpacing.xl),
        _Attribution(provider: lyrics.provider),
      ],
    );
  }
}

class _Attribution extends StatelessWidget {
  const _Attribution({required this.provider});

  final String provider;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(top: AppSpacing.xl),
      child: Text(
        'Lyrics by $provider',
        style: AppTypography.labelSmall.copyWith(
          color: context.palette.textTertiary,
        ),
      ),
    );
  }
}

class _SheetGrabHandle extends StatelessWidget {
  const _SheetGrabHandle();

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(top: AppSpacing.md, bottom: AppSpacing.sm),
      child: Container(
        width: 38,
        height: 4,
        decoration: BoxDecoration(
          color: context.palette.hairlineStrong,
          borderRadius: BorderRadius.circular(AppRadius.pill),
        ),
      ),
    );
  }
}

class _SheetHeader extends StatelessWidget {
  const _SheetHeader({required this.title, this.subtitle});

  final String title;
  final String? subtitle;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(
        AppSpacing.xxl,
        AppSpacing.sm,
        AppSpacing.md,
        AppSpacing.md,
      ),
      child: Row(
        children: <Widget>[
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                Text(
                  title,
                  style: AppTypography.titleMedium,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
                if (subtitle != null && subtitle!.isNotEmpty)
                  Text(
                    subtitle!,
                    style: AppTypography.labelMedium.copyWith(
                      color: context.palette.textSecondary,
                    ),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
              ],
            ),
          ),
          IconButton(
            onPressed: () => Navigator.of(context).maybePop(),
            icon: const AurixIcon(AurixGlyph.close, size: 22),
            tooltip: 'Close lyrics',
          ),
        ],
      ),
    );
  }
}

class _SheetNotice extends StatelessWidget {
  const _SheetNotice({
    required this.glyph,
    required this.headline,
    required this.detail,
  });

  final AurixGlyph glyph;
  final String headline;
  final String detail;

  @override
  Widget build(BuildContext context) {
    final palette = context.palette;

    return Center(
      child: Padding(
        padding: const EdgeInsets.all(AppSpacing.xxxl),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            AurixIcon(glyph, size: 40, color: palette.textTertiary),
            const SizedBox(height: AppSpacing.lg),
            Text(headline, style: AppTypography.headlineSmall),
            const SizedBox(height: AppSpacing.sm),
            Text(
              detail,
              style: AppTypography.bodyMedium.copyWith(
                color: palette.textSecondary,
              ),
              textAlign: TextAlign.center,
            ),
          ],
        ),
      ),
    );
  }
}
