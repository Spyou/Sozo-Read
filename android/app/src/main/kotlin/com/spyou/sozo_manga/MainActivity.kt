package com.spyou.sozo_manga

import android.content.ComponentName
import android.content.pm.PackageManager
import android.view.WindowManager
import io.flutter.embedding.android.FlutterFragmentActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

// FlutterFragmentActivity (NOT FlutterActivity) is required by `local_auth`
// for the biometric prompt — the prompt is hosted in a BiometricFragment
// which only attaches to a FragmentActivity. Using FlutterActivity here
// crashes when the user taps the biometric button.
class MainActivity : FlutterFragmentActivity() {
    private val appIconChannel = "sozo_manga/app_icon"
    private val secureWindowChannel = "sozo/secure_window"

    private val aliases = listOf(
        "com.spyou.sozo_manga.MainActivityRed",
        "com.spyou.sozo_manga.MainActivityBlue",
        "com.spyou.sozo_manga.MainActivityGreen",
        "com.spyou.sozo_manga.MainActivityPurple"
    )

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)

        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, appIconChannel)
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

        // Toggles FLAG_SECURE on the host window. When set, Android blanks
        // the task-switcher preview and prevents screenshots / screen
        // recording. Driven from /settings/security via SecureWindowChannel.
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, secureWindowChannel)
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "setFlagSecure" -> {
                        val enabled = call.argument<Boolean>("enabled") ?: false
                        try {
                            runOnUiThread {
                                if (enabled) {
                                    window.setFlags(
                                        WindowManager.LayoutParams.FLAG_SECURE,
                                        WindowManager.LayoutParams.FLAG_SECURE
                                    )
                                } else {
                                    window.clearFlags(
                                        WindowManager.LayoutParams.FLAG_SECURE
                                    )
                                }
                            }
                            result.success(true)
                        } catch (e: Exception) {
                            result.error("SET_FLAG_SECURE_FAILED", e.message, null)
                        }
                    }
                    else -> result.notImplemented()
                }
            }
    }
}
