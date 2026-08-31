import 'package:flutter/material.dart';

import '../../../core/constants/app_constants.dart';
import '../../../core/theme/app_dimens.dart';
import '../../../core/theme/app_typography.dart';
import '../../../core/theme/aurix_palette.dart';
import '../../../shared/widgets/controls/aurix_switch.dart';
import '../../../shared/widgets/icons/aurix_glyphs.dart';
import '../../../shared/widgets/icons/aurix_icon.dart';

/// Section heading between groups of settings.
class SettingsGroup extends StatelessWidget {
  const SettingsGroup({required this.title, super.key});

  final String title;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(
        AppSpacing.page,
        AppSpacing.xxl,
        AppSpacing.page,
        AppSpacing.sm,
      ),
      child: Text(title.toUpperCase(), style: AppTypography.overline),
    );
  }
}

/// A tappable settings row.
class SettingsTile extends StatelessWidget {
  const SettingsTile({
    required this.icon,
    required this.title,
    required this.onTap,
    this.subtitle,
    this.leading,
    this.trailing,
    this.destructive = false,
    super.key,
  });

  final AurixGlyph icon;
  final String title;
  final String? subtitle;
  final VoidCallback onTap;

  /// Replaces the leading glyph. For the rows whose subject has a picture of
  /// its own — the account row, which shows the user's AURIX avatar rather
  /// than a generic silhouette.
  final Widget? leading;

  final Widget? trailing;
  final bool destructive;

  @override
  Widget build(BuildContext context) {
    final color = destructive ? context.palette.attention : context.palette.textPrimary;

    return ListTile(
      onTap: onTap,
      leading: leading ??
          AurixIcon(icon, size: 22, color: destructive ? context.palette.attention : null),
      title: Text(title, style: AppTypography.bodyLarge.copyWith(color: color)),
      subtitle: subtitle == null
          ? null
          : Text(subtitle!, style: AppTypography.bodySmall),
      trailing: trailing ??
          AurixIcon(
            AurixGlyph.chevronRight,
            size: 20,
            color: context.palette.textTertiary,
          ),
    );
  }
}

/// A settings row with a switch.
class SettingsSwitch extends StatelessWidget {
  const SettingsSwitch({
    required this.icon,
    required this.title,
    required this.value,
    required this.onChanged,
    this.subtitle,
    this.enabled = true,
    super.key,
  });

  final AurixGlyph icon;
  final String title;
  final String? subtitle;
  final bool value;
  final ValueChanged<bool> onChanged;
  final bool enabled;

  @override
  Widget build(BuildContext context) {
    return SwitchListTile.adaptive(
      value: value,
      onChanged: enabled ? onChanged : null,
      secondary: AurixIcon(
        icon,
        size: 22,
        color: enabled ? null : context.palette.textTertiary,
      ),
      title: Text(
        title,
        style: AppTypography.bodyLarge.copyWith(
          color: enabled ? context.palette.textPrimary : context.palette.textTertiary,
        ),
      ),
      subtitle: subtitle == null
          ? null
          : Text(subtitle!, style: AppTypography.bodySmall),
      contentPadding: const EdgeInsets.symmetric(horizontal: AppSpacing.page),
      activeThumbColor: context.palette.textOnAccent,
      activeTrackColor: context.palette.accent,
    );
  }
}

/// A settings row carrying the brand's own switch, plus a literal ON/OFF read.
///
/// Reserved for the handful of preferences that change what the app *looks
/// like* while it is being changed — the switch is the preview. Everything
/// else stays on [SettingsSwitch], because a list where every row shouts is a
/// list with no hierarchy.
class SettingsBrandSwitch extends StatelessWidget {
  const SettingsBrandSwitch({
    required this.icon,
    required this.title,
    required this.value,
    required this.onChanged,
    this.subtitle,
    this.enabled = true,
    super.key,
  });

  final AurixGlyph icon;
  final String title;
  final String? subtitle;
  final bool value;
  final ValueChanged<bool> onChanged;
  final bool enabled;

