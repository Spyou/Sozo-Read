package com.spyou.sozo_manga

import android.content.ComponentName
import android.content.pm.PackageManager
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

class MainActivity : FlutterActivity() {
    private val channelName = "sozo_manga/app_icon"

    private val aliases = listOf(
        "com.spyou.sozo_manga.MainActivityRed",
        "com.spyou.sozo_manga.MainActivityBlue",
        "com.spyou.sozo_manga.MainActivityGreen",
        "com.spyou.sozo_manga.MainActivityPurple"
    )

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)

        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, channelName)
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "setIcon" -> {
                        val activeClass = call.argument<String>("activeClass")
                        if (activeClass == null || !aliases.contains(activeClass)) {
                            result.error("BAD_ARG", "Unknown activity alias: $activeClass", null)
                            return@setMethodCallHandler
                        }
                        try {
                            val pm = packageManager
                            for (alias in aliases) {
                                val cn = ComponentName(packageName, alias)
                                val desired = if (alias == activeClass) {
                                    PackageManager.COMPONENT_ENABLED_STATE_ENABLED
                                } else {
                                    PackageManager.COMPONENT_ENABLED_STATE_DISABLED
                                }
                                pm.setComponentEnabledSetting(
                                    cn,
                                    desired,
                                    PackageManager.DONT_KILL_APP
                                )
                            }
                            result.success(true)
                        } catch (e: Exception) {
                            result.error("SET_FAILED", e.message, null)
                        }
                    }
                    else -> result.notImplemented()
                }
            }
    }
}
