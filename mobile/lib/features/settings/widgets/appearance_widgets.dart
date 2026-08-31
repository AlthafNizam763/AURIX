/// The controls the Appearance screen is built from.
///
/// Split out for the same reason the settings kit is: the screen should read as
/// a list of what an administrator can change, not as five hundred lines of
/// `Container`. Each widget here is dumb — it renders a value and reports a new
/// one — and none of them reaches for a provider, which is what makes them
/// testable on their own.
library;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../../core/theme/app_dimens.dart';
import '../../../core/theme/aurix_palette.dart';
import '../../../core/theme/theme_config.dart';
import '../../../core/theme/theme_presets.dart';
import '../../../data/services/api/api_theme_service.dart';
import '../../../shared/widgets/icons/aurix_glyphs.dart';
import '../../../shared/widgets/icons/aurix_icon.dart';

/// A heading between groups of controls, with room for a caption and a control.
class AppearanceGroup extends StatelessWidget {
  const AppearanceGroup({
    required this.title,
    this.caption,
    this.trailing,
    super.key,
  });

  final String title;
  final String? caption;
  final Widget? trailing;

  @override
  Widget build(BuildContext context) {
    final palette = context.palette;
    final text = Theme.of(context).textTheme;

    return Padding(
      padding: const EdgeInsets.fromLTRB(
        AppSpacing.page,
        AppSpacing.xxl,
        AppSpacing.page,
        AppSpacing.sm,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(
                  title.toUpperCase(),
                  style: text.labelSmall?.copyWith(
                    letterSpacing: 1.8,
                    color: palette.textTertiary,
                  ),
                ),
              ),
              ?trailing,
            ],
          ),
          if (caption != null) ...[
            const SizedBox(height: AppSpacing.xs),
            Text(
              caption!,
              style: text.bodySmall?.copyWith(color: palette.textSecondary),
            ),
          ],
        ],
      ),
    );
  }
}

/// Light / dark, for the colour pickers.
class BrightnessToggle extends StatelessWidget {
  const BrightnessToggle({
    required this.value,
    required this.onChanged,
    super.key,
  });

  final Brightness value;
  final ValueChanged<Brightness> onChanged;

  @override
  Widget build(BuildContext context) {
    final palette = context.palette;

    return SegmentedButton<Brightness>(
      segments: const <ButtonSegment<Brightness>>[
        ButtonSegment(value: Brightness.dark, label: Text('Dark')),
        ButtonSegment(value: Brightness.light, label: Text('Light')),
      ],
      selected: <Brightness>{value},
      showSelectedIcon: false,
      onSelectionChanged: (selection) => onChanged(selection.first),
      style: ButtonStyle(
        visualDensity: VisualDensity.compact,
        textStyle: WidgetStatePropertyAll(Theme.of(context).textTheme.labelMedium),
        side: WidgetStatePropertyAll(BorderSide(color: palette.hairline)),
      ),
    );
  }
}

/// The font-family picker.
///
/// Shows every family in the catalogue, including ones with no font file
/// uploaded — those are marked and disabled rather than hidden, so an
/// administrator can see the whole list and understand why one entry is not
/// selectable yet. Hiding them would make "where is Poppins?" unanswerable
/// from inside the app.
class FontPicker extends StatelessWidget {
  const FontPicker({
    required this.selected,
    required this.options,
    required this.onSelected,
    super.key,
  });

  final String selected;
  final List<FontOption> options;
  final ValueChanged<FontOption> onSelected;

  @override
  Widget build(BuildContext context) {
    final palette = context.palette;
    final text = Theme.of(context).textTheme;

    // A family set by an earlier admin that has since left the catalogue must
    // still appear as the current selection, or the next save would silently
    // change the font.
    final entries = <FontOption>[
      ...options,
      if (!options.any((font) => font.family == selected))
        FontOption(family: selected, bundled: false, available: true),
    ];

    return Column(
      children: [
        for (final font in entries)
          ListTile(
            enabled: font.available,
            onTap: font.available ? () => onSelected(font) : null,
            contentPadding: const EdgeInsets.symmetric(
              horizontal: AppSpacing.page,
            ),
            title: Text(
              font.family,
              // Rendered *in the face itself* where it is available, so the
              // picker shows what it is offering rather than naming it. A
              // family that is not registered falls through to the fallback,
              // which is exactly what selecting it would do.
              style: text.titleMedium?.copyWith(
                fontFamily: font.available ? font.family : null,
              ),
            ),
            subtitle: Text(
              font.bundled
                  ? 'Ships in the app. Always available, offline included.'
                  : font.available
                  ? 'Loaded from the server and cached on this device.'
                  : 'No font file uploaded yet — add one in the web console.',
              style: text.bodySmall?.copyWith(color: palette.textTertiary),
            ),
            trailing: font.family == selected
                ? AurixIcon(AurixGlyph.check, size: 20, color: palette.accent)
                : null,
          ),
      ],
    );
  }
}

