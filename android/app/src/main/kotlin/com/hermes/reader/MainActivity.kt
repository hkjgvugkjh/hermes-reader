package com.hermes.reader

import android.view.KeyEvent
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

class MainActivity : FlutterActivity() {
    private var methodChannel: MethodChannel? = null
    // When true, volume keys are intercepted for page navigation instead of
    // adjusting system volume. Flutter toggles this when entering/leaving the
    // reader screen so other screens keep normal volume behaviour.
    private var volumePageEnabled = false

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        methodChannel = MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            "hermes/volume"
        )
        methodChannel?.setMethodCallHandler { call, result ->
            when (call.method) {
                "setEnabled" -> {
                    volumePageEnabled = call.argument<Boolean>("enabled") ?: false
                    result.success(null)
                }
                else -> result.notImplemented()
            }
        }
    }

    override fun onKeyDown(keyCode: Int, event: KeyEvent?): Boolean {
        if (volumePageEnabled &&
            (keyCode == KeyEvent.KEYCODE_VOLUME_UP ||
                keyCode == KeyEvent.KEYCODE_VOLUME_DOWN)
        ) {
            val direction = if (keyCode == KeyEvent.KEYCODE_VOLUME_UP) "up" else "down"
            methodChannel?.invokeMethod("volumeKey", direction)
            return true
        }
        return super.onKeyDown(keyCode, event)
    }

    override fun onDestroy() {
        methodChannel?.setMethodCallHandler(null)
        methodChannel = null
        super.onDestroy()
    }
}