  @override
  Widget build(BuildContext context) {
    final color = enabled ? context.palette.textPrimary : context.palette.textTertiary;

    return ListTile(
      onTap: enabled ? () => onChanged(!value) : null,
      contentPadding: const EdgeInsets.symmetric(horizontal: AppSpacing.page),
      leading: AurixIcon(
        icon,
        size: 22,
        // The row's icon lights with the setting, so the state reads from the
        // left edge as well as the right.
        emphasis: enabled && value,
        color: enabled ? null : context.palette.textTertiary,
      ),
      title: Text(title, style: AppTypography.bodyLarge.copyWith(color: color)),
      subtitle: subtitle == null
          ? null
          : Text(subtitle!, style: AppTypography.bodySmall),
      trailing: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          _StateLabel(value: value, enabled: enabled),
          const SizedBox(width: AppSpacing.xs),
          AurixSwitch(
            value: value,
            onChanged: onChanged,
            enabled: enabled,
            semanticLabel: title,
          ),
        ],
      ),
    );
  }
}

/// The `ON` / `OFF` word beside an [AurixSwitch].
///
/// This was always a redundancy for colour-blind users. In a palette with no
/// hue at all it stops being redundant and becomes the primary read: the switch
/// distinguishes its states by inversion and position, both of which are
/// spatial, and a spatial-only control is the one thing a low-vision user
/// genuinely cannot resolve. The word is now the accessible state.
class _StateLabel extends StatelessWidget {
  const _StateLabel({required this.value, required this.enabled});

  final bool value;
  final bool enabled;

  @override
  Widget build(BuildContext context) {
    final accent = context.palette.accent;

    return AnimatedSwitcher(
      duration: AppConstants.fast,
      child: Text(
        value ? 'ON' : 'OFF',
        key: ValueKey<bool>(value),
        style: AppTypography.labelSmall.copyWith(
          color: !enabled
              ? context.palette.textTertiary
              : (value ? accent : context.palette.textTertiary),
        ),
      ),
    );
  }
}

/// A settings row with a slider and a live value label.
class SettingsSlider extends StatelessWidget {
  const SettingsSlider({
    required this.icon,
    required this.title,
    required this.value,
    required this.max,
    required this.onChanged,
    required this.labelBuilder,
    this.min = 0,
    this.divisions,
    super.key,
  });

  final AurixGlyph icon;
  final String title;
  final double value;
  final double min;
  final double max;
  final int? divisions;
  final ValueChanged<double> onChanged;
  final String Function(double) labelBuilder;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(
        horizontal: AppSpacing.page,
        vertical: AppSpacing.sm,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              AurixIcon(icon, size: 22, color: context.palette.textSecondary),
              const SizedBox(width: AppSpacing.xxl - AppSpacing.xs),
              Expanded(child: Text(title, style: AppTypography.bodyLarge)),
              Text(labelBuilder(value), style: AppTypography.bodySmall),
            ],
          ),
          Slider(
            value: value.clamp(min, max),
            min: min,
            max: max,
            divisions: divisions,
            onChanged: onChanged,
            activeColor: context.palette.accent,
          ),
        ],
      ),
    );
  }
}

/// An explanatory footnote under a settings group.
///
/// Used wherever a control's real behaviour is narrower than its label
/// suggests — which, for an app built on someone else's API, is often.
class SettingsNote extends StatelessWidget {
  const SettingsNote({required this.text, super.key});

  final String text;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(
        AppSpacing.page,
        AppSpacing.sm,
        AppSpacing.page,
        AppSpacing.sm,
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.only(top: 2),
            child: AurixIcon(
              AurixGlyph.info,
              size: 14,
              color: context.palette.textTertiary,
            ),
          ),
          const SizedBox(width: AppSpacing.sm),
          Expanded(
            child: Text(
              text,
              style: AppTypography.bodySmall.copyWith(
                fontSize: 11.5,
                color: context.palette.textTertiary,
                height: 1.5,
              ),
            ),
          ),
        ],
      ),
    );
  }
}
