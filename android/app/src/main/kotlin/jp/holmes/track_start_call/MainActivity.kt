package jp.holmes.track_start_call

import android.app.ActivityManager
import android.graphics.BitmapFactory
import android.os.Build
import android.os.Bundle
import android.view.KeyEvent
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.EventChannel

class MainActivity : FlutterActivity() {
    private var volumeKeyEventSink: EventChannel.EventSink? = null
    private var interceptVolumeKeys = false

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)

        // Set task description icon for recent apps
        val icon = BitmapFactory.decodeResource(resources, R.mipmap.ic_launcher)
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.P) {
            setTaskDescription(ActivityManager.TaskDescription("TRACK STARTER", R.mipmap.ic_launcher))
        } else {
            @Suppress("DEPRECATION")
            setTaskDescription(ActivityManager.TaskDescription("TRACK STARTER", icon))
        }
    }

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        
        // Event channel for volume key events
        EventChannel(flutterEngine.dartExecutor.binaryMessenger, "jp.holmes.track_start_call/volume_keys")
            .setStreamHandler(object : EventChannel.StreamHandler {
                override fun onListen(arguments: Any?, events: EventChannel.EventSink?) {
                    volumeKeyEventSink = events
                    interceptVolumeKeys = true
                }

                override fun onCancel(arguments: Any?) {
                    volumeKeyEventSink = null
                    interceptVolumeKeys = false
                }
            })
    }

    override fun onKeyDown(keyCode: Int, event: KeyEvent?): Boolean {
        if (interceptVolumeKeys) {
            when (keyCode) {
                KeyEvent.KEYCODE_VOLUME_UP -> {
                    volumeKeyEventSink?.success("volume_up")
                    return true // Consume the event - prevents volume change and HUD
                }
                KeyEvent.KEYCODE_VOLUME_DOWN -> {
                    volumeKeyEventSink?.success("volume_down")
                    return true // Consume the event - prevents volume change and HUD
                }
            }
        }
        return super.onKeyDown(keyCode, event)
    }
}