/// A labelled slider with its value read out.
class AppearanceSlider extends StatelessWidget {
  const AppearanceSlider({
    required this.label,
    required this.value,
    required this.min,
    required this.max,
    required this.format,
    required this.onChanged,
    super.key,
  });

  final String label;
  final double value;
  final double min;
  final double max;
  final String Function(double) format;
  final ValueChanged<double> onChanged;

  @override
  Widget build(BuildContext context) {
    final palette = context.palette;
    final text = Theme.of(context).textTheme;

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
              Expanded(child: Text(label, style: text.titleSmall)),
              Text(
                format(value),
                style: text.bodySmall?.copyWith(
                  color: palette.textSecondary,
                  fontFeatures: const <FontFeature>[FontFeature.tabularFigures()],
                ),
              ),
            ],
          ),
          Slider(
            value: value.clamp(min, max),
            min: min,
            max: max,
            // Discrete steps rather than a continuous slider: every change
            // repaints the whole app, and a continuous drag would rebuild it
            // on every pixel of travel.
            divisions: ((max - min) * 20).round(),
            label: format(value),
            onChanged: onChanged,
          ),
        ],
      ),
    );
  }
}

/// The four weight steps, as steppers.
class WeightRow extends StatelessWidget {
  const WeightRow({required this.typography, required this.onChanged, super.key});

  final ThemeTypography typography;
  final ValueChanged<ThemeTypography> onChanged;

  @override
  Widget build(BuildContext context) {
    final entries = <(String, int, ThemeTypography Function(int))>[
      ('Body', typography.weightRegular, (v) => typography.copyWith(weightRegular: v)),
      ('Title', typography.weightMedium, (v) => typography.copyWith(weightMedium: v)),
      ('Heading', typography.weightBold, (v) => typography.copyWith(weightBold: v)),
      ('Display', typography.weightDisplay, (v) => typography.copyWith(weightDisplay: v)),
    ];

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: AppSpacing.page),
      child: Column(
        children: [
          for (final (label, value, apply) in entries)
            _WeightStepper(
              label: label,
              value: value,
              onChanged: (next) => onChanged(apply(next)),
            ),
        ],
      ),
    );
  }
}

class _WeightStepper extends StatelessWidget {
  const _WeightStepper({
    required this.label,
    required this.value,
    required this.onChanged,
  });

  final String label;
  final int value;
  final ValueChanged<int> onChanged;

  @override
  Widget build(BuildContext context) {
    final palette = context.palette;
    final text = Theme.of(context).textTheme;

    return Padding(
      padding: const EdgeInsets.symmetric(vertical: AppSpacing.xs),
      child: Row(
        children: [
          Expanded(
            child: Text(
              label,
              // Previewed at the weight it sets, which is the whole point of a
              // weight control: a number tells an administrator nothing.
              style: text.titleSmall?.copyWith(
                fontWeight: _nearest(value),
                fontVariations: <FontVariation>[
                  FontVariation('wght', value.toDouble()),
                ],
              ),
            ),
          ),
          IconButton(
            onPressed: value > 100 ? () => onChanged(value - 100) : null,
            icon: AurixIcon(
              AurixGlyph.close,
              size: 16,
              color: palette.textSecondary,
              semanticLabel: 'Lighter',
            ),
          ),
          SizedBox(
            width: 40,
            child: Text(
              '$value',
              textAlign: TextAlign.center,
              style: text.bodySmall?.copyWith(
                fontFeatures: const <FontFeature>[FontFeature.tabularFigures()],
              ),
            ),
          ),
          IconButton(
            onPressed: value < 900 ? () => onChanged(value + 100) : null,
            icon: AurixIcon(
              AurixGlyph.add,
              size: 16,
              color: palette.textSecondary,
              semanticLabel: 'Bolder',
            ),
          ),
        ],
      ),
    );
  }

  static FontWeight _nearest(int weight) =>
      FontWeight.values[((weight / 100).round() - 1).clamp(0, 8)];
}

