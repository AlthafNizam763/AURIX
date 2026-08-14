/// The AURIX avatar catalogue.
///
/// AURIX profile pictures are **not** user-supplied. There is no gallery
/// picker, no camera, no file chooser and no image-URL field anywhere in the
/// app; the only valid profile picture is one of the marks bundled in
/// `assets/avatars/`. That is a product rule, and it is worth stating where the
/// code lives rather than only in a spec:
///
///  * Nothing leaves the device. Selecting an avatar writes a short string —
///    never bytes, never a file path, never a remote URL — so there is no
///    upload path to secure and no user image to moderate, host or delete.
///  * No permissions. Because there is no capture or file access, AURIX never
///    asks for camera, photo-library or storage permission for a profile
///    picture, on any platform.
///  * It works offline. Every avatar is already in the bundle, so the picker
///    opens and a selection takes effect with no network at all.
///
/// This file is deliberately **free of any Flutter import**, because
/// `tool/generate_avatars.dart` imports it to render exactly the assets this
/// catalogue names. The catalogue is the single source of truth for how many
/// avatars exist and what they are called; the tool fails loudly if its artwork
/// list and this one ever disagree.
library;

/// One bundled avatar.
///
/// [id] is the only thing that is ever persisted or sent anywhere. [assetPath]
/// is derived from it and is a bundle path — never a device path.
class Avatar {
  const Avatar({required this.id, required this.assetPath, required this.name});

  /// Stable identifier, e.g. `avatar_05`. This is what gets saved.
  final String id;

  /// Bundled asset, e.g. `assets/avatars/avatar_05.png`.
  final String assetPath;

  /// Human-readable name, used for accessibility labels and the picker.
  final String name;

  @override
  bool operator ==(Object other) => other is Avatar && other.id == id;

  @override
  int get hashCode => id.hashCode;

  @override
  String toString() => 'Avatar($id)';
}

/// Every avatar AURIX ships, in display order.
///
/// ## Changing the number of avatars
///
/// Add or remove an entry in [names] and everything follows: [count], the
/// generated ids, the picker grid and the resolver. No UI hardcodes the count —
/// the grid is column-driven and the sheet sizes itself to whatever this list
/// holds. After changing it, run:
///
/// ```
/// dart run tool/generate_avatars.dart
/// ```
///
/// which renders the matching PNGs and refuses to run if it has no artwork
/// design for an entry, so the catalogue can never name an asset that is not in
/// the bundle.
abstract final class AvatarCatalog {
  /// Folder inside the bundle. Registered in `pubspec.yaml`.
  static const String directory = 'assets/avatars';

  /// The avatar a brand-new profile gets, and the fallback for anything
  /// unrecognised. It must always exist — [defaultAvatar] asserts it does.
  static const String defaultId = 'avatar_01';

  /// The catalogue, in order. Its length *is* [count].
  ///
  /// Names are part of the product, not decoration: the picker announces
  /// "Nova avatar, 1 of 16" to a screen reader, which is navigable in a way
  /// that sixteen identically-labelled tiles are not. They are *character*
  /// names because these are characters — see the note on the set below.
  ///
  /// ## What these are, and what they replaced
  ///
  /// Sixteen illustrated portraits: a figure with a face, hair and something
  /// worn — headphones, a visor, a cap, a hood. Every one is an original
  /// construction of ellipses and strokes, so no likeness, logo or third-party
  /// character appears anywhere in the set.
  ///
  /// They replace a set of twelve abstract geometric marks. Those were
  /// consistent and cheap and entirely wrong for the job: a profile picture is
  /// how a person is represented in an app, and a chevron on a grey square
  /// represents nothing. A user picking one was choosing a *symbol*, not a
  /// self.
  static const List<String> names = <String>[
    'Nova',
    'Kairo',
    'Vela',
    'Rune',
    'Iris',
    'Onyx',
    'Lyra',
    'Atlas',
    'Echo',
    'Sable',
    'Zephyr',
    'Juno',
    'Orbit',
    'Ember',
    'Nyx',
    'Vox',
  ];

  /// How many avatars exist. Derived, never typed twice.
  static int get count => names.length;

  static final List<Avatar> all = List<Avatar>.unmodifiable(<Avatar>[
    for (var index = 0; index < names.length; index++)
      Avatar(
        id: idAt(index),
        assetPath: '$directory/${idAt(index)}.png',
        name: names[index],
      ),
  ]);

  /// The id at a position: `avatar_01`, `avatar_02`, … Zero-padded to two
  /// digits so a directory listing sorts the way the grid reads.
  static String idAt(int index) =>
      'avatar_${(index + 1).toString().padLeft(2, '0')}';

  /// The default, guaranteed present.
  ///
  /// [defaultId] is asserted rather than looked up leniently: a catalogue whose
  /// default is missing would send every fallback through a null and put an
  /// empty circle where a face belongs, which is the one outcome this whole
  /// system exists to prevent.
  static Avatar get defaultAvatar {
    assert(
      all.any((avatar) => avatar.id == defaultId),
      'AvatarCatalog.defaultId ("$defaultId") is not in the catalogue.',
    );
    return all.firstWhere(
      (avatar) => avatar.id == defaultId,
      orElse: () => all.first,
    );
  }

  /// The avatar with this id, or null if the catalogue has no such entry.
  static Avatar? find(String? id) {
    if (id == null || id.isEmpty) return null;
    for (final avatar in all) {
      if (avatar.id == id) return avatar;
    }
    return null;
  }

  /// True when [id] names a bundled avatar.
  static bool contains(String? id) => find(id) != null;

  /// Position in the grid, 1-based, for accessibility announcements.
  static int positionOf(Avatar avatar) => all.indexOf(avatar) + 1;
}

/// Turns a stored id into something drawable.
///
/// Every profile surface in the app goes through here, which is what makes an
/// unknown id harmless: a profile saved by a newer build (an avatar this
/// version does not ship), a hand-edited preference, a null from a fresh
/// install and a value from an API that knows nothing about avatars all land on
/// the same well-defined default instead of on an empty circle.
abstract final class AvatarResolver {
  /// The bundled asset for [avatarId], falling back to the default.
  ///
  /// Never returns null and never returns a path outside the bundle.
  static String getAssetPath(String? avatarId) => resolve(avatarId).assetPath;

  /// The avatar for [avatarId], falling back to the default.
  static Avatar resolve(String? avatarId) =>
      AvatarCatalog.find(avatarId) ?? AvatarCatalog.defaultAvatar;

  /// Normalises an id for storage: a known id passes through, anything else
  /// becomes the default id.
  ///
  /// Used on the way *in* — when reading preferences or a profile payload — so
  /// that state never carries a value the UI would have to defend against
  /// again further down.
  static String sanitize(String? avatarId) => resolve(avatarId).id;

  /// Whether [avatarId] is a real, currently-bundled avatar.
  static bool isValid(String? avatarId) => AvatarCatalog.contains(avatarId);
}
