package com.spheres.spheres_app

import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.os.Handler
import android.os.Looper
import android.util.Log
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.embedding.engine.FlutterEngineCache
import io.flutter.embedding.engine.dart.DartExecutor
import io.flutter.plugin.common.MethodChannel

/// The minute a scheduled message or post is due. If the app's engine is
/// alive, Dart is told and runs its sweeps; if not, a headless engine is
/// started with `--scheduled-bg`, the same way a push wake starts one, and
/// the broadcast is kept open until Dart says it is done or half a minute
/// has passed.
class AlarmReceiver : BroadcastReceiver() {
    override fun onReceive(context: Context, intent: Intent) {
        val cached = FlutterEngineCache.getInstance().get(MainActivity.ENGINE_ID)
        if (cached != null) {
            Log.d(TAG, "Alarm: app engine alive, asking Dart to send")
            MethodChannel(cached.dartExecutor.binaryMessenger, CHANNEL).invokeMethod("due", null)
            return
        }
        Log.d(TAG, "Alarm: starting a headless engine")
        val pending = goAsync()
        val engine = FlutterEngine(context.applicationContext)
        var finished = false
        val finish = Runnable {
            if (finished) return@Runnable
            finished = true
            Handler(Looper.getMainLooper()).postDelayed({ engine.destroy() }, 2000)
            pending.finish()
        }
        MethodChannel(engine.dartExecutor.binaryMessenger, CHANNEL).setMethodCallHandler { call, result ->
            when (call.method) {
                "done" -> { result.success(null); finish.run() }
                "exact" -> result.success(Alarms.exactAllowed(context))
                "set" -> result.success(Alarms.set(context, call.argument<Long>("at") ?: 0L))
                "cancel" -> { Alarms.cancel(context); result.success(null) }
                else -> result.notImplemented()
            }
        }
        engine.dartExecutor.executeDartEntrypoint(
            DartExecutor.DartEntrypoint.createDefault(),
            listOf("--scheduled-bg"),
        )
        Handler(Looper.getMainLooper()).postDelayed(finish, 28_000)
    }

    companion object {
        const val TAG = "SpheresAlarm"
        const val CHANNEL = "spheres/alarms"
    }
}