/// One uploadable brand asset — the logo or the icon.
class AssetSlot extends StatelessWidget {
  const AssetSlot({
    required this.label,
    required this.preview,
    required this.isCustom,
    required this.onUpload,
    required this.onClear,
    super.key,
  });

  final String label;
  final Widget preview;
  final bool isCustom;
  final VoidCallback? onUpload;
  final VoidCallback? onClear;

  @override
  Widget build(BuildContext context) {
    final palette = context.palette;
    final text = Theme.of(context).textTheme;

    return Container(
      padding: const EdgeInsets.all(AppSpacing.md),
      decoration: BoxDecoration(
        color: palette.surfaceElevated,
        borderRadius: AppRadius.card,
        border: Border.all(color: palette.hairline),
      ),
      child: Column(
        children: [
          SizedBox(height: 56, child: Center(child: preview)),
          const SizedBox(height: AppSpacing.sm),
          Text(label, style: text.titleSmall),
          Text(
            isCustom ? 'Custom' : 'AURIX default',
            style: text.bodySmall?.copyWith(color: palette.textTertiary),
          ),
          const SizedBox(height: AppSpacing.sm),
          Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              TextButton(onPressed: onUpload, child: const Text('Upload')),
              if (isCustom)
                TextButton(
                  onPressed: onClear,
                  style: TextButton.styleFrom(foregroundColor: palette.attention),
                  child: const Text('Reset'),
                ),
            ],
          ),
        ],
      ),
    );
  }
}

/// The named colourways, above the eight individual pickers.
///
/// ## Why this sits above [ColorGrid] rather than replacing it
///
/// The two answer different questions. A preset answers "make it look like
/// that", which is what almost every deployment wants; the grid answers "make
/// `accent` exactly `#E50914`", which is what a deployment with a brand book
/// needs. Hiding the grid behind the preset would break the second case, and
/// hiding the presets would leave the first case mixing sixteen colours by
/// hand.
///
/// So they are stacked, and they operate on the same state: tapping a preset
/// writes into the pickers below, and moving a picker turns the selection into
/// [ThemePreset.custom]. Nothing is modal and nothing is hidden, which is what
/// makes the relationship between the two legible without a word of
/// explanation.
///
/// ## The Custom row
///
/// Rendered only when it is the current selection, and never tappable. "Custom"
/// is not a thing you can choose — it is what the app calls the colours you
/// already have when they match no preset — and offering it as a button would
/// raise the question of what tapping it does, which has no good answer.
class ThemePresetPicker extends StatelessWidget {
  const ThemePresetPicker({
    required this.selected,
    required this.onSelected,
    super.key,
  });

  /// The preset the current colours match, possibly [ThemePreset.custom].
  final ThemePreset selected;

  final ValueChanged<ThemePreset> onSelected;

  @override
  Widget build(BuildContext context) {
    final palette = context.palette;
    final text = Theme.of(context).textTheme;

    Widget row(ThemePreset preset, {required bool enabled}) {
      final isSelected = preset == selected;
      final dark = ThemePresets.dark(preset);
      final light = ThemePresets.light(preset);

      return ListTile(
        enabled: enabled,
        onTap: enabled ? () => onSelected(preset) : null,
        contentPadding: const EdgeInsets.symmetric(horizontal: AppSpacing.page),
        // The swatch is the control's whole point: a name like "Midnight"
        // means nothing until you can see it, and an admin should not have to
        // apply a preset to find out what it looks like.
        leading: dark == null || light == null
            ? _PresetSwatchPlaceholder(palette: palette)
            : _PresetSwatch(dark: dark, light: light),
        title: Text(preset.label, style: text.titleMedium),
        subtitle: Text(
          preset.description,
          style: text.bodySmall?.copyWith(color: palette.textTertiary),
        ),
        trailing: isSelected
            ? AurixIcon(AurixGlyph.check, size: 20, color: palette.accent)
            : null,
      );
    }

    return Column(
      children: [
        for (final preset in ThemePresets.selectable) row(preset, enabled: true),
        if (selected.isCustom) row(ThemePreset.custom, enabled: false),
      ],
    );
  }
}

/// A preset's dark and light colourways, side by side in one chip.
///
/// Both halves, because a preset writes both and showing only the one being
/// edited would hide half of what the tap is about to do. Each half stacks the
/// three colours that decide whether the theme reads as itself — the ground it
/// sits on, the accent, and the ink.
class _PresetSwatch extends StatelessWidget {
  const _PresetSwatch({required this.dark, required this.light});

