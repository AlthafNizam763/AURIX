import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:image_picker/image_picker.dart';

import '../../core/config/env.dart';
import '../../core/theme/app_dimens.dart';
import '../../core/theme/aurix_palette.dart';
import '../../core/theme/theme_config.dart';
import '../../core/theme/theme_controller.dart';
import '../../core/theme/theme_presets.dart';
import '../../core/utils/app_logger.dart';
import '../../data/services/api/api_theme_service.dart';
import '../../shared/widgets/brand/aurix_logo.dart';
import '../../shared/widgets/feedback/app_snackbar.dart';
import '../../shared/widgets/icons/aurix_glyphs.dart';
import '../../shared/widgets/icons/aurix_icon.dart';
import 'widgets/appearance_widgets.dart';

/// The in-app half of the appearance console.
///
/// ## Who sees it
///
/// Administrators only, and the gate is on the *route* rather than on the
/// screen — see `app_router.dart`. Doing it there means a deep link to
/// `/settings/appearance` from a non-admin account lands on Settings rather
/// than on a screen full of controls that will all be refused. The API refuses
/// every write here regardless of what the client believes, so this gate is
/// about not offering something that cannot work.
///
/// ## What it changes, and when
///
/// Every control edits a working copy and calls
/// [ThemeController.preview], so the app repaints under the admin's finger —
/// the screen they are looking at *is* the preview. Nothing is persisted until
/// **Save**, and **Discard** re-fetches from the server, which is what makes
/// experimenting safe.
///
/// ## What is deliberately not here
///
/// Font *file* upload. Choosing a family is here; supplying a TTF for it is on
/// the web panel at `/admin/`, because picking arbitrary files out of a phone's
/// storage is a worse experience than a drag-and-drop on a desktop and would
/// add a heavyweight file-picker plugin for a once-a-deployment task. The
/// screen says so rather than leaving an admin looking for the control.
class AppearanceScreen extends ConsumerStatefulWidget {
  const AppearanceScreen({super.key});

  @override
  ConsumerState<AppearanceScreen> createState() => _AppearanceScreenState();
}

class _AppearanceScreenState extends ConsumerState<AppearanceScreen> {
  /// Which colourway the pickers are editing. Both are stored and both ship.
  Brightness _editing = Brightness.dark;

  /// The font catalogue, fetched once. Null while loading.
  ThemeOptions? _options;

  bool _busy = false;

  /// True once anything has been previewed but not saved.
  bool _dirty = false;

  @override
  void initState() {
    super.initState();
    // After the first frame: reading a provider in `initState` is a lifecycle
    // error, and this is not on the critical path — the screen is fully usable
    // with the fallback catalogue until it lands.
    WidgetsBinding.instance.addPostFrameCallback((_) => _loadOptions());
  }

  Future<void> _loadOptions() async {
    final options = await ref.read(themeServiceProvider).options();
    if (mounted) setState(() => _options = options);
  }

  ThemeConfig get _config => ref.read(themeControllerProvider).config;

  /// Applies a change to the working copy, live, without saving it.
  void _preview(ThemeConfig next) {
    setState(() => _dirty = true);
    ref.read(themeControllerProvider.notifier).preview(next);
  }

  Future<void> _save() async {
    setState(() => _busy = true);
    final ok = await ref.read(themeControllerProvider.notifier).save(_config);
    if (!mounted) return;

    setState(() {
      _busy = false;
      if (ok) _dirty = false;
    });

    if (ok) {
      AppSnackbar.success(context, 'Saved. Every device picks this up on its next launch.');
    } else {
      AppSnackbar.error(
        context,
        ref.read(themeControllerProvider).error ?? 'That change was refused.',
      );
    }
  }

  Future<void> _discard() async {
    setState(() => _busy = true);
    await ref.read(themeControllerProvider.notifier).refresh();
    if (!mounted) return;
    setState(() {
      _busy = false;
      _dirty = false;
    });
  }

