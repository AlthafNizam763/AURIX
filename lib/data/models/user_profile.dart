import 'package:equatable/equatable.dart';

import 'json_utils.dart';
import 'spotify_image.dart';

/// Spotify subscription tier.
///
/// This gates real capability, not cosmetics: Spotify Connect playback control
/// is Premium-only, so the UI must know the tier to explain *why* a control is
/// unavailable instead of silently failing.
enum SpotifyProduct {
  premium,
  free,
  open,
  unknown;

  static SpotifyProduct parse(String? raw) {
    switch (raw?.toLowerCase()) {
      case 'premium':
        return SpotifyProduct.premium;
      case 'free':
        return SpotifyProduct.free;
      case 'open':
        return SpotifyProduct.open;
      default:
        return SpotifyProduct.unknown;
    }
  }

  bool get canControlPlayback => this == SpotifyProduct.premium;

  /// Whether Spotify actually told us the tier.
  ///
  /// [unknown] is not a synonym for "free". Spotify's February 2026 changes
  /// removed `product` from `GET /me` for apps in Development Mode, so a
  /// Premium subscriber now reports [unknown] to any such app. Treating that
  /// as "not Premium" makes the UI state, wrongly and confidently, that the
  /// account cannot use Spotify Connect — and hides the guidance that would
  /// actually get playback working.
  bool get isKnown => this != SpotifyProduct.unknown;

  String get label {
    switch (this) {
      case SpotifyProduct.premium:
        return 'Premium';
      case SpotifyProduct.free:
      case SpotifyProduct.open:
        return 'Free';
      case SpotifyProduct.unknown:
        return 'Spotify';
    }
  }
}

/// The account's explicit-content filter, as Spotify reports it on `GET /me`.
///
/// Spotify sends this as `"explicit_content": {"filter_enabled": bool,
/// "filter_locked": bool}`. It is **only** present for the signed-in user, and
/// only when the token carries `user-read-private` — a playlist owner fetched
/// through `/users/{id}` never has it, which is why [UserProfile
/// .explicitContent] is nullable rather than defaulted.
///
/// The two flags answer different questions and both matter:
///
/// * [filterEnabled] — is explicit content currently being filtered out for
///   this account?
/// * [filterLocked] — can the account holder turn that off? It is `true` for
///   accounts under a parental or plan-level restriction, where the setting is
///   not theirs to change.
///
/// A client must not offer a control that Spotify has locked, and must not
/// present explicit material to an account that filters it. [allowsExplicit]
/// and [isUserChangeable] are the two questions the UI actually asks.
class ExplicitContentSettings extends Equatable {
  const ExplicitContentSettings({
    this.filterEnabled = false,
    this.filterLocked = false,
  });

  /// True when Spotify is filtering explicit content for this account.
  final bool filterEnabled;

  /// True when the account holder cannot change [filterEnabled] themselves.
  final bool filterLocked;

  factory ExplicitContentSettings.fromJson(Map<String, dynamic> json) =>
      ExplicitContentSettings(
        filterEnabled: Json.boolVal(json, 'filter_enabled'),
        filterLocked: Json.boolVal(json, 'filter_locked'),
      );

  Map<String, dynamic> toJson() => <String, dynamic>{
    'filter_enabled': filterEnabled,
    'filter_locked': filterLocked,
  };

  /// Whether explicit tracks may be surfaced to this account.
  bool get allowsExplicit => !filterEnabled;

  /// Whether the app may offer a toggle for this at all. A locked filter is
  /// enforced by Spotify; showing an enabled switch beside it would promise
  /// something the app cannot deliver.
  bool get isUserChangeable => !filterLocked;

  /// One line for the settings row.
  String get summary {
    if (!filterEnabled) return 'Allowed by your Spotify account';
    return filterLocked
        ? 'Filtered by your Spotify account and locked'
        : 'Filtered by your Spotify account';
  }

  @override
  List<Object?> get props => [filterEnabled, filterLocked];
}

/// The signed-in user, or another Spotify user (a playlist owner).
class UserProfile extends Equatable {
  const UserProfile({
    required this.id,
    required this.displayName,
    this.email,
    this.country,
    this.product = SpotifyProduct.unknown,
    this.followers = 0,
    this.images = const [],
    this.spotifyUrl,
    this.uri,
    this.explicitContent,
    this.avatarId,
  });

  final String id;
  final String displayName;

  /// Requires the `user-read-email` scope; null for other users.
  final String? email;

  /// ISO 3166-1 alpha-2. Used as the `market` parameter so track availability
  /// and relinking match what the user can actually play.
  final String? country;

  final SpotifyProduct product;
  final int followers;
  final List<SpotifyImage> images;
  final String? spotifyUrl;
  final String? uri;

  /// The account's explicit-content filter, or null when Spotify did not send
  /// one.
  ///
  /// Null is a real and increasingly common answer, not just a parse miss:
  ///
  ///  * `/users/{id}` never includes it — only `/me` does;
  ///  * it needs the `user-read-private` scope;
  ///  * Spotify's February 2026 changes removed `explicit_content` (along with
  ///    `country`, `email`, `followers` and `product`) from the `/me` response
  ///    for apps in Development Mode.
  ///
  /// So the app must treat "Spotify did not tell us" as its own state and fall
  /// back to the local preference, rather than assuming the filter is off.
  /// See https://developer.spotify.com/documentation/web-api/references/changes/february-2026
  final ExplicitContentSettings? explicitContent;