  final ThemeColors dark;
  final ThemeColors light;

  @override
  Widget build(BuildContext context) {
    Widget half(ThemeColors colors, BorderRadius radius) => Container(
      width: 22,
      decoration: BoxDecoration(color: colors.background, borderRadius: radius),
      child: Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            _dot(colors.accent),
            const SizedBox(height: 3),
            _dot(colors.text),
          ],
        ),
      ),
    );

    return SizedBox.square(
      dimension: 44,
      child: ClipRRect(
        borderRadius: AppRadius.card,
        child: DecoratedBox(
          decoration: BoxDecoration(
            borderRadius: AppRadius.card,
            border: Border.all(color: context.palette.hairline),
          ),
          child: Row(
            children: [
              half(dark, const BorderRadius.horizontal(left: Radius.circular(8))),
              half(light, const BorderRadius.horizontal(right: Radius.circular(8))),
            ],
          ),
        ),
      ),
    );
  }

  static Widget _dot(Color color) => Container(
    width: 8,
    height: 8,
    decoration: BoxDecoration(color: color, shape: BoxShape.circle),
  );
}

/// The Custom row's swatch: an outline, because there is no fixed colour to show.
class _PresetSwatchPlaceholder extends StatelessWidget {
  const _PresetSwatchPlaceholder({required this.palette});

  final AurixPalette palette;

  @override
  Widget build(BuildContext context) => SizedBox.square(
    dimension: 44,
    child: DecoratedBox(
      decoration: BoxDecoration(
        borderRadius: AppRadius.card,
        border: Border.all(color: palette.hairline),
      ),
      child: Center(
        child: AurixIcon(AurixGlyph.palette, size: 18, color: palette.textTertiary),
      ),
    ),
  );
}

/// The eight colour roles, each with a swatch and a hex field.
class ColorGrid extends StatelessWidget {
  const ColorGrid({required this.colors, required this.onChanged, super.key});

  final ThemeColors colors;

  /// `(role, value)` — role names match the server's `COLOR_KEYS`.
  final void Function(String role, Color value) onChanged;

  /// What each role actually paints. Shown under its swatch, because "primary"
  /// and "accent" mean nothing on their own and an administrator picking blind
  /// is how a palette ends up unreadable.
  static const Map<String, String> _notes = <String, String>{
    'primary': 'Headings, active tabs, the brand mark',
    'secondary': 'Chips, dividers, the top surface layer',
    'accent': 'Play button, focus rings — the one thing to press',
    'background': 'The page itself',
    'surface': 'Cards, sheets, list rows',
    'text': 'Body and title text',
    'player': 'Mini player and full player background',
    'button': 'Filled button fill',
  };

  @override
  Widget build(BuildContext context) {
    final entries = <(String, Color)>[
      ('primary', colors.primary),
      ('secondary', colors.secondary),
      ('accent', colors.accent),
      ('background', colors.background),
      ('surface', colors.surface),
      ('text', colors.text),
      ('player', colors.player),
      ('button', colors.button),
    ];

    return Column(
      children: [
        for (final (role, value) in entries)
          _ColorRow(
            role: role,
            note: _notes[role] ?? '',
            value: value,
            onChanged: (next) => onChanged(role, next),
          ),
      ],
    );
  }
}

class _ColorRow extends StatelessWidget {
  const _ColorRow({
    required this.role,
    required this.note,
    required this.value,
    required this.onChanged,
  });

  final String role;
  final String note;
  final Color value;
  final ValueChanged<Color> onChanged;

  @override
  Widget build(BuildContext context) {
    final palette = context.palette;
    final text = Theme.of(context).textTheme;

    return ListTile(
      contentPadding: const EdgeInsets.symmetric(horizontal: AppSpacing.page),
      leading: Container(
        width: 40,
        height: 40,
        decoration: BoxDecoration(
          color: value,
          borderRadius: BorderRadius.circular(AppRadius.xs),
          border: Border.all(color: palette.hairlineStrong),
        ),
      ),
      title: Text(
        role[0].toUpperCase() + role.substring(1),
        style: text.titleSmall,
      ),
      subtitle: Text(
        note,
        style: text.bodySmall?.copyWith(color: palette.textTertiary),
      ),
      trailing: Text(
        ThemeColors.toHex(value),
        style: text.bodySmall?.copyWith(
          color: palette.textSecondary,
          fontFeatures: const <FontFeature>[FontFeature.tabularFigures()],
        ),
      ),
      onTap: () => _edit(context),
    );
  }

