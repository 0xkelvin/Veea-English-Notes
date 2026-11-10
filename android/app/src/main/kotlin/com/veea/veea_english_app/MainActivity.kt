package com.veea.veea_english_app

import android.content.Context
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

class MainActivity : FlutterActivity() {
    companion object {
        const val CHANNEL_NAME = "app.veea.english/app_gate"
        const val PREFS_NAME = "veea_app_gate"
        // Retained for the unregistered pre-launch service's source compatibility.
        const val EXTRA_GATE_TARGET = "gate_target_package"
    }

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        // Retire persisted accessibility protection on upgrade. Learning remains local.
        getSharedPreferences(PREFS_NAME, Context.MODE_PRIVATE).edit()
            .putBoolean("gate_enabled", false)
            .remove("gated_apps_json")
            .apply()
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, CHANNEL_NAME)
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "consumePendingGate", "setGateEnabled", "revokePass", "pickAppsToGate" -> result.success(null)
                    "requestPermissions", "launchApp" -> result.success(false)
                    "getInstalledApps" -> result.success(emptyList<String>())
                    "getScreenTimeStatus" -> result.success(mapOf("supported" to false, "available" to false))
                    "grantPass" -> result.error("UNSUPPORTED_GATE", "App protection requires iOS Screen Time.", null)
                    else -> result.notImplemented()
                }
            }
    }
}
