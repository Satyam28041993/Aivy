package com.example.aivy

import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import java.io.BufferedReader
import java.io.InputStreamReader

class MainActivity : FlutterActivity() {

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, CHANNEL)
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "debugToken" -> result.success(readDebugSecret())
                    else -> result.notImplemented()
                }
            }
    }

    /**
     * The App Check debug secret, or null if it has not been logged yet.
     *
     * The debug provider only ever announces the secret through logcat, which
     * normally means plugging the phone into a computer to read it. An app may
     * read its own log output without any permission, so a sideloaded QA build
     * can recover the secret on the device and show it for registration in the
     * Firebase Console.
     */
    private fun readDebugSecret(): String? {
        return try {
            val process = Runtime.getRuntime()
                .exec(arrayOf("logcat", "-d", "-s", "DebugAppCheckProvider:I"))
            val text = BufferedReader(InputStreamReader(process.inputStream))
                .use { it.readText() }
            // The secret is logged inside a sentence, so match the UUID itself
            // rather than depending on the wording around it.
            UUID_PATTERN.findAll(text).lastOrNull()?.value
        } catch (e: Exception) {
            null
        }
    }

    private companion object {
        const val CHANNEL = "aivy/app_check_debug"
        val UUID_PATTERN =
            Regex("[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}")
    }
}
