import 'dart:async';

import 'package:cloud_firestore/cloud_firestore.dart';

import '../../../core/utils/app_logger.dart';
import '../../models/aurix_user.dart';
import '../../models/avatar.dart';
import 'firestore_paths.dart';

/// Reads and writes `/users/{uid}`.
///
/// One document per person, holding exactly what the spec calls for: uid, name,
/// email, avatarId, createdAt, updatedAt. Nothing else goes in it — a user's
/// playlists, likes and history are subcollections, so the document stays small
/// enough to be read on every launch without thought.
class FirestoreProfileService {
  FirestoreProfileService({FirebaseFirestore? firestore})
      : _db = firestore ?? FirebaseFirestore.instance;

  final FirebaseFirestore _db;

  /// Live view of a user's profile.
  ///
  /// A stream rather than a one-shot read because the profile changes from more
  /// than one place — the avatar picker, the edit screen, and a second device
  /// signed into the same account — and every surface that shows a name or an
  /// avatar should follow all of them without a manual refresh.
  ///
  /// Emits null while the document does not exist yet, which is a real state
  /// and not an error: registration writes the Auth record first, so there is a
  /// brief window on a new account where the user is signed in and the document
  /// is still on its way. [ensureProfile] closes that window.
  Stream<AurixUser?> watch(String uid) => FirestorePaths.user(_db, uid)
      .snapshots()
      .map((snapshot) {
        final data = snapshot.data();
        if (!snapshot.exists || data == null) return null;
        return AurixUser.fromFirestore(snapshot.id, data);
      })
      .handleError((Object error, StackTrace stackTrace) {
        // A permission error here means the rules and the path disagree, which
        // is worth naming loudly — the symptom otherwise is a profile screen
        // that stays empty with nothing in the console.
        AppLogger.error(
          'Profile stream failed for $uid',
          scope: 'profile',
          error: error,
          stackTrace: stackTrace,
        );
      });

  Future<AurixUser?> read(String uid) async {
    final snapshot = await FirestorePaths.user(_db, uid).get();
    final data = snapshot.data();
    if (!snapshot.exists || data == null) return null;
    return AurixUser.fromFirestore(snapshot.id, data);
  }

  /// Creates the profile document if it is not already there, and returns the
  /// user either way.
  ///
  /// Called after every sign-in, not only after registration. That is not
  /// belt-and-braces: an account can exist in Firebase Auth with no Firestore
  /// document — created in the console, created by an earlier build, or created
  /// by a registration whose second write failed offline — and a user in that
  /// state would otherwise sign in successfully to an app with no profile,
  /// which reads as data loss.
  ///
  /// Existing documents are never overwritten here. The name passed in is a
  /// *seed* for a document that does not exist; a user who has since renamed
  /// themselves keeps their name.
  Future<AurixUser> ensureProfile({
    required String uid,
    required String email,
    required String name,
    bool emailVerified = false,
  }) async {
    final reference = FirestorePaths.user(_db, uid);

    // A transaction rather than a read-then-write: two devices signing in at
    // the same moment would otherwise both see "no document" and both create
    // one, and the loser's `createdAt` would silently replace the winner's.
    final user = await _db.runTransaction<AurixUser>((transaction) async {
      final snapshot = await transaction.get(reference);
      final existing = snapshot.data();

      if (snapshot.exists && existing != null) {
        final current = AurixUser.fromFirestore(snapshot.id, existing);

        // The email on the Auth record is authoritative — the user may have
        // changed it there — so a divergence is corrected rather than ignored.
        if (current.email != email && email.isNotEmpty) {
          transaction.update(reference, <String, Object?>{
            'email': email,
            FirestoreFields.updatedAt: FieldValue.serverTimestamp(),
          });
          return current.copyWith(email: email, emailVerified: emailVerified);
        }

        return current.copyWith(emailVerified: emailVerified);
      }

      final created = AurixUser(
        uid: uid,
        name: name,
        email: email,
        avatarId: AvatarCatalog.defaultId,
        emailVerified: emailVerified,
      );

      transaction.set(reference, <String, Object?>{
        ...created.toFirestore(),
        FirestoreFields.createdAt: FieldValue.serverTimestamp(),
        FirestoreFields.updatedAt: FieldValue.serverTimestamp(),
      });

      AppLogger.info('Created profile document for $uid', scope: 'profile');
      return created;
    });

    return user;
  }

  /// Updates the mutable parts of a profile.
  ///
  /// Only three fields can change, and they are named individually rather than
  /// taking a map: a general "update this document" method is how `uid` or
  /// `createdAt` eventually gets overwritten by a caller that meant well.
  Future<void> update(
    String uid, {
    String? name,
    String? avatarId,
    String? email,
  }) async {
    final changes = <String, Object?>{
      if (name != null) 'name': name.trim(),
      // Sanitised rather than trusted. An id with no bundled asset behind it
      // would render as an empty circle on every surface, and the write is the
      // last place that can be caught.
      if (avatarId != null && AvatarResolver.isValid(avatarId))
        'avatarId': avatarId,
      if (email != null) 'email': email.trim(),
    };

    if (changes.isEmpty) {
      if (avatarId != null) {
        AppLogger.warn(
          'Refusing to store unknown avatar id "$avatarId"',
          scope: 'profile',
        );
      }
      return;
    }

    changes[FirestoreFields.updatedAt] = FieldValue.serverTimestamp();
    await FirestorePaths.user(_db, uid).update(changes);
  }

  /// Convenience for the avatar picker, which is the one profile edit reachable
  /// from more than one screen.
  Future<void> setAvatar(String uid, String avatarId) =>
      update(uid, avatarId: avatarId);
}
