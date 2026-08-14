import 'dart:io';

import 'package:aurix/core/storage/preferences_store.dart';
import 'package:aurix/data/models/models.dart';
import 'package:aurix/data/repositories/profile_repository.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../support/fixtures.dart';

/// The avatar catalogue, the resolver and the persistence behind them.
///
/// The product rule these enforce is that a profile picture is *always* one of
/// the bundled avatars: never absent, never unknown, never something the user
/// supplied. Most of what follows is checking that no input — null, garbage, a
/// newer build's id, another account's choice — can produce any other outcome.
void main() {
  Future<ProfileRepository> buildRepository([
    Map<String, Object> initial = const {},
  ]) async {
    SharedPreferences.setMockInitialValues(initial);
    return ProfileRepository(preferences: await PreferencesStore.open());
  }

  UserProfile profileWith({String id = 'user_1', String? avatarId}) =>
      UserProfile(id: id, displayName: 'Ada', avatarId: avatarId);

  group('AvatarCatalog', () {
    test('ships the avatars it names', () {
      expect(AvatarCatalog.all, hasLength(AvatarCatalog.count));
      expect(AvatarCatalog.count, AvatarCatalog.names.length);
      expect(AvatarCatalog.count, greaterThan(0));
    });

    test('ids are unique, ordered and zero-padded', () {
      final ids = AvatarCatalog.all.map((a) => a.id).toList();
      expect(ids.toSet(), hasLength(ids.length));
      expect(ids.first, 'avatar_01');
      // Padding is what makes a directory listing sort the way the grid reads.
      expect(ids[9], 'avatar_10');
    });

    test('every asset path points inside the bundled avatar folder', () {
      for (final avatar in AvatarCatalog.all) {
        expect(avatar.assetPath, '${AvatarCatalog.directory}/${avatar.id}.png');
      }
    });

    /// The rule from the brief: "The default avatar must always exist in the
    /// application assets." Checked against the filesystem rather than against
    /// the catalogue, because the catalogue is exactly the thing that could be
    /// wrong — an entry added without running `tool/generate_avatars.dart`
    /// would name a file nobody generated, and every screen would fall through
    /// to an error builder.
    test('every catalogued avatar exists on disk', () {
      for (final avatar in AvatarCatalog.all) {
        expect(
          File(avatar.assetPath).existsSync(),
          isTrue,
          reason: '${avatar.assetPath} is missing — run '
              '`dart run tool/generate_avatars.dart`',
        );
      }
    });

    test('the default is a real catalogue entry', () {
      expect(AvatarCatalog.contains(AvatarCatalog.defaultId), isTrue);
      expect(AvatarCatalog.defaultAvatar.id, AvatarCatalog.defaultId);
    });
  });

  group('AvatarResolver', () {
    test('resolves a known id', () {
      expect(AvatarResolver.resolve('avatar_05').id, 'avatar_05');
      expect(
        AvatarResolver.getAssetPath('avatar_05'),
        'assets/avatars/avatar_05.png',
      );
    });

    test('falls back to the default for null, empty and unknown ids', () {
      for (final input in <String?>[
        null,
        '',
        'avatar_99',
        'not-an-avatar',
        '../../etc/passwd',
      ]) {
        expect(
          AvatarResolver.resolve(input).id,
          AvatarCatalog.defaultId,
          reason: 'input: $input',
        );
        // Never returns a path outside the bundle, whatever it is handed.
        expect(
          AvatarResolver.getAssetPath(input),
          startsWith('${AvatarCatalog.directory}/'),
        );
      }
    });

    test('sanitize normalises on the way in', () {
      expect(AvatarResolver.sanitize('avatar_03'), 'avatar_03');
      expect(AvatarResolver.sanitize('garbage'), AvatarCatalog.defaultId);
      expect(AvatarResolver.isValid('avatar_03'), isTrue);
      expect(AvatarResolver.isValid('garbage'), isFalse);
    });
  });

  group('ProfileRepository', () {
    test('a fresh user gets the default avatar', () async {
      final repository = await buildRepository();
      expect(repository.avatarIdFor(profileWith()), AvatarCatalog.defaultId);
      expect(repository.hasChosenAvatar('user_1'), isFalse);
    });

    test('saves a choice and reads it back', () async {
      final repository = await buildRepository();
      await repository.saveAvatarId('user_1', 'avatar_05');

      expect(repository.avatarIdFor(profileWith()), 'avatar_05');
      expect(repository.hasChosenAvatar('user_1'), isTrue);
    });

    test('survives a restart — the value is in preferences, not memory',
        () async {
      final first = await buildRepository();
      await first.saveAvatarId('user_1', 'avatar_07');

      // A second repository over the same backing store is what a relaunch
      // looks like: nothing carried over except what was written.
      final second = ProfileRepository(preferences: await PreferencesStore.open());
      expect(second.avatarIdFor(profileWith()), 'avatar_07');
    });

    test('keeps accounts apart', () async {
      final repository = await buildRepository();
      await repository.saveAvatarId('user_1', 'avatar_05');
      await repository.saveAvatarId('user_2', 'avatar_09');

      expect(repository.avatarIdFor(profileWith(id: 'user_1')), 'avatar_05');
      expect(repository.avatarIdFor(profileWith(id: 'user_2')), 'avatar_09');
      // Signing in as someone who never chose shows them the default, not the
      // previous user's face.
      expect(
        repository.avatarIdFor(profileWith(id: 'user_3')),
        AvatarCatalog.defaultId,
      );
    });

    test('refuses to store an id with no bundled image behind it', () async {
      final repository = await buildRepository();
      await repository.saveAvatarId('user_1', 'avatar_9001');

      expect(repository.hasChosenAvatar('user_1'), isFalse);
      expect(repository.avatarIdFor(profileWith()), AvatarCatalog.defaultId);
    });

    test('a valid avatarId on the profile wins and is written through',
        () async {
      final repository = await buildRepository();
      await repository.saveAvatarId('user_1', 'avatar_02');

      final resolved =
          repository.avatarIdFor(profileWith(avatarId: 'avatar_08'));
      expect(resolved, 'avatar_08');

      // Written through, so the next launch renders the server's answer from
      // the first frame instead of the stale local one.
      final next = ProfileRepository(preferences: await PreferencesStore.open());
      expect(next.avatarIdFor(profileWith()), 'avatar_08');
    });

    test('an unusable avatarId on the profile falls back to the local choice',
        () async {
      final repository = await buildRepository();
      await repository.saveAvatarId('user_1', 'avatar_04');

      expect(
        repository.avatarIdFor(profileWith(avatarId: 'avatar_9001')),
        'avatar_04',
      );
      // …and does not overwrite the good local value with the bad one.
      expect(repository.avatarIdFor(profileWith()), 'avatar_04');
    });

    test('a Spotify profile carries no avatarId, which is not an error',
        () async {
      final repository = await buildRepository();
      // The real `GET /me` shape, straight from the fixtures.
      expect(Fixtures.user.avatarId, isNull);
      expect(repository.avatarIdFor(Fixtures.user), AvatarCatalog.defaultId);
    });
  });

  group('UserProfile.avatarId', () {
    test('round-trips through JSON', () {
      final withAvatar = Fixtures.user.withAvatarId('avatar_06');
      expect(withAvatar.toJson()['avatarId'], 'avatar_06');
      expect(
        UserProfile.fromJson(withAvatar.toJson()).avatarId,
        'avatar_06',
      );
    });

    test('is omitted rather than written as null when unset', () {
      expect(Fixtures.user.toJson().containsKey('avatarId'), isFalse);
    });

    test('leaves the rest of the profile untouched', () {
      final original = Fixtures.user;
      final updated = original.withAvatarId('avatar_06');

      expect(updated.id, original.id);
      expect(updated.displayName, original.displayName);
      expect(updated.product, original.product);
      expect(updated.country, original.country);
      expect(updated.email, original.email);
      expect(updated.explicitContent, original.explicitContent);
    });
  });
}
