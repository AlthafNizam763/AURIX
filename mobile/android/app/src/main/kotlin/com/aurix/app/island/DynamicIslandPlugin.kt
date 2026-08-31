package com.aurix.app.island

import android.app.Activity
import android.content.Context
import android.content.Intent
import android.net.Uri
import android.provider.Settings
import io.flutter.embedding.engine.plugins.FlutterPlugin
import io.flutter.embedding.engine.plugins.activity.ActivityAware
import io.flutter.embedding.engine.plugins.activity.ActivityPluginBinding
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import io.flutter.plugin.common.PluginRegistry

/**
 * The Android half of AURIX's floating Dynamic Island.
 *
 * ## Its whole job
 *
 * Carry state one way and presses the other. Dart owns playback; this owns a
 * window. There is no path from here into the Spotify SDK, into `audio_service`
 * or into the media session — a press becomes a `command` message and stops,
 * and what happens next is decided by the same [PlayerController] that a tap on
 * the mini player reaches.
 *
 * ## Permission
 *
 * `SYSTEM_ALERT_WINDOW` is declared in the manifest and requested **never**,
 * except through [requestPermission], which exists so the Settings row that
 * explains it has something to call. Nothing on the show path asks for it: if
 * the grant is absent, [capability] says so and Dart stops trying rather than
 * escalating.
 */
