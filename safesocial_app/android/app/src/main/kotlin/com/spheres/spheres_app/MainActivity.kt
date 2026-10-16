package com.spheres.spheres_app

import android.app.AlarmManager
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.content.ActivityNotFoundException
import android.content.Context
import android.content.Intent
import android.net.Uri
import android.os.Build
import android.provider.CalendarContract
import android.provider.OpenableColumns
import android.provider.Settings
import android.view.WindowManager
import androidx.core.app.NotificationCompat
import androidx.core.app.NotificationManagerCompat
import androidx.core.app.Person
import androidx.core.content.FileProvider
import androidx.core.content.pm.ShortcutInfoCompat
import androidx.core.content.pm.ShortcutManagerCompat
import androidx.core.graphics.drawable.IconCompat
import io.flutter.embedding.android.FlutterFragmentActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.embedding.engine.FlutterEngineCache
import io.flutter.plugin.common.MethodChannel
import java.io.File

// FragmentActivity: required by local_auth for the biometric prompt.
class MainActivity : FlutterFragmentActivity() {
    private var pendingPick: MethodChannel.Result? = null

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        // The one engine, kept so a chat bubble can attach to it instead of
        // starting a second copy of the app in the same process.
        FlutterEngineCache.getInstance().put(ENGINE_ID, flutterEngine)
        Bubbles.channel = MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "spheres/bubbles")
        Bubbles.channel?.setMethodCallHandler { call, result ->
            when (call.method) {
                "show" -> result.success(
                    Bubbles.show(
                        this,
                        call.argument<String>("chatKey") ?: "",
                        call.argument<String>("name") ?: "Spheres",
                        call.argument<String>("text") ?: "",
                        call.argument<Int>("id") ?: 0,
                    )
                )
                else -> result.notImplemented()
            }
        }
        // The one wake for scheduled sends; see AlarmReceiver and Alarms.
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, AlarmReceiver.CHANNEL)
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "exact" -> result.success(Alarms.exactAllowed(this))
                    "set" -> result.success(Alarms.set(this, call.argument<Long>("at") ?: 0L))
                    "cancel" -> { Alarms.cancel(this); result.success(null) }
                    "settings" -> { Alarms.openSettings(this); result.success(null) }
                    "done" -> result.success(null)
                    else -> result.notImplemented()
                }
            }
        // Protected media: the window refuses screenshots, screen recording
        // and the recents thumbnail while a protected viewer is open. The
        // answer says whether the flag took, so Dart never claims a
        // protection it did not get.
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "spheres/screen")
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "secure" -> {
                        if (call.argument<Boolean>("on") == true) {
                            window.addFlags(WindowManager.LayoutParams.FLAG_SECURE)
                        } else {
                            window.clearFlags(WindowManager.LayoutParams.FLAG_SECURE)
                        }
                        result.success(true)
                    }
                    else -> result.notImplemented()
                }
            }
        // Notes from our side of a call, made on the phone; see CallNotes.
        CallNotes.channel = MethodChannel(flutterEngine.dartExecutor.binaryMessenger, CallNotes.CHANNEL)
        CallNotes.channel?.setMethodCallHandler { call, result ->
            when (call.method) {
                "available" -> result.success(CallNotes.unavailable(this))
                "start" -> {
                    val why = CallNotes.start(this, call.argument<String>("callId") ?: "call")
                    if (why == null) result.success(null) else result.error("unavailable", why, null)
                }
                "stop" -> result.success(CallNotes.stop())
                else -> result.notImplemented()
            }
        }
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
        // Any file in, any file out: the system picker and the system viewer.
        // What is picked is copied into our cache; what is opened is copied
        // out to a folder the viewer may read, and nowhere else.
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "spheres/files")
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "pick" -> {
                        if (pendingPick != null) {
                            result.error("busy", "A picker is already open", null)
                            return@setMethodCallHandler
                        }
                        pendingPick = result
                        val intent = Intent(Intent.ACTION_OPEN_DOCUMENT)
                            .addCategory(Intent.CATEGORY_OPENABLE)
                            .setType("*/*")
                        try {
                            @Suppress("DEPRECATION")
                            startActivityForResult(intent, PICK_FILE)
                        } catch (e: ActivityNotFoundException) {
                            pendingPick = null
                            result.error("no_picker", "No file picker on this device", null)
                        }
                    }
                    "open" -> {
                        try {
                            val src = File(call.argument<String>("path") ?: "")
                            val name = (call.argument<String>("name") ?: src.name)
                                .replace(Regex("[^A-Za-z0-9._-]"), "_")
                            val mime = call.argument<String>("mime") ?: "application/octet-stream"
                            val dir = File(cacheDir, "open").apply { mkdirs() }
                            val copy = File(dir, name)
                            src.inputStream().use { input -> copy.outputStream().use { input.copyTo(it) } }
                            val uri = FileProvider.getUriForFile(this, "$packageName.spheres.files", copy)
                            val view = Intent(Intent.ACTION_VIEW)
                                .setDataAndType(uri, mime)
                                .addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
                            startActivity(Intent.createChooser(view, "Open with"))
                            result.success(null)
                        } catch (e: ActivityNotFoundException) {
                            result.error("no_app", "Nothing on this device opens that type", null)
                        } catch (e: Exception) {
                            result.error("open_failed", e.message, null)
                        }
                    }
                    else -> result.notImplemented()
                }
            }
    }

    @Deprecated("Deprecated in Java")
    override fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?) {
        super.onActivityResult(requestCode, resultCode, data)
        if (requestCode != PICK_FILE) return
        val result = pendingPick ?: return
        pendingPick = null
        val uri = data?.data
        if (resultCode != RESULT_OK || uri == null) {
            result.success(null)
            return
        }
        try {
            var name = "file"
            contentResolver.query(uri, arrayOf(OpenableColumns.DISPLAY_NAME), null, null, null)?.use { c ->
                if (c.moveToFirst()) c.getString(0)?.let { name = it }
            }
            val safe = name.replace(Regex("[^A-Za-z0-9._ -]"), "_").ifEmpty { "file" }
            val dir = File(cacheDir, "picked").apply { mkdirs() }
            val copy = File(dir, "${System.currentTimeMillis()}_$safe")
            contentResolver.openInputStream(uri)!!.use { input -> copy.outputStream().use { input.copyTo(it) } }
            result.success(
                mapOf(
                    "path" to copy.absolutePath,
                    "name" to safe,
                    "mime" to (contentResolver.getType(uri) ?: "application/octet-stream"),
                    "size" to copy.length(),
                )
            )
        } catch (e: Exception) {
            result.error("pick_failed", e.message, null)
        }
    }

    companion object {
        const val ENGINE_ID = "main"
        private const val PICK_FILE = 4101
    }
}

