package com.edde746.plezy

import android.app.Activity
import android.content.ActivityNotFoundException
import android.content.Intent
import android.util.Log
import androidx.core.content.FileProvider
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodChannel
import java.io.File

/**
 * Fork-only (wetpas/plezy): hands an update APK that Dart downloaded into `cache/fork_update/`
 * to the system package installer. On first use the installer asks the user to allow installs
 * from this app; it refuses an APK that is not signed with the installed app's key, so only the
 * fork's own builds can replace it.
 */
internal class ForkUpdateChannel(private val activity: Activity) {
  companion object {
    private const val CHANNEL = "com.edde746.plezy/fork_update"
    private const val TAG = "ForkUpdate"
  }

  fun register(messenger: BinaryMessenger) {
    MethodChannel(messenger, CHANNEL).setMethodCallHandler { call, result ->
      when (call.method) {
        "installApk" -> result.success(install(call.argument<String>("path")))
        else -> result.notImplemented()
      }
    }
  }

  private fun install(path: String?): Boolean {
    if (path == null) return false
    val updateDir = File(activity.cacheDir, "fork_update").canonicalFile
    val apk = File(path).canonicalFile
    if (apk.parentFile != updateDir || !apk.isFile || !apk.name.endsWith(".apk")) {
      Log.w(TAG, "Refusing to install $path")
      return false
    }
    return try {
      val uri = FileProvider.getUriForFile(activity, "${activity.packageName}.fileprovider", apk)
      activity.startActivity(
        Intent(Intent.ACTION_VIEW).apply {
          setDataAndType(uri, "application/vnd.android.package-archive")
          addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION or Intent.FLAG_ACTIVITY_NEW_TASK)
        }
      )
      true
    } catch (e: ActivityNotFoundException) {
      Log.w(TAG, "No package installer", e)
      false
    } catch (e: IllegalArgumentException) {
      Log.w(TAG, "APK outside the FileProvider paths", e)
      false
    }
  }
}
