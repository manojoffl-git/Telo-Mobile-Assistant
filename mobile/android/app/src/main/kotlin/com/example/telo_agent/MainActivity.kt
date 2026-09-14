package com.example.telo_agent

import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import android.os.Bundle
import androidx.core.content.ContextCompat
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

/** Flutter is only the LiveKit bridge; accessibility work stays in Android. */
class MainActivity : FlutterActivity() {
    private val channelName = "telo/android"
    private var methodChannel: MethodChannel? = null

    private val screenReceiver = object : BroadcastReceiver() {
        override fun onReceive(context: Context?, intent: Intent?) {
            intent?.getStringExtra("data")?.let { methodChannel?.invokeMethod("accessibilityScreen", it) }
        }
    }
    private val resultReceiver = object : BroadcastReceiver() {
        override fun onReceive(context: Context?, intent: Intent?) {
            intent?.getStringExtra("data")?.let { methodChannel?.invokeMethod("accessibilityActionResult", it) }
        }
    }

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        methodChannel = MethodChannel(flutterEngine.dartExecutor.binaryMessenger, channelName)
        methodChannel?.setMethodCallHandler { call, result ->
            when (call.method) {
                "executeAccessibilityAction" -> {
                    val command = call.argument<String>("command")
                    if (command.isNullOrBlank()) result.error("INVALID_COMMAND", "Action command is empty", null)
                    else { sendAccessibilityCommand(command); result.success(true) }
                }
                "startBackgroundSession" -> { ContextCompat.startForegroundService(this, Intent(this, TeloConnectionService::class.java)); result.success(true) }
                "stopBackgroundSession" -> { stopService(Intent(this, TeloConnectionService::class.java)); result.success(true) }
                else -> result.notImplemented()
            }
        }
        registerReceiver(screenReceiver, IntentFilter(TeloAccessibilityService.ACTION_SCREEN), Context.RECEIVER_NOT_EXPORTED)
        registerReceiver(resultReceiver, IntentFilter(TeloAccessibilityService.ACTION_RESULT), Context.RECEIVER_NOT_EXPORTED)
    }

    private fun sendAccessibilityCommand(command: String) {
        sendBroadcast(Intent(TeloAccessibilityService.ACTION_COMMAND).setPackage(packageName).putExtra("data", command))
    }

    override fun onDestroy() {
        try { unregisterReceiver(screenReceiver) } catch (_: Exception) {}
        try { unregisterReceiver(resultReceiver) } catch (_: Exception) {}
        super.onDestroy()
    }
}
