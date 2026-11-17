package com.example.bpm_metronome

import android.app.Activity
import android.content.Intent
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

class MainActivity : FlutterActivity() {
    private var pendingSave: Pair<ByteArray, MethodChannel.Result>? = null

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        // "Save to…": the system document picker (Downloads, Drive, …), which
        // the share sheet doesn't offer for saving to the phone itself.
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "beth/files")
            .setMethodCallHandler { call, result ->
                if (call.method != "saveFile") {
                    result.notImplemented()
                    return@setMethodCallHandler
                }
                if (pendingSave != null) {
                    result.error("busy", "A save is already in progress", null)
                    return@setMethodCallHandler
                }
                val name = call.argument<String>("name") ?: "backup.json"
                val mimeType = call.argument<String>("mimeType") ?: "application/octet-stream"
                val bytes = call.argument<ByteArray>("bytes") ?: ByteArray(0)
                pendingSave = bytes to result
                val intent = Intent(Intent.ACTION_CREATE_DOCUMENT).apply {
                    addCategory(Intent.CATEGORY_OPENABLE)
                    type = mimeType
                    putExtra(Intent.EXTRA_TITLE, name)
                }
                @Suppress("DEPRECATION")
                startActivityForResult(intent, SAVE_REQUEST)
            }
    }

    @Deprecated("Deprecated in Java")
    override fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?) {
        @Suppress("DEPRECATION")
        super.onActivityResult(requestCode, resultCode, data)
        if (requestCode != SAVE_REQUEST) return
        val (bytes, result) = pendingSave ?: return
        pendingSave = null
        val uri = data?.data
        if (resultCode != Activity.RESULT_OK || uri == null) {
            result.success(false) // cancelled
            return
        }
        try {
            contentResolver.openOutputStream(uri, "wt")!!.use { it.write(bytes) }
            result.success(true)
        } catch (e: Exception) {
            result.error("write_failed", e.message, null)
        }
    }

    companion object {
        private const val SAVE_REQUEST = 4201
    }
}