class DynamicIslandPlugin :
    FlutterPlugin,
    ActivityAware,
    MethodChannel.MethodCallHandler,
    PluginRegistry.ActivityResultListener {

    private companion object {
        const val CHANNEL = "com.aurix.app/dynamic_island"
        const val PERMISSION_REQUEST = 0x41_49 // 'AI'
    }

    private var channel: MethodChannel? = null
    private var context: Context? = null
    private var activity: Activity? = null
    private var binding: ActivityPluginBinding? = null

    /** Held across the trip to system settings, which returns on a callback. */
    private var pendingPermission: MethodChannel.Result? = null

    private val overlay: DynamicIslandOverlay?
        get() = context?.let { DynamicIslandOverlay.get(it) }

    override fun onAttachedToEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        context = binding.applicationContext
        channel = MethodChannel(binding.binaryMessenger, CHANNEL).also {
            it.setMethodCallHandler(this)
        }
        // Re-registered rather than added to: `MainActivity` can attach to a
        // cached engine more than once, and a second listener would deliver
        // every press twice — which reads as a double-skip.
        overlay?.setCommandListener(::sendCommand)
    }

    override fun onDetachedFromEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        // The engine is going away, so nothing can answer a press or update the
        // metadata any more. A window left behind would keep showing whatever
        // song was playing when Dart died, with buttons that do nothing.
        overlay?.setCommandListener(null)
        overlay?.hide()
        channel?.setMethodCallHandler(null)
        channel = null
        context = null
    }

    override fun onAttachedToActivity(binding: ActivityPluginBinding) {
        this.binding = binding
        activity = binding.activity
        binding.addActivityResultListener(this)
    }

    override fun onReattachedToActivityForConfigChanges(binding: ActivityPluginBinding) =
        onAttachedToActivity(binding)

    override fun onDetachedFromActivityForConfigChanges() = onDetachedFromActivity()

    /**
     * The activity is gone — the user pressed Home, or Android reclaimed it.
     *
     * Deliberately empty of teardown. This is the exact moment the island is
     * supposed to keep working, and it can: the window was added with the
     * application context and belongs to the process, not to this activity.
     */
    override fun onDetachedFromActivity() {
        binding?.removeActivityResultListener(this)
        binding = null
        activity = null
    }

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        when (call.method) {
            "capability" -> result.success(capability())

            "requestPermission" -> requestPermission(result)

            // Answers with whether the window is actually up, rather than
            // succeeding unconditionally. Dart keeps a `floatingVisible` flag,
            // and letting it believe a window exists that does not would leave
            // the island permanently "shown" and never updated again — the
            // failure being silent is what would make it permanent.
            "show" -> result.success(overlay?.show(frameFrom(call)) ?: false)

            "update" -> {
                overlay?.update(frameFrom(call))
                result.success(null)
            }

            "syncPosition" -> {
                overlay?.syncPosition(
                    positionMs = call.argument<Number>("positionMs")?.toLong() ?: 0L,
                    playing = call.argument<Boolean>("playing") ?: false,
                )
                result.success(null)
            }

            "hide" -> {
                overlay?.hide()
                result.success(null)
            }

            else -> result.notImplemented()
        }
    }

    // ---- Capability -------------------------------------------------------

    /**
     * What this device can do, read fresh every time.
     *
     * Never cached: the answer changes while AURIX is not running, because the
     * user grants and revokes it in system settings. Dart re-asks on every
     * foreground for the same reason.
     */
    private fun capability(): Map<String, Any?> {
        val ctx = context
        if (ctx == null || !DynamicIslandOverlay.isSupported()) {
            return mapOf(
                "surface" to "none",
                "reason" to "unsupportedPlatform",
                "granted" to false,
            )
        }
        val granted = DynamicIslandOverlay.hasPermission(ctx)
        return mapOf(
            "surface" to "overlayWindow",
            "reason" to if (granted) "none" else "overlayPermissionMissing",
            "granted" to granted,
        )
    }

    /**
     * Sends the user to Android's "Display over other apps" screen.
     *
     * There is no dialog to accept — this permission has no runtime prompt, only
     * a settings page — so the flow is: AURIX explains it in its own words (see
     * `island_settings_section.dart`), the user agrees, and this opens the page.
     * The answer comes back through [onActivityResult], because
     * `ACTION_MANAGE_OVERLAY_PERMISSION` returns no result of its own and the
     * only reliable read is a fresh [Settings.canDrawOverlays] on the way back.
     */
    private fun requestPermission(result: MethodChannel.Result) {
        val ctx = context
        if (ctx == null || !DynamicIslandOverlay.isSupported()) {
            result.success(capability())
            return
        }
        if (DynamicIslandOverlay.hasPermission(ctx)) {
            result.success(capability())
            return
        }

        val current = activity
        if (current == null) {
            // No activity to return to. Refusing beats opening a settings page
            // from the background with nothing to hand the answer back to.
            result.success(capability())
            return
        }
        if (pendingPermission != null) {
            result.success(capability())
            return
        }

        pendingPermission = result
        val intent = Intent(
            Settings.ACTION_MANAGE_OVERLAY_PERMISSION,
            Uri.parse("package:${ctx.packageName}"),
        )
        runCatching {
            current.startActivityForResult(intent, PERMISSION_REQUEST)
        }.onFailure {
            // Some OEM builds have no such screen. Say so rather than leaving
            // the caller waiting on a result that will never arrive.
            pendingPermission = null
            result.success(capability())
        }
    }

    override fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?): Boolean {
        if (requestCode != PERMISSION_REQUEST) return false
        val result = pendingPermission ?: return true
        pendingPermission = null
        // `resultCode` is always RESULT_CANCELED for this screen, whatever the
        // user did. The grant itself is the answer.
        result.success(capability())
        return true
    }

    // ---- Plumbing ---------------------------------------------------------

    private fun frameFrom(call: MethodCall): IslandFrame = IslandFrame(
        trackId = call.argument<String>("trackId").orEmpty(),
        title = call.argument<String>("title").orEmpty(),
        artist = call.argument<String>("artist").orEmpty(),
        album = call.argument<String>("album"),
        artworkUrl = call.argument<String>("artworkUrl"),
        playing = call.argument<Boolean>("playing") ?: false,
        positionMs = call.argument<Number>("positionMs")?.toLong() ?: 0L,
        durationMs = call.argument<Number>("durationMs")?.toLong() ?: 0L,
    )

    private fun sendCommand(command: IslandCommand) {
        channel?.invokeMethod("command", mapOf("command" to command.wire))
    }
}
