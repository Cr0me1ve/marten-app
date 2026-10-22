package app.marten.native_resume

import android.content.Context
import android.net.Uri
import android.os.Looper

/**
 * Public, Activity-free entry point for the foreground VPN service.
 *
 * The canonical automation source is generated into the APK from the Dart
 * runner at build time, so Flutter and service-only Quick Settings starts use
 * the exact same driver after a cold process start.
 */
object MartenNativeCaptchaRunner {
    private const val AUTOMATION_ASSET = "marten_captcha_automation.js"
    private const val CAPTCHA_PORT = 8765
    private const val MAX_AUTOMATION_SCRIPT_LENGTH = 512 * 1024
    private val scriptLock = Any()
    @Volatile private var cachedAutomationScript: String? = null

    fun initialize(context: Context) {
        HeadlessCaptchaWebView.initializeDiagnostics(context.applicationContext)
    }

    fun load(context: Context, rawUrl: String, revision: Long): Boolean {
        check(Looper.myLooper() == Looper.getMainLooper()) {
            "service captcha runner must run on the main thread"
        }
        require(revision > 0L) { "service captcha revision must be positive" }
        val resolvedUrl = normalizeServiceUrl(rawUrl)
        return HeadlessCaptchaWebView.load(
            context.applicationContext,
            resolvedUrl,
            automationScript(context.applicationContext),
            revision,
        )
    }

    fun clear(revision: Long): Boolean {
        check(Looper.myLooper() == Looper.getMainLooper()) {
            "service captcha runner must run on the main thread"
        }
        return HeadlessCaptchaWebView.clear(revision)
    }

    fun recordControl(
        context: Context,
        event: String,
        outcome: String,
        revision: Long,
        generation: Long,
    ) {
        HeadlessCaptchaWebView.recordControlLifecycle(
            context.applicationContext,
            event,
            outcome,
            revision,
            generation,
        )
    }

    private fun normalizeServiceUrl(rawUrl: String): String {
        val uri = Uri.parse(rawUrl)
        require(
            uri.scheme == "http" &&
                (uri.host == "localhost" || uri.host == "127.0.0.1") &&
                uri.port == CAPTCHA_PORT &&
                uri.getQueryParameter("blank") == "1"
        ) {
            "service captcha URL must use the fixed loopback origin"
        }
        return uri.buildUpon()
            .encodedAuthority("127.0.0.1:$CAPTCHA_PORT")
            .build()
            .toString()
    }

    private fun automationScript(context: Context): String {
        cachedAutomationScript?.let { return it }
        return synchronized(scriptLock) {
            cachedAutomationScript?.let { return@synchronized it }
            val script = context.assets.open(AUTOMATION_ASSET).bufferedReader(Charsets.UTF_8).use {
                it.readText()
            }
            require(script.isNotBlank() && script.length <= MAX_AUTOMATION_SCRIPT_LENGTH) {
                "service captcha automation asset is invalid"
            }
            script.also { cachedAutomationScript = it }
        }
    }
}
