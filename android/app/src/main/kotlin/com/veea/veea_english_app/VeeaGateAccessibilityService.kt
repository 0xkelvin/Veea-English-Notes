package com.veea.veea_english_app

import android.accessibilityservice.AccessibilityService
import android.content.Context
import android.content.Intent
import android.view.accessibility.AccessibilityEvent
import org.json.JSONArray

class VeeaGateAccessibilityService : AccessibilityService() {
    companion object {
        private val KNOWN_PACKAGE_LABELS = mapOf(
            "com.instagram.android" to "Instagram",
            "com.twitter.android" to "X",
            "com.google.android.youtube" to "YouTube",
            "com.zhiliaoapp.musically" to "TikTok",
            "com.ss.android.ugc.trill" to "TikTok",
            "com.reddit.frontpage" to "Reddit",
            "com.instagram.barcelona" to "Threads",
            "com.facebook.katana" to "Facebook",
            "com.facebook.orca" to "Messenger",
            "com.whatsapp" to "WhatsApp",
            "org.telegram.messenger" to "Telegram",
            "com.discord" to "Discord",
            "com.snapchat.android" to "Snapchat",
            "com.netflix.mediaclient" to "Netflix",
            "tv.twitch.android.app" to "Twitch"
        )
    }

    private fun resolveAppLabel(packageName: String): String? {
        KNOWN_PACKAGE_LABELS[packageName]?.let { return it }
        return try {
            val pm = applicationContext.packageManager
            val appInfo = pm.getApplicationInfo(packageName, 0)
            pm.getApplicationLabel(appInfo)?.toString()?.trim()
        } catch (_: Exception) {
            null
        }
    }

    override fun onAccessibilityEvent(event: AccessibilityEvent?) {
        if (event?.eventType != AccessibilityEvent.TYPE_WINDOW_STATE_CHANGED) return
        val pkg = event.packageName?.toString() ?: return
        if (pkg == applicationContext.packageName) return

        val prefs = getSharedPreferences(MainActivity.PREFS_NAME, Context.MODE_PRIVATE)
        if (!prefs.getBoolean("gate_enabled", false)) return

        val rawApps = prefs.getString("gated_apps_json", "[]") ?: "[]"
        val gatedMap = mutableMapOf<String, String>()
        try {
            val arr = JSONArray(rawApps)
            for (i in 0 until arr.length()) {
                val item = arr.getString(i).trim()
                if (item.isNotEmpty()) {
                    gatedMap[item.lowercase()] = item
                }
            }
        } catch (_: Exception) {
            return
        }

        val friendlyLabel = resolveAppLabel(pkg)
        val matchedTarget = when {
            friendlyLabel != null && gatedMap.containsKey(friendlyLabel.lowercase()) ->
                gatedMap[friendlyLabel.lowercase()]
            gatedMap.containsKey(pkg.lowercase()) ->
                gatedMap[pkg.lowercase()]
            else -> null
        } ?: return

        val now = System.currentTimeMillis()
        val unlockedUntil = prefs.getLong("unlocked_until_${matchedTarget.lowercase()}", 0L)
        if (unlockedUntil > now) return

        val launchIntent = Intent(this, MainActivity::class.java).apply {
            addFlags(Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_SINGLE_TOP or Intent.FLAG_ACTIVITY_CLEAR_TOP)
            putExtra(MainActivity.EXTRA_GATE_TARGET, matchedTarget)
        }
        startActivity(launchIntent)
    }

    override fun onInterrupt() {
        // No-op
    }
}