  /// The AURIX avatar this profile carries, as an [AvatarCatalog] id.
  ///
  /// This is AURIX's own field, not Spotify's: `GET /me` has never returned it
  /// and never will, so it is null for every profile that comes off the Web
  /// API. It exists so the *transport* is already correct —
  /// `{"avatarId": "avatar_05"}`, an identifier and never image bytes, a
  /// base64 blob, a device path or a URL — the day a profile is served by a
  /// backend that knows about avatars.
  ///
  /// Until then the selection lives in local preferences, keyed by user id, and
  /// [ProfileRepository] is what reconciles the two: a valid id from the
  /// payload wins, otherwise the stored local choice, otherwise the default.
  /// Nothing renders this field directly — every profile surface reads the
  /// resolved id from `ProfileState` instead, so there is exactly one answer to
  /// "which avatar is this?" on screen at any moment.
  ///
  /// Null is the normal case and is not an error: [AvatarResolver] turns it,
  /// and any unrecognised value, into the default avatar.
  final String? avatarId;

  factory UserProfile.fromJson(Map<String, dynamic> json) {
    final followers = Json.obj(json, 'followers');
    final explicit = Json.obj(json, 'explicit_content');
    final id = Json.str(json, 'id');
    return UserProfile(
      id: id,
      // Playlist owners frequently have no display name; the ID is the only
      // human-readable thing left.
      displayName: Json.strOrNull(json, 'display_name') ?? (id.isEmpty ? 'Spotify user' : id),
      email: Json.strOrNull(json, 'email'),
      country: Json.strOrNull(json, 'country'),
      product: SpotifyProduct.parse(Json.strOrNull(json, 'product')),
      followers: followers == null ? 0 : Json.intVal(followers, 'total'),
      images: Json.list(json, 'images', SpotifyImage.fromJson),
      spotifyUrl: Json.spotifyUrl(json),
      uri: Json.strOrNull(json, 'uri'),
      explicitContent: explicit == null
          ? null
          : ExplicitContentSettings.fromJson(explicit),
      // camelCase, unlike every Spotify key around it, because this one is
      // AURIX's field rather than Spotify's — and it is read back out of the
      // metadata cache, which is where a profile round-trips through
      // [toJson] between launches.
      avatarId: Json.strOrNull(json, 'avatarId'),
    );
  }

  Map<String, dynamic> toJson() => <String, dynamic>{
    'id': id,
    'display_name': displayName,
    if (email != null) 'email': email,
    if (country != null) 'country': country,
    'product': product.name,
    'followers': <String, dynamic>{'total': followers},
    'images': images.map((i) => i.toJson()).toList(),
    if (spotifyUrl != null) 'external_urls': <String, dynamic>{'spotify': spotifyUrl},
    if (uri != null) 'uri': uri,
    // Omitted when null so a round trip through the cache preserves the
    // difference between "Spotify said the filter is off" and "Spotify did not
    // say" — the two lead to different UI.
    if (explicitContent != null) 'explicit_content': explicitContent!.toJson(),
    // Omitted when null so a profile that has never been given an avatar stays
    // distinguishable from one whose avatar was explicitly cleared.
    if (avatarId != null) 'avatarId': avatarId,
  };

  /// Returns a copy carrying [avatarId].
  ///
  /// The only field of a profile AURIX ever changes. Everything else on a
  /// [UserProfile] is Spotify's to state, which is why there is no general
  /// `copyWith` here — a setter for `displayName` or `product` would imply the
  /// app can change them, and it cannot.
  UserProfile withAvatarId(String? avatarId) => UserProfile(
    id: id,
    displayName: displayName,
    email: email,
    country: country,
    product: product,
    followers: followers,
    images: images,
    spotifyUrl: spotifyUrl,
    uri: uri,
    explicitContent: explicitContent,
    avatarId: avatarId,
  );

  // There is deliberately no `avatarUrl` here.
  //
  // Spotify serves whatever photo the account holder uploaded to Spotify, and
  // AURIX profile pictures come from the bundled catalogue and nowhere else —
  // a remote user photo is a user-supplied image, which is the one thing this
  // system exists to exclude. The getter was removed rather than left unused so
  // that reintroducing a user-supplied picture is a compile error at every call
  // site instead of a one-line temptation. [images] stays parsed because the
  // model is a faithful record of what Spotify sent; nothing renders it.

  bool get hasPremium => product.canControlPlayback;

  /// True only when Spotify has positively said this account is *not* Premium.
  ///
  /// The inverse of [hasPremium] is not this: `!hasPremium` is also true when
  /// Spotify declined to say, which is now the normal case for a Development
  /// Mode app. Anything that tells the user "Premium required" must gate on
  /// this, or it will say so to Premium subscribers.
  bool get knownNonPremium => product.isKnown && !product.canControlPlayback;

  /// True only when Spotify has positively said the filter is on.
  ///
  /// A missing [explicitContent] is *not* treated as "filtered": the app would
  /// otherwise hide explicit tracks from every Development Mode user, since
  /// Spotify no longer sends the field to those apps.
  bool get filtersExplicitContent => explicitContent?.filterEnabled ?? false;

  /// True when Spotify enforces the filter and the account cannot turn it off.
  bool get explicitFilterLocked => explicitContent?.filterLocked ?? false;

  /// First letter, for the fallback avatar when the account has no image.
  String get initial =>
      displayName.isEmpty ? '?' : displayName.trim()[0].toUpperCase();

  @override
  List<Object?> get props => [
    id,
    displayName,
    email,
    country,
    product,
    followers,
    images,
    explicitContent,
    avatarId,
  ];
}
