package com.aurix.app.island

import android.animation.LayoutTransition
import android.annotation.SuppressLint
import android.content.Context
import android.content.Intent
import android.graphics.PixelFormat
import android.os.Build
import android.os.Handler
import android.os.Looper
import android.os.SystemClock
import android.provider.Settings
import android.view.Gravity
import android.view.LayoutInflater
import android.view.MotionEvent
import android.view.View
import android.view.WindowManager
import android.widget.ImageButton
import android.widget.ImageView
import android.widget.ProgressBar
import android.widget.TextView
import com.aurix.app.R
import kotlin.math.abs

/**
 * One frame of playback, as Dart hands it over.
 *
 * [positionMs] is Spotify's own reported position at the moment the frame was
 * built, and [anchoredAtUptime] stamps when that was. Together they are an
 * anchor, not a clock — see [DynamicIslandOverlay.projectedPositionMs].
 */
internal data class IslandFrame(
    val trackId: String,
    val title: String,
    val artist: String,
    val album: String?,
    val artworkUrl: String?,
    val playing: Boolean,
    val positionMs: Long,
    val durationMs: Long,
    val anchoredAtUptime: Long = SystemClock.elapsedRealtime(),
)

/** What the user pressed. Executed by Dart, never here. */
internal enum class IslandCommand(val wire: String) {
    PLAY("play"),
    PAUSE("pause"),
    NEXT("next"),
    PREVIOUS("previous"),
    OPEN("open"),
    DISMISS("dismiss"),
}

/**
 * The Dynamic Island, drawn outside AURIX.
 *
 * ## What it is
 *
 * A single view in a `TYPE_APPLICATION_OVERLAY` window, added to the
 * [WindowManager] with the **application** context. That is the whole reason it
 * survives the thing the Flutter island cannot: an overlay window belongs to the
 * process, not to an `Activity`, so Android destroying `MainActivity` on the way
 * to the home screen leaves it exactly where it was.
 *
 * ## What it is not
 *
 * It is not a player, and it cannot become one. It holds no Spotify binding, no
 * queue and no media session; every button posts a [IslandCommand] back to Dart
 * and waits to be told what happened. If Dart never answers, the island simply
 * keeps showing the last thing it was told — which is the correct failure mode
 * for a remote control, and an impossible one for a second playback engine.
 *
 * ## The one timer, and why it is not a source of truth
 *
 * While the island is up *and* playing, a 500ms handler advances the progress
 * bar. It never accumulates: each pass recomputes the position from the last
 * anchor Dart pushed plus elapsed real time, exactly as Android advances a
 * `PlaybackState` from `updateTime` and `speed`. A skip inside the Spotify app
 * re-anchors it within milliseconds through the App Remote push, and a dropped
 * frame or a doze window costs nothing because nothing was being summed. Spotify
 * remains the source of truth; this only fills the gaps between its reports.
 */
internal class DynamicIslandOverlay private constructor(private val app: Context) {

    companion object {
        @Volatile
        private var instance: DynamicIslandOverlay? = null

        /**
         * One island per process.
         *
         * `MainActivity` can be destroyed and recreated against the same cached
         * Flutter engine, which runs plugin registration again. A per-plugin
         * instance would leave the previously added window on screen with
         * nothing holding a reference to remove it.
         */
        fun get(context: Context): DynamicIslandOverlay =
            instance ?: synchronized(this) {
                instance ?: DynamicIslandOverlay(context.applicationContext).also {
                    instance = it
                }
            }

        /** Whether a floating window can be drawn at all on this device. */
        fun isSupported(): Boolean = Build.VERSION.SDK_INT >= Build.VERSION_CODES.M

        /** Whether the user has granted "Display over other apps". */
        fun hasPermission(context: Context): Boolean =
            if (!isSupported()) false else Settings.canDrawOverlays(context)

        /** Progress refresh while playing. Matches the foreground scrubber's
         *  cadence, and stops entirely when paused or hidden. */
        private const val TICK_MS = 500L

        /** Travel past which a touch is a drag rather than a tap. */
        private const val DRAG_SLOP_DP = 8f
    }

    private val windowManager =
        app.getSystemService(Context.WINDOW_SERVICE) as WindowManager

    private val artwork = ArtworkLoader()
    private val main = Handler(Looper.getMainLooper())

