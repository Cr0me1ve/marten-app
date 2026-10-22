package app.marten.native_resume

import android.annotation.SuppressLint
import android.content.Context
import android.net.Uri
import android.os.Build
import android.os.Handler
import android.os.Looper
import android.os.SystemClock
import android.util.Log
import android.webkit.JavascriptInterface
import android.webkit.RenderProcessGoneDetail
import android.webkit.WebResourceError
import android.webkit.WebResourceRequest
import android.webkit.WebView
import android.webkit.WebViewClient
import java.io.File
import java.util.concurrent.Executors
import java.util.concurrent.atomic.AtomicLong

/**
 * A detached WebView for the automatic TURNcoat CAPTCHA path.
 *
 * A Flutter platform WebView is attached to the Activity window. Chromium
 * intentionally stops its compositor when that window becomes invisible, so
 * canvas/PoW CAPTCHA pages may never finish while Chrome or another app is in
 * front. This WebView is deliberately never attached to a window and is owned
 * by the process-wide foreground VPN service lifetime instead.
 */
internal object HeadlessCaptchaWebView {
    private const val TAG = "MartenCaptchaHeadless"
    private const val MAX_AUTOMATION_SCRIPT_LENGTH = 512 * 1024
    private const val MAX_REPLAYS_PER_REVISION = 1
    private const val CAPTCHA_OUTER_DEADLINE_MILLIS = 60_000L
    private const val CAPTCHA_STALL_REPLAY_MILLIS = 25_000L
    private const val CAPTCHA_LOG_NAME = "captcha.log"
    private const val CAPTCHA_OLD_LOG_NAME = "captcha.log.old"
    private const val MAX_CAPTCHA_LOG_BYTES = 512 * 1024L
    private val allowedEvents = setOf(
        "request-bridge-installed",
        "monitor-installed",
        "driver-installed",
        "checkbox-seen",
        "autoclick-scheduled",
        "checkbox-click",
        "autoclick-fired",
        "autoclick-retry",
        "autoclick-unconfirmed",
        "autoclick-error",
        "autoclick-timeout",
        "pow-function-absent-compat-ready",
        "pow-result-missing-wait",
        "pow-result-error-wait",
        "pow-result-invalid-wait",
        "pow-hash-missing-wait",
        "pow-ready",
        "check-request-observed",
        "check-response-received",
        "check-response-rejected",
        "check-request-error",
        "callback-request-observed",
        "callback-response-accepted",
        "callback-response-rejected",
        "callback-request-error",
    )
    private val meaningfulProgressEvents = setOf(
        "check-request-observed",
        "check-response-received",
        "callback-request-observed",
        "callback-response-accepted",
    )
    private val allowedLifecycleEvents = setOf(
        "runner",
        "control",
        "load",
        "clear",
        "page",
        "renderer",
        "main_frame_error",
        "watchdog",
        "replay",
        "automation",
        "stale",
    )
    private val allowedReasons = allowedEvents + setOf(
        "none",
        "initialized",
        "started",
        "finished",
        "deduplicated",
        "replaced",
        "completed",
        "scheduled",
        "progress",
        "deadline",
        "stall",
        "renderer_gone",
        "crashed",
        "killed",
        "main_frame_error",
        "requested",
        "exhausted",
        "no_active",
        "page_started",
        "page_finished",
        "renderer",
        "automation",
        "clear",
    )
    private val allowedControlEvents = setOf(
        "listener",
        "required",
        "terminal",
        "runner",
    )
    private val allowedControlOutcomes = setOf(
        "started",
        "connected",
        "retry",
        "stopped",
        "disabled",
        "accepted",
        "rejected",
        "cleared",
        "forwarded",
        "stale",
        "failed",
    )
    private val mainHandler = Handler(Looper.getMainLooper())
    private val runnerSequence = AtomicLong()
    private val diagnosticsExecutor = Executors.newSingleThreadExecutor { runnable ->
        Thread(runnable, "marten-captcha-diagnostics").apply { isDaemon = true }
    }

    private var webView: WebView? = null
    private var applicationContext: Context? = null
    @Volatile private var diagnosticsDirectory: File? = null
    private var currentUrl = "about:blank"
    private var currentAutomationScript = ""
    private var currentRevision = 0L
    private var currentRunner = 0L
    private var challengeStartedAt = 0L
    private var lastMeaningfulProgress = 0L
    private var replayCount = 0
    private var watchdog: Runnable? = null

