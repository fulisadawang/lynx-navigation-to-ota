package com.example.lynxcapacitormodule

import android.Manifest
import android.app.Activity
import android.app.AlarmManager
import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.media.RingtoneManager
import android.net.Uri
import android.os.Build
import android.os.Handler
import android.os.Looper
import android.provider.Settings
import android.util.Log
import androidx.core.app.NotificationCompat
import androidx.core.content.ContextCompat
import java.time.Instant
import java.time.LocalDateTime
import java.time.OffsetDateTime
import java.time.ZoneId
import java.time.ZonedDateTime
import java.time.format.DateTimeFormatter
import java.util.Locale
import org.json.JSONArray
import org.json.JSONObject

/**
 * Android 本地通知的自有实现。
 *
 * AlarmManager 只负责唤醒，Manifest 中的 LocalNotificationRestoreReceiver 负责在进程未运行
 * 时重新进入本 Module。通知数据和 pending/delivered 索引保存在 App 私有 SharedPreferences；
 * 不依赖 Capacitor notification plugin 或第三方推送 SDK。
 */
object NativeLocalNotificationCapabilities {
    private const val TAG = "LynxNativeModule"
    const val ACTION_LOCAL_NOTIFICATION = "com.example.lynxcapacitormodule.LOCAL_NOTIFICATION"
    const val ACTION_NOTIFICATION_CLICK = "com.example.lynxcapacitormodule.LOCAL_NOTIFICATION_CLICK"
    const val EXTRA_NOTIFICATION = "com.example.lynxcapacitormodule.NOTIFICATION"
    const val EXTRA_NOTIFICATION_ID = "com.example.lynxcapacitormodule.NOTIFICATION_ID"
    const val EXTRA_NOTIFICATION_TAG = "com.example.lynxcapacitormodule.NOTIFICATION_TAG"
    const val EXTRA_NOTIFICATION_ACTION_ID = "com.example.lynxcapacitormodule.NOTIFICATION_ACTION_ID"

    private const val PREFS = "lynx-native-local-notifications-v2"
    private const val PENDING_KEY = "pending"
    private const val DELIVERED_KEY = "delivered"
    private const val PENDING_ACTION_KEY = "pendingAction"
    // 独立版本号避免旧版普通 channel 的厂商设置（showBanner=false）继续覆盖新包。
    private const val DEFAULT_CHANNEL_ID = "lynx-native-local-v2"
    private const val DEFAULT_CHANNEL_NAME = "Lynx 本地通知"
    private const val MAX_INDEX_ITEMS = 256

    @Volatile
    private var eventSender: ((String) -> Unit)? = null
    private val mainHandler = Handler(Looper.getMainLooper())
    private var eventContext: Context? = null

    fun setEventSender(context: Context, sender: (String) -> Unit) {
        eventContext = context.applicationContext
        eventSender = sender
        // Bundle 首帧和 ReactLynx useEffect 可能晚于 NativeModule 初始化，等待 listener 建立。
        mainHandler.postDelayed({ flushPendingActions() }, 2000L)
    }

    fun clearEventSender(sender: (String) -> Unit) {
        if (eventSender === sender) {
            eventSender = null
            eventContext = null
        }
    }

    fun dispatch(
        activity: Activity,
        methodName: String,
        options: JSONObject,
        complete: (JSONObject) -> Unit,
    ): Boolean {
        if (methodName !in HANDLED_METHODS) return false
        val result = runCatching {
            when (methodName) {
                "schedule" -> schedule(activity, options)
                "getPending" -> getPending(activity)
                "cancel" -> cancel(activity, options)
                "getDeliveredNotifications" -> getDelivered(activity)
                "createChannel" -> createChannel(activity, options)
                "listChannels" -> listChannels(activity)
                else -> error("UNSUPPORTED", "LocalNotifications.$methodName 未实现")
            }
        }.getOrElse { throwable ->
            if (throwable is SecurityException) error("PERMISSION_DENIED", throwable.message ?: "通知权限不足")
            else error("NATIVE_ERROR", throwable.message ?: "本地通知操作失败")
        }
        complete(result)
        return true
    }

