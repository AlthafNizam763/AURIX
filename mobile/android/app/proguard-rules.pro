# ---------------------------------------------------------------------------
# Auralis — R8 / ProGuard rules for release builds
#
# Only rules that are actually needed are here. Blanket `-keep class **` rules
# defeat the point of shrinking and are a common reason release APKs balloon.
# ---------------------------------------------------------------------------

# --- audio_service / media session -----------------------------------------
# The service and receiver are instantiated by the Android framework from the
# manifest, so R8 cannot see the reference and would strip them.
-keep class com.ryanheise.audioservice.** { *; }
-keep class androidx.media.** { *; }
-keep class android.support.v4.media.** { *; }

# --- just_audio / ExoPlayer -------------------------------------------------
# ExoPlayer resolves extractors and renderers reflectively.
-keep class com.google.android.exoplayer2.** { *; }
-keep class androidx.media3.** { *; }
-dontwarn com.google.android.exoplayer2.**
-dontwarn androidx.media3.**

# --- flutter_web_auth_2 -----------------------------------------------------
# CallbackActivity is referenced only from the manifest.
-keep class com.linusu.flutter_web_auth_2.** { *; }

# --- flutter_secure_storage -------------------------------------------------
-keep class com.it_nomads.fluttersecurestorage.** { *; }
-keep class androidx.security.crypto.** { *; }

# --- Flutter core -----------------------------------------------------------
-keep class io.flutter.app.** { *; }
-keep class io.flutter.plugin.** { *; }
-keep class io.flutter.embedding.** { *; }

# --- Spotify App Remote -----------------------------------------------------
#
# These are Spotify's own consumer rules, copied out of
# spotify-app-remote-release-0.8.0.aar (its proguard.txt), plus three additions
# below.
#
# They have to be copied because of how the SDK is vendored: Spotify does not
# publish App Remote to Maven Central, so it is included as a bare artifact
# module (android/spotify-app-remote/build.gradle), and AGP only auto-applies
# an .aar's consumer rules for a real library dependency. A plain
# `artifacts.add("default", file(...))` is just a file — its proguard.txt is
# never read. Without this block, `flutter build apk --release` fails in
# :app:minifyReleaseWithR8 with "Missing class ... StdDeserializer".
#
# If you ever replace the .aar, re-extract its proguard.txt and diff it against
# this block:  unzip -p spotify-app-remote-release-*.aar proguard.txt
-keep class com.spotify.protocol.types.Item
-keep class * implements com.spotify.protocol.types.Item { *; }
-keep class com.spotify.android.appremote.internal.DebugSpotifyLocator
-keep class com.spotify.android.appremote.internal.ReleaseSpotifyLocator
-keep class com.spotify.android.appremote.api.ConnectionParams$Builder
-dontwarn com.spotify.android.appremote.api.ContentApi$ContentType
-dontwarn com.spotify.android.appremote.api.PlayerApi$StreamType

# Addition 1: Spotify's own rules use a single `*`, which in ProGuard matches
# within one package only. The real references reach deeper —
# com.fasterxml.jackson.databind.deser.std.StdDeserializer and
# com.spotify.protocol.types.ImageUri — so `**` is required or R8 still fails.
-dontwarn com.spotify.protocol.types.**
-dontwarn com.fasterxml.jackson.**

# Addition 2: the App Remote protocol objects are (de)serialised by reflection,
# so their field names must survive obfuscation or every player state comes
# back with null fields.
-keep class com.spotify.protocol.** { *; }

# Addition 3: not in Spotify's list, but referenced by SpotifyServiceBinder.
# An annotation that is not shipped inside the .aar; harmless at runtime.
-dontwarn com.spotify.base.annotations.**

# --- Play Core / Flutter deferred components --------------------------------
#
# Flutter's embedding references SplitCompat and SplitInstall for deferred
# components. AURIX does not use deferred components and does not depend on
# Play Core, so the classes are genuinely absent — the references are dead code
# that R8 nonetheless refuses to shrink past without being told.
#
# Unrelated to Spotify; it surfaced only because this is the first release
# build to run R8 with the App Remote dependency in place.
-dontwarn com.google.android.play.core.**

# --- Kotlin -----------------------------------------------------------------
-keepclassmembers class **$WhenMappings { <fields>; }
-dontwarn kotlin.**

# --- Keep annotations used for reflection ----------------------------------
-keepattributes *Annotation*
-keepattributes Signature
-keepattributes InnerClasses
-keepattributes EnclosingMethod

# --- Never keep debug logging in release -----------------------------------
-assumenosideeffects class android.util.Log {
    public static *** d(...);
    public static *** v(...);
}