  Future<void> _resetToDefault() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Reset appearance?'),
        content: const Text(
          'This restores the colours, type and player designs AURIX ships '
          'with, for everyone. Uploaded logos stay available.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('Reset'),
          ),
        ],
      ),
    );

    if (confirmed != true || !mounted) return;

    setState(() => _busy = true);
    final ok = await ref.read(themeControllerProvider.notifier).reset();
    if (!mounted) return;
    setState(() {
      _busy = false;
      _dirty = false;
    });
    if (ok) AppSnackbar.success(context, 'Appearance reset to the AURIX default.');
  }

  /// Picks an image and uploads it as the logo.
  ///
  /// The picker returns a path; the bytes are read here rather than streamed,
  /// because the server caps a logo at 2MB and a whole file that size is
  /// nothing to hold briefly. The server validates the *bytes* — a `.png`
  /// extension proves nothing — and rejects anything that is not a real image.
  Future<void> _pickLogo({required bool asIcon}) async {
    try {
      final picked = await ImagePicker().pickImage(
        source: ImageSource.gallery,
        // Generous: the server's own cap is what actually decides, and
        // downscaling here would hand it a worse image than the admin chose.
        maxWidth: 2048,
        maxHeight: 2048,
      );
      if (picked == null || !mounted) return;

      setState(() => _busy = true);
      final bytes = await picked.readAsBytes();
      final controller = ref.read(themeControllerProvider.notifier);

      final ok = asIcon
          ? await controller.uploadIcon(bytes, filename: picked.name)
          : await controller.uploadLogo(bytes, filename: picked.name);

      if (!mounted) return;
      setState(() => _busy = false);

      if (ok) {
        AppSnackbar.success(context, asIcon ? 'App icon updated.' : 'Logo updated.');
      } else {
        AppSnackbar.error(
          context,
          ref.read(themeControllerProvider).error ?? 'That image was refused.',
        );
      }
    } on Object catch (error) {
      AppLogger.warn('Could not pick an image', scope: 'theme', error: error);
      if (!mounted) return;
      setState(() => _busy = false);
      AppSnackbar.error(context, 'Could not open the photo library.');
    }
  }

  Future<void> _clearLogo({required bool asIcon}) async {
    setState(() => _busy = true);
    final controller = ref.read(themeControllerProvider.notifier);
    final ok = asIcon ? await controller.clearIcon() : await controller.clearLogo();
    if (!mounted) return;
    setState(() => _busy = false);
    if (ok) AppSnackbar.success(context, 'Reset to the AURIX mark.');
  }

  @override
  Widget build(BuildContext context) {
    final theme = ref.watch(themeControllerProvider);
    final config = theme.config;
    final palette = context.palette;
    final colors = config.colorsFor(_editing);

    return PopScope(
      // Unsaved edits are live on screen but not on the server. Leaving without
      // saving would silently revert them at the next refresh, so the exit is
      // guarded rather than the edits being auto-saved — an accidental colour
      // change should not repaint the app for every user.
      canPop: !_dirty,
      onPopInvokedWithResult: (didPop, _) async {
        if (didPop || !_dirty) return;

        // Captured before the gap. `Navigator.of(context)` after two awaits is
        // a lookup on a context that may no longer be in the tree, and the
        // `mounted` checks below guard the *State*, not this context.
        final navigator = Navigator.of(context);

        final leave = await _confirmDiscard();
        if (leave != true || !mounted) return;

        await _discard();
        if (mounted) navigator.pop();
      },
      child: Scaffold(
        appBar: AppBar(
          title: const Text('Appearance'),
          actions: [
            if (_busy)
              const Padding(
                padding: EdgeInsets.only(right: AppSpacing.lg),
                child: Center(
                  child: SizedBox.square(
                    dimension: 18,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  ),
                ),
              )
            else ...[
              if (_dirty)
                TextButton(onPressed: _discard, child: const Text('Discard')),
              TextButton(
                onPressed: _dirty ? _save : null,
                child: const Text('Save'),
              ),
            ],
          ],
        ),
        body: ListView(
          padding: const EdgeInsets.only(bottom: AppSpacing.huge),
          children: [
            _VersionBanner(version: config.version, dirty: _dirty),

            // ---- Typography ---------------------------------------------
            const AppearanceGroup(
              title: 'Typography',
              caption: 'The face and weight the whole app is set in.',
            ),
            FontPicker(
              selected: config.fontFamily,
              options: _options?.fonts ?? ThemeOptions.fallback.fonts,
              onSelected: (font) => _preview(
                config.copyWith(fontFamily: font.family, fontAssetId: font.assetId),
              ),
            ),
            AppearanceSlider(
              label: 'Type scale',
              value: config.typography.scale,
              min: 0.8,
              max: 1.4,
              format: (v) => '${v.toStringAsFixed(2)}×',
              onChanged: (v) => _preview(
                config.copyWith(typography: config.typography.copyWith(scale: v)),
              ),
            ),
            AppearanceSlider(
              label: 'Letter spacing',
              value: config.typography.letterSpacing,
              min: -1,
              max: 2,
              format: (v) => '${v.toStringAsFixed(2)} px',
              onChanged: (v) => _preview(
                config.copyWith(
                  typography: config.typography.copyWith(letterSpacing: v),
                ),
              ),
            ),
            WeightRow(
              typography: config.typography,
              onChanged: (t) => _preview(config.copyWith(typography: t)),
            ),

            // ---- Branding ------------------------------------------------
            const AppearanceGroup(
              title: 'Logo & icon',
              caption:
                  'PNG, JPEG, WebP or GIF, up to 2 MB. With none set, AURIX '
                  'draws its own mark — that fallback is always available.',
            ),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: AppSpacing.page),
              child: Row(
                children: [
                  Expanded(
                    child: AssetSlot(
                      label: 'App logo',
                      preview: const AurixLogo(size: 48),
                      isCustom: config.appLogo != null,
                      onUpload: _busy ? null : () => _pickLogo(asIcon: false),
                      onClear: _busy || config.appLogo == null
                          ? null
                          : () => _clearLogo(asIcon: false),
                    ),
                  ),
                  const SizedBox(width: AppSpacing.md),
                  Expanded(
                    child: AssetSlot(
                      label: 'App icon',
                      preview: AurixIcon(
                        AurixGlyph.musicNote,
                        size: 40,
                        color: palette.textSecondary,
                      ),
                      isCustom: config.appIcon != null,
                      onUpload: _busy ? null : () => _pickLogo(asIcon: true),
                      onClear: _busy || config.appIcon == null
                          ? null
                          : () => _clearLogo(asIcon: true),
                    ),
                  ),
                ],
              ),
            ),

            // ---- Colour ---------------------------------------------------
            AppearanceGroup(
              title: 'Colour theme',
              caption:
                  'Both colourways are stored. AURIX follows the device '
                  'setting unless the user has chosen one, so leaving light '
                  'unstyled would show white text on white.',
              trailing: BrightnessToggle(
                value: _editing,
                onChanged: (b) => setState(() => _editing = b),
              ),
            ),
            ThemePresetPicker(
              // Derived from the colours themselves, so it stays correct
              // however they were set — by a picker below, by the web console,
              // or by a config restored from a backup. See [ThemePresets].
              selected: ThemePresets.matching(config),
              onSelected: (preset) => _preview(ThemePresets.apply(config, preset)),
            ),
            const _CustomColourHeading(),
            ColorGrid(
              colors: colors,
              onChanged: (role, value) => _preview(
                config.copyWith(
                  dark: _editing == Brightness.dark
                      ? _withRole(colors, role, value)
                      : null,
                  light: _editing == Brightness.light
                      ? _withRole(colors, role, value)
                      : null,
                ),
              ),
            ),
            ContrastNotice(colors: colors),

            // ---- Player ---------------------------------------------------
            const AppearanceGroup(
              title: 'Music player theme',
              caption:
                  'Each player surface picks its own design, independently of '
                  'the app theme. Every variant uses the colours above.',
            ),
            for (final surface in PlayerSurface.values)
              PlayerVariantPicker(
                surface: surface,
                selected: config.musicPlayer.forSurface(surface),
                onSelected: (variant) => _preview(
                  config.copyWith(
                    musicPlayer: config.musicPlayer.withSurface(surface, variant),
                  ),
                ),
              ),

            // ---- The rest -------------------------------------------------
            const AppearanceGroup(title: 'More'),
            const WebPanelNote(),
            Padding(
              padding: const EdgeInsets.all(AppSpacing.page),
              child: OutlinedButton(
                onPressed: _busy ? null : _resetToDefault,
                child: const Text('Reset to the AURIX default'),
              ),
            ),
          ],
        ),
      ),
    );
  }

  ThemeColors _withRole(ThemeColors colors, String role, Color value) =>
      switch (role) {
        'primary' => _copy(colors, primary: value),
        'secondary' => _copy(colors, secondary: value),
        'accent' => _copy(colors, accent: value),
        'background' => _copy(colors, background: value),
        'surface' => _copy(colors, surface: value),
        'text' => _copy(colors, text: value),
        'player' => _copy(colors, player: value),
        'button' => _copy(colors, button: value),
        _ => colors,
      };

  /// [ThemeColors] has no `copyWith` on purpose — the eight roles are always
  /// written together by the server — so this is the one place that builds a
  /// partial update, for the pickers.
  ThemeColors _copy(
    ThemeColors c, {
    Color? primary,
    Color? secondary,
    Color? accent,
    Color? background,
    Color? surface,
    Color? text,
    Color? player,
    Color? button,
  }) => ThemeColors(
    primary: primary ?? c.primary,
    secondary: secondary ?? c.secondary,
    accent: accent ?? c.accent,
    background: background ?? c.background,
    surface: surface ?? c.surface,
    text: text ?? c.text,
    player: player ?? c.player,
    button: button ?? c.button,
  );

  Future<bool?> _confirmDiscard() => showDialog<bool>(
    context: context,
    builder: (context) => AlertDialog(
      title: const Text('Discard changes?'),
      content: const Text(
        'These colours are showing on this device only. Leave without saving '
        'and they will be dropped.',
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(false),
          child: const Text('Keep editing'),
        ),
        FilledButton(
          onPressed: () => Navigator.of(context).pop(true),
          child: const Text('Discard'),
        ),
      ],
    ),
  );
}

