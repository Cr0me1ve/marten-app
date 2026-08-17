package app.marten.native_resume

import android.annotation.SuppressLint
import android.content.Context
import android.net.Uri
import android.os.Build
import android.os.Looper
import android.util.Log
import android.webkit.JavascriptInterface
import android.webkit.RenderProcessGoneDetail
import android.webkit.WebView
import android.webkit.WebViewClient

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
    private val allowedEvents = setOf(
        "request-bridge-installed",
        "monitor-installed",
        "driver-installed",
        "checkbox-seen",
        "autoclick-scheduled",
        "checkbox-click",
        "autoclick-fired",
        "check-request-observed",
        "check-response-received",
        "callback-request-observed",
        "callback-response-accepted",
    )

    private var webView: WebView? = null
    private var currentUrl = "about:blank"
    private var currentAutomationScript = ""

    @SuppressLint("SetJavaScriptEnabled", "JavascriptInterface")
    fun load(context: Context, url: String, automationScript: String) {
        check(Looper.myLooper() == Looper.getMainLooper()) { "headless captcha must run on the main thread" }
        validateUrl(url)
        require(automationScript.isNotBlank() && automationScript.length <= MAX_AUTOMATION_SCRIPT_LENGTH) {
            "invalid headless captcha automation"
        }

        currentUrl = url
        currentAutomationScript = automationScript
        val target = webView ?: create(context.applicationContext).also { webView = it }
        target.onResume()
        Log.i(TAG, "phase=load")
        target.loadUrl(url)
    }

    fun clear() {
        check(Looper.myLooper() == Looper.getMainLooper()) { "headless captcha must run on the main thread" }
        currentUrl = "about:blank"
        currentAutomationScript = ""
        webView?.loadUrl("about:blank")
        Log.i(TAG, "phase=clear")
    }

    @SuppressLint("SetJavaScriptEnabled", "JavascriptInterface")
    private fun create(context: Context): WebView = WebView(context).apply {
        settings.javaScriptEnabled = true
        settings.domStorageEnabled = true
        setBackgroundColor(0x00ffffff)
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            setRendererPriorityPolicy(WebView.RENDERER_PRIORITY_IMPORTANT, false)
        }
        addJavascriptInterface(AutomationEvents, "MartenCaptchaAutomation")
        webViewClient = object : WebViewClient() {
            override fun onPageStarted(view: WebView, url: String, favicon: android.graphics.Bitmap?) {
                Log.i(TAG, "phase=page_started")
                inject(view)
            }

            override fun onPageFinished(view: WebView, url: String) {
                Log.i(TAG, "phase=page_finished")
                inject(view)
            }

            override fun onRenderProcessGone(view: WebView, detail: RenderProcessGoneDetail): Boolean {
                Log.w(TAG, "phase=renderer_gone")
                view.destroy()
                if (webView === view) webView = null
                return true
            }
        }
    }

    private fun inject(view: WebView) {
        val script = currentAutomationScript
        if (script.isEmpty() || currentUrl == "about:blank") return
        view.evaluateJavascript(script, null)
    }

    private fun validateUrl(rawUrl: String) {
        val uri = Uri.parse(rawUrl)
        require(uri.scheme == "http" && uri.host == "127.0.0.1" && uri.port in 1..65535) {
            "headless captcha URL must use an IPv4 loopback HTTP origin"
        }
    }

    private object AutomationEvents {
        @JavascriptInterface
        fun postMessage(message: String) {
            val event = message.takeIf(allowedEvents::contains) ?: "unknown"
            Log.i(TAG, "phase=automation event=$event")
        }
    }
}
