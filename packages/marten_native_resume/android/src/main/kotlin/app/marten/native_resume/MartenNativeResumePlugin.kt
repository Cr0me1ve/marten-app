package app.marten.native_resume

import android.os.Handler
import android.os.Looper
import io.flutter.embedding.engine.plugins.FlutterPlugin
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import java.io.File
import java.util.concurrent.Executors

class MartenNativeResumePlugin : FlutterPlugin, MethodChannel.MethodCallHandler {
    private var channel: MethodChannel? = null
    private var binding: FlutterPlugin.FlutterPluginBinding? = null

    override fun onAttachedToEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        this.binding = binding
        channel = MethodChannel(binding.binaryMessenger, CHANNEL_NAME).also {
            it.setMethodCallHandler(this)
        }
    }

    override fun onDetachedFromEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        channel?.setMethodCallHandler(null)
        channel = null
        this.binding = null
    }

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        val context = binding?.applicationContext
            ?: return result.error("detached", "native resume bridge is detached", null)

        when (call.method) {
            "loadHeadlessCaptcha" -> {
                val arguments = call.arguments as? Map<*, *>
                    ?: return result.error("invalid_arguments", "missing headless captcha arguments", null)
                val url = arguments["url"] as? String
                    ?: return result.error("invalid_arguments", "missing headless captcha URL", null)
                val automationScript = arguments["automationScript"] as? String
                    ?: return result.error("invalid_arguments", "missing headless captcha automation", null)
                mainHandler.post {
                    runCatching {
                        HeadlessCaptchaWebView.load(context, url, automationScript)
                        true
                    }.onSuccess(result::success).onFailure {
                        result.error("headless_captcha_failed", it.message, null)
                    }
                }
                return
            }

            "clearHeadlessCaptcha" -> {
                mainHandler.post {
                    runCatching {
                        HeadlessCaptchaWebView.clear()
                        true
                    }.onSuccess(result::success).onFailure {
                        result.error("headless_captcha_failed", it.message, null)
                    }
                }
                return
            }
        }

        val operation: () -> Boolean = when (call.method) {
            "store" -> {
                val arguments = call.arguments as? Map<*, *>
                    ?: return result.error("invalid_arguments", "missing native resume arguments", null)
                val path = arguments["path"] as? String
                    ?: return result.error("invalid_arguments", "missing native resume path", null)
                val name = arguments["name"] as? String ?: ""
                { NativeResumeConfigPublisher.store(context, File(path), name); true }
            }

            "clear" -> {
                { NativeResumeConfigPublisher.clear(context); true }
            }

            else -> return result.notImplemented()
        }
        executor.execute {
            val outcome = runCatching(operation)
            mainHandler.post {
                outcome.onSuccess(result::success).onFailure {
                    result.error("native_resume_failed", it.message, null)
                }
            }
        }
    }

    private companion object {
        const val CHANNEL_NAME = "app.marten.client/native_resume"
        val mainHandler = Handler(Looper.getMainLooper())
        val executor = Executors.newSingleThreadExecutor { runnable ->
            Thread(runnable, "marten-native-resume").apply { isDaemon = true }
        }
    }
}