/// The divider between the presets and the eight individual pickers.
///
/// Small, and load-bearing. Without it the colour rows read as a continuation
/// of the preset list — eight more things to choose between — rather than as
/// what the chosen preset just wrote. One line saying so is cheaper than an
/// administrator discovering the relationship by moving a picker and watching
/// the selection above change to Custom.
class _CustomColourHeading extends StatelessWidget {
  const _CustomColourHeading();

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.fromLTRB(
      AppSpacing.page,
      AppSpacing.lg,
      AppSpacing.page,
      AppSpacing.xs,
    ),
    child: Text(
      'Or set each colour yourself. Changing one makes the theme Custom.',
      style: Theme.of(
        context,
      ).textTheme.bodySmall?.copyWith(color: context.palette.textSecondary),
    ),
  );
}

/// Says which version is live, and whether what is on screen is it.
class _VersionBanner extends StatelessWidget {
  const _VersionBanner({required this.version, required this.dirty});

  final int version;
  final bool dirty;

  @override
  Widget build(BuildContext context) {
    final palette = context.palette;
    final text = Theme.of(context).textTheme;

    return Container(
      margin: const EdgeInsets.fromLTRB(
        AppSpacing.page,
        AppSpacing.md,
        AppSpacing.page,
        0,
      ),
      padding: const EdgeInsets.all(AppSpacing.md),
      decoration: BoxDecoration(
        color: palette.surfaceElevated,
        borderRadius: AppRadius.card,
        border: Border.all(color: palette.hairline),
      ),
      child: Row(
        children: [
          AurixIcon(
            dirty ? AurixGlyph.warning : AurixGlyph.info,
            size: 18,
            color: dirty ? palette.attention : palette.textSecondary,
          ),
          const SizedBox(width: AppSpacing.sm),
          Expanded(
            child: Text(
              dirty
                  ? 'Previewing on this device. Save to apply for everyone.'
                  : 'Version $version is live for every AURIX install.',
              style: text.bodySmall,
            ),
          ),
        ],
      ),
    );
  }
}

/// Points at the web console for the things this screen cannot do.
class WebPanelNote extends ConsumerWidget {
  const WebPanelNote({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final palette = context.palette;
    final base = Env.apiBaseUrl;

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: AppSpacing.page),
      child: Text(
        'Uploading a font file, managing administrators and browsing stored '
        'assets live in the web console'
        '${base.isEmpty ? '' : ' at $base/admin/'}.',
        style: Theme.of(
          context,
        ).textTheme.bodySmall?.copyWith(color: palette.textTertiary),
      ),
    );
  }
}
