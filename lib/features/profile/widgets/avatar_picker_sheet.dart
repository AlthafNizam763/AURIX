import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/constants/app_constants.dart';
import '../../../core/theme/app_dimens.dart';
import '../../../core/theme/app_typography.dart';
import '../../../core/theme/aurix_palette.dart';
import '../../../core/utils/responsive.dart';
import '../../../data/models/avatar.dart';
import '../../../shared/widgets/icons/aurix_glyphs.dart';
import '../../../shared/widgets/icons/aurix_icon.dart';
import '../../../shared/widgets/media/aurix_avatar.dart';
import '../../settings/providers/settings_provider.dart';
import '../providers/profile_provider.dart';

/// The "Choose Avatar" sheet.
///
/// This is the *entire* profile-picture affordance in AURIX. There is no
/// gallery option, no camera option, no file picker, no URL field and no
/// hidden fallback for any of them — the grid below is the complete set of
/// pictures a profile can have, and it ships in the app bundle.
///
/// Two consequences worth stating where the UI lives:
///
///  * **It never asks for a permission.** Nothing here can read the photo
///    library, the camera or the filesystem, so there is no permission to
///    request and none is declared for this feature on any platform.
///  * **It never waits.** Opening the sheet, choosing a face and seeing it
///    applied are all local operations against bundled assets and a preference
///    write. The flow is identical with the network off.
///
/// ## Not a file picker
///
/// The design brief for this screen was that it must not look like one, and
/// that is a real distinction rather than a stylistic one: a file picker
/// presents *your* content and asks you to find something in it, so it is a
/// list with names and dates. This presents a *curated set* and asks you to
/// pick a favourite, so it is a grid of the things themselves at a size you can
/// actually judge, with the current choice ringed and named.
class AvatarPickerSheet extends ConsumerWidget {
  const AvatarPickerSheet({super.key});

