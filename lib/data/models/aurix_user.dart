import 'package:equatable/equatable.dart';

import 'auth_method.dart';
import 'avatar.dart';
import 'json_utils.dart';

/// The signed-in AURIX user.
///
/// ## Identity
///
/// [uid] is issued by the AURIX API and is the primary key for everything the
/// user owns: every per-user collection in MongoDB is keyed on it. Nothing else
/// identifies a person in AURIX — not an email address, which the user can
/// change, and certainly not a Spotify account id, which they may never have.
///
/// It is deliberately *not* the Mongo `_id`. Keeping a separate opaque string
/// is what let identity move off Firebase without changing this model, the
/// rows cached on the device, or `importedByUserId` on shared playlists.
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
    this.phone = '',
    this.avatarId = AvatarCatalog.defaultId,
    this.createdAt,
    this.updatedAt,
    this.emailVerified = false,
    this.phoneVerified = false,
    this.emailIsPrivateRelay = false,
    this.isAdmin = false,
    this.linkedMethods = const <AuthMethod>[],
  });

  /// The AURIX account id. The primary identity.
  final String uid;

  /// Display name. Never empty — [displayName] guarantees something renderable
  /// even for an account created before a name was captured.
  final String name;

  final String email;

  /// The phone number on this account, in E.164, or empty.
  ///
  /// Empty is the normal state — most accounts never add one — and it is
  /// *absent* rather than blank on the server, which is what lets the unique
  /// index there hold across every account that has no number. The client sees
  /// the two as the same thing and does not need to distinguish them.
  final String phone;

  /// An [AvatarCatalog] id such as `avatar_05`. Never a URL and never bytes.
  ///
  /// Sanitised on the way in by [fromDocument], so every reader downstream can
  /// assume it names a bundled asset. An id written by a newer build that ships
  /// more avatars resolves to the default rather than to an empty circle.
  final String avatarId;

  final DateTime? createdAt;
  final DateTime? updatedAt;

  /// Whether the address on this account has been confirmed.
  ///
  /// A real field on the user document now rather than a value read from a
  /// second system. Under Firebase this lived in the Auth record and was
  /// deliberately *not* mirrored into Firestore, because two copies of it went
  /// out of step the moment the user clicked the link. With one store there is
  /// one copy, and the split that made mirroring a mistake is gone.
  final bool emailVerified;

  /// Whether a one-time code has been redeemed against [phone].
  ///
  /// Always true where [phone] is non-empty, because the only way a number
  /// reaches the account is by redeeming a code sent to it. Carried anyway
  /// rather than inferred, so that a future path which records a number
  /// without proving it — an admin import, say — cannot silently claim the
  /// stronger fact.
  final bool phoneVerified;

  /// Whether [email] is one of Apple's per-application relay addresses.
  ///
  /// A real, deliverable mailbox, but one Apple minted for AURIX alone — so it
  /// is not the user's email address in any sense they would recognise, and a
  /// profile screen that renders `k2j9x8w4@privaterelay.appleid.com` without
  /// saying where it came from looks broken. It is also why such an address is
  /// never used to match an existing account: it is unique to this app and
  /// could not match one anyway.
  final bool emailIsPrivateRelay;

  /// Every way into this account: a password, a phone, and any linked provider.
  ///
  /// Reported by the server on every account read, and never asserted by the
  /// client. Two screens depend on it — Settings, to show what is linked and to
  /// refuse to unlink the last one, and the account-link sheet, to say "you
  /// usually continue with Google".
  ///
  /// Unknown identifiers are dropped rather than carried through, so a server
  /// that grows a fifth provider does not break an app that predates it.
  final List<AuthMethod> linkedMethods;

  /// Whether this account may change the application theme.
  ///
  /// Read from the server on every profile fetch and **never** written by the
  /// client. It is a display concern here — it decides whether the Appearance
  /// row appears in Settings — and nothing more: the API re-reads the user
  /// document on every admin write, so a client that set this locally would
  /// see the screen and still be refused by every button on it.
  final bool isAdmin;

  /// Reads a user document from the AURIX API.
  ///
  /// [uid] is passed separately as well as being a field on the body, because
  /// the cached copy in [AurixSessionStore] is keyed by it and a document that
  /// somehow lost the field must still resolve to the right account.
  factory AurixUser.fromDocument(String uid, Map<String, dynamic> data) =>
      AurixUser(
        uid: uid.isNotEmpty ? uid : Json.str(data, 'uid'),
        name: Json.str(data, 'name'),
        email: Json.str(data, 'email'),
        phone: Json.str(data, 'phone'),
        avatarId: AvatarResolver.sanitize(Json.strOrNull(data, 'avatarId')),
        createdAt: Json.timestamp(data, 'createdAt'),
        updatedAt: Json.timestamp(data, 'updatedAt'),
        emailVerified: Json.boolVal(data, 'emailVerified'),
        phoneVerified: Json.boolVal(data, 'phoneVerified'),
        emailIsPrivateRelay: Json.boolVal(data, 'emailIsPrivateRelay'),
        isAdmin: Json.boolVal(data, 'isAdmin'),
        linkedMethods: AuthMethod.fromIds(data['providers']),
      );

  /// The document body.
  ///
  /// Used for the encrypted copy [AurixSessionStore] keeps on the device, which
  /// is what lets the splash screen render the right account before the first
  /// network call returns.
  ///
  /// The timestamps are absent for the usual reason — they are server values —
  /// and so is anything the client is not allowed to assert. `isAdmin` is
  /// carried so the cached copy can decide whether to draw the Appearance row
  /// offline; the server ignores it on every write.
  Map<String, dynamic> toDocument() => <String, dynamic>{
    'uid': uid,
    'name': name,
    'email': email,
    'phone': phone,
    'avatarId': avatarId,
    'emailVerified': emailVerified,
    'phoneVerified': phoneVerified,
    'emailIsPrivateRelay': emailIsPrivateRelay,
    'isAdmin': isAdmin,
    // Carried so Settings can draw the linked-accounts list from the cached
    // copy while offline. Like `isAdmin` it is a server fact the client only
    // ever reads back — every write route ignores it.
    'providers': [for (final method in linkedMethods) method.id],
  };

  /// Something to render under the avatar, whatever the record holds.
  ///
  /// Falls back to the local part of the email rather than to "User": a person
  /// who signed up as `alex@example.com` and never set a name recognises
  /// "alex", and recognises nothing in a placeholder.
  String get displayName {
    if (name.trim().isNotEmpty) return name.trim();
    // Not for a relay address. `k2j9x8w4@privaterelay.appleid.com` yields a
    // "name" of `k2j9x8w4`, which is worse than the generic fallback because
    // it looks deliberate.
    final at = email.indexOf('@');
    if (at > 0 && !emailIsPrivateRelay) return email.substring(0, at);
    // An account created from a phone number has neither a name nor an
    // address until its owner sets one, and the last four digits are the part
    // they would recognise.
    if (phone.length >= 4) return 'AURIX ${phone.substring(phone.length - 4)}';
    return 'AURIX listener';
  }

  /// True when this account has exactly one way back in.
  ///
  /// What Settings consults before offering to unlink something. The server
  /// refuses the last one regardless — see `detachIdentity` — but a disabled
  /// control with an explanation beats a button that always fails.
  bool get hasSingleSignInMethod => linkedMethods.length <= 1;

  bool hasMethod(AuthMethod method) => linkedMethods.contains(method);

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
    String? phone,
    String? avatarId,
    DateTime? updatedAt,
    bool? emailVerified,
    bool? phoneVerified,
    bool? emailIsPrivateRelay,
    bool? isAdmin,
    List<AuthMethod>? linkedMethods,
  }) => AurixUser(
    uid: uid,
    name: name ?? this.name,
    email: email ?? this.email,
    phone: phone ?? this.phone,
    avatarId: avatarId ?? this.avatarId,
    createdAt: createdAt,
    updatedAt: updatedAt ?? this.updatedAt,
    emailVerified: emailVerified ?? this.emailVerified,
    phoneVerified: phoneVerified ?? this.phoneVerified,
    emailIsPrivateRelay: emailIsPrivateRelay ?? this.emailIsPrivateRelay,
    isAdmin: isAdmin ?? this.isAdmin,
    linkedMethods: linkedMethods ?? this.linkedMethods,
  );

  @override
  List<Object?> get props => [
    uid,
    name,
    email,
    phone,
    avatarId,
    updatedAt,
    emailVerified,
    phoneVerified,
    emailIsPrivateRelay,
    isAdmin,
    // Included so that linking a provider rebuilds the screens that render the
    // list. Without it, `Equatable` would call the two accounts identical and
    // Riverpod would skip the notification.
    linkedMethods,
  ];
}
