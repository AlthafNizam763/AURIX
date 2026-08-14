import 'package:aurix/core/storage/preferences_store.dart';
import 'package:aurix/data/models/models.dart';
import 'package:aurix/features/auth/providers/auth_provider.dart';
import 'package:aurix/features/profile/edit_profile_screen.dart';
import 'package:aurix/features/profile/providers/profile_provider.dart';
import 'package:aurix/features/profile/widgets/avatar_picker_sheet.dart';
import 'package:aurix/shared/widgets/media/aurix_avatar.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import '../support/fixtures.dart';
import '../support/harness.dart';

/// The avatar picker, and the rule it exists to enforce.
///
/// The important tests here are the negative ones. "Users can only choose from
/// the predefined AURIX avatars" is a claim about what the UI *cannot* do, and
/// the way to hold that is to assert on the widget tree rather than on copy: no
/// text field to paste a URL into, and every image on screen backed by an
/// [AssetImage] whose path is in the catalogue. A `FileImage`, `NetworkImage`
/// or `MemoryImage` appearing anywhere in the profile UI would mean a picture
/// arrived from somewhere other than the bundle, and these fail if one does.
void main() {
  /// Uses a phone-sized surface so the 3-across grid lays out the way it does
  /// on a device — at the 800×600 test default only one row is on screen and
  /// tapping the fifth avatar would silently miss.
  void usePhoneSurface(WidgetTester tester) {
    tester.view
      ..physicalSize = const Size(1170, 2532)
      ..devicePixelRatio = 3;
    addTearDown(tester.view.reset);
  }

  Future<List<Override>> overridesFor({
    Map<String, Object> preferences = const {},
    UserProfile? user,
  }) async => <Override>[
    ...await baseOverrides(initialPreferences: preferences),
    currentUserProvider.overrideWithValue(user ?? Fixtures.user),
  ];

  /// The tile drawing a particular avatar.
  Finder avatarTile(String id) => find.byWidgetPredicate(
    (widget) => widget is AurixAvatar && widget.avatar.id == id,
    description: 'AurixAvatar($id)',
  );

  /// Unwraps the `ResizeImage` that `Image.asset(cacheWidth: …)` produces.
  ImageProvider unwrap(ImageProvider provider) =>
      provider is ResizeImage ? provider.imageProvider : provider;

  group('Bundle', () {
    /// The unit tests check the PNGs are on disk; this checks they are in the
    /// *bundle*, which is a different claim and the one that matters at
    /// runtime. A missing `assets/avatars/` entry in `pubspec.yaml` leaves
    /// every file exactly where it is and every avatar blank on device.
    testWidgets('every catalogued avatar is registered as an asset',
        (tester) async {
      for (final avatar in AvatarCatalog.all) {
        final data = await rootBundle.load(avatar.assetPath);
        expect(
          data.lengthInBytes,
          greaterThan(0),
          reason: '${avatar.assetPath} is not bundled — check pubspec.yaml',
        );
      }
    });
  });

  group('AvatarPickerSheet', () {
    testWidgets('shows the whole catalogue and nothing but the catalogue',
        (tester) async {
      usePhoneSurface(tester);
      await tester.pumpWidget(
        wrapForTest(
          const AvatarPickerSheet(),
          overrides: await overridesFor(),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.text('Choose Avatar'), findsOneWidget);

      // Every avatar is offered — the grid is driven by the catalogue, so this
      // also fails if one is added to it without artwork behind it.
      //
      // Reached by scrolling rather than asserted on the mounted tree, because
      // the grid is lazy and the catalogue no longer fits a phone in one
      // screenful: three across, the last rows start below the fold. Asserting
      // on what happens to be built would pass or fail on the test surface's
      // height, which is a fact about the harness and not about the picker.
      for (final avatar in AvatarCatalog.all) {
        await tester.scrollUntilVisible(avatarTile(avatar.id), 140);
        expect(
          avatarTile(avatar.id),
          findsOneWidget,
          reason: '${avatar.id} is missing from the picker',
        );
      }

      // …and nothing else is. The other half of the claim: a tile drawing
      // something outside the catalogue would mean a picture reached the
      // picker from somewhere other than the bundled set.
      final shown = tester
          .widgetList<AurixAvatar>(find.byType(AurixAvatar))
          .map((tile) => tile.avatar.id);
      expect(shown, isNotEmpty);
      for (final id in shown) {
        expect(
          AvatarCatalog.contains(id),
          isTrue,
          reason: '$id is not in the catalogue',
        );
      }
    });

    testWidgets('offers no way to supply an image', (tester) async {
      usePhoneSurface(tester);
      await tester.pumpWidget(
        wrapForTest(
          const AvatarPickerSheet(),
          overrides: await overridesFor(),
        ),
      );
      await tester.pumpAndSettle();

      // No field to paste an image URL or a file path into.
      expect(find.byType(TextField), findsNothing);
      expect(find.byType(EditableText), findsNothing);

      // And every picture on screen came out of the app bundle.
      final images = tester.widgetList<Image>(find.byType(Image));
      expect(images, isNotEmpty);

      final catalogued =
          AvatarCatalog.all.map((avatar) => avatar.assetPath).toSet();
      for (final image in images) {
        final provider = unwrap(image.image);
        expect(
          provider,
          isA<AssetImage>(),
          reason: 'a profile picture came from outside the bundle: $provider',
        );
        expect(catalogued, contains((provider as AssetImage).assetName));
      }
    });

    testWidgets('selecting an avatar applies and persists it', (tester) async {
      usePhoneSurface(tester);
      final overrides = await overridesFor();
      // The same backing store the overrides installed — `SharedPreferences`
      // is a per-process singleton, so this is a handle on what the app wrote
      // rather than a second, empty store.
      final preferences = await PreferencesStore.open();

      final container = ProviderContainer(overrides: overrides);
      addTearDown(container.dispose);

      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: container,
          child: const MaterialApp(
            home: Scaffold(body: AvatarPickerSheet()),
          ),
        ),
      );
      await tester.pumpAndSettle();

      // Fresh account: the default, not an empty circle.
      expect(
        container.read(profileProvider).selectedAvatarId,
        AvatarCatalog.defaultId,
      );

      await tester.tap(avatarTile('avatar_05'));
      await tester.pumpAndSettle();

      // Applied immediately, with no request made.
      expect(container.read(profileProvider).selectedAvatarId, 'avatar_05');
      expect(container.read(selectedAvatarProvider).id, 'avatar_05');

      // And saved as an id — not bytes, not a path, not a URL.
      final stored = preferences.getString(
        PrefKeys.profileAvatar(Fixtures.user.id),
      );
      expect(stored, 'avatar_05');
    });

    testWidgets('restores the stored avatar for the signed-in account',
        (tester) async {
      usePhoneSurface(tester);
      final container = ProviderContainer(
        overrides: await overridesFor(
          preferences: {
            PrefKeys.profileAvatar(Fixtures.user.id): 'avatar_09',
            // Another account's choice must not leak into this one.
            PrefKeys.profileAvatar('someone_else'): 'avatar_03',
          },
        ),
      );
      addTearDown(container.dispose);

      expect(container.read(selectedAvatarProvider).id, 'avatar_09');
    });

    testWidgets('an unknown stored id falls back to the default',
        (tester) async {
      final container = ProviderContainer(
        overrides: await overridesFor(
          preferences: {
            PrefKeys.profileAvatar(Fixtures.user.id): 'avatar_from_the_future',
          },
        ),
      );
      addTearDown(container.dispose);

      expect(
        container.read(selectedAvatarProvider).id,
        AvatarCatalog.defaultId,
      );
    });
  });

  group('Shared avatar state', () {
    testWidgets('one selection changes every avatar on screen', (tester) async {
      usePhoneSurface(tester);
      final container = ProviderContainer(overrides: await overridesFor());
      addTearDown(container.dispose);

      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: container,
          child: MaterialApp(
            home: Scaffold(
              body: Column(
                children: [
                  // Stand-ins for the header, the sidebar row and the profile
                  // screen: three independent widgets, one source of truth.
                  AurixAvatar.of(size: 30),
                  AurixAvatar.of(size: 44),
                  AurixAvatar.of(size: 96),
                ],
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(avatarTile(AvatarCatalog.defaultId), findsNWidgets(3));

      await container.read(profileProvider.notifier).selectAvatar('avatar_11');
      await tester.pumpAndSettle();

      expect(avatarTile('avatar_11'), findsNWidgets(3));
      expect(avatarTile(AvatarCatalog.defaultId), findsNothing);
    });
  });

  group('EditProfileScreen', () {
    testWidgets('offers Choose Avatar and no upload affordance',
        (tester) async {
      usePhoneSurface(tester);
      await tester.pumpWidget(
        wrapScreenForTest(
          const EditProfileScreen(),
          overrides: await overridesFor(),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.text('Choose Avatar'), findsOneWidget);

      // Nothing on this screen accepts an image from anywhere.
      expect(find.byType(TextField), findsNothing);
      expect(find.byType(EditableText), findsNothing);

      for (final image in tester.widgetList<Image>(find.byType(Image))) {
        expect(unwrap(image.image), isA<AssetImage>());
      }
    });

    testWidgets('tapping the picture opens the picker', (tester) async {
      usePhoneSurface(tester);
      await tester.pumpWidget(
        wrapScreenForTest(
          const EditProfileScreen(),
          overrides: await overridesFor(),
        ),
      );
      await tester.pumpAndSettle();

      await tester.tap(find.byType(AurixAvatar).first);
      await tester.pumpAndSettle();

      expect(find.byType(AvatarPickerSheet), findsOneWidget);
      // A grid, not a single picture: the sheet that opened is the catalogue.
      // Not the full count — the grid is lazy and only builds the rows that
      // fit; whether the whole catalogue is reachable is the picker's own test
      // above, and this one is about the sheet opening at all.
      expect(find.byType(AurixAvatar), findsAtLeastNWidgets(6));
    });
  });
}