    /** Manifest receiver 的统一入口：开机恢复或到点展示通知。 */
    fun onReceive(context: Context, intent: Intent) {
        when (intent.action) {
            Intent.ACTION_BOOT_COMPLETED,
            Intent.ACTION_LOCKED_BOOT_COMPLETED,
            -> restorePending(context)
            ACTION_LOCAL_NOTIFICATION -> {
                val raw = intent.getStringExtra(EXTRA_NOTIFICATION) ?: return
                val notification = runCatching { JSONObject(raw) }.getOrNull() ?: return
                val id = intValue(notification.opt("id")) ?: return
                val tag = notification.optString("channelId", DEFAULT_CHANNEL_ID)
                if (!showNotification(context, notification, id, tag)) return
                removePending(context, id)
                appendDelivered(context, notification.put("deliveredAt", System.currentTimeMillis()))
                emit(
                    eventName = "localNotificationReceived",
                    data = notification,
                )
            }
        }
    }

    /** MainActivity 复用时接收通知点击，并把 action event 送回当前 Lynx 页面。 */
    fun onNotificationAction(context: Context, intent: Intent) {
        if (intent.action != ACTION_NOTIFICATION_CLICK) return
        val raw = intent.getStringExtra(EXTRA_NOTIFICATION) ?: return
        val notification = runCatching { JSONObject(raw) }.getOrNull() ?: return
        val data = JSONObject()
            .put("actionId", intent.getStringExtra(EXTRA_NOTIFICATION_ACTION_ID) ?: "tap")
            .put("notification", notification)
        writePendingAction(context, data)
        flushPendingActions()
    }

