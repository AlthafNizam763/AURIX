package com.aurix.app.island

import android.graphics.Bitmap
import android.graphics.BitmapFactory
import android.os.Handler
import android.os.Looper
import android.util.LruCache
import java.net.HttpURLConnection
import java.net.URL
import java.util.concurrent.Executors
import javax.net.ssl.HttpsURLConnection

/**
 * Fetches album art for the floating island.
 *
 * ## Why not a library
 *
 * Glide or Coil would each add a few hundred kilobytes and an initialiser to
 * the app for one job: one small image at a time, replaced when the track
 * changes, shown at 44dp. This is that job, in one file, with a bounded cache
 * and a single background thread.
 *
 * ## Why one thread
 *
 * The island shows exactly one cover. A pool would let a burst of track changes
 * — Spotify rolling through a queue while AURIX is backgrounded — run several
 * decodes at once, and every one but the last would be thrown away. Serialising
 * them costs nothing and means the phone is never decoding three images to
 * display the newest.
 *
 * The [token] carried through each request is what stops a slow fetch painting
 * a cover over the song that replaced it: the loader compares the token on the
 * way back and drops anything stale, exactly as the Dart side does when it
 * enriches a remote track.
 */
internal class ArtworkLoader {

    private companion object {
        /** Six covers — a listening session's worth of back-and-forth, and
         *  about 1.5MB at the decoded size below. */
        const val CACHE_ENTRIES = 6

        /** Decode target. The island draws the cover at 44dp; 192px covers
         *  every density in use without decoding Spotify's 640px original. */
        const val TARGET_PX = 192

        const val CONNECT_TIMEOUT_MS = 8_000
        const val READ_TIMEOUT_MS = 8_000
    }

    private val cache = object : LruCache<String, Bitmap>(CACHE_ENTRIES) {
        override fun sizeOf(key: String, value: Bitmap) = 1
    }

    private val executor = Executors.newSingleThreadExecutor { runnable ->
        Thread(runnable, "aurix-island-artwork").apply { isDaemon = true }
    }

    private val main = Handler(Looper.getMainLooper())

    /** Returns a cached cover without touching the network, for the common case
     *  where the island is re-shown for a track it has already drawn. */
    fun cached(url: String?): Bitmap? = url?.let { cache.get(it) }

    /**
     * Loads [url] and calls [onLoaded] on the main thread, unless [isCurrent]
     * says the request has been superseded by then.
     */
    fun load(url: String?, token: String, isCurrent: (String) -> Boolean, onLoaded: (Bitmap) -> Unit) {
        if (url.isNullOrEmpty()) return

        cache.get(url)?.let {
            onLoaded(it)
            return
        }

        executor.execute {
            val bitmap = runCatching { fetch(url) }.getOrNull() ?: return@execute
            cache.put(url, bitmap)
            main.post { if (isCurrent(token)) onLoaded(bitmap) }
        }
    }

    private fun fetch(url: String): Bitmap? {
        val connection = (URL(url).openConnection() as HttpURLConnection).apply {
            connectTimeout = CONNECT_TIMEOUT_MS
            readTimeout = READ_TIMEOUT_MS
            instanceFollowRedirects = true
            requestMethod = "GET"
        }

        // Spotify's CDN is https-only. A plain-http URL here would be a
        // misconfiguration rather than something to silently downgrade for.
        if (connection !is HttpsURLConnection) {
            connection.disconnect()
            return null
        }

        return try {
            if (connection.responseCode !in 200..299) return null
            connection.inputStream.use { stream -> decodeScaled(stream.readBytes()) }
        } finally {
            connection.disconnect()
        }
    }

    /**
     * Decodes at roughly [TARGET_PX], measuring first.
     *
     * Two passes rather than a full decode and a scale: a 640×640 Spotify cover
     * is 1.6MB decoded at full size, and this process is holding a media
     * session while backgrounded — the moment a bitmap allocation is worth
     * avoiding.
     */
    private fun decodeScaled(bytes: ByteArray): Bitmap? {
        val bounds = BitmapFactory.Options().apply { inJustDecodeBounds = true }
        BitmapFactory.decodeByteArray(bytes, 0, bytes.size, bounds)

        var sample = 1
        var largest = maxOf(bounds.outWidth, bounds.outHeight)
        while (largest / 2 >= TARGET_PX) {
            sample *= 2
            largest /= 2
        }

        val options = BitmapFactory.Options().apply {
            inSampleSize = sample
            inPreferredConfig = Bitmap.Config.RGB_565
        }
        return BitmapFactory.decodeByteArray(bytes, 0, bytes.size, options)
    }

    fun clear() {
        cache.evictAll()
    }
}