  /// A hex field rather than a colour wheel.
  ///
  /// Deliberate: an operator theming an app is working from a brand
  /// specification that gives hex values, and typing `#E50914` is both faster
  /// and more accurate than finding it on a wheel. It also keeps this screen
  /// free of a colour-picker dependency.
  Future<void> _edit(BuildContext context) async {
    final controller = TextEditingController(text: ThemeColors.toHex(value));

    final entered = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text('${role[0].toUpperCase()}${role.substring(1)} colour'),
        content: TextField(
          controller: controller,
          autofocus: true,
          textCapitalization: TextCapitalization.characters,
          decoration: const InputDecoration(
            hintText: '#RRGGBB',
            helperText: 'Also accepts #RGB and #AARRGGBB',
          ),
          inputFormatters: <TextInputFormatter>[
            FilteringTextInputFormatter.allow(RegExp(r'[#0-9a-fA-F]')),
            LengthLimitingTextInputFormatter(9),
          ],
          onSubmitted: (v) => Navigator.of(context).pop(v),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(controller.text),
            child: const Text('Apply'),
          ),
        ],
      ),
    );

    controller.dispose();
    if (entered == null) return;

    final parsed = ThemeColors.parseHex(entered);
    // A malformed value leaves the colour alone rather than defaulting it —
    // silently substituting black for a typo is how a theme gets wrecked.
    if (parsed != null) onChanged(parsed);
  }
}

/// Warns when body text on the page fails WCAG AA.
///
/// The one thing the palette derivation cannot fix for an administrator: it can
/// guarantee readable ink on a filled button, because it computes that, but a
/// background and a text colour that are both mid-grey are a decision, and the
/// only honest response is to say so before it ships to every user.
class ContrastNotice extends StatelessWidget {
  const ContrastNotice({required this.colors, super.key});

  final ThemeColors colors;

  @override
  Widget build(BuildContext context) {
    final ratio = AurixPalette.contrastRatio(colors.text, colors.background);
    if (ratio >= 4.5) return const SizedBox.shrink();

    final palette = context.palette;
    final text = Theme.of(context).textTheme;

    return Container(
      margin: const EdgeInsets.symmetric(
        horizontal: AppSpacing.page,
        vertical: AppSpacing.sm,
      ),
      padding: const EdgeInsets.all(AppSpacing.md),
      decoration: BoxDecoration(
        color: palette.surfaceHighest,
        borderRadius: AppRadius.card,
        border: Border.all(color: palette.attention.withValues(alpha: 0.5)),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          AurixIcon(AurixGlyph.warning, size: 18, color: palette.attention),
          const SizedBox(width: AppSpacing.sm),
          Expanded(
            child: Text(
              'Text on the background measures ${ratio.toStringAsFixed(1)}:1. '
              'WCAG AA asks for 4.5:1 at body size — this will be hard to read '
              'for some people. Darken the background or lighten the text.',
              style: text.bodySmall,
            ),
          ),
        ],
      ),
    );
  }
}

/// The three designs for one player surface.
class PlayerVariantPicker extends StatelessWidget {
  const PlayerVariantPicker({
    required this.surface,
    required this.selected,
    required this.onSelected,
    super.key,
  });

  final PlayerSurface surface;
  final PlayerVariant selected;
  final ValueChanged<PlayerVariant> onSelected;

  @override
  Widget build(BuildContext context) {
    final palette = context.palette;
    final text = Theme.of(context).textTheme;

    return Padding(
      padding: const EdgeInsets.fromLTRB(
        AppSpacing.page,
        AppSpacing.md,
        AppSpacing.page,
        0,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(surface.label, style: text.titleSmall),
          Text(
            surface.description,
            style: text.bodySmall?.copyWith(color: palette.textTertiary),
          ),
          const SizedBox(height: AppSpacing.sm),
          Row(
            children: [
              for (final variant in PlayerVariant.values) ...[
                Expanded(
                  child: _VariantChip(
                    variant: variant,
                    surface: surface,
                    isSelected: variant == selected,
                    onTap: () => onSelected(variant),
                  ),
                ),
                if (variant != PlayerVariant.values.last)
                  const SizedBox(width: AppSpacing.sm),
              ],
            ],
          ),
        ],
      ),
    );
  }
}

class _VariantChip extends StatelessWidget {
  const _VariantChip({
    required this.variant,
    required this.surface,
    required this.isSelected,
    required this.onTap,
  });

