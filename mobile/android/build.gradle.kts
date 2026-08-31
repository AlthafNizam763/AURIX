allprojects {
    repositories {
        google()
        mavenCentral()
    }
}

val newBuildDir: Directory =
    rootProject.layout.buildDirectory
        .dir("../../build")
        .get()
rootProject.layout.buildDirectory.value(newBuildDir)

subprojects {
    val newSubprojectBuildDir: Directory = newBuildDir.dir(project.name)
    project.layout.buildDirectory.value(newSubprojectBuildDir)
}

// ---------------------------------------------------------------------------
// Pin every module to one compileSdk.
//
// Some plugins (flutter_secure_storage 11 among them) declare `compileSdk = 37`.
// The Android SDK now ships that platform as `android-37.0`, but AGP 8.11
// resolves it by the older `android-37` hash string and fails with
// "Failed to find target with hash string 'android-37'".
//
// Rather than requiring every developer to hand-install a specific SDK
// package, all Android modules are pinned to the version below. compileSdk
// only controls what can be *compiled against* — what the app runs on is
// governed by minSdk/targetSdk in app/build.gradle.kts, which are untouched.
//
// This uses `plugins.withId` rather than `afterEvaluate` because the
// `evaluationDependsOn` block further down has already evaluated some
// projects by the time this file is read, and `afterEvaluate` throws on an
// already-evaluated project.
//
// Raise this once AGP is new enough to understand minor SDK versions.
// ---------------------------------------------------------------------------
val aurixCompileSdk = 36

subprojects {
    plugins.withId("com.android.library") {
        extensions.configure<com.android.build.gradle.LibraryExtension> {
            compileSdk = aurixCompileSdk
        }
    }
    plugins.withId("com.android.application") {
        extensions.configure<com.android.build.gradle.AppExtension> {
            compileSdkVersion(aurixCompileSdk)
        }
    }
}

subprojects {
    project.evaluationDependsOn(":app")
}

tasks.register<Delete>("clean") {
    delete(rootProject.layout.buildDirectory)
}
