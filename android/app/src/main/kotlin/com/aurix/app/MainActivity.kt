package com.aurix.app

import com.aurix.app.island.DynamicIslandPlugin
import com.aurix.app.media.MediaPermissionsPlugin
import com.ryanheise.audioservice.AudioServiceActivity
import io.flutter.embedding.engine.FlutterEngine

/**
 * Extends [AudioServiceActivity] rather than Flutter's default `FlutterActivity`.
 *
 * This is required by `audio_service`: the base class keeps the Flutter engine
 * alive in a background-capable state so preview playback survives the activity
 * being backgrounded, and it routes media-button intents into the plugin.
 * Using plain `FlutterActivity` makes playback stop the moment the app leaves
 * the foreground, which is the most commonly reported "audio_service does not
 * work" problem.
 *
 * ## The two plugins registered here
 *
 * Both are AURIX's own, and both are registered against the *engine* rather
 * than against this activity. That distinction is the whole reason the Dynamic
 * Island can outlive the app being minimised: `audio_service` keeps the engine
 * running while a media session is active, so a channel attached to the engine
 * keeps answering after Android has destroyed this activity. The island's
 * window is added with the application context for the same reason — see
 * `DynamicIslandOverlay`.
 *
 * Neither plugin plays anything. `MediaPermissionsPlugin` asks for
 * `POST_NOTIFICATIONS` so the media notification can actually appear on Android
 * 13+, and `DynamicIslandPlugin` draws a window and forwards button presses
 * back to Dart. Playback itself belongs to the Spotify app over App Remote, and
 * to `audio_service` for previews — there is no third player, here or anywhere.
 */
class MainActivity : AudioServiceActivity() {
    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        flutterEngine.plugins.add(DynamicIslandPlugin())
        flutterEngine.plugins.add(MediaPermissionsPlugin())
    }
}