  final PlayerVariant variant;
  final PlayerSurface surface;
  final bool isSelected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final palette = context.palette;
    final text = Theme.of(context).textTheme;

    return Semantics(
      selected: isSelected,
      button: true,
      label: '${surface.label}, ${variant.label}',
      child: InkWell(
        onTap: onTap,
        borderRadius: AppRadius.card,
        child: Container(
          padding: const EdgeInsets.symmetric(vertical: AppSpacing.md),
          decoration: BoxDecoration(
            color: palette.surfaceElevated,
            borderRadius: AppRadius.card,
            border: Border.all(
              color: isSelected ? palette.accent : palette.hairline,
              width: isSelected ? 1.5 : 1,
            ),
          ),
          child: Column(
            // Stretch, so the glyph below is sized by the chip rather than by
            // a constant. With four variants across a 320dp phone each chip is
            // about 66dp wide, and a fixed 56dp glyph plus padding does not
            // fit — this is what keeps the row responsive as variants are
            // added rather than needing the constant retuned each time.
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              // A shape, not a screenshot. Four static previews per surface
              // would be sixteen images to keep in step with the code; a glyph
              // that shows the *silhouette* the variant produces is honest
              // about what changes and cannot go stale.
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: AppSpacing.xs),
                child: SizedBox(
                  height: 26,
                  child: CustomPaint(
                    painter: _VariantGlyphPainter(
                      variant: variant,
                      color: isSelected ? palette.accent : palette.textTertiary,
                    ),
                  ),
                ),
              ),
              const SizedBox(height: AppSpacing.xs),
              Text(
                variant.label,
                textAlign: TextAlign.center,
                // "Theme 4" at labelMedium is wider than a quarter of a small
                // phone. Clipped rather than wrapped: a chip that grows a
                // second line is a chip that misaligns with its three
                // neighbours.
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: text.labelMedium?.copyWith(
                  color: isSelected ? palette.textPrimary : palette.textTertiary,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Draws the silhouette each variant produces.
class _VariantGlyphPainter extends CustomPainter {
  const _VariantGlyphPainter({required this.variant, required this.color});

  final PlayerVariant variant;
  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    final stroke = Paint()
      ..color = color
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.4;
    final fill = Paint()..color = color;

    switch (variant) {
      // A slab with a small square cover at the leading edge.
      case PlayerVariant.theme1:
        final body = RRect.fromRectAndRadius(
          Rect.fromLTWH(1, size.height * 0.28, size.width - 2, size.height * 0.44),
          const Radius.circular(3),
        );
        canvas.drawRRect(body, stroke);
        canvas.drawRRect(
          RRect.fromRectAndRadius(
            Rect.fromLTWH(4, size.height * 0.34, 8, 8),
            const Radius.circular(1.5),
          ),
          fill,
        );

      // A pill with a round cover.
      case PlayerVariant.theme2:
        final body = RRect.fromRectAndRadius(
          Rect.fromLTWH(1, size.height * 0.28, size.width - 2, size.height * 0.44),
          Radius.circular(size.height * 0.22),
        );
        canvas.drawRRect(body, stroke);
        canvas.drawCircle(Offset(9, size.height * 0.5), 4, fill);

      // A tall card, artwork-led.
      case PlayerVariant.theme3:
        final body = RRect.fromRectAndRadius(
          Rect.fromLTWH(size.width * 0.22, 1, size.width * 0.56, size.height - 2),
          const Radius.circular(3),
        );
        canvas.drawRRect(body, stroke);
        canvas.drawRRect(
          RRect.fromRectAndRadius(
            Rect.fromLTWH(size.width * 0.28, 4, size.width * 0.44, 9),
            const Radius.circular(1.5),
          ),
          fill,
        );

      // A squared bar, no cover tint — the quiet one. Drawn as a plain
      // rectangle with a hairline divider so it reads as the flattest of the
      // four at a glance.
      case PlayerVariant.theme4:
        final body = RRect.fromRectAndRadius(
          Rect.fromLTWH(1, size.height * 0.3, size.width - 2, size.height * 0.4),
          const Radius.circular(1.5),
        );
        canvas.drawRRect(body, stroke);
        canvas.drawRect(
          Rect.fromLTWH(4, size.height * 0.5 - 1, size.width * 0.3, 2),
          fill,
        );
    }
  }

  @override
  bool shouldRepaint(_VariantGlyphPainter old) =>
      old.variant != variant || old.color != color;
}