    fun initializeDiagnostics(context: Context) {
        if (diagnosticsDirectory != null) return
        diagnosticsDirectory = context.applicationContext.getExternalFilesDir(null)
            ?: context.applicationContext.filesDir
        recordLifecycle(event = "runner", revision = 0L, runner = 0L, reason = "initialized")
    }

    internal fun recordControlLifecycle(
        context: Context,
        controlEvent: String,
        outcome: String,
        revision: Long,
        generation: Long,
    ) {
        initializeDiagnostics(context)
        val safeControlEvent = controlEvent.takeIf(allowedControlEvents::contains) ?: "runner"
        val safeOutcome = outcome.takeIf(allowedControlOutcomes::contains) ?: "failed"
        val line = "MARTEN_CAPTCHA_LIFECYCLE component=android event=control " +
            "control=$safeControlEvent revision=${maxOf(0L, revision)} generation=${maxOf(0L, generation)} " +
            "outcome=$safeOutcome"
        Log.i(TAG, line)
        persistDiagnosticLine(line)
    }

    @SuppressLint("SetJavaScriptEnabled", "JavascriptInterface")
    fun load(context: Context, url: String, automationScript: String, revision: Long): Boolean {
        check(Looper.myLooper() == Looper.getMainLooper()) { "headless captcha must run on the main thread" }
        initializeDiagnostics(context)
        validateUrl(url)
        require(automationScript.isNotBlank() && automationScript.length <= MAX_AUTOMATION_SCRIPT_LENGTH) {
            "invalid headless captcha automation"
        }
        require(revision >= 0L) { "invalid headless captcha revision" }

        if (currentUrl == url && currentRevision == revision && webView != null) {
            webView?.onResume()
            scheduleWatchdog(revision)
            recordLifecycle(event = "load", revision = revision, reason = "deduplicated")
            return true
        }

        val replacesExisting = webView != null && currentUrl != "about:blank"
        cancelWatchdog()
        applicationContext = context.applicationContext
        currentUrl = url
        currentAutomationScript = automationScript
        currentRevision = revision
        currentRunner = runnerSequence.incrementAndGet()
        challengeStartedAt = SystemClock.elapsedRealtime()
        lastMeaningfulProgress = challengeStartedAt
        replayCount = 0
        webView?.stopLoading()
        webView?.destroy()
        val target = create(context.applicationContext, revision, currentRunner).also { webView = it }
        target.onResume()
        recordLifecycle(
            event = "load",
            revision = revision,
            reason = if (replacesExisting) "replaced" else "started",
        )
        target.loadUrl(url)
        scheduleWatchdog(revision)
        return true
    }

    fun clear(revision: Long): Boolean {
        check(Looper.myLooper() == Looper.getMainLooper()) { "headless captcha must run on the main thread" }
        if (revision > 0L && currentRevision != revision) {
            recordLifecycle(event = "stale", revision = revision, reason = "clear")
            return true
        }
        val clearedRevision = currentRevision
        val clearedRunner = currentRunner
        recordLifecycle(
            event = "clear",
            revision = clearedRevision.takeIf { it > 0L } ?: revision,
            runner = clearedRunner,
            reason = "completed",
        )
        cancelWatchdog()
        currentUrl = "about:blank"
        currentAutomationScript = ""
        currentRevision = 0L
        currentRunner = 0L
        challengeStartedAt = 0L
        lastMeaningfulProgress = 0L
        replayCount = 0
        webView?.stopLoading()
        webView?.loadUrl("about:blank")
        return true
    }

