import 'package:flutter/material.dart';

import '../../../core/constants/app_constants.dart';
import '../../../core/theme/app_colors.dart';
import '../../../core/theme/app_dimens.dart';
import '../../../core/theme/app_typography.dart';
import '../../../core/theme/aurix_palette.dart';
import '../../../shared/widgets/icons/aurix_glyphs.dart';
import '../../../shared/widgets/icons/aurix_icon.dart';

/// The rounded search field.
///
/// Owns no query state — the controller is passed in and lives with the search
/// provider, so a query survives navigating to a result and back.
class AurixSearchBar extends StatefulWidget {
  const AurixSearchBar({
    required this.controller,
    required this.onChanged,
    this.onSubmitted,
    this.onClear,
    this.onVoiceSearch,
    this.focusNode,
    this.hintText = 'Songs, artists, albums or playlists',
    this.autofocus = false,
    this.readOnly = false,
    this.onTap,
    super.key,
  });

  final TextEditingController controller;
  final ValueChanged<String> onChanged;
  final ValueChanged<String>? onSubmitted;
  final VoidCallback? onClear;

  /// Null hides the microphone affordance entirely.
  ///
  /// AURIX ships the control but not a speech engine — tapping it explains
  /// that voice search is not wired up rather than silently doing nothing.
  final VoidCallback? onVoiceSearch;

  final FocusNode? focusNode;
  final String hintText;
  final bool autofocus;

  /// Renders as a tappable field that opens the real search screen — used for
  /// the search entry point on other tabs.
  final bool readOnly;

  final VoidCallback? onTap;

  @override
  State<AurixSearchBar> createState() => _AurixSearchBarState();
}

class _AurixSearchBarState extends State<AurixSearchBar> {
  late final FocusNode _focusNode = widget.focusNode ?? FocusNode();
  bool _ownsFocusNode = false;
  bool _hasFocus = false;

  @override
  void initState() {
    super.initState();
    _ownsFocusNode = widget.focusNode == null;
    _focusNode.addListener(_onFocusChanged);
    widget.controller.addListener(_onTextChanged);
  }

  void _onFocusChanged() {
    if (!mounted) return;
    setState(() => _hasFocus = _focusNode.hasFocus);
  }

  void _onTextChanged() {
    if (!mounted) return;
    // Rebuild only for the clear button appearing/disappearing.
    setState(() {});
  }

  @override
  void dispose() {
    _focusNode.removeListener(_onFocusChanged);
    widget.controller.removeListener(_onTextChanged);
    if (_ownsFocusNode) _focusNode.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final hasText = widget.controller.text.isNotEmpty;
    final accent = context.palette.accent;

    return AnimatedContainer(
      duration: AppConstants.fast,
      clipBehavior: Clip.antiAlias,
      decoration: BoxDecoration(
        color: AppColors.surfaceElevated,
        borderRadius: BorderRadius.circular(AppRadius.sm),
        border: Border.all(
          color: _hasFocus ? accent : Colors.transparent,
          width: 1.4,
        ),
        // The 1.4px ring is the entire focus signal. It used to be backed by a
        // bloom, which is exactly the move this palette cannot afford: a white
        // glow on a near-black field is the loudest thing the app can draw, and
        // spending it on a text field outranks the play button.
      ),
      child: TextField(
        controller: widget.controller,
        focusNode: _focusNode,
        autofocus: widget.autofocus,
        readOnly: widget.readOnly,
        onTap: widget.onTap,
        onChanged: widget.onChanged,
        onSubmitted: widget.onSubmitted,
        textInputAction: TextInputAction.search,
        textCapitalization: TextCapitalization.none,
        autocorrect: false,
        style: AppTypography.bodyLarge,
        cursorColor: accent,
        decoration: InputDecoration(
          hintText: widget.hintText,
          hintStyle: AppTypography.bodyMedium.copyWith(color: AppColors.textTertiary),
          filled: false,
          border: InputBorder.none,
          enabledBorder: InputBorder.none,
          focusedBorder: InputBorder.none,
          contentPadding: const EdgeInsets.symmetric(vertical: AppSpacing.md + 2),
          prefixIcon: const AurixIcon(AurixGlyph.search, size: 22),
          suffixIcon: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (hasText)
                IconButton(
                  onPressed: () {
                    widget.controller.clear();
                    widget.onChanged('');
                    widget.onClear?.call();
                  },
                  icon: const AurixIcon(AurixGlyph.close, size: 19),
                  tooltip: 'Clear',
                  visualDensity: VisualDensity.compact,
                )
              else if (widget.onVoiceSearch != null)
                IconButton(
                  onPressed: widget.onVoiceSearch,
                  icon: const AurixIcon(AurixGlyph.mic, size: 21),
                  tooltip: 'Voice search',
                  visualDensity: VisualDensity.compact,
                ),
              const SizedBox(width: AppSpacing.xs),
            ],
          ),
        ),
      ),
    );
  }
}

/// Horizontal row of filter chips (search categories, library filters).
class FilterChipRow<T> extends StatelessWidget {
  const FilterChipRow({
    required this.values,
    required this.selected,
    required this.labelOf,
    required this.onSelected,
    this.padding,
    this.allowDeselect = false,
    super.key,
  });

  final List<T> values;
  final T? selected;
  final String Function(T) labelOf;
  final ValueChanged<T?> onSelected;
  final EdgeInsetsGeometry? padding;

  /// Tapping the selected chip clears the filter — the behaviour a library
  /// filter wants, but not a search tab bar.
  final bool allowDeselect;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: 40,
      child: ListView.separated(
        scrollDirection: Axis.horizontal,
        padding: padding ?? const EdgeInsets.symmetric(horizontal: AppSpacing.page),
        itemCount: values.length,
        separatorBuilder: (_, _) => const SizedBox(width: AppSpacing.sm),
        itemBuilder: (context, index) {
          final value = values[index];
          final isSelected = value == selected;
          return ChoiceChip(
            label: Text(labelOf(value)),
            selected: isSelected,
            onSelected: (_) {
              if (isSelected && allowDeselect) {
                onSelected(null);
              } else {
                onSelected(value);
              }
            },
          );
        },
      ),
    );
  }
}
