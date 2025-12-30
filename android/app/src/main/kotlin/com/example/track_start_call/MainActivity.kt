package com.example.track_start_call

import android.app.ActivityManager
import android.graphics.BitmapFactory
import android.os.Build
import android.os.Bundle
import io.flutter.embedding.android.FlutterActivity

class MainActivity : FlutterActivity() {
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
}
