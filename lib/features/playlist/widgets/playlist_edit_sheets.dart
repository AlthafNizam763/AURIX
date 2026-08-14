import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/network/error_mapper.dart';
import '../../../core/providers/app_providers.dart';
import '../../../core/theme/app_dimens.dart';
import '../../../core/theme/app_typography.dart';
import '../../../core/theme/aurix_palette.dart';
import '../../../data/models/playlist.dart';
import '../../../data/models/track.dart';
import '../../../shared/widgets/feedback/app_snackbar.dart';
import '../../../shared/widgets/icons/aurix_glyphs.dart';
import '../../../shared/widgets/icons/aurix_icon.dart';
import '../../../shared/widgets/media/app_artwork.dart';
import '../../auth/providers/auth_provider.dart';
import '../providers/playlist_providers.dart';

/// A playlist's name and description, as entered.
class PlaylistDetails {
  const PlaylistDetails({required this.name, required this.description});

  final String name;
  final String description;
}

/// Creates a playlist, or edits an existing one's name and description.
///
/// One sheet for both, because the fields and the validation are identical and
/// the only difference is the verb on the button. Two sheets would be two
/// places to keep the "a playlist must have a name" rule.
class PlaylistDetailsSheet extends StatefulWidget {
  const PlaylistDetailsSheet({
    super.key,
    this.initialName = '',
    this.initialDescription = '',
    this.isCreating = false,
  });

  final String initialName;
  final String initialDescription;
  final bool isCreating;

  /// Presents the sheet. Resolves to null when dismissed.
  static Future<PlaylistDetails?> show(
    BuildContext context, {
    String initialName = '',
    String initialDescription = '',
    bool isCreating = false,
  }) {
    return showModalBottomSheet<PlaylistDetails>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (_) => PlaylistDetailsSheet(
        initialName: initialName,
        initialDescription: initialDescription,
        isCreating: isCreating,
      ),
    );
  }

  @override
  State<PlaylistDetailsSheet> createState() => _PlaylistDetailsSheetState();
}

class _PlaylistDetailsSheetState extends State<PlaylistDetailsSheet> {
  late final TextEditingController _name =
      TextEditingController(text: widget.initialName);
  late final TextEditingController _description =
      TextEditingController(text: widget.initialDescription);
  final _formKey = GlobalKey<FormState>();

  @override
  void dispose() {
    _name.dispose();
    _description.dispose();
    super.dispose();
  }