    private fun schedule(activity: Activity, options: JSONObject): JSONObject {
        requireNotificationPermission(activity)?.let { return it }
        val notifications = options.optJSONArray("notifications")
            ?: return error("INVALID_ARGUMENT", "notifications 不能为空")
        if (notifications.length() == 0) return error("INVALID_ARGUMENT", "notifications 不能为空")
        val alarmManager = activity.getSystemService(Context.ALARM_SERVICE) as? AlarmManager
            ?: return error("NO_PROVIDER", "AlarmManager 不可用")
        val manager = activity.getSystemService(Context.NOTIFICATION_SERVICE) as? NotificationManager
            ?: return error("NO_PROVIDER", "NotificationManager 不可用")

        val pending = readIndex(activity, PENDING_KEY)
        val result = JSONArray()
        for (index in 0 until notifications.length()) {
            val notification = notifications.optJSONObject(index)
                ?: return error("INVALID_ARGUMENT", "notifications[$index] 必须是对象")
            val id = intValue(notification.opt("id"))
                ?: return error("INVALID_ARGUMENT", "notifications[$index].id 必须是整数")
            val triggerAt = triggerAt(notification)
                ?: return error("INVALID_ARGUMENT", "notifications[$index].schedule.at/in 无法解析")
            val channelId = notification.optString("channelId", DEFAULT_CHANNEL_ID).ifBlank { DEFAULT_CHANNEL_ID }
            createChannelFromNotification(manager, channelId, notification)
            cancelPendingIntent(activity, id, channelId)
            val alarmIntent = Intent(ACTION_LOCAL_NOTIFICATION)
                .setPackage(activity.packageName)
                .putExtra(EXTRA_NOTIFICATION, notification.toString())
                .putExtra(EXTRA_NOTIFICATION_ID, id)
                .putExtra(EXTRA_NOTIFICATION_TAG, channelId)
            val pendingIntent = PendingIntent.getBroadcast(
                activity,
                requestCode(id, channelId),
                alarmIntent,
                PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
            )
            val exact = Build.VERSION.SDK_INT < Build.VERSION_CODES.S || alarmManager.canScheduleExactAlarms()
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.M) {
                if (exact) alarmManager.setExactAndAllowWhileIdle(AlarmManager.RTC_WAKEUP, triggerAt, pendingIntent)
                else alarmManager.setAndAllowWhileIdle(AlarmManager.RTC_WAKEUP, triggerAt, pendingIntent)
            } else {
                @Suppress("DEPRECATION")
                alarmManager.setExact(AlarmManager.RTC_WAKEUP, triggerAt, pendingIntent)
            }
            pending.removeAll { intValue(it.opt("id")) == id }
            pending += JSONObject(notification.toString())
                .put("triggerAt", triggerAt)
                .put("channelId", channelId)
            result.put(JSONObject().put("id", id).put("triggerAt", triggerAt).put("exact", exact))
        }
        writeIndex(activity, PENDING_KEY, pending)
        return JSONObject()
            .put("notifications", result)
            .put("scheduledBy", "AlarmManager")
            .put("exactAlarm", Build.VERSION.SDK_INT < Build.VERSION_CODES.S || alarmManager.canScheduleExactAlarms())
            .put("deliveryBoundary", "manifest_receiver")
    }

    private fun getPending(activity: Activity): JSONObject {
        val now = System.currentTimeMillis()
        val pending = readIndex(activity, PENDING_KEY)
        val active = pending.filter { it.optLong("triggerAt", 0L) > now }
        if (active.size != pending.size) writeIndex(activity, PENDING_KEY, active)
        val result = JSONArray().apply {
            active.forEach { item -> put(JSONObject(item.toString()).apply { remove("triggerAt"); remove("channelId") }) }
        }
        return JSONObject().put("notifications", result)
    }

    private fun cancel(activity: Activity, options: JSONObject): JSONObject {
        val notifications = options.optJSONArray("notifications")
            ?: return error("INVALID_ARGUMENT", "notifications 不能为空")
        val alarmManager = activity.getSystemService(Context.ALARM_SERVICE) as? AlarmManager
            ?: return error("NO_PROVIDER", "AlarmManager 不可用")
        val manager = activity.getSystemService(Context.NOTIFICATION_SERVICE) as? NotificationManager
            ?: return error("NO_PROVIDER", "NotificationManager 不可用")
        val pending = readIndex(activity, PENDING_KEY)
        val cancelled = JSONArray()
        for (index in 0 until notifications.length()) {
            val value = notifications.optJSONObject(index) ?: continue
            val id = intValue(value.opt("id")) ?: continue
            val channelId = value.optString("channelId", DEFAULT_CHANNEL_ID).ifBlank { DEFAULT_CHANNEL_ID }
            val intent = Intent(ACTION_LOCAL_NOTIFICATION).setPackage(activity.packageName)
            val pendingIntent = PendingIntent.getBroadcast(
                activity,
                requestCode(id, channelId),
                intent,
                PendingIntent.FLAG_NO_CREATE or PendingIntent.FLAG_IMMUTABLE,
            )
            if (pendingIntent != null) {
                alarmManager.cancel(pendingIntent)
                pendingIntent.cancel()
            }
            manager.cancel(channelId, id)
            pending.removeAll { intValue(it.opt("id")) == id }
            cancelled.put(id)
        }
        writeIndex(activity, PENDING_KEY, pending)
        return JSONObject().put("notifications", cancelled)
    }

    private fun getDelivered(activity: Activity): JSONObject {
        val manager = activity.getSystemService(Context.NOTIFICATION_SERVICE) as? NotificationManager
            ?: return error("NO_PROVIDER", "NotificationManager 不可用")
        val activeIds = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.M) {
            manager.activeNotifications.map { it.id to (it.tag ?: DEFAULT_CHANNEL_ID) }.toSet()
        } else {
            emptySet()
        }
        val delivered = readIndex(activity, DELIVERED_KEY)
        val result = JSONArray().apply {
            delivered.forEach { item ->
                val id = intValue(item.opt("id")) ?: return@forEach
                val tag = item.optString("channelId", DEFAULT_CHANNEL_ID)
                if (activeIds.isEmpty() || activeIds.contains(id to tag)) put(stripInternalFields(item))
            }
        }
        return JSONObject().put("notifications", result)
    }

    private fun createChannel(activity: Activity, options: JSONObject): JSONObject {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.O) return JSONObject().put("created", false)
        val channel = options.optJSONObject("channel") ?: options
        val id = channel.optString("id").trim()
        val name = channel.optString("name").trim()
        if (id.isEmpty() || name.isEmpty()) return error("INVALID_ARGUMENT", "channel.id 和 channel.name 不能为空")
        val manager = activity.getSystemService(Context.NOTIFICATION_SERVICE) as? NotificationManager
            ?: return error("NO_PROVIDER", "NotificationManager 不可用")
        createChannelFromNotification(manager, id, channel)
        return JSONObject().put("id", id).put("created", true)
    }

    private fun listChannels(activity: Activity): JSONObject {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.O) return JSONObject().put("channels", JSONArray())
        val manager = activity.getSystemService(Context.NOTIFICATION_SERVICE) as? NotificationManager
            ?: return error("NO_PROVIDER", "NotificationManager 不可用")
        val channels = JSONArray().apply {
            manager.notificationChannels.forEach { channel ->
                put(
                    JSONObject()
                        .put("id", channel.id)
                        .put("name", channel.name)
                        .put("description", channel.description ?: "")
                        .put("importance", channel.importance)
                        .put("blocked", channel.importance == NotificationManager.IMPORTANCE_NONE),
                )
            }
        }
        return JSONObject().put("channels", channels)
    }

    private fun restorePending(context: Context) {
        val alarmManager = context.getSystemService(Context.ALARM_SERVICE) as? AlarmManager ?: return
        val pending = readIndex(context, PENDING_KEY)
        val now = System.currentTimeMillis()
        val active = pending.filter { it.optLong("triggerAt", 0L) > now }
        writeIndex(context, PENDING_KEY, active)
        active.forEach { notification ->
            val id = intValue(notification.opt("id")) ?: return@forEach
            val triggerAt = notification.optLong("triggerAt", 0L)
            val channelId = notification.optString("channelId", DEFAULT_CHANNEL_ID).ifBlank { DEFAULT_CHANNEL_ID }
            val intent = Intent(ACTION_LOCAL_NOTIFICATION)
                .setPackage(context.packageName)
                .putExtra(EXTRA_NOTIFICATION, JSONObject(notification.toString()).apply { remove("triggerAt") }.toString())
            val pendingIntent = PendingIntent.getBroadcast(
                context,
                requestCode(id, channelId),
                intent,
                PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
            )
            val exact = Build.VERSION.SDK_INT < Build.VERSION_CODES.S || alarmManager.canScheduleExactAlarms()
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.M) {
                if (exact) alarmManager.setExactAndAllowWhileIdle(AlarmManager.RTC_WAKEUP, triggerAt, pendingIntent)
                else alarmManager.setAndAllowWhileIdle(AlarmManager.RTC_WAKEUP, triggerAt, pendingIntent)
            } else {
                @Suppress("DEPRECATION")
                alarmManager.setExact(AlarmManager.RTC_WAKEUP, triggerAt, pendingIntent)
            }
        }
    }

    private fun showNotification(context: Context, notification: JSONObject, id: Int, tag: String): Boolean {
        val manager = context.getSystemService(Context.NOTIFICATION_SERVICE) as? NotificationManager ?: return false
        if (!canPostNotifications(context, manager)) {
            Log.w(TAG, "NOTIFICATION_SKIPPED permission_or_channel_disabled id=$id")
            return false
        }
        val channelId = notification.optString("channelId", DEFAULT_CHANNEL_ID).ifBlank { DEFAULT_CHANNEL_ID }
        createChannelFromNotification(manager, channelId, notification)
        val title = notification.optString("title", "")
        val body = notification.optString("body", notification.optString("subtitle", ""))
        val clickIntent = context.packageManager.getLaunchIntentForPackage(context.packageName)?.apply {
            action = ACTION_NOTIFICATION_CLICK
            flags = Intent.FLAG_ACTIVITY_CLEAR_TOP or Intent.FLAG_ACTIVITY_SINGLE_TOP
            putExtra(EXTRA_NOTIFICATION, notification.toString())
            putExtra(EXTRA_NOTIFICATION_ID, id)
            putExtra(EXTRA_NOTIFICATION_TAG, tag)
            putExtra(EXTRA_NOTIFICATION_ACTION_ID, "tap")
        }
        val clickPendingIntent = clickIntent?.let {
            PendingIntent.getActivity(
                context,
                requestCode(id, tag) + 1,
                it,
                PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
            )
        }
        val requestedImportance = notification.optString("importance", "").trim().lowercase(Locale.US)
        val priority = when (requestedImportance) {
            "none" -> NotificationCompat.PRIORITY_MIN
            "low" -> NotificationCompat.PRIORITY_LOW
            "high", "max" -> NotificationCompat.PRIORITY_HIGH
            else -> if (channelId == DEFAULT_CHANNEL_ID) NotificationCompat.PRIORITY_HIGH else NotificationCompat.PRIORITY_DEFAULT
        }
        val builder = NotificationCompat.Builder(context, channelId)
            .setSmallIcon(android.R.drawable.ic_dialog_info)
            .setContentTitle(title)
            .setContentText(body)
            .setAutoCancel(notification.optBoolean("autoCancel", true))
            .setPriority(priority)
        clickPendingIntent?.let(builder::setContentIntent)
        if (notification.optBoolean("silent", false)) builder.setSilent(true)
        if (notification.optString("sound").isNotBlank()) {
            builder.setSound(RingtoneManager.getDefaultUri(RingtoneManager.TYPE_NOTIFICATION))
        }
        return runCatching {
            manager.notify(tag, id, builder.build())
            true
        }.getOrElse { throwable ->
            Log.e(TAG, "NOTIFICATION_FAILED id=$id", throwable)
            false
        }
    }

    private fun canPostNotifications(context: Context, manager: NotificationManager): Boolean {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU &&
            ContextCompat.checkSelfPermission(context, Manifest.permission.POST_NOTIFICATIONS) != PackageManager.PERMISSION_GRANTED
        ) return false
        return Build.VERSION.SDK_INT < Build.VERSION_CODES.N || manager.areNotificationsEnabled()
    }

    private fun createChannelFromNotification(manager: NotificationManager, id: String, source: JSONObject) {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.O) return
        val requestedImportance = source.optString("importance", "").trim().lowercase(Locale.US)
        val fallbackImportance = if (id == DEFAULT_CHANNEL_ID) {
            NotificationManager.IMPORTANCE_HIGH
        } else {
            NotificationManager.IMPORTANCE_DEFAULT
        }
        val importance = when (requestedImportance) {
            "none" -> NotificationManager.IMPORTANCE_NONE
            "low" -> NotificationManager.IMPORTANCE_LOW
            "high" -> NotificationManager.IMPORTANCE_HIGH
            "max" -> NotificationManager.IMPORTANCE_MAX
            "default" -> NotificationManager.IMPORTANCE_DEFAULT
            else -> fallbackImportance
        }
        val channel = NotificationChannel(id, source.optString("name", DEFAULT_CHANNEL_NAME), importance).apply {
            description = source.optString("description", "")
            if (source.optBoolean("lights", false)) enableLights(true)
            if (source.optBoolean("vibrate", true)) enableVibration(true)
        }
        manager.createNotificationChannel(channel)
    }

    private fun requireNotificationPermission(activity: Activity): JSONObject? {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.TIRAMISU ||
            ContextCompat.checkSelfPermission(activity, Manifest.permission.POST_NOTIFICATIONS) == PackageManager.PERMISSION_GRANTED
        ) return null
        return error("PERMISSION_DENIED", "未授予通知权限，请先点击 LocalNotifications.requestPermissions")
    }

    private fun cancelPendingIntent(context: Context, id: Int, tag: String) {
        val intent = Intent(ACTION_LOCAL_NOTIFICATION).setPackage(context.packageName)
        PendingIntent.getBroadcast(
            context,
            requestCode(id, tag),
            intent,
            PendingIntent.FLAG_NO_CREATE or PendingIntent.FLAG_IMMUTABLE,
        )?.let {
            val manager = context.getSystemService(Context.ALARM_SERVICE) as? AlarmManager
            manager?.cancel(it)
            it.cancel()
        }
    }

    private fun requestCode(id: Int, tag: String): Int = 1_000_000 + (id * 31 + tag.hashCode()).and(0x3FFF_FFFF)

    private fun readIndex(context: Context, key: String): MutableList<JSONObject> {
        val raw = context.getSharedPreferences(PREFS, Context.MODE_PRIVATE).getString(key, null) ?: return mutableListOf()
        val result = mutableListOf<JSONObject>()
        runCatching {
            val array = JSONArray(raw)
            for (index in 0 until array.length()) array.optJSONObject(index)?.let { result += JSONObject(it.toString()) }
        }
        return result
    }

    private fun writeIndex(context: Context, key: String, values: List<JSONObject>) {
        val array = JSONArray()
        values.takeLast(MAX_INDEX_ITEMS).forEach { array.put(it) }
        context.getSharedPreferences(PREFS, Context.MODE_PRIVATE).edit().putString(key, array.toString()).apply()
    }

    private fun removePending(context: Context, id: Int) {
        writeIndex(context, PENDING_KEY, readIndex(context, PENDING_KEY).filterNot { intValue(it.opt("id")) == id })
    }

    private fun appendDelivered(context: Context, notification: JSONObject) {
        val delivered = readIndex(context, DELIVERED_KEY)
        val id = intValue(notification.opt("id"))
        delivered.removeAll { intValue(it.opt("id")) == id }
        delivered += JSONObject(notification.toString())
        writeIndex(context, DELIVERED_KEY, delivered)
    }

    private fun writePendingAction(context: Context, data: JSONObject) {
        context.getSharedPreferences(PREFS, Context.MODE_PRIVATE)
            .edit()
            .putString(PENDING_ACTION_KEY, data.toString())
            .apply()
    }

    private fun flushPendingActions() {
        val context = eventContext ?: return
        val sender = eventSender ?: return
        val raw = context.getSharedPreferences(PREFS, Context.MODE_PRIVATE)
            .getString(PENDING_ACTION_KEY, null)
            ?: return
        val data = runCatching { JSONObject(raw) }.getOrNull() ?: run {
            context.getSharedPreferences(PREFS, Context.MODE_PRIVATE).edit().remove(PENDING_ACTION_KEY).apply()
            return
        }
        val event = JSONObject()
            .put("callbackId", "local-notification-${System.nanoTime()}")
            .put("pluginId", "LocalNotifications")
            .put("methodName", "addListener")
            .put("eventName", "localNotificationActionPerformed")
            .put("success", true)
            .put("data", data)
            .put("save", true)
        if (runCatching { sender(event.toString()) }.isSuccess) {
            context.getSharedPreferences(PREFS, Context.MODE_PRIVATE).edit().remove(PENDING_ACTION_KEY).apply()
        }
    }

    private fun stripInternalFields(source: JSONObject): JSONObject = JSONObject(source.toString()).apply {
        remove("triggerAt")
        remove("channelId")
        remove("deliveredAt")
    }

    private fun triggerAt(notification: JSONObject): Long? {
        val schedule = notification.optJSONObject("schedule") ?: return null
        epochMillis(schedule.opt("at"))?.let { return it }
        val seconds = when (val value = schedule.opt("in")) {
            is Number -> value.toDouble()
            is String -> value.toDoubleOrNull()
            else -> null
        } ?: return null
        if (!seconds.isFinite() || seconds < 0) return null
        return System.currentTimeMillis() + (seconds * 1_000.0).toLong()
    }

    private fun epochMillis(value: Any?): Long? = when (value) {
        null, JSONObject.NULL -> null
        is Number -> value.toDouble().takeIf(Double::isFinite)?.toLong()
        is String -> {
            val text = value.trim()
            text.toLongOrNull() ?: runCatching { Instant.parse(text).toEpochMilli() }.getOrNull()
                ?: runCatching { OffsetDateTime.parse(text, DateTimeFormatter.ISO_DATE_TIME).toInstant().toEpochMilli() }.getOrNull()
                ?: runCatching { ZonedDateTime.parse(text, DateTimeFormatter.ISO_DATE_TIME).toInstant().toEpochMilli() }.getOrNull()
                ?: runCatching { LocalDateTime.parse(text, DateTimeFormatter.ISO_DATE_TIME).atZone(ZoneId.systemDefault()).toInstant().toEpochMilli() }.getOrNull()
        }
        else -> null
    }

    private fun intValue(value: Any?): Int? = when (value) {
        is Number -> value.toDouble().takeIf { it.isFinite() && it % 1.0 == 0.0 }?.toInt()
        is String -> value.trim().toIntOrNull()
        else -> null
    }

    private fun emit(eventName: String, data: JSONObject) {
        val event = JSONObject()
            .put("callbackId", "local-notification-${System.nanoTime()}")
            .put("pluginId", "LocalNotifications")
            .put("methodName", "addListener")
            .put("eventName", eventName)
            .put("success", true)
            .put("data", data)
            .put("save", true)
        runCatching { eventSender?.invoke(event.toString()) }
    }

    private fun error(code: String, message: String): JSONObject = JSONObject()
        .put("error", JSONObject().put("code", code).put("message", message))

    private val HANDLED_METHODS = setOf(
        "schedule",
        "getPending",
        "cancel",
        "getDeliveredNotifications",
        "createChannel",
        "listChannels",
    )
}

/** Manifest 入口，确保 AlarmManager/开机恢复不依赖进程内动态 receiver。 */
class LocalNotificationRestoreReceiver : android.content.BroadcastReceiver() {
    override fun onReceive(context: Context, intent: Intent) {
        NativeLocalNotificationCapabilities.onReceive(context, intent)
    }
}
