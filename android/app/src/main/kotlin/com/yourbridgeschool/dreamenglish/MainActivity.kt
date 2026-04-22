package com.yourbridgeschool.dreamenglish

import android.content.Context
import android.content.Intent
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

class MainActivity : FlutterActivity() {
    companion object {
        const val CHANNEL = "dream_english/widget_bridge"
        const val WIDGET_PREFS = "teacher_schedule_widget"
        const val KEY_WIDGET_PAYLOAD = "teacher_schedule_widget_payload"
        const val KEY_PENDING_LAUNCH_ACTION = "pending_launch_action"
        const val ACTION_TEACHER_SCHEDULE = "teacher_schedule"
        const val EXTRA_OPEN_TEACHER_SCHEDULE = "open_teacher_schedule"
    }

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        captureLaunchIntent(intent)

        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, CHANNEL)
            .setMethodCallHandler { call, result ->
                val prefs = getSharedPreferences(WIDGET_PREFS, Context.MODE_PRIVATE)
                when (call.method) {
                    "saveTeacherScheduleWidgetData" -> {
                        val payload = call.argument<String>("payload").orEmpty()
                        prefs.edit().putString(KEY_WIDGET_PAYLOAD, payload).apply()
                        TeacherScheduleWidgetProvider.updateAllWidgets(this)
                        result.success(null)
                    }

                    "clearTeacherScheduleWidgetData" -> {
                        prefs.edit().remove(KEY_WIDGET_PAYLOAD).apply()
                        TeacherScheduleWidgetProvider.updateAllWidgets(this)
                        result.success(null)
                    }

                    "getPendingLaunchAction" -> {
                        result.success(prefs.getString(KEY_PENDING_LAUNCH_ACTION, ""))
                    }

                    "clearPendingLaunchAction" -> {
                        prefs.edit().remove(KEY_PENDING_LAUNCH_ACTION).apply()
                        result.success(null)
                    }

                    else -> result.notImplemented()
                }
            }
    }

    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        setIntent(intent)
        captureLaunchIntent(intent)
    }

    private fun captureLaunchIntent(intent: Intent?) {
        if (intent?.getBooleanExtra(EXTRA_OPEN_TEACHER_SCHEDULE, false) != true) {
            return
        }
        getSharedPreferences(WIDGET_PREFS, Context.MODE_PRIVATE)
            .edit()
            .putString(KEY_PENDING_LAUNCH_ACTION, ACTION_TEACHER_SCHEDULE)
            .apply()
    }
}