  void _submit() {
    if (!(_formKey.currentState?.validate() ?? false)) return;
    Navigator.of(context).pop(
      PlaylistDetails(
        name: _name.text.trim(),
        description: _description.text.trim(),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: EdgeInsets.only(bottom: MediaQuery.viewInsetsOf(context).bottom),
      child: Container(
        decoration: BoxDecoration(
          color: context.palette.surface,
          borderRadius: AppRadius.sheet,
        ),
        padding: const EdgeInsets.fromLTRB(
          AppSpacing.xl,
          AppSpacing.md,
          AppSpacing.xl,
          AppSpacing.xl,
        ),
        child: SafeArea(
          top: false,
          child: Form(
            key: _formKey,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                const _SheetGrabber(),
                const SizedBox(height: AppSpacing.xl),

                Text(
                  widget.isCreating ? 'New playlist' : 'Edit playlist',
                  style: AppTypography.headlineSmall,
                ),
                const SizedBox(height: AppSpacing.xl),

                TextFormField(
                  controller: _name,
                  autofocus: true,
                  textCapitalization: TextCapitalization.words,
                  textInputAction: TextInputAction.next,
                  style: AppTypography.bodyLarge,
                  decoration: const InputDecoration(labelText: 'Name'),
                  validator: (value) => (value ?? '').trim().isEmpty
                      ? 'Give the playlist a name.'
                      : null,
                ),
                const SizedBox(height: AppSpacing.md),

                TextFormField(
                  controller: _description,
                  textCapitalization: TextCapitalization.sentences,
                  maxLines: 3,
                  minLines: 1,
                  style: AppTypography.bodyMedium,
                  decoration: const InputDecoration(
                    labelText: 'Description',
                    hintText: 'Optional',
                  ),
                ),

                const SizedBox(height: AppSpacing.xl),

                FilledButton(
                  onPressed: _submit,
                  style: FilledButton.styleFrom(minimumSize: const Size(0, 50)),
                  child: Text(widget.isCreating ? 'Create' : 'Save'),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// Adds one track to any number of playlists.
///
/// Multi-select rather than one-at-a-time, because that is the "add songs to
/// multiple playlists" case and doing it one sheet at a time is four taps per
/// playlist. Selections are applied on confirm, not on tap, so the sheet can
/// report how many landed and the user can change their mind before anything is
/// written.
class AddToPlaylistSheet extends ConsumerStatefulWidget {
  const AddToPlaylistSheet({required this.track, super.key});

  final Track track;

  static Future<void> show(BuildContext context, {required Track track}) {
    return showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (_) => AddToPlaylistSheet(track: track),
    );
  }

  @override
  ConsumerState<AddToPlaylistSheet> createState() => _AddToPlaylistSheetState();
}

class _AddToPlaylistSheetState extends ConsumerState<AddToPlaylistSheet> {
  final Set<String> _selected = <String>{};
  bool _busy = false;

  Future<void> _createAndAdd() async {
    final uid = ref.read(currentUserIdProvider);
    if (uid == null) return;

    final details = await PlaylistDetailsSheet.show(context, isCreating: true);
    if (details == null || !mounted) return;

    setState(() => _busy = true);
    try {
      final repository = ref.read(libraryRepositoryProvider);
      final playlistId = await repository.createPlaylist(
        uid: uid,
        name: details.name,
        description: details.description,
        // Seeded from the track being added, so a playlist built around one
        // song has a cover from the first frame rather than a placeholder that
        // never fills in — AURIX has no cover-upload path.
        coverUrl: widget.track.artworkUrl ?? '',
      );
      await repository.addTrackToPlaylist(
        uid: uid,
        playlistId: playlistId,
        track: widget.track,
      );
      if (!mounted) return;
      Navigator.of(context).pop();
      AppSnackbar.success(context, 'Added to ${details.name}');
    } on Object catch (error) {
      if (!mounted) return;
      setState(() => _busy = false);
      AppSnackbar.error(context, ErrorMapper.fromUnknown(error).message);
    }
  }

  Future<void> _confirm() async {
    final uid = ref.read(currentUserIdProvider);
    if (uid == null || _selected.isEmpty) return;

    setState(() => _busy = true);
    try {
      final added = await ref
          .read(libraryRepositoryProvider)
          .addTrackToPlaylists(
            uid: uid,
            playlistIds: _selected.toList(growable: false),
            track: widget.track,
          );

      if (!mounted) return;
      Navigator.of(context).pop();

      // Reports what actually happened rather than what was asked for. A
      // partial failure is possible — each playlist is its own transaction —
      // and claiming all four when three landed is the kind of small lie that
      // makes a user stop trusting the rest.
      if (added.length == _selected.length) {
        AppSnackbar.success(
          context,
          added.length == 1
              ? 'Added to 1 playlist'
              : 'Added to ${added.length} playlists',
        );
      } else {
        AppSnackbar.warning(
          context,
          'Added to ${added.length} of ${_selected.length} playlists',
        );
      }
    } on Object catch (error) {
      if (!mounted) return;
      setState(() => _busy = false);
      AppSnackbar.error(context, ErrorMapper.fromUnknown(error).message);
    }
  }

  @override
  Widget build(BuildContext context) {
    final playlists = ref.watch(addToPlaylistTargetsProvider);

    return Container(
      constraints: BoxConstraints(
        maxHeight: MediaQuery.sizeOf(context).height * 0.75,
      ),
      decoration: BoxDecoration(
        color: context.palette.surface,
        borderRadius: AppRadius.sheet,
      ),
      padding: const EdgeInsets.only(top: AppSpacing.md),
      child: SafeArea(
        top: false,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const _SheetGrabber(),
            const SizedBox(height: AppSpacing.lg),

            Padding(
              padding: const EdgeInsets.symmetric(horizontal: AppSpacing.xl),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text('Add to playlist', style: AppTypography.headlineSmall),
                  const SizedBox(height: AppSpacing.xs),
                  Text(
                    widget.track.name,
                    style: AppTypography.bodySmall.copyWith(
                      color: context.palette.textSecondary,
                    ),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                ],
              ),
            ),

            const SizedBox(height: AppSpacing.md),

            ListTile(
              onTap: _busy ? null : _createAndAdd,
              leading: Container(
                width: AppSizes.tileArtworkLarge,
                height: AppSizes.tileArtworkLarge,
                decoration: BoxDecoration(
                  color: context.palette.accentSoft,
                  borderRadius: AppRadius.artwork,
                ),
                child: AurixIcon(
                  AurixGlyph.add,
                  size: 20,
                  color: context.palette.accent,
                ),
              ),
              title: const Text('New playlist', style: AppTypography.titleMedium),
            ),

            const Divider(height: 1),

            Flexible(
              child: playlists.when(
                data: (items) => items.isEmpty
                    ? const Padding(
                        padding: EdgeInsets.all(AppSpacing.xl),
                        child: Text('No playlists yet.'),
                      )
                    : ListView.builder(
                        shrinkWrap: true,
                        itemCount: items.length,
                        itemBuilder: (context, index) =>
                            _PlaylistRow(
                              playlist: items[index],
                              selected: _selected.contains(items[index].id),
                              onChanged: _busy
                                  ? null
                                  : (value) => setState(() {
                                      if (value) {
                                        _selected.add(items[index].id);
                                      } else {
                                        _selected.remove(items[index].id);
                                      }
                                    }),
                            ),
                      ),
                loading: () => const Padding(
                  padding: EdgeInsets.all(AppSpacing.xl),
                  child: Center(child: CircularProgressIndicator()),
                ),
                error: (error, _) => Padding(
                  padding: const EdgeInsets.all(AppSpacing.xl),
                  child: Text(ErrorMapper.fromUnknown(error).message),
                ),
              ),
            ),

            Padding(
              padding: const EdgeInsets.all(AppSpacing.xl),
              child: SizedBox(
                width: double.infinity,
                child: FilledButton(
                  onPressed: _selected.isEmpty || _busy ? null : _confirm,
                  style: FilledButton.styleFrom(minimumSize: const Size(0, 50)),
                  child: Text(
                    _selected.isEmpty
                        ? 'Choose a playlist'
                        : 'Add to ${_selected.length}',
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _PlaylistRow extends StatelessWidget {
  const _PlaylistRow({
    required this.playlist,
    required this.selected,
    required this.onChanged,
  });

  final Playlist playlist;
  final bool selected;
  final ValueChanged<bool>? onChanged;

  @override
  Widget build(BuildContext context) {
    return ListTile(
      onTap: onChanged == null ? null : () => onChanged!(!selected),
      leading: AppArtwork(
        imageUrl: playlist.thumbnailUrl,
        size: AppSizes.tileArtworkLarge,
        seed: playlist.id,
        fallbackIcon: AurixGlyph.playlist,
      ),
      title: Text(
        playlist.name,
        style: AppTypography.titleMedium,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
      ),
      subtitle: Text(
        '${playlist.trackCount} ${playlist.trackCount == 1 ? 'song' : 'songs'}',
        style: AppTypography.bodySmall,
      ),
      trailing: Checkbox(
        value: selected,
        onChanged: onChanged == null ? null : (value) => onChanged!(value ?? false),
      ),
    );
  }
}

class _SheetGrabber extends StatelessWidget {
  const _SheetGrabber();

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Container(
        width: 36,
        height: 4,
        decoration: BoxDecoration(
          color: context.palette.hairline,
          borderRadius: BorderRadius.circular(2),
        ),
      ),
    );
  }
}
