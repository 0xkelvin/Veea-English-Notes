package com.veea.veea_english_app

import android.content.ComponentName
import android.content.Context
import android.content.Intent
import android.os.Bundle
import android.provider.Settings
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import org.json.JSONArray

class MainActivity : FlutterActivity() {
    companion object {
        const val CHANNEL_NAME = "app.veea.english/app_gate"
        const val PREFS_NAME = "veea_app_gate"
        const val EXTRA_GATE_TARGET = "gate_target_package"
    }

    private var appGateChannel: MethodChannel? = null
    private var pendingGateTarget: String? = null

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        extractGateIntent(intent)
    }

    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        setIntent(intent)
        extractGateIntent(intent)
    }

    private fun extractGateIntent(intent: Intent?) {
        val target = intent?.getStringExtra(EXTRA_GATE_TARGET)
        if (!target.isNullOrBlank()) {
            intent.removeExtra(EXTRA_GATE_TARGET)
            if (appGateChannel != null) {
                appGateChannel?.invokeMethod("onGateTriggered", mapOf("targetApp" to target))
            } else {
                pendingGateTarget = target
            }
        }
    }

    private fun isAccessibilityServiceEnabled(): Boolean {
        val expectedComponent = ComponentName(this, VeeaGateAccessibilityService::class.java)
        val enabledServices = Settings.Secure.getString(
            contentResolver,
            Settings.Secure.ENABLED_ACCESSIBILITY_SERVICES
        ) ?: return false
        return enabledServices.split(':').any {
            ComponentName.unflattenFromString(it) == expectedComponent
        }
    }

    private fun queryLaunchableApps(): List<String> {
        return try {
            val mainIntent = Intent(Intent.ACTION_MAIN, null).apply {
                addCategory(Intent.CATEGORY_LAUNCHER)
            }
            val pm = applicationContext.packageManager
            val resolveInfos = pm.queryIntentActivities(mainIntent, 0)
            resolveInfos
                .mapNotNull { info ->
                    val pkg = info.activityInfo?.packageName ?: return@mapNotNull null
                    if (pkg == applicationContext.packageName) return@mapNotNull null
                    val label = info.loadLabel(pm)?.toString()?.trim()
                    if (label.isNullOrEmpty()) null else label
                }
                .distinct()
                .sortedBy { it.lowercase() }
        } catch (_: Exception) {
            emptyList()
        }
    }

    private fun launchInstalledApp(targetApp: String): Boolean {
        return try {
            val normalized = targetApp.trim().lowercase()
            val pm = applicationContext.packageManager
            val mainIntent = Intent(Intent.ACTION_MAIN, null).apply {
                addCategory(Intent.CATEGORY_LAUNCHER)
            }
            val resolveInfos = pm.queryIntentActivities(mainIntent, 0)
            for (info in resolveInfos) {
                val pkg = info.activityInfo?.packageName ?: continue
                val label = info.loadLabel(pm)?.toString()?.trim() ?: ""
                if (pkg.lowercase() == normalized || label.lowercase() == normalized) {
                    val launchIntent = pm.getLaunchIntentForPackage(pkg)
                    if (launchIntent != null) {
                        launchIntent.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
                        startActivity(launchIntent)
                        return true
                    }
                }
            }
            false
        } catch (_: Exception) {
            false
        }
    }

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        val channel = MethodChannel(flutterEngine.dartExecutor.binaryMessenger, CHANNEL_NAME)
        appGateChannel = channel

        channel.setMethodCallHandler { call, result ->
            val prefs = getSharedPreferences(PREFS_NAME, Context.MODE_PRIVATE)
            when (call.method) {
                "requestPermissions" -> {
                    if (!isAccessibilityServiceEnabled()) {
                        try {
                            val settingsIntent = Intent(Settings.ACTION_ACCESSIBILITY_SETTINGS).apply {
                                addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
                            }
                            startActivity(settingsIntent)
                        } catch (_: Exception) {
                        }
                    }
                    result.success(true)
                }

                "getInstalledApps" -> {
                    result.success(queryLaunchableApps())
                }

                "pickAppsToGate" -> {
                    result.success(null)
                }

                "setGateEnabled" -> {
                    val enabled = call.argument<Boolean>("enabled") ?: false
                    val passMinutes = call.argument<Int>("passMinutes") ?: 15
                    val gatedApps = call.argument<List<String>>("gatedApps") ?: emptyList()
                    val jsonArr = JSONArray(gatedApps)
                    prefs.edit()
                        .putBoolean("gate_enabled", enabled)
                        .putInt("pass_minutes", passMinutes)
                        .putString("gated_apps_json", jsonArr.toString())
                        .apply()
                    result.success(null)
                }

                "grantPass" -> {
                    val targetApp = call.argument<String>("targetApp") ?: ""
                    val durationMinutes = call.argument<Int>("durationMinutes") ?: 15
                    val durationMs = if (durationMinutes <= 0) 60_000L else durationMinutes * 60_000L
                    val unlockUntil = System.currentTimeMillis() + durationMs
                    prefs.edit()
                        .putLong("unlocked_until_${targetApp.lowercase()}", unlockUntil)
                        .apply()
                    result.success(null)
                }

                "launchApp" -> {
                    val targetApp = call.argument<String>("targetApp") ?: ""
                    result.success(launchInstalledApp(targetApp))
                }

                else -> result.notImplemented()
            }
        }

        pendingGateTarget?.let { target ->
            pendingGateTarget = null
            channel.invokeMethod("onGateTriggered", mapOf("targetApp" to target))
        }
    }
}
