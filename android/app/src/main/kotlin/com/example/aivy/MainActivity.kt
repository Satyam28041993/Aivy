package com.example.aivy

import android.content.Context
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import java.io.BufferedReader
import java.io.File
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
     * The App Check debug secret, or null if it cannot be found.
     *
     * The debug provider only ever announces the secret through logcat, which
     * normally means plugging the phone into a computer to read it. An app may
     * read its own log output and its own preferences without any permission,
     * so a sideloaded QA build can recover the secret on the device and show it
     * for registration in the Firebase Console.
     */
    private fun readDebugSecret(): String? = fromPreferences() ?: fromLogcat()

    /**
     * Reads the secret the debug provider persisted.
     *
     * Preferred over the log: the log buffer is a ring that rotates, so the
     * announcement is gone on a long-running app, while the stored secret is
     * the same one every launch reuses. The file is named after the Firebase
     * app's persistence key, so match on the prefix rather than rebuilding it.
     */
    private fun fromPreferences(): String? {
        return try {
            val dir = File(applicationInfo.dataDir, "shared_prefs")
            val prefsFile = dir.listFiles()
                ?.firstOrNull { it.name.startsWith(DEBUG_STORE_PREFIX) }
                ?: return null
            getSharedPreferences(prefsFile.name.removeSuffix(".xml"), Context.MODE_PRIVATE)
                .getString(DEBUG_SECRET_KEY, null)
        } catch (e: Exception) {
            null
        }
    }

    private fun fromLogcat(): String? {
        return try {
            // The announcement is logged at debug priority, so an info-level
            // filter never sees it.
            val process = Runtime.getRuntime()
                .exec(arrayOf("logcat", "-d", "DebugAppCheckProvider:D", "*:S"))
            val text = BufferedReader(InputStreamReader(process.inputStream))
                .use { it.readText() }
            // The secret sits inside a sentence, so match the UUID itself rather
            // than depending on the wording around it.
            UUID_PATTERN.findAll(text).lastOrNull()?.value
        } catch (e: Exception) {
            null
        }
    }

    private companion object {
        const val CHANNEL = "aivy/app_check_debug"
        const val DEBUG_STORE_PREFIX = "com.google.firebase.appcheck.debug.store"
        const val DEBUG_SECRET_KEY = "com.google.firebase.appcheck.debug.DEBUG_SECRET"
        val UUID_PATTERN =
            Regex("[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}")
    }
}
