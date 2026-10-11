package com.spheres.spheres_app

import android.content.ActivityNotFoundException
import android.content.Intent
import android.provider.CalendarContract
import androidx.core.content.FileProvider
import io.flutter.embedding.android.FlutterFragmentActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import java.io.File

// FragmentActivity: required by local_auth for the biometric prompt.
class MainActivity : FlutterFragmentActivity() {
    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        // The device's calendar and share sheet, for events. Nothing here
        // talks to the network; it hands data to apps the user picks.
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "spheres/calendar")
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "insert" -> {
                        val intent = Intent(Intent.ACTION_INSERT)
                            .setData(CalendarContract.Events.CONTENT_URI)
                            .putExtra(CalendarContract.Events.TITLE, call.argument<String>("title"))
                            .putExtra(CalendarContract.Events.EVENT_LOCATION, call.argument<String>("location"))
                            .putExtra(CalendarContract.Events.DESCRIPTION, call.argument<String>("description"))
                        call.argument<Long>("begin")?.let { intent.putExtra(CalendarContract.EXTRA_EVENT_BEGIN_TIME, it) }
                        call.argument<Long>("end")?.let { intent.putExtra(CalendarContract.EXTRA_EVENT_END_TIME, it) }
                        try {
                            startActivity(intent)
                            result.success(null)
                        } catch (e: ActivityNotFoundException) {
                            result.error("no_calendar", "No calendar app on this device", null)
                        }
                    }
                    "shareIcs" -> {
                        try {
                            val dir = File(cacheDir, "ics").apply { mkdirs() }
                            val name = (call.argument<String>("name") ?: "event.ics")
                                .replace(Regex("[^A-Za-z0-9._-]"), "_")
                            val file = File(dir, name)
                            file.writeText(call.argument<String>("contents") ?: "")
                            val uri = FileProvider.getUriForFile(this, "$packageName.spheres.files", file)
                            val send = Intent(Intent.ACTION_SEND)
                                .setType("text/calendar")
                                .putExtra(Intent.EXTRA_STREAM, uri)
                                .addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
                            startActivity(Intent.createChooser(send, "Export event"))
                            result.success(null)
                        } catch (e: Exception) {
                            result.error("share_failed", e.message, null)
                        }
                    }
                    else -> result.notImplemented()
                }
            }
    }
}