    @SuppressLint("SetJavaScriptEnabled", "JavascriptInterface")
    private fun create(context: Context, revision: Long, runner: Long): WebView = WebView(context).apply {
        settings.javaScriptEnabled = true
        settings.domStorageEnabled = true
        setBackgroundColor(0x00ffffff)
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            setRendererPriorityPolicy(WebView.RENDERER_PRIORITY_IMPORTANT, false)
        }
        addJavascriptInterface(AutomationEvents(revision, runner), "MartenCaptchaAutomation")
        webViewClient = object : WebViewClient() {
            override fun onPageStarted(view: WebView, url: String, favicon: android.graphics.Bitmap?) {
                if (revision != currentRevision || runner != currentRunner || webView !== view) {
                    recordLifecycle(event = "stale", revision = revision, runner = runner, reason = "page_started")
                    return
                }
                recordLifecycle(event = "page", revision = revision, runner = runner, reason = "started")
                inject(view)
            }

            override fun onPageFinished(view: WebView, url: String) {
                if (revision != currentRevision || runner != currentRunner || webView !== view) {
                    recordLifecycle(event = "stale", revision = revision, runner = runner, reason = "page_finished")
                    return
                }
                recordLifecycle(event = "page", revision = revision, runner = runner, reason = "finished")
                inject(view)
            }

            override fun onRenderProcessGone(view: WebView, detail: RenderProcessGoneDetail): Boolean {
                if (revision != currentRevision || runner != currentRunner || webView !== view) {
                    recordLifecycle(event = "stale", revision = revision, runner = runner, reason = "renderer")
                    view.destroy()
                    return true
                }
                recordLifecycle(
                    event = "renderer",
                    revision = revision,
                    runner = runner,
                    reason = if (detail.didCrash()) "crashed" else "killed",
                )
                view.destroy()
                if (webView === view) webView = null
                replayCurrentChallenge("renderer_gone")
                return true
            }

            override fun onReceivedError(view: WebView, request: WebResourceRequest, error: WebResourceError) {
                if (!request.isForMainFrame) return
                if (revision != currentRevision || runner != currentRunner || webView !== view) {
                    recordLifecycle(event = "stale", revision = revision, runner = runner, reason = "main_frame_error")
                    return
                }
                recordLifecycle(
                    event = "main_frame_error",
                    revision = revision,
                    runner = runner,
                    reason = "main_frame_error",
                    code = error.errorCode,
                )
                replayCurrentChallenge("main_frame_error")
            }
        }
    }

    private fun inject(view: WebView) {
        val script = currentAutomationScript
        if (script.isEmpty() || currentUrl == "about:blank") return
        val replayState = if (replayCount > 0) "true" else "false"
        view.evaluateJavascript("window.__martenCaptchaHostReplayUsed=$replayState;\n$script", null)
    }

    private fun scheduleWatchdog(revision: Long) {
        cancelWatchdog()
        if (currentUrl == "about:blank" || revision != currentRevision || challengeStartedAt == 0L) return
        val now = SystemClock.elapsedRealtime()
        val deadlineRemaining = CAPTCHA_OUTER_DEADLINE_MILLIS - (now - challengeStartedAt)
        if (deadlineRemaining <= 0L) {
            recordLifecycle(event = "watchdog", revision = revision, reason = "deadline")
            return
        }
        val progressAt = maxOf(challengeStartedAt, lastMeaningfulProgress)
        val stallRemaining = CAPTCHA_STALL_REPLAY_MILLIS - (now - progressAt)
        val runnable = Runnable {
            watchdog = null
            if (revision != currentRevision || currentUrl == "about:blank") return@Runnable
            val observedAt = SystemClock.elapsedRealtime()
            if (observedAt - challengeStartedAt >= CAPTCHA_OUTER_DEADLINE_MILLIS) {
                recordLifecycle(event = "watchdog", revision = revision, reason = "deadline")
                return@Runnable
            }
            if (observedAt - maxOf(challengeStartedAt, lastMeaningfulProgress) < CAPTCHA_STALL_REPLAY_MILLIS) {
                recordLifecycle(event = "watchdog", revision = revision, reason = "progress")
                scheduleWatchdog(revision)
                return@Runnable
            }
            replayCurrentChallenge("stall")
        }
        watchdog = runnable
        val waitMillis = minOf(maxOf(0L, stallRemaining), deadlineRemaining)
        recordLifecycle(event = "watchdog", revision = revision, reason = "scheduled", waitMillis = waitMillis)
        mainHandler.postDelayed(runnable, waitMillis)
    }

    private fun cancelWatchdog() {
        watchdog?.let(mainHandler::removeCallbacks)
        watchdog = null
    }

    private fun replayCurrentChallenge(reason: String) {
        check(Looper.myLooper() == Looper.getMainLooper()) { "headless captcha replay must run on the main thread" }
        val revision = currentRevision
        val url = currentUrl
        val script = currentAutomationScript
        val context = applicationContext
        if (url == "about:blank" || script.isEmpty() || context == null) {
            recordLifecycle(event = "replay", revision = revision, reason = "no_active")
            return
        }
        recordLifecycle(event = "replay", revision = revision, reason = reason)
        if (replayCount >= MAX_REPLAYS_PER_REVISION) {
            recordLifecycle(event = "replay", revision = revision, reason = "exhausted")
            return
        }
        if (SystemClock.elapsedRealtime() - challengeStartedAt >= CAPTCHA_OUTER_DEADLINE_MILLIS) {
            recordLifecycle(event = "replay", revision = revision, reason = "deadline")
            return
        }

        replayCount++
        lastMeaningfulProgress = SystemClock.elapsedRealtime()
        cancelWatchdog()
        webView?.stopLoading()
        webView?.destroy()
        webView = null
        currentRunner = runnerSequence.incrementAndGet()
        val target = create(context, revision, currentRunner).also { webView = it }
        target.onResume()
        recordLifecycle(event = "replay", revision = revision, reason = "started")
        target.loadUrl(url)
        scheduleWatchdog(revision)
    }

    private fun handleAutomationEvent(revision: Long, runner: Long, message: String) {
        if (revision != currentRevision || runner != currentRunner || currentUrl == "about:blank") {
            recordLifecycle(event = "stale", revision = revision, runner = runner, reason = "automation")
            return
        }
        val event = message.takeIf(allowedEvents::contains) ?: "unknown"
        recordLifecycle(event = "automation", revision = revision, runner = runner, reason = event)
        if (event == "autoclick-retry") {
            // The canonical JS driver is allowed one page reload. Count it in
            // the same host-level budget so native recovery cannot add a
            // second replay for this challenge revision.
            replayCount = MAX_REPLAYS_PER_REVISION
            lastMeaningfulProgress = SystemClock.elapsedRealtime()
            scheduleWatchdog(revision)
        }
        if (event in meaningfulProgressEvents) {
            lastMeaningfulProgress = SystemClock.elapsedRealtime()
            if (event == "callback-response-accepted") {
                cancelWatchdog()
            } else {
                scheduleWatchdog(revision)
            }
        }
    }

    private fun validateUrl(rawUrl: String) {
        val uri = Uri.parse(rawUrl)
        require(uri.scheme == "http" && uri.host == "127.0.0.1" && uri.port in 1..65535) {
            "headless captcha URL must use an IPv4 loopback HTTP origin"
        }
    }

    private fun recordLifecycle(
        event: String,
        revision: Long = currentRevision,
        runner: Long = currentRunner,
        reason: String = "none",
        code: Int = 0,
        waitMillis: Long = 0L,
    ) {
        val safeEvent = event.takeIf(allowedLifecycleEvents::contains) ?: "stale"
        val safeReason = reason.takeIf(allowedReasons::contains) ?: "unknown"
        val elapsedMillis = if (challengeStartedAt > 0L) {
            maxOf(0L, SystemClock.elapsedRealtime() - challengeStartedAt)
        } else {
            0L
        }
        val line = "MARTEN_CAPTCHA_LIFECYCLE component=android event=$safeEvent " +
            "revision=${maxOf(0L, revision)} runner=${maxOf(0L, runner)} replay=${maxOf(0, replayCount)} " +
            "elapsed_ms=$elapsedMillis reason=$safeReason code=$code wait_ms=${maxOf(0L, waitMillis)}"
        Log.i(TAG, line)
        persistDiagnosticLine(line)
    }

    private fun persistDiagnosticLine(line: String) {
        val directory = diagnosticsDirectory ?: return
        diagnosticsExecutor.execute {
            runCatching {
                if (!directory.exists()) directory.mkdirs()
                val current = File(directory, CAPTCHA_LOG_NAME)
                val archived = File(directory, CAPTCHA_OLD_LOG_NAME)
                val encoded = "$line\n".toByteArray(Charsets.UTF_8)
                if (current.exists() && current.length() + encoded.size > MAX_CAPTCHA_LOG_BYTES) {
                    rotate(current, archived)
                }
                current.appendBytes(encoded)
            }
        }
    }

    private fun rotate(current: File, archived: File) {
        if (archived.exists()) archived.delete()
        if (!current.renameTo(archived)) {
            current.copyTo(archived, overwrite = true)
            current.writeBytes(byteArrayOf())
        }
    }

    private class AutomationEvents(private val revision: Long, private val runner: Long) {
        @JavascriptInterface
        fun postMessage(message: String) {
            mainHandler.post { handleAutomationEvent(revision, runner, message) }
        }
    }
}
