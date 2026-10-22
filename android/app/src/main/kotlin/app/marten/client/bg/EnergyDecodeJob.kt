package app.marten.client.bg

import java.io.File
import java.io.FileNotFoundException
import java.io.IOException

/** Only closed producer slots have markers. A bad segment cannot pin a slot. */
internal fun runClosedEnergyJob(
    marker: File,
    rawFiles: List<File>,
    onLoss: (String) -> Unit,
    decode: () -> Unit,
): Boolean {
    val modified = marker.lastModified()
    val size = marker.length()
    val snapshot = if (size <= 2048) runCatching { marker.readBytes() }.getOrNull() else null
    var category = "invalid_metadata"
    var success = false
    for (attempt in 0 until 3) {
        try {
            require(snapshot != null && size <= 2048)
            decode()
            success = true
            break
        } catch (error: Throwable) {
            val permanent = error !is IOException || error is FileNotFoundException && rawFiles.any { !it.exists() }
            category = if (permanent) "invalid_capture" else "capture_io"
            if (permanent || attempt == 2) break
            Thread.sleep((attempt + 1) * 100L)
        }
    }
    if (!success) onLoss(category)
    // Keep the marker until every old raw input is gone; otherwise the producer
    // could reuse this slot while the decoder still owns its previous files.
    val same = marker.exists() && marker.lastModified() == modified && marker.length() == size &&
        (snapshot == null || runCatching { marker.readBytes().contentEquals(snapshot) }.getOrDefault(false))
    if (same) {
        if (rawFiles.all { !it.exists() || it.delete() }) {
            if (!marker.delete()) onLoss("slot_cleanup")
        } else onLoss("slot_cleanup")
    }
    return success
}
