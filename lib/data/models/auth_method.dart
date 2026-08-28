/// A way into an AURIX account.
///
/// ## Why this is one enum and not two
///
/// It would be tidier, in a sense, to keep "the ways you can sign in" apart
/// from "the accounts you have linked". They are the same list. A method is
/// offered on the login screen when the *server* has credentials for it, and it
/// appears as linked on the profile when the *account* has it — and both facts
/// arrive as the same strings, from `GET /auth/methods` and from
/// `user.providers` respectively. Two enums would mean two mappings that could
/// disagree about what `github` is called.
///
/// ## The identifiers are a wire contract
///
/// [id] is what the API says and what its `identities` collection stores. It
/// must not be renamed to suit the UI: the label lives in [label], the sentence
/// lives in [buttonLabel], and [id] is the only part either side is allowed to
/// care about.
enum AuthMethod {
  /// Email and password — the original, and still the default.
  ///
  /// Named `password` rather than `email` because that is what it proves. An
  /// account can hold an email address without having a password, which is
  /// exactly what "Continue with Google" produces.
  password('password', 'Email'),

  phone('phone', 'Phone'),
  google('google', 'Google'),
  apple('apple', 'Apple'),
  facebook('facebook', 'Facebook'),
  github('github', 'GitHub');

  const AuthMethod(this.id, this.label);

  /// The wire identifier. Never shown to a user.
  final String id;

  /// The provider's own name, spelled the way the provider spells it.
  final String label;

  /// The copy on the login screen's button.
  ///
  /// The provider's bare name. The buttons used to read "Continue with
  /// Google", and dropping the preamble is what lets five stacked options be
  /// scanned as a list of names rather than read as five near-identical
  /// sentences — the mark beside each one already says what kind of thing it
  /// is, so the verb was carrying nothing.
  ///
  /// Phone keeps a "with", because it is the one option that names a *thing
  /// you have* rather than an account somewhere. Standing alone, "Phone" reads
  /// as a heading; the rest do not have that problem because a person's
  /// Google, Apple, Facebook and GitHub accounts share their names.
  String get buttonLabel => this == AuthMethod.phone ? 'with $label' : label;

  /// What a screen reader announces for the same button.
  ///
  /// Deliberately longer than what is drawn. Sighted users have the mark and
  /// the surrounding "or" rule to tell them these are sign-in choices; someone
  /// hearing "Google, button" in isolation has neither, so the announcement
  /// keeps the verb the visible label drops.
  String get signInSemanticLabel => 'Sign in with $label';

  /// True for the four that involve a browser round trip to a third party.
  ///
  /// The distinction the UI cares about: these need a system browser, an
  /// allow-listed redirect and a grant exchange, where [password] and [phone]
  /// are answered by a form in the app.
  bool get isSocial => switch (this) {
    AuthMethod.google || AuthMethod.apple || AuthMethod.facebook || AuthMethod.github => true,
    AuthMethod.password || AuthMethod.phone => false,
  };

  /// The order the login screen offers them in.
  ///
  /// Phone first among the alternatives because it is the one that needs no
  /// account anywhere else; the rest follow the order in the product brief.
  /// [password] is absent because it is the form above them, not a button.
  static const List<AuthMethod> loginOrder = [
    AuthMethod.phone,
    AuthMethod.google,
    AuthMethod.apple,
    AuthMethod.facebook,
    AuthMethod.github,
  ];

  /// Parses a wire identifier, or null for one this build does not know.
  ///
  /// Null rather than a throw, deliberately: a server that has grown a fifth
  /// provider must not crash an older app that has never heard of it. The
  /// unknown method is simply not offered.
  static AuthMethod? fromId(String? id) {
    if (id == null) return null;
    for (final method in AuthMethod.values) {
      if (method.id == id) return method;
    }
    return null;
  }

  /// Parses a list of identifiers, dropping any this build does not know.
  static List<AuthMethod> fromIds(Object? raw) {
    if (raw is! List) return const [];
    return raw
        .map((value) => fromId(value is String ? value : null))
        .whereType<AuthMethod>()
        .toList(growable: false);
  }
}
