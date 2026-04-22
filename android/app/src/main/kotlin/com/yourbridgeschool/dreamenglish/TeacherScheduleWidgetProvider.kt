package com.yourbridgeschool.dreamenglish

import android.app.PendingIntent
import android.appwidget.AppWidgetManager
import android.appwidget.AppWidgetProvider
import android.content.ComponentName
import android.content.Context
import android.content.Intent
import android.view.View
import android.widget.RemoteViews
import org.json.JSONArray
import org.json.JSONObject
import java.time.Instant
import java.time.ZoneId
import java.time.format.DateTimeFormatter

class TeacherScheduleWidgetProvider : AppWidgetProvider() {
    companion object {
        private val timeFormatter: DateTimeFormatter = DateTimeFormatter.ofPattern("hh:mm a")
        private val updatedFormatter: DateTimeFormatter = DateTimeFormatter.ofPattern("hh:mm a")

        fun updateAllWidgets(context: Context) {
            val manager = AppWidgetManager.getInstance(context)
            val component = ComponentName(context, TeacherScheduleWidgetProvider::class.java)
            val ids = manager.getAppWidgetIds(component)
            if (ids.isNotEmpty()) {
                onUpdateStatic(context, manager, ids)
            }
        }

        private fun onUpdateStatic(
            context: Context,
            appWidgetManager: AppWidgetManager,
            appWidgetIds: IntArray,
        ) {
            for (appWidgetId in appWidgetIds) {
                appWidgetManager.updateAppWidget(appWidgetId, buildRemoteViews(context))
            }
        }

        private fun buildRemoteViews(context: Context): RemoteViews {
            val views = RemoteViews(context.packageName, R.layout.teacher_schedule_widget)
            val prefs = context.getSharedPreferences(MainActivity.WIDGET_PREFS, Context.MODE_PRIVATE)
            val payload = prefs.getString(MainActivity.KEY_WIDGET_PAYLOAD, "").orEmpty().ifBlank {
                context.getSharedPreferences("FlutterSharedPreferences", Context.MODE_PRIVATE)
                    .getString("flutter.teacher_schedule_widget_payload", "")
                    .orEmpty()
            }
            val data = payload.toWidgetPayload()

            val launchIntent = Intent(context, MainActivity::class.java).apply {
                flags = Intent.FLAG_ACTIVITY_NEW_TASK or
                    Intent.FLAG_ACTIVITY_CLEAR_TOP or
                    Intent.FLAG_ACTIVITY_SINGLE_TOP
                putExtra(MainActivity.EXTRA_OPEN_TEACHER_SCHEDULE, true)
            }
            val pendingIntent = PendingIntent.getActivity(
                context,
                2001,
                launchIntent,
                PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
            )
            views.setOnClickPendingIntent(R.id.widget_root, pendingIntent)

            if (!data.hasSignedInTeacher) {
                views.setTextViewText(R.id.widget_subtitle, context.getString(R.string.widget_open_app_to_load))
                views.setTextViewText(R.id.widget_updated, "")
                bindRows(views, emptyList())
                views.setViewVisibility(R.id.widget_empty_state, View.VISIBLE)
                views.setTextViewText(R.id.widget_empty_state, context.getString(R.string.widget_open_app_to_load))
                return views
            }

            views.setTextViewText(
                R.id.widget_subtitle,
                if (data.teacherName.isBlank()) context.getString(R.string.widget_next_classes)
                else data.teacherName,
            )
            views.setTextViewText(
                R.id.widget_updated,
                if (data.updatedAt == null) ""
                else context.getString(
                    R.string.widget_updated_format,
                    updatedFormatter.format(data.updatedAt.atZone(ZoneId.systemDefault())),
                ),
            )

            if (data.items.isEmpty()) {
                bindRows(views, emptyList())
                views.setViewVisibility(R.id.widget_empty_state, View.VISIBLE)
                views.setTextViewText(R.id.widget_empty_state, context.getString(R.string.widget_no_upcoming_classes))
                return views
            }

            views.setViewVisibility(R.id.widget_empty_state, View.GONE)
            bindRows(views, data.items)
            return views
        }

        private fun bindRows(views: RemoteViews, items: List<WidgetItem>) {
            val rowIds = listOf(R.id.row_1, R.id.row_2, R.id.row_3)
            val timeIds = listOf(R.id.row_1_time, R.id.row_2_time, R.id.row_3_time)
            val titleIds = listOf(R.id.row_1_title, R.id.row_2_title, R.id.row_3_title)
            val badgeIds = listOf(R.id.row_1_badge, R.id.row_2_badge, R.id.row_3_badge)

            for (index in rowIds.indices) {
                val item = items.getOrNull(index)
                if (item == null) {
                    views.setViewVisibility(rowIds[index], View.GONE)
                    continue
                }

                views.setViewVisibility(rowIds[index], View.VISIBLE)
                views.setTextViewText(timeIds[index], item.timeLabel)
                views.setTextViewText(titleIds[index], item.title)
                views.setViewVisibility(badgeIds[index], if (item.isOnline) View.VISIBLE else View.GONE)
            }
        }

        private data class WidgetPayload(
            val teacherName: String,
            val updatedAt: Instant?,
            val hasSignedInTeacher: Boolean,
            val items: List<WidgetItem>,
        )

        private data class WidgetItem(
            val timeLabel: String,
            val title: String,
            val isOnline: Boolean,
        )

        private fun String.toWidgetPayload(): WidgetPayload {
            if (isBlank()) {
                return WidgetPayload(
                    teacherName = "",
                    updatedAt = null,
                    hasSignedInTeacher = false,
                    items = emptyList(),
                )
            }

            return try {
                val root = JSONObject(this)
                val items = mutableListOf<WidgetItem>()
                val rawItems = root.optJSONArray("items") ?: JSONArray()
                for (i in 0 until minOf(rawItems.length(), 3)) {
                    val item = rawItems.optJSONObject(i) ?: continue
                    val start = item.optString("start")
                    val end = item.optString("end")
                    val title = item.optString("title").ifBlank { "Untitled Class" }
                    val isOnline = item.optBoolean("isOnline", false)
                    val label = buildTimeLabel(start, end)
                    items.add(WidgetItem(timeLabel = label, title = title, isOnline = isOnline))
                }

                WidgetPayload(
                    teacherName = root.optString("teacherName"),
                    updatedAt = root.optString("updatedAt").takeIf { it.isNotBlank() }?.let { Instant.parse(it) },
                    hasSignedInTeacher = root.optBoolean("hasSignedInTeacher", false),
                    items = items,
                )
            } catch (_: Exception) {
                WidgetPayload(
                    teacherName = "",
                    updatedAt = null,
                    hasSignedInTeacher = false,
                    items = emptyList(),
                )
            }
        }

        private fun buildTimeLabel(startRaw: String, endRaw: String): String {
            return try {
                val zone = ZoneId.systemDefault()
                val start = Instant.parse(startRaw).atZone(zone)
                val end = Instant.parse(endRaw).atZone(zone)
                "${timeFormatter.format(start)} - ${timeFormatter.format(end)}"
            } catch (_: Exception) {
                "--"
            }
        }
    }

    override fun onUpdate(context: Context, appWidgetManager: AppWidgetManager, appWidgetIds: IntArray) {
        onUpdateStatic(context, appWidgetManager, appWidgetIds)
    }
}
