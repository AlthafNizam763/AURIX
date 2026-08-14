package com.aurix.app.media

import android.Manifest
import android.app.Activity
import android.app.NotificationManager
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.net.Uri
import android.os.Build
import android.provider.Settings
import io.flutter.embedding.engine.plugins.FlutterPlugin
import io.flutter.embedding.engine.plugins.activity.ActivityAware
import io.flutter.embedding.engine.plugins.activity.ActivityPluginBinding
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import io.flutter.plugin.common.PluginRegistry

/**
 * The runtime grant AURIX's media notification depends on.
 *
 * ## Why this is hand-written
 *
 * From Android 13 (API 33) `POST_NOTIFICATIONS` is a runtime permission, and
 * without it the media session is invisible where it matters most: the
 * foreground service still runs and the lock screen still shows the session,
 * but the notification shade — what someone actually pulls down after pressing
 * Home — stays empty. `audio_service` declares the permission and never asks
 * for it, because asking is a UX decision that belongs to the app.
 *
 * It is about fifty lines, so it is fifty lines rather than a dependency: a
 * general permission plugin would pull in a matrix of platforms and permissions
 * AURIX does not use, for one string.
 *
 * ## What it refuses to do
 *
 * It never asks on its own. Dart decides when — once, as the first track
 * starts — and a refusal changes nothing about playback. There is deliberately
 * no retry loop and no second prompt: Android stops showing the dialog after
 * two refusals, and an app that keeps trying is only teaching the user to
 * dismiss it faster.
 */
class MediaPermissionsPlugin :
    FlutterPlugin,
    ActivityAware,
    MethodChannel.MethodCallHandler,
    PluginRegistry.RequestPermissionsResultListener {

    private companion object {
        const val CHANNEL = "com.aurix.app/media_permissions"
        const val REQUEST_CODE = 0x41_55 // 'AU'

        /** Private to this plugin — not Flutter's SharedPreferences file. */
        const val PREFS = "aurix_native"
        const val KEY_ASKED = "asked_post_notifications"

        const val GRANTED = "granted"
        const val DENIED = "denied"
        const val PERMANENTLY_DENIED = "permanentlyDenied"
        const val NOT_REQUIRED = "notRequired"
    }

    private var channel: MethodChannel? = null
    private var context: Context? = null
    private var activity: Activity? = null
    private var binding: ActivityPluginBinding? = null

    /** Held across the system dialog, which answers on a different callback. */
    private var pendingResult: MethodChannel.Result? = null

    override fun onAttachedToEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        context = binding.applicationContext
        channel = MethodChannel(binding.binaryMessenger, CHANNEL).also {
            it.setMethodCallHandler(this)
        }
    }

    override fun onDetachedFromEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        channel?.setMethodCallHandler(null)
        channel = null
        context = null
    }

    override fun onAttachedToActivity(binding: ActivityPluginBinding) {
        this.binding = binding
        activity = binding.activity
        binding.addRequestPermissionsResultListener(this)
    }

    override fun onReattachedToActivityForConfigChanges(binding: ActivityPluginBinding) =
        onAttachedToActivity(binding)

    override fun onDetachedFromActivityForConfigChanges() = onDetachedFromActivity()

    override fun onDetachedFromActivity() {
        binding?.removeRequestPermissionsResultListener(this)
        binding = null
        activity = null
    }

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        when (call.method) {
            "notificationPermissionStatus" -> result.success(status())
            "requestNotificationPermission" -> request(result)
            "openNotificationSettings" -> {
                openNotificationSettings()
                result.success(null)
            }
            else -> result.notImplemented()
        }
    }

    /**
     * Where the grant stands.
     *
     * Two separate facts are folded together on purpose. `POST_NOTIFICATIONS`
     * is the API 33 runtime permission; [NotificationManager.areNotificationsEnabled]
     * is the master switch that exists on every version and that the user can
     * turn off in system settings afterwards. Reporting only the first would
     * claim a notification will appear when the second has silently blocked it.
     */
    private fun status(): String {
        val ctx = context ?: return NOT_REQUIRED
        val manager = ctx.getSystemService(Context.NOTIFICATION_SERVICE) as? NotificationManager
        val enabled = manager?.areNotificationsEnabled() ?: true

        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.TIRAMISU) {
            // No runtime permission here. Notifications are on unless the user
            // has switched them off, and only Settings can switch them back —
            // which is exactly what `permanentlyDenied` means to the caller.
            return if (enabled) GRANTED else PERMANENTLY_DENIED
        }

        val held = ctx.checkSelfPermission(Manifest.permission.POST_NOTIFICATIONS) ==
            PackageManager.PERMISSION_GRANTED
        if (held) return if (enabled) GRANTED else PERMANENTLY_DENIED

        // Not held. Whether the dialog will still appear is the question, and
        // `shouldShowRequestPermissionRationale` alone cannot answer it: it is
        // false both before the first ask and after the final refusal. The
        // remembered flag separates the two.
        val current = activity
        if (current != null &&
            current.shouldShowRequestPermissionRationale(Manifest.permission.POST_NOTIFICATIONS)
        ) {
            return DENIED
        }
        return if (hasAsked(ctx)) PERMANENTLY_DENIED else DENIED
    }

    private fun request(result: MethodChannel.Result) {
        val ctx = context
        val current = activity
        if (ctx == null || Build.VERSION.SDK_INT < Build.VERSION_CODES.TIRAMISU) {
            result.success(status())
            return
        }
        if (current == null) {
            // Backgrounded, or between activities. Asking now would either
            // crash or show a dialog over another app; the next play attempt
            // reaches this again with an activity attached.
            result.success(status())
            return
        }
        if (pendingResult != null) {
            // A dialog is already up. Answer this call with what is known
            // rather than stacking a second request behind the first.
            result.success(status())
            return
        }

        pendingResult = result
        markAsked(ctx)
        current.requestPermissions(
            arrayOf(Manifest.permission.POST_NOTIFICATIONS),
            REQUEST_CODE,
        )
    }

    override fun onRequestPermissionsResult(
        requestCode: Int,
        permissions: Array<out String>,
        grantResults: IntArray,
    ): Boolean {
        if (requestCode != REQUEST_CODE) return false
        val result = pendingResult ?: return true
        pendingResult = null
        result.success(status())
        return true
    }

    /** Opens AURIX's own notification settings — the only fix once the system
     *  dialog has stopped appearing. */
    private fun openNotificationSettings() {
        val ctx = context ?: return
        val intent = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            Intent(Settings.ACTION_APP_NOTIFICATION_SETTINGS)
                .putExtra(Settings.EXTRA_APP_PACKAGE, ctx.packageName)
        } else {
            Intent(Settings.ACTION_APPLICATION_DETAILS_SETTINGS)
                .setData(Uri.fromParts("package", ctx.packageName, null))
        }
        // From the application context when no activity is attached, which is
        // the case this exists for.
        intent.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
        runCatching { (activity ?: ctx).startActivity(intent) }
    }

    private fun hasAsked(ctx: Context): Boolean =
        ctx.getSharedPreferences(PREFS, Context.MODE_PRIVATE).getBoolean(KEY_ASKED, false)

    private fun markAsked(ctx: Context) {
        ctx.getSharedPreferences(PREFS, Context.MODE_PRIVATE)
            .edit()
            .putBoolean(KEY_ASKED, true)
            .apply()
    }
}
