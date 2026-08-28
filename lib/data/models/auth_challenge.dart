import 'aurix_user.dart';
import 'auth_method.dart';

/// What the API said when a one-time code was sent.
///
/// The two durations are the server's, not the client's, and that matters: the
/// resend cooldown and the code's lifetime are enforced in `services/otp.js`,
/// so a countdown drawn from a constant in the app would eventually disagree
/// with the only clock that decides anything.
class PhoneCodeRequest {
  const PhoneCodeRequest({
    required this.maskedPhone,
    required this.expiresIn,
    required this.resendIn,
  });

  /// `+44•••••123`. Enough to recognise your own number, and not enough to
  /// learn a stranger's.
  final String maskedPhone;

  final Duration expiresIn;
  final Duration resendIn;

  // There is deliberately no field for the code.
  //
  // The API does not return one — in any environment, under any configuration
  // — and this model is written so that it could not carry one if it did. A
  // nullable `devCode` here would be a place for the value to accumulate: in a
  // log line, in a widget's state, in a crash report. The only way to be sure
  // it never leaks to the client is for the client to have nowhere to put it.

  factory PhoneCodeRequest.fromJson(Map<String, dynamic> json) => PhoneCodeRequest(
    maskedPhone: json['phone'] as String? ?? '',
    expiresIn: Duration(seconds: (json['expiresInSeconds'] as num?)?.toInt() ?? 300),
    resendIn: Duration(seconds: (json['resendInSeconds'] as num?)?.toInt() ?? 30),
  );
}

/// The API's answer when a social sign-in matched an account that already
/// exists — and asked the user to prove they own it.
///
/// ## Why this is a value and not an error
///
/// Nothing has gone wrong. A provider vouched for an address, an AURIX account
/// claims the same address, and the only missing fact is that they belong to
/// the same person. Modelling that as a failure would push the UI towards
/// "sign-in failed, try again", which is the one thing that cannot help —
/// trying again produces the identical challenge.
///
/// What resolves it is [AurixUser]-shaped: confirm with the account's password
/// or with a code sent to it, and the same session arrives that would have
/// arrived if the two had been linked all along.
class PendingAccountLink {
  const PendingAccountLink({
    required this.token,
    required this.provider,
    required this.providerLabel,
    required this.maskedEmail,
    required this.hasPassword,
    required this.existingMethods,
    required this.expiresIn,
  });

  /// Presented to `/auth/link/code` and `/auth/link/confirm`. Short-lived, and
  /// destroyed by the server after a handful of wrong answers.
  final String token;

  /// The provider being linked *in*, or null if this build has never heard of
  /// it — which is survivable, because [providerLabel] still names it.
  final AuthMethod? provider;

  final String providerLabel;

  /// The existing account's address, masked. The caller has proved nothing
  /// about this account yet, so they are told only enough to recognise it.
  final String maskedEmail;

  /// Whether "confirm with your password" is an option at all. False for an
  /// account that was itself created by a social sign-in, which leaves the
  /// emailed code as the only proof — and a real one, because delivery is what
  /// an address means.
  final bool hasPassword;

  /// How the owner usually gets in. Shown as "you normally continue with
  /// Google", which is what turns a bare challenge into something recognisable.
  final List<AuthMethod> existingMethods;

  final Duration expiresIn;

  factory PendingAccountLink.fromJson(Map<String, dynamic> json) {
    final id = json['provider'] as String?;
    return PendingAccountLink(
      token: json['linkToken'] as String? ?? '',
      provider: AuthMethod.fromId(id),
      providerLabel: json['providerLabel'] as String? ?? id ?? 'that account',
      maskedEmail: json['email'] as String? ?? '',
      hasPassword: json['hasPassword'] == true,
      existingMethods: AuthMethod.fromIds(json['methods']),
      expiresIn: Duration(seconds: (json['expiresInSeconds'] as num?)?.toInt() ?? 600),
    );
  }
}

/// Where the account-link confirmation code was sent.
class LinkCodeSent {
  const LinkCodeSent({
    required this.channel,
    required this.destination,
    required this.expiresIn,
    required this.resendIn,
  });

  /// `email` or `sms`.
  final String channel;

  /// Masked, for the same reason [PendingAccountLink.maskedEmail] is.
  final String destination;

  final Duration expiresIn;
  final Duration resendIn;

  // No field for the code, for the reason given on [PhoneCodeRequest].

  factory LinkCodeSent.fromJson(Map<String, dynamic> json) => LinkCodeSent(
    channel: json['channel'] as String? ?? 'email',
    destination: json['destination'] as String? ?? '',
    expiresIn: Duration(seconds: (json['expiresInSeconds'] as num?)?.toInt() ?? 300),
    resendIn: Duration(seconds: (json['resendInSeconds'] as num?)?.toInt() ?? 30),
  );
}

/// The two things a sign-in attempt can produce.
///
/// Every method on `ApiAuthService` that can end in a link challenge returns
/// this rather than an [AurixUser], so the caller cannot forget the second
/// case: there is no way to read the user without acknowledging that it may be
/// absent.
class AuthResult {
  const AuthResult.signedIn(AurixUser this.user) : link = null;
  const AuthResult.linkRequired(PendingAccountLink this.link) : user = null;

  final AurixUser? user;
  final PendingAccountLink? link;

  bool get needsLink => link != null;
}
