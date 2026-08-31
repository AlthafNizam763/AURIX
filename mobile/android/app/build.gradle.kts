plugins {
    id("com.android.application")
    id("kotlin-android")
    // The Flutter Gradle Plugin must be applied after the Android and Kotlin Gradle plugins.
    id("dev.flutter.flutter-gradle-plugin")
}

android {
    namespace = "com.aurix.app"
    compileSdk = flutter.compileSdkVersion
    ndkVersion = flutter.ndkVersion

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    kotlinOptions {
        jvmTarget = JavaVersion.VERSION_17.toString()
    }

    defaultConfig {
        applicationId = "com.aurix.app"

        // Flutter's default (currently 24) already satisfies every plugin
        // requirement here: flutter_secure_storage 11 needs 24 for AES-GCM in
        // the Android Keystore, and audio_service / just_audio need 21+.
        // If you lower this, login will fail on first token write.
        minSdk = flutter.minSdkVersion

        targetSdk = flutter.targetSdkVersion
        versionCode = flutter.versionCode
        versionName = flutter.versionName

        // Keeps the method count under control once the Spotify, audio and
        // secure-storage dependency trees are all linked in.
        multiDexEnabled = true

        // Required by the Spotify auth library that ships inside `spotify_sdk`.
        // Its manifest declares an activity whose intent-filter is built from
        // these two placeholders; without them the manifest merger fails with
        // "Attribute data@scheme requires a placeholder substitution".
        //
        // AURIX does not use that activity — sign-in is the app's own
        // Authorization Code + PKCE flow through flutter_web_auth_2, on
        // aurix://auth-callback. These values exist only to satisfy the
        // merger, and are deliberately NOT the AURIX callback: pointing them
        // at aurix://auth-callback would put Spotify's auth activity in
        // competition with the OAuth CallbackActivity for the same redirect.
        // Must match Env.appRemoteRedirectUri (aurix://spotify-remote) and be
        // registered in the Spotify dashboard as its own Redirect URI.
        //
        // The host is NOT "auth-callback": that URI belongs to the PKCE flow's
        // CallbackActivity, and two activities claiming one URI is resolved by
        // Android with a chooser dialog or an arbitrary pick.
        manifestPlaceholders["redirectSchemeName"] = "aurix"
        manifestPlaceholders["redirectHostName"] = "spotify-remote"
    }

    buildTypes {
        release {
            // TODO: replace with your own signing config before publishing.
            // Debug keys are used here only so `flutter run --release` works
            // out of the box. See android/key.properties (git-ignored).
            signingConfig = signingConfigs.getByName("debug")

            isMinifyEnabled = true
            isShrinkResources = true
            proguardFiles(
                getDefaultProguardFile("proguard-android-optimize.txt"),
                "proguard-rules.pro"
            )
        }
    }
}

flutter {
    source = "../.."
}
