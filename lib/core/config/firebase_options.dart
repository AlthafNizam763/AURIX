import 'package:firebase_core/firebase_core.dart';
import 'package:flutter/foundation.dart';

import 'env.dart';

/// Where AURIX's Firebase project lives.
///
/// ## Why this is hand-written rather than generated
///
/// `flutterfire configure` writes a file with this name full of `const` string
/// literals, one block per platform, and commits it. That works, but it means
/// the project identifiers are baked into the binary at compile time and into
/// the repository at rest, and pointing a build at a staging project means
/// regenerating the file rather than changing a variable.
///
/// AURIX already has a configuration mechanism — `.env` plus `--dart-define`,
/// resolved by [Env] — so this reads through it instead. The shape returned is
/// exactly what the generated file returns, so `Firebase.initializeApp` cannot
/// tell the difference and nothing downstream needs to know.
///
/// ## What is and is not secret here
///
/// Nothing here is a credential. A Firebase `apiKey` identifies a project to
/// Google's endpoints; it grants no access by itself and is visible in every
/// shipped app and every web page that talks to Firebase. What actually decides
/// who may read and write is Firebase Authentication plus the rules in
/// `firestore.rules`, which is why those rules are the security boundary of
/// this application and this file is not.
///
/// ## Using `google-services.json` instead
///
/// Passing explicit [FirebaseOptions] is the supported alternative to the
/// platform config files, so AURIX needs neither `google-services.json` nor the
/// `com.google.gms.google-services` Gradle plugin, and no `GoogleService-Info
/// .plist` on iOS. If you would rather use those files, drop them in and call
/// `Firebase.initializeApp()` with no arguments — see `initializeFirebase`.
abstract final class AurixFirebaseOptions {
  /// The options for the platform this build is running on, or null when the
  /// configuration is incomplete.
  ///
  /// Null rather than a throw: a developer who has cloned the repository and
  /// not yet made a Firebase project should meet the setup screen, which says
  /// what to paste and where, rather than a crash on the first frame.
  static FirebaseOptions? forCurrentPlatform() {
    if (!Env.isFirebaseConfigured) return null;

    return FirebaseOptions(
      apiKey: Env.firebaseApiKey,
      appId: Env.firebaseAppId,
      projectId: Env.firebaseProjectId,
      messagingSenderId: Env.firebaseMessagingSenderId,
      // Optional everywhere. Firestore and Auth do not need a bucket; only
      // Cloud Storage does, and AURIX writes nothing to it today.
      storageBucket: _orNull(Env.firebaseStorageBucket),
      // Web-only fields. Harmless on native, where the SDK ignores them.
      authDomain: kIsWeb ? _orNull(Env.firebaseAuthDomain) : null,
      // Apple platforms reject an app whose bundle id does not match the one
      // registered in the console, so this is passed through when set.
      iosBundleId: _isApple ? _orNull(Env.firebaseIosBundleId) : null,
    );
  }

  static bool get _isApple =>
      !kIsWeb &&
      (defaultTargetPlatform == TargetPlatform.iOS ||
          defaultTargetPlatform == TargetPlatform.macOS);

  static String? _orNull(String value) => value.isEmpty ? null : value;
}