/// Android chat bubbles: a message notification with a bubble that opens
/// [BubbleActivity] on the chat. Returns false whenever the platform will not
/// show one, so the caller posts an ordinary notification instead.
object Bubbles {
    var channel: MethodChannel? = null
    private const val CHANNEL_ID = "chat_bubbles"

    fun show(context: Context, chatKey: String, name: String, text: String, id: Int): Boolean {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.R) return false
        if (chatKey.isEmpty()) return false
        val manager = context.getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
        if (!NotificationManagerCompat.from(context).areNotificationsEnabled()) return false
        val channel = NotificationChannel(CHANNEL_ID, "Chat bubbles", NotificationManager.IMPORTANCE_HIGH).apply {
            description = "Direct messages as bubbles"
            setAllowBubbles(true)
        }
        manager.createNotificationChannel(channel)

        val route = "/chat/$chatKey"
        val target = Intent(context, BubbleActivity::class.java)
            .setAction(Intent.ACTION_VIEW)
            .setData(Uri.parse("spheres://bubble/$chatKey"))
            .putExtra("route", route)
        val person = Person.Builder().setName(name).setKey(chatKey).build()
        val shortcutId = "chat:$chatKey"
        val shortcut = ShortcutInfoCompat.Builder(context, shortcutId)
            .setLongLived(true)
            .setIntent(target)
            .setShortLabel(name)
            .setPerson(person)
            .setIcon(IconCompat.createWithResource(context, R.mipmap.ic_launcher))
            .build()
        ShortcutManagerCompat.pushDynamicShortcut(context, shortcut)

        val pending = PendingIntent.getActivity(
            context, chatKey.hashCode(), target,
            PendingIntent.FLAG_MUTABLE or PendingIntent.FLAG_UPDATE_CURRENT,
        )
        val bubble = NotificationCompat.BubbleMetadata.Builder(pending, IconCompat.createWithResource(context, R.mipmap.ic_launcher))
            .setDesiredHeight(640)
            .setAutoExpandBubble(false)
            .setSuppressNotification(false)
            .build()
        val me = Person.Builder().setName("You").build()
        val style = NotificationCompat.MessagingStyle(me).addMessage(text, System.currentTimeMillis(), person)
        val notification = NotificationCompat.Builder(context, CHANNEL_ID)
            .setSmallIcon(R.mipmap.ic_launcher)
            .setContentTitle(name)
            .setContentText(text)
            .setStyle(style)
            .setCategory(NotificationCompat.CATEGORY_MESSAGE)
            .setShortcutId(shortcutId)
            .setBubbleMetadata(bubble)
            .setContentIntent(pending)
            .setAutoCancel(true)
            .build()
        try {
            NotificationManagerCompat.from(context).notify(id, notification)
        } catch (e: SecurityException) {
            return false
        }
        return true
    }
}

/// One exact alarm for the earliest scheduled send. Exact alarms need the
/// person's say-so on Android 12+; when refused, an inexact alarm is set
/// instead and the answer says so, so the UI never promises the minute.
object Alarms {
    private const val REQUEST = 7301

    private fun pending(context: Context): PendingIntent =
        PendingIntent.getBroadcast(
            context,
            REQUEST,
            Intent(context, AlarmReceiver::class.java),
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
        )

    private fun manager(context: Context) =
        context.getSystemService(Context.ALARM_SERVICE) as AlarmManager

    fun exactAllowed(context: Context): Boolean =
        Build.VERSION.SDK_INT < Build.VERSION_CODES.S || manager(context).canScheduleExactAlarms()

    /** Returns true when the alarm set is exact. */
    fun set(context: Context, atMillis: Long): Boolean {
        val m = manager(context)
        val at = maxOf(atMillis, System.currentTimeMillis() + 1000)
        return if (exactAllowed(context)) {
            m.setExactAndAllowWhileIdle(AlarmManager.RTC_WAKEUP, at, pending(context))
            true
        } else {
            m.setAndAllowWhileIdle(AlarmManager.RTC_WAKEUP, at, pending(context))
            false
        }
    }

    fun cancel(context: Context) = manager(context).cancel(pending(context))

    fun openSettings(context: Context) {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.S) return
        try {
            context.startActivity(
                Intent(Settings.ACTION_REQUEST_SCHEDULE_EXACT_ALARM)
                    .setData(Uri.parse("package:" + context.packageName))
                    .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK),
            )
        } catch (e: ActivityNotFoundException) {
            // Nothing to open on this build; the inexact alarm still stands.
        }
    }
}
