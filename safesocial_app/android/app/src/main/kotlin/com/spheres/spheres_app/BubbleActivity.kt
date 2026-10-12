package com.spheres.spheres_app

import io.flutter.embedding.android.FlutterFragmentActivity
import io.flutter.embedding.engine.FlutterEngineCache

/// The small window a chat bubble opens. It attaches to the app's running
/// engine when there is one, so there is never a second copy of the services
/// in the process; after a cold start it runs the app with the chat as its
/// first route.
class BubbleActivity : FlutterFragmentActivity() {
    override fun getCachedEngineId(): String? =
        if (FlutterEngineCache.getInstance().contains(MainActivity.ENGINE_ID)) MainActivity.ENGINE_ID else null

    override fun shouldDestroyEngineWithHost(): Boolean = false

    override fun getInitialRoute(): String? = intent.getStringExtra("route") ?: super.getInitialRoute()

    override fun onResume() {
        super.onResume()
        // An attached engine ignores the initial route; ask the app to go there.
        intent.getStringExtra("route")?.let { route ->
            Bubbles.channel?.invokeMethod("open", mapOf("route" to route))
        }
    }
}
