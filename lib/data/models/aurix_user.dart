import 'package:equatable/equatable.dart';

import 'avatar.dart';
import 'json_utils.dart';

/// The signed-in AURIX user.
///
/// ## Identity
///
/// [uid] is the Firebase Authentication UID, and it is the primary key for
/// everything the user owns: `/users/{uid}` and every subcollection under it.
/// Nothing else identifies a person in AURIX — not an email address, which the
/// user can change, and certainly not a Spotify account id, which they may
/// never have.
///
/// ## What is deliberately absent
///
/// This model replaces [UserProfile] as the app's identity, and the fields it
/// does *not* carry are the point of the change:
///
///  * **No subscription tier.** AURIX has no tiers. The old `product` field was
///    Spotify's, and it gated playback controls — that decision now belongs to
///    whichever playback provider is active, not to the user record.
///  * **No country/market.** That existed to set the `market` parameter on
///    Spotify catalogue requests. AURIX's library is the user's own data and is
///    not region-filtered.
///  * **No photo URL.** AURIX profile pictures are chosen from the bundled
///    catalogue and stored as an [avatarId]. There is no upload path anywhere
///    in the app — see the rule in `avatar.dart`. Storing a URL here would be
///    the first half of building one.
class AurixUser extends Equatable {
  const AurixUser({
    required this.uid,
    required this.name,
    required this.email,
    this.avatarId = AvatarCatalog.defaultId,
    this.createdAt,
    this.updatedAt,
    this.emailVerified = false,
  });

  /// Firebase Authentication UID. The primary identity.
  final String uid;

  /// Display name. Never empty — [displayName] guarantees something renderable
  /// even for an account created before a name was captured.
  final String name;

  final String email;

  /// An [AvatarCatalog] id such as `avatar_05`. Never a URL and never bytes.
  ///
  /// Sanitised on the way in by [fromFirestore], so every reader downstream can
  /// assume it names a bundled asset. An id written by a newer build that ships
  /// more avatars resolves to the default rather than to an empty circle.
  final String avatarId;

  final DateTime? createdAt;
  final DateTime? updatedAt;

  /// From Firebase Auth, not from Firestore. Carried on the model because the
  /// profile screen shows it, but never written to the user document — the
  /// authoritative copy lives in the Auth record and a mirrored one would go
  /// stale the moment the user clicked the verification link.
  final bool emailVerified;

  /// Reads `/users/{uid}`.
  factory AurixUser.fromFirestore(String uid, Map<String, dynamic> data) =>
      AurixUser(
        uid: uid,
        name: Json.str(data, 'name'),
        email: Json.str(data, 'email'),
        avatarId: AvatarResolver.sanitize(Json.strOrNull(data, 'avatarId')),
        createdAt: Json.timestamp(data, 'createdAt'),
        updatedAt: Json.timestamp(data, 'updatedAt'),
      );

  /// The document body.
  ///
  /// `uid` is written into the document as well as being the document id. That
  /// is redundant on a direct read and load-bearing on a collection-group
  /// query, where the id is not part of the result body.
  ///
  /// The timestamps are absent for the usual reason: they are server values,
  /// set by `FirestoreProfileService` on write.
  Map<String, dynamic> toFirestore() => <String, dynamic>{
    'uid': uid,
    'name': name,
    'email': email,
    'avatarId': avatarId,
  };

  /// Something to render under the avatar, whatever the record holds.
  ///
  /// Falls back to the local part of the email rather than to "User": a person
  /// who signed up as `alex@example.com` and never set a name recognises
  /// "alex", and recognises nothing in a placeholder.
  String get displayName {
    if (name.trim().isNotEmpty) return name.trim();
    final at = email.indexOf('@');
    if (at > 0) return email.substring(0, at);
    return 'AURIX listener';
  }

  /// First letter, for any surface that renders a monogram.
  String get initial {
    final source = displayName;
    return source.isEmpty ? '?' : source[0].toUpperCase();
  }

  /// The bundled asset for this user's avatar. Always a real, drawable path.
  String get avatarAssetPath => AvatarResolver.getAssetPath(avatarId);

  AurixUser copyWith({
    String? name,
    String? email,
    String? avatarId,
    DateTime? updatedAt,
    bool? emailVerified,
  }) => AurixUser(
    uid: uid,
    name: name ?? this.name,
    email: email ?? this.email,
    avatarId: avatarId ?? this.avatarId,
    createdAt: createdAt,
    updatedAt: updatedAt ?? this.updatedAt,
    emailVerified: emailVerified ?? this.emailVerified,
  );

  @override
  List<Object?> get props => [uid, name, email, avatarId, updatedAt, emailVerified];
}