    private var root: View? = null
    private var params: WindowManager.LayoutParams? = null

    private var frame: IslandFrame? = null
    private var expanded = false

    /** Where the user last dragged it, kept across hide/show so the island
     *  comes back where they left it rather than snapping to the default. */
    private var offsetX = 0
    private var offsetY = Int.MIN_VALUE

    private var onCommand: ((IslandCommand) -> Unit)? = null

    private val ticker = object : Runnable {
        override fun run() {
            renderProgress()
            if (frame?.playing == true && root != null) main.postDelayed(this, TICK_MS)
        }
    }

    // ---- Views ------------------------------------------------------------

    private var artView: ImageView? = null
    private var titleView: TextView? = null
    private var artistView: TextView? = null
    private var progressView: ProgressBar? = null
    private var inlinePlay: ImageButton? = null
    private var transportRow: View? = null
    private var transportPlay: ImageButton? = null

    fun setCommandListener(listener: ((IslandCommand) -> Unit)?) {
        onCommand = listener
    }

    val isVisible: Boolean get() = root != null

    // ---- Lifecycle --------------------------------------------------------

    /**
     * Puts the island on screen carrying [next].
     *
     * Idempotent: calling it while already visible updates rather than adding a
     * second window. Returns false when the grant is missing, which the caller
     * reports back to Dart rather than swallowing — a silent no-op here would
     * show up as a Settings switch that appears to work and does nothing.
     */
    @SuppressLint("InflateParams")
    fun show(next: IslandFrame): Boolean {
        if (!hasPermission(app)) return false

        frame = next

        if (root != null) {
            render()
            return true
        }

        // No parent to attach to — an overlay window is the root of its own
        // hierarchy, which is what `null` means here rather than an oversight.
        val view = LayoutInflater.from(app).inflate(R.layout.aurix_island, null, false)
        bind(view)

        val layout = buildLayoutParams()
        params = layout

        return try {
            windowManager.addView(view, layout)
            root = view
            render()
            startTicking()
            true
        } catch (error: Exception) {
            // A revoked grant, or an OEM that refuses the window type. Neither
            // is worth crashing the media service the user is listening to.
            root = null
            params = null
            false
        }
    }

    fun update(next: IslandFrame) {
        frame = next
        if (root == null) return
        render()
        startTicking()
    }

    /**
     * Re-anchors the timeline without disturbing metadata.
     *
     * The counterpart of `PlaybackState.updatePosition`: called when Spotify's
     * real position has diverged from what this window was projecting — a scrub
     * inside the Spotify app, a resume that did not land where it paused.
     */
    fun syncPosition(positionMs: Long, playing: Boolean) {
        val current = frame ?: return
        frame = current.copy(
            positionMs = positionMs,
            playing = playing,
            anchoredAtUptime = SystemClock.elapsedRealtime(),
        )
        if (root == null) return
        renderTransport()
        renderProgress()
        startTicking()
    }

    /** Removes the window. Playback, the media session and the notification are
     *  untouched — this takes a view off the screen and nothing else. */
    fun hide() {
        main.removeCallbacks(ticker)
        val view = root ?: return
        root = null
        params = null
        runCatching { windowManager.removeView(view) }
        clearViewRefs()
    }

    // ---- Window -----------------------------------------------------------

    private fun buildLayoutParams(): WindowManager.LayoutParams {
        val type = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            WindowManager.LayoutParams.TYPE_APPLICATION_OVERLAY
        } else {
            @Suppress("DEPRECATION")
            WindowManager.LayoutParams.TYPE_PHONE
        }

        if (offsetY == Int.MIN_VALUE) offsetY = defaultTopOffset()