  /// Presents the sheet and returns once it is dismissed.
  ///
  /// Selections apply as they are made, so there is nothing to return: by the
  /// time this future completes the choice is already saved and every avatar on
  /// screen behind the sheet has already changed.
  static Future<void> show(BuildContext context) => showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    useSafeArea: true,
    // The sheet is a decision surface, not a destination — dimming further than
    // the default keeps the faces the only lit thing on screen.
    barrierColor: Colors.black.withValues(alpha: 0.62),
    builder: (_) => const AvatarPickerSheet(),
  );

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final selectedId = ref.watch(
      profileProvider.select((state) => state.selectedAvatarId),
    );
    final reduceMotion = ref.watch(reduceMotionProvider);
    final palette = context.palette;

    // Three across on a phone: at four, a 12-avatar set stops reading as a
    // considered collection and starts reading as a sheet of stickers.
    final columns = context.responsive(compact: 3, medium: 4, expanded: 6);

    return SafeArea(
      top: false,
      child: ConstrainedBox(
        constraints: BoxConstraints(maxHeight: context.screenHeight * 0.85),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(
                AppSpacing.page,
                AppSpacing.xs,
                AppSpacing.page,
                AppSpacing.lg,
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  const Text(
                    'Choose Avatar',
                    style: AppTypography.headlineSmall,
                  ),
                  const SizedBox(height: AppSpacing.xs),
                  Text(
                    'AURIX profile pictures come from this set. '
                    'Nothing is uploaded from your device.',
                    style: AppTypography.bodySmall.copyWith(height: 1.45),
                  ),
                ],
              ),
            ),

            Flexible(
              child: LayoutBuilder(
                builder: (context, constraints) {
                  const gap = AppSpacing.lg;
                  final gutter = context.pageGutter;
                  final tile =
                      (constraints.maxWidth - (gutter * 2) - (gap * (columns - 1))) /
                          columns;

                  return GridView.builder(
                    padding: EdgeInsets.fromLTRB(gutter, 0, gutter, AppSpacing.lg),
                    physics: const BouncingScrollPhysics(
                      parent: AlwaysScrollableScrollPhysics(),
                    ),
                    shrinkWrap: true,
                    gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
                      crossAxisCount: columns,
                      crossAxisSpacing: gap,
                      mainAxisSpacing: AppSpacing.lg,
                      // The tile is the avatar plus its name underneath.
                      childAspectRatio: tile / (tile + _AvatarTile.labelHeight),
                    ),
                    itemCount: AvatarCatalog.all.length,
                    itemBuilder: (context, index) {
                      final avatar = AvatarCatalog.all[index];
                      return _AvatarTile(
                        avatar: avatar,
                        extent: tile,
                        position: index + 1,
                        total: AvatarCatalog.all.length,
                        selected: avatar.id == selectedId,
                        reduceMotion: reduceMotion,
                        onTap: () => _select(context, ref, avatar),
                      );
                    },
                  );
                },
              ),
            ),

            Padding(
              padding: EdgeInsets.fromLTRB(
                context.pageGutter,
                AppSpacing.sm,
                context.pageGutter,
                AppSpacing.lg,
              ),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Divider(height: 1, color: palette.hairline),
                  const SizedBox(height: AppSpacing.lg),
                  FilledButton(
                    onPressed: () => Navigator.of(context).pop(),
                    child: const Text('Done'),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  void _select(BuildContext context, WidgetRef ref, Avatar avatar) {
    // Selection feedback, not confirmation feedback: the choice is already
    // applied by the time the finger lifts, and a picker that changes something
    // visible under your thumb should say so through the hardware as well as
    // through the ring.
    unawaited(HapticFeedback.selectionClick());
    ref.read(profileProvider.notifier).selectAvatar(avatar.id);
  }
}

/// One avatar in the grid.
///
/// Selection is signalled three ways — a ring, a check badge and a step up in
/// scale — because any one of them alone fails somewhere. The ring is the
/// primary read but is a *colour* difference at the tile's edge, which is
/// exactly what a low-vision user resolves worst; the badge is a shape, which
/// survives that; and the scale carries the state even in a screenshot with the
/// badge cropped. The same reasoning as the ON/OFF label beside `AurixSwitch`.
class _AvatarTile extends StatefulWidget {
  const _AvatarTile({
    required this.avatar,
    required this.extent,
    required this.position,
    required this.total,
    required this.selected,
    required this.reduceMotion,
    required this.onTap,
  });

  final Avatar avatar;

  /// Width of the tile's square avatar area.
  final double extent;

  final int position;
  final int total;
  final bool selected;
  final bool reduceMotion;
  final VoidCallback onTap;

  /// Room under the avatar for its name.
  static const double labelHeight = 22;

  /// Ring geometry. The selected ring is thick enough to read at three-up on a
  /// small phone; the resting one is a hairline whose real job is to keep the
  /// pale avatars in the set from dissolving into a light-theme sheet.
  static const double _selectedRing = 2.5;
  static const double _restingRing = 1;
  static const double _ringGap = 4;

  @override
  State<_AvatarTile> createState() => _AvatarTileState();
}

class _AvatarTileState extends State<_AvatarTile> {
  bool _pressed = false;

  @override
  Widget build(BuildContext context) {
    final palette = context.palette;
    final duration = widget.reduceMotion ? Duration.zero : AppConstants.fast;

    // Sized for the *thickest* ring so the image never has to resize when the
    // ring does — the ring animates, the face stays exactly where it was.
    final imageSize = (widget.extent -
            (2 * (_AvatarTile._selectedRing + _AvatarTile._ringGap)))
        .clamp(24.0, double.infinity);

    final badge = (widget.extent * 0.30).clamp(18.0, 26.0);

    return Semantics(
      button: true,
      selected: widget.selected,
      label: '${widget.avatar.name} avatar, '
          '${widget.position} of ${widget.total}',
      excludeSemantics: true,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: widget.onTap,
        onTapDown: (_) => _setPressed(true),
        onTapUp: (_) => _setPressed(false),
        onTapCancel: () => _setPressed(false),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            AnimatedScale(
              // Resting tiles sit fractionally back so the chosen one steps
              // forward, rather than the chosen one inflating out of the grid.
              scale: (widget.selected ? 1.0 : 0.94) * (_pressed ? 0.94 : 1.0),
              duration: duration,
              curve: Curves.easeOutCubic,
              child: SizedBox(
                width: widget.extent,
                height: widget.extent,
                child: Stack(
                  alignment: Alignment.center,
                  children: [
                    AnimatedContainer(
                      duration: duration,
                      curve: Curves.easeOut,
                      // Sized to the tile rather than to its child, so the ring
                      // sits on the tile's edge and the badge below can be
                      // placed against a radius that does not move.
                      width: widget.extent,
                      height: widget.extent,
                      decoration: BoxDecoration(
                        shape: BoxShape.circle,
                        border: Border.all(
                          color: widget.selected
                              ? palette.accent
                              : palette.hairlineStrong,
                          width: widget.selected
                              ? _AvatarTile._selectedRing
                              : _AvatarTile._restingRing,
                        ),
                        boxShadow: widget.selected
                            ? [
                                BoxShadow(
                                  color: palette.glow(0.22),
                                  blurRadius: 14,
                                  spreadRadius: 1,
                                ),
                              ]
                            : null,
                      ),
                      alignment: Alignment.center,
                      child: AurixAvatar(
                        avatar: widget.avatar,
                        size: imageSize,
                      ),
                    ),
                    Positioned(
                      // Inset off the square's corner so the badge lands on the
                      // circle's lower-right rim at roughly 45°, half over the
                      // avatar. Flush to the corner it would float in the
                      // whitespace outside the circle entirely.
                      right: widget.extent * 0.04,
                      bottom: widget.extent * 0.04,
                      child: AnimatedScale(
                        scale: widget.selected ? 1 : 0,
                        duration: duration,
                        curve: Curves.easeOutBack,
                        child: Container(
                          width: badge,
                          height: badge,
                          decoration: BoxDecoration(
                            color: palette.accent,
                            shape: BoxShape.circle,
                            // Rings in the sheet's own surface colour so the
                            // badge separates from whatever avatar is behind
                            // it — several of them are near-white.
                            border: Border.all(
                              color: palette.surfaceElevated,
                              width: 2,
                            ),
                          ),
                          alignment: Alignment.center,
                          child: AurixIcon(
                            AurixGlyph.check,
                            size: badge * 0.58,
                            color: palette.textOnAccent,
                          ),
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
            SizedBox(
              height: _AvatarTile.labelHeight,
              child: Align(
                alignment: Alignment.center,
                child: AnimatedDefaultTextStyle(
                  duration: duration,
                  style: AppTypography.labelSmall.copyWith(
                    color: widget.selected
                        ? palette.textPrimary
                        : palette.textTertiary,
                    fontWeight:
                        widget.selected ? FontWeight.w700 : FontWeight.w500,
                  ),
                  child: Text(
                    widget.avatar.name,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  void _setPressed(bool value) {
    if (_pressed == value) return;
    setState(() => _pressed = value);
  }
}