        return WindowManager.LayoutParams(
            WindowManager.LayoutParams.WRAP_CONTENT,
            WindowManager.LayoutParams.WRAP_CONTENT,
            type,
            // NOT_FOCUSABLE keeps the keyboard and the back button with
            // whatever app is actually in front; the island still receives
            // touches, which is all it needs. WATCH_OUTSIDE_TOUCH is
            // deliberately absent: collapsing the island because the user
            // tapped something else would make it fight the app underneath.
            WindowManager.LayoutParams.FLAG_NOT_FOCUSABLE or
                WindowManager.LayoutParams.FLAG_NOT_TOUCH_MODAL,
            PixelFormat.TRANSLUCENT,
        ).apply {
            gravity = Gravity.TOP or Gravity.CENTER_HORIZONTAL
            x = offsetX
            y = offsetY
        }
    }

    /**
     * Where the island hangs when it has never been dragged.
     *
     * Below whatever the screen already has up there. Read from the status bar
     * height rather than from a device model, for the same reason the in-app
     * pill reads `MediaQuery.padding.top`: there is no list of handsets to
     * maintain, and a notch, a punch-hole, a cutout and a flat top all resolve
     * themselves.
     */
    private fun defaultTopOffset(): Int {
        val resources = app.resources
        val id = resources.getIdentifier("status_bar_height", "dimen", "android")
        val statusBar = if (id > 0) resources.getDimensionPixelSize(id) else dp(24f)
        return statusBar + dp(6f)
    }

    // ---- Binding ----------------------------------------------------------

    private fun bind(view: View) {
        artView = view.findViewById(R.id.island_art)
        titleView = view.findViewById(R.id.island_title)
        artistView = view.findViewById(R.id.island_artist)
        progressView = view.findViewById(R.id.island_progress)
        inlinePlay = view.findViewById(R.id.island_inline_play)
        transportRow = view.findViewById(R.id.island_transport)
        transportPlay = view.findViewById(R.id.island_play)

        // Animates the capsule between its collapsed and expanded boxes without
        // a hand-written morph. The overlay is a plain Android view hierarchy,
        // so the expensive part of the Flutter island — a painted glass capsule
        // repainted per frame — has no equivalent here to be careful about.
        (view as? android.view.ViewGroup)?.layoutTransition = LayoutTransition().apply {
            enableTransitionType(LayoutTransition.CHANGING)
        }

        inlinePlay?.setOnClickListener { togglePlayback() }
        transportPlay?.setOnClickListener { togglePlayback() }
        view.findViewById<ImageButton>(R.id.island_next)
            ?.setOnClickListener { emit(IslandCommand.NEXT) }
        view.findViewById<ImageButton>(R.id.island_previous)
            ?.setOnClickListener { emit(IslandCommand.PREVIOUS) }
        view.findViewById<ImageButton>(R.id.island_close)
            ?.setOnClickListener { emit(IslandCommand.DISMISS) }

        artView?.setOnClickListener { openApp() }
        view.setOnTouchListener(DragAndTapListener())
    }

    private fun clearViewRefs() {
        artView = null
        titleView = null
        artistView = null
        progressView = null
        inlinePlay = null
        transportRow = null
        transportPlay = null
    }

    // ---- Rendering --------------------------------------------------------

    private fun render() {
        val current = frame ?: return

        titleView?.text = current.title
        artistView?.text = current.artist

        artView?.let { image ->
            val cached = artwork.cached(current.artworkUrl)
            if (cached != null) {
                image.setImageBitmap(cached)
            } else {
                // Cleared before the request, not after it. Leaving the previous
                // cover up while the new one loads is precisely the stale-artwork
                // bug this whole path exists to avoid — a placeholder for a
                // moment is honest, the wrong album is not.
                image.setImageResource(R.drawable.island_artwork_placeholder)
                artwork.load(
                    url = current.artworkUrl,
                    token = current.trackId,
                    isCurrent = { token -> frame?.trackId == token },
                    onLoaded = image::setImageBitmap,
                )
            }
        }

        renderTransport()
        renderProgress()
        renderExpansion()
    }

    private fun renderTransport() {
        val playing = frame?.playing ?: false
        val icon = if (playing) R.drawable.ic_island_pause else R.drawable.ic_island_play
        val label = if (playing) R.string.island_pause else R.string.island_play
        inlinePlay?.apply {
            setImageResource(icon)
            contentDescription = app.getString(label)
        }
        transportPlay?.apply {
            setImageResource(icon)
            contentDescription = app.getString(label)
        }
    }

    private fun renderProgress() {
        val current = frame ?: return
        val bar = progressView ?: return
        if (current.durationMs <= 0) {
            bar.progress = 0
            return
        }
        val fraction = projectedPositionMs(current).toDouble() / current.durationMs
        bar.progress = (fraction.coerceIn(0.0, 1.0) * bar.max).toInt()
    }

    /**
     * The position to draw, interpolated from the last anchor.
     *
     * Recomputed from the anchor every time rather than incremented, so a
     * skipped tick, a doze window or a device that slept for ten minutes all
     * cost nothing — the projection is a function of elapsed time, not a
     * running total that can silently lose the time it was not scheduled for.
     *
     * Clamped to the duration: when a track ends, Spotify starts the next one
     * and pushes its state, and parking here until it does is what stops the
     * bar sailing past the end of a song that has already finished.
     */
    private fun projectedPositionMs(current: IslandFrame): Long {
        if (!current.playing) return current.positionMs
        val elapsed = SystemClock.elapsedRealtime() - current.anchoredAtUptime
        return (current.positionMs + elapsed).coerceAtMost(current.durationMs)
    }

    private fun renderExpansion() {
        transportRow?.visibility = if (expanded) View.VISIBLE else View.GONE
        artistView?.visibility = if (expanded) View.VISIBLE else View.GONE
        // The inline button hands its job to the transport row, rather than
        // sitting behind it as a second Play the user can reach with a screen
        // reader but not with their eyes.
        inlinePlay?.visibility = if (expanded) View.GONE else View.VISIBLE
    }

    private fun startTicking() {
        main.removeCallbacks(ticker)
        if (frame?.playing == true && root != null) main.postDelayed(ticker, TICK_MS)
    }

    // ---- Interaction ------------------------------------------------------

    private fun togglePlayback() {
        emit(if (frame?.playing == true) IslandCommand.PAUSE else IslandCommand.PLAY)
    }

    private fun emit(command: IslandCommand) {
        onCommand?.invoke(command)
    }

    /**
     * Brings AURIX to the front.
     *
     * Starting an activity from the background is normally blocked from Android
     * 10, and `SYSTEM_ALERT_WINDOW` is one of the documented exemptions — which
     * is fair, since the user is looking at the window they granted it for and
     * has just tapped it. The command still goes to Dart as well, so the app
     * arrives on the player screen rather than wherever it was left.
     */
    private fun openApp() {
        emit(IslandCommand.OPEN)
        val launch = app.packageManager.getLaunchIntentForPackage(app.packageName) ?: return
        launch.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_SINGLE_TOP)
        runCatching { app.startActivity(launch) }
    }

    /**
     * Tap to expand, drag to reposition.
     *
     * The two have to share one listener because they share the same gesture
     * until the finger has travelled far enough to tell them apart. Deciding at
     * `ACTION_UP` on total travel — rather than committing to a drag on the
     * first move — is what keeps a tap with a slightly unsteady thumb from
     * nudging the island instead of opening it.
     */
    private inner class DragAndTapListener : View.OnTouchListener {
        private var downX = 0f
        private var downY = 0f
        private var startX = 0
        private var startY = 0
        private var travelled = 0f

        @SuppressLint("ClickableViewAccessibility")
        override fun onTouch(view: View, event: MotionEvent): Boolean {
            val layout = params ?: return false

            when (event.action) {
                MotionEvent.ACTION_DOWN -> {
                    downX = event.rawX
                    downY = event.rawY
                    startX = layout.x
                    startY = layout.y
                    travelled = 0f
                    return true
                }

                MotionEvent.ACTION_MOVE -> {
                    val dx = event.rawX - downX
                    val dy = event.rawY - downY
                    travelled = maxOf(travelled, abs(dx) + abs(dy))
                    if (travelled < dp(DRAG_SLOP_DP)) return true

                    // Gravity is TOP|CENTER_HORIZONTAL, so x is an offset from
                    // the centre and moves with the finger directly.
                    layout.x = startX + dx.toInt()
                    layout.y = (startY + dy.toInt()).coerceAtLeast(0)
                    offsetX = layout.x
                    offsetY = layout.y
                    runCatching { windowManager.updateViewLayout(view, layout) }
                    return true
                }

                MotionEvent.ACTION_UP -> {
                    if (travelled < dp(DRAG_SLOP_DP)) {
                        expanded = !expanded
                        renderExpansion()
                        view.performClick()
                    }
                    return true
                }

                MotionEvent.ACTION_CANCEL -> return true
            }
            return false
        }
    }

    private fun dp(value: Float): Int =
        (value * app.resources.displayMetrics.density).toInt()
}
