package com.example.lynxcapacitormodule

import android.Manifest
import android.app.Activity
import android.content.pm.PackageManager
import android.os.Build
import android.util.Log
import androidx.core.content.ContextCompat
import java.lang.ref.WeakReference
import java.util.Locale
import org.json.JSONObject

/** 供宿主或测试记录挂起请求的最小公开模型；真正的 Activity 引用由内部弱引用保存。 */
data class PendingPermission(
    val requestCode: Int,
    val pluginId: String,
    val methodName: String,
    val permissions: List<String>,
    val callback: (JSONObject) -> Unit,
)

/**
 * Android 自有权限协调器。
 *
 * 这个类只负责 Android runtime permission 的声明检查、状态读取和系统回调收口，
 * 不创建 Capacitor Bridge，也不访问联系人、日历、媒体或其它敏感数据。
 */
object NativePermissionCoordinator {
    private const val TAG = "LynxNativeModule"
    private data class PermissionPlan(
        val pluginId: String,
        val fields: LinkedHashMap<String, List<String>>,
        val locationUsesAnyPermission: Boolean = false,
        val photosAcceptLimited: Boolean = false,
    ) {
        val permissions: List<String>
            get() = fields.values.flatten().distinct()
    }

    private data class PendingEntry(
        val pending: PendingPermission,
        val activity: WeakReference<Activity>,
        val plan: PermissionPlan,
    )

    private const val REQUEST_CODE_FIRST = 0x5200
    private const val REQUEST_CODE_LAST = 0x52FF
    private const val REQUEST_HISTORY_PREFS = "lynx-native-permission-history"
    private const val REQUEST_HISTORY_PREFIX = "requested."

    private val lock = Any()
    private val pendingRequests = LinkedHashMap<Int, PendingEntry>()
    /** 只记录本协调器曾经发起过的权限请求，用于区分 prompt 和 denied。 */
    private val requestedPermissionHistory = HashSet<String>()
    private val requestedPermissionCounts = HashMap<String, Int>()
    private var nextRequestCode = REQUEST_CODE_FIRST

    /**
     * 申请指定 plugin 当前能力所需的 Android 权限。
     *
     * 返回 false 表示当前 plugin 不属于本协调器；返回 true 表示请求已被本协调器接管，
     * 包括参数错误、Manifest 缺失和 Activity 失效等结构化错误。
     */
    fun request(
        activity: Activity,
        pluginId: String,
        methodName: String,
        options: JSONObject,
        callback: (JSONObject) -> Unit,
    ): Boolean {
        if (pluginId !in SUPPORTED_PLUGINS) return false

        if (!isUsable(activity)) {
            callback(error("ACTIVITY_UNAVAILABLE", "Activity 已失效，无法申请权限"))
            return true
        }

        val plan = resolvePlan(pluginId, methodName, options).getOrElse { throwable ->
            callback(error("INVALID_ARGUMENT", throwable.message ?: "权限参数无效"))
            return true
        }

        val undeclared = plan.permissions.filterNot { isDeclared(activity, it) }
        if (undeclared.isNotEmpty()) {
            callback(error("PERMISSION_NOT_DECLARED", "宿主 Manifest 未声明所需 Android 权限"))
            return true
        }

        val alreadySatisfied = plan.fields.all { (field, permissions) ->
            fieldSatisfied(activity, plan, field, permissions)
        }
        if (alreadySatisfied) {
            callback(status(activity, plan))
            return true
        }

        val permissionsToRequest = plan.fields
            .filterNot { (field, permissions) -> fieldSatisfied(activity, plan, field, permissions) }
            .values
            .flatten()
            .filterNot { hasPermission(activity, it) }
            .distinct()

        if (permissionsToRequest.isEmpty()) {
            // 例如 Android 14 的图片“有限访问”已满足 photos 能力，但不属于全量授权。
            callback(status(activity, plan))
            return true
        }

        val allocation = synchronized(lock) {
            cleanupCollectedRequestsLocked()
            if (pendingRequests.values.any { it.activity.get() === activity }) {
                Allocation.InProgress
            } else {
                val requestCode = allocateRequestCodeLocked()
                if (requestCode == null) Allocation.Exhausted
                else {
                    val pending = PendingPermission(
                        requestCode = requestCode,
                        pluginId = pluginId,
                        methodName = methodName,
                        permissions = permissionsToRequest,
                        callback = callback,
                    )
                    pendingRequests[requestCode] = PendingEntry(
                        pending = pending,
                        activity = WeakReference(activity),
                        plan = plan,
                    )
                    permissionsToRequest.forEach { permission -> markRequestedLocked(activity, permission) }
                    Allocation.Created(requestCode)
                }
            }
        }

        when (allocation) {
            Allocation.InProgress -> callback(error("PERMISSION_REQUEST_IN_PROGRESS", "当前 Activity 已有权限请求未完成"))
            Allocation.Exhausted -> callback(error("PERMISSION_REQUEST_LIMIT", "权限请求编号暂时耗尽，请稍后重试"))
            is Allocation.Created -> {
                try {
                    activity.requestPermissions(permissionsToRequest.toTypedArray(), allocation.requestCode)
                } catch (throwable: RuntimeException) {
                    val removed = synchronized(lock) { removePendingLocked(allocation.requestCode) }
                    if (removed != null) {
                        callback(error("PERMISSION_REQUEST_FAILED", throwable.message ?: "无法发起系统权限请求"))
                    }
                }
            }
        }
        return true
    }

    /**
     * 收口 Activity 的系统权限回调。
     *
     * 已知 requestCode 会先从 pending 表移除，再调用 callback，因此重复系统回调不会重复完成。
     */
    fun onRequestPermissionsResult(
        requestCode: Int,
        permissions: Array<out String>,
        grantResults: IntArray,
    ): Boolean {
        val entry = synchronized(lock) { removePendingLocked(requestCode) }
        Log.i(TAG, "PERMISSION_RESULT requestCode=$requestCode known=${entry != null} permissions=${permissions.contentToString()} grantResults=${grantResults.contentToString()}")
        entry ?: return false
        val activity = entry.activity.get()
        if (activity == null || !isUsable(activity)) {
            entry.pending.callback(error("ACTIVITY_UNAVAILABLE", "Activity 已失效，无法返回权限状态"))
            return true
        }

        if (permissions.size != grantResults.size) {
            entry.pending.callback(error("INVALID_PERMISSION_RESULT", "系统返回的权限结果长度不一致"))
            return true
        }

        entry.pending.callback(status(activity, entry.plan))
        return true
    }

    /**
     * Activity 销毁时取消仍在系统权限页中的请求，避免旧 Lynx 页面永久占用 pending 槽位。
     * 回调在锁外执行，防止页面回调再次进入权限协调器时形成锁重入链。
     */
    fun release(activity: Activity) {
        val entries = synchronized(lock) {
            pendingRequests.keys
                .toList()
                .filter { requestCode -> pendingRequests[requestCode]?.activity?.get() === activity }
                .mapNotNull { requestCode -> removePendingLocked(requestCode) }
        }
        if (entries.isEmpty()) return
        Log.i(TAG, "PERMISSION_RELEASE count=${entries.size} activity=${activity.javaClass.name}")
        entries.forEach { entry ->
            entry.pending.callback(error("ACTIVITY_DESTROYED", "Activity 已销毁，权限请求已取消"))
        }
    }

    /** 返回当前 plugin 的真实权限状态；不读取联系人、媒体或其它敏感值。 */
    fun check(activity: Activity, pluginId: String, options: JSONObject): JSONObject? {
        if (pluginId !in SUPPORTED_PLUGINS) return null
        if (!isUsable(activity)) return error("ACTIVITY_UNAVAILABLE", "Activity 已失效，无法检查权限")

        val plan = resolvePlan(pluginId, "checkPermissions", options).getOrElse { throwable ->
            return error("INVALID_ARGUMENT", throwable.message ?: "权限参数无效")
        }
        val undeclared = plan.permissions.filterNot { isDeclared(activity, it) }
        if (undeclared.isNotEmpty()) {
            return error("PERMISSION_NOT_DECLARED", "宿主 Manifest 未声明所需 Android 权限")
        }
        return status(activity, plan)
    }

    private sealed interface Allocation {
        data class Created(val requestCode: Int) : Allocation
        data object InProgress : Allocation
        data object Exhausted : Allocation
    }

    private fun resolvePlan(
        pluginId: String,
        methodName: String,
        options: JSONObject,
    ): Result<PermissionPlan> = runCatching {
        when (pluginId) {
            "Camera" -> cameraPlan(methodName, options)
            "Geolocation" -> PermissionPlan(
                pluginId = pluginId,
                fields = linkedMapOf("location" to listOf(
                    Manifest.permission.ACCESS_FINE_LOCATION,
                    Manifest.permission.ACCESS_COARSE_LOCATION,
                )),
                locationUsesAnyPermission = true,
            )
            "Contacts" -> providerPlan(
                pluginId = pluginId,
                methodName = methodName,
                options = options,
                readField = "readContacts",
                writeField = "writeContacts",
                readPermission = Manifest.permission.READ_CONTACTS,
                writePermission = Manifest.permission.WRITE_CONTACTS,
            )
            "Calendar" -> providerPlan(
                pluginId = pluginId,
                methodName = methodName,
                options = options,
                readField = "readCalendar",
                writeField = "writeCalendar",
                readPermission = Manifest.permission.READ_CALENDAR,
                writePermission = Manifest.permission.WRITE_CALENDAR,
            )
            "LocalNotifications", "PushNotifications" -> PermissionPlan(
                pluginId = pluginId,
                fields = linkedMapOf(notificationField(pluginId) to listOf(Manifest.permission.POST_NOTIFICATIONS)),
            )
            "BackgroundRunner" -> PermissionPlan(
                pluginId = pluginId,
                fields = linkedMapOf(
                    "geolocation" to listOf(
                        Manifest.permission.ACCESS_FINE_LOCATION,
                        Manifest.permission.ACCESS_COARSE_LOCATION,
                    ),
                    "notifications" to listOf(Manifest.permission.POST_NOTIFICATIONS),
                ),
                locationUsesAnyPermission = true,
            )
            "Audio" -> PermissionPlan(
                pluginId = pluginId,
                fields = linkedMapOf("audio" to listOf(Manifest.permission.RECORD_AUDIO)),
            )
            else -> error("不支持的权限 plugin")
        }
    }

    private fun cameraPlan(methodName: String, options: JSONObject): PermissionPlan {
        val requested = requestedNames(
            options = options,
            default = when (methodName) {
                "takePhoto" -> listOf("camera")
                "getPhoto" -> when (options.optString("source").uppercase(Locale.US)) {
                    "CAMERA" -> listOf("camera")
                    "PHOTOS" -> listOf("photos")
                    else -> listOf("camera", "photos")
                }
                "pickImages", "chooseFromGallery" -> listOf("photos")
                else -> listOf("camera", "photos")
            },
            accepted = setOf("camera", "photos", "video", "videos"),
        )
        val includeVideos = options.optBoolean("includeVideos", false) ||
            requested.any { it == "video" || it == "videos" }
        val fields = linkedMapOf<String, List<String>>()
        if (requested.contains("camera")) fields["camera"] = listOf(Manifest.permission.CAMERA)
        if (requested.any { it == "photos" || it == "video" || it == "videos" }) {
            fields["photos"] = photoPermissions(includeVideos)
        }
        return PermissionPlan(
            pluginId = "Camera",
            fields = fields,
            photosAcceptLimited = true,
        )
    }

    private fun providerPlan(
        pluginId: String,
        methodName: String,
        options: JSONObject,
        readField: String,
        writeField: String,
        readPermission: String,
        writePermission: String,
    ): PermissionPlan {
        val default = when (methodName) {
            "find", "findEvents", "listCalendars" -> listOf("read")
            "save", "remove", "deleteEvent", "deleteCalendar", "createCalendar", "createEvent" -> listOf("write")
            else -> listOf("read", "write")
        }
        val requested = requestedNames(
            options = options,
            default = default,
            accepted = setOf("read", "write", "contacts", "calendar", readField.lowercase(Locale.US), writeField.lowercase(Locale.US)),
        )
        val fields = linkedMapOf<String, List<String>>()
        if (requested.any { it == "read" || it == "contacts" || it == "calendar" || it == readField.lowercase(Locale.US) }) {
            fields[readField] = listOf(readPermission)
        }
        if (requested.any { it == "write" || it == "contacts" || it == "calendar" || it == writeField.lowercase(Locale.US) }) {
            fields[writeField] = listOf(writePermission)
        }
        return PermissionPlan(pluginId = pluginId, fields = fields)
    }

    private fun requestedNames(
        options: JSONObject,
        default: List<String>,
        accepted: Set<String>,
    ): List<String> {
        val array = options.optJSONArray("permissions")
        val raw = if (array != null) {
            buildList {
                for (index in 0 until array.length()) add(array.optString(index))
            }
        } else if (options.has("permission") && !options.isNull("permission")) {
            listOf(options.optString("permission"))
        } else {
            default
        }
        if (raw.isEmpty()) throw IllegalArgumentException("permissions 不能为空")
        return raw.map { it.trim().lowercase(Locale.US) }
            .also { names ->
                if (names.any { it !in accepted }) {
                    throw IllegalArgumentException("permissions 包含当前 plugin 不支持的权限类型")
                }
            }
            .distinct()
    }

    private fun photoPermissions(includeVideos: Boolean): List<String> = when {
        Build.VERSION.SDK_INT >= 34 -> buildList {
            add(Manifest.permission.READ_MEDIA_IMAGES)
            if (includeVideos) add(Manifest.permission.READ_MEDIA_VIDEO)
            add(Manifest.permission.READ_MEDIA_VISUAL_USER_SELECTED)
        }
        Build.VERSION.SDK_INT >= 33 -> buildList {
            add(Manifest.permission.READ_MEDIA_IMAGES)
            if (includeVideos) add(Manifest.permission.READ_MEDIA_VIDEO)
        }
        else -> listOf(Manifest.permission.READ_EXTERNAL_STORAGE)
    }

    private fun notificationField(pluginId: String): String = when (pluginId) {
        "LocalNotifications" -> "display"
        else -> "receive"
    }

    private fun status(activity: Activity, plan: PermissionPlan): JSONObject = JSONObject().apply {
        plan.fields.forEach { (field, permissions) ->
            put(field, fieldState(activity, plan, field, permissions))
        }
    }

    private fun fieldState(
        activity: Activity,
        plan: PermissionPlan,
        field: String,
        permissions: List<String>,
    ): String {
        if (field == "photos") {
            val fullMediaPermissions = permissions.filterNot {
                it == Manifest.permission.READ_MEDIA_VISUAL_USER_SELECTED
            }
            if (fullMediaPermissions.all { hasPermission(activity, it) }) {
                return "granted"
            }
            if (plan.photosAcceptLimited && Build.VERSION.SDK_INT >= 34 &&
                hasPermission(activity, Manifest.permission.READ_MEDIA_VISUAL_USER_SELECTED)
            ) {
                return "limited"
            }
        }
        if (plan.locationUsesAnyPermission && permissions.any { hasPermission(activity, it) }) return "granted"
        if (permissions.all { hasPermission(activity, it) }) return "granted"
        return if (permissions.any { wasRequested(activity, it) }) "denied" else "prompt"
    }

    private fun fieldSatisfied(
        activity: Activity,
        plan: PermissionPlan,
        field: String,
        permissions: List<String>,
    ): Boolean = when {
        field == "photos" && permissions
            .filterNot { it == Manifest.permission.READ_MEDIA_VISUAL_USER_SELECTED }
            .all { hasPermission(activity, it) } -> true
        field == "photos" && plan.photosAcceptLimited && Build.VERSION.SDK_INT >= 34 ->
            hasPermission(activity, Manifest.permission.READ_MEDIA_VISUAL_USER_SELECTED)
        plan.locationUsesAnyPermission -> permissions.any { hasPermission(activity, it) }
        else -> permissions.all { hasPermission(activity, it) }
    }

    private fun isUsable(activity: Activity?): Boolean = activity != null &&
        !activity.isFinishing && !activity.isDestroyed

    private fun isDeclared(activity: Activity, permission: String): Boolean = runCatching {
        val packageInfo = activity.packageManager.getPackageInfo(
            activity.packageName,
            PackageManager.GET_PERMISSIONS,
        )
        packageInfo.requestedPermissions?.contains(permission) == true
    }.getOrDefault(false)

    private fun hasPermission(activity: Activity, permission: String): Boolean =
        if (permission == Manifest.permission.POST_NOTIFICATIONS && Build.VERSION.SDK_INT < 33) {
            // Android 12 及更低版本没有通知 runtime permission，通知权限由系统默认授予。
            true
        } else {
            ContextCompat.checkSelfPermission(activity, permission) == PackageManager.PERMISSION_GRANTED
        }

    private fun wasRequested(activity: Activity, permission: String): Boolean = synchronized(lock) {
        permission in requestedPermissionHistory || activity.getSharedPreferences(
            REQUEST_HISTORY_PREFS,
            Activity.MODE_PRIVATE,
        ).getBoolean(REQUEST_HISTORY_PREFIX + permission, false)
    }

    private fun allocateRequestCodeLocked(): Int? {
        repeat(REQUEST_CODE_LAST - REQUEST_CODE_FIRST + 1) {
            val candidate = nextRequestCode
            nextRequestCode = if (nextRequestCode == REQUEST_CODE_LAST) REQUEST_CODE_FIRST else nextRequestCode + 1
            if (candidate !in pendingRequests) return candidate
        }
        return null
    }

    private fun markRequestedLocked(activity: Activity, permission: String) {
        requestedPermissionHistory += permission
        requestedPermissionCounts[permission] = requestedPermissionCounts[permission].orZero() + 1
        activity.getSharedPreferences(REQUEST_HISTORY_PREFS, Activity.MODE_PRIVATE)
            .edit()
            .putBoolean(REQUEST_HISTORY_PREFIX + permission, true)
            .apply()
    }

    private fun removePendingLocked(requestCode: Int): PendingEntry? {
        val entry = pendingRequests.remove(requestCode) ?: return null
        entry.pending.permissions.forEach { permission ->
            val next = requestedPermissionCounts[permission].orZero() - 1
            if (next > 0) requestedPermissionCounts[permission] = next else requestedPermissionCounts.remove(permission)
        }
        return entry
    }

    private fun cleanupCollectedRequestsLocked() {
        pendingRequests.keys.toList().forEach { requestCode ->
            if (pendingRequests[requestCode]?.activity?.get() == null) removePendingLocked(requestCode)
        }
    }

    private fun Int?.orZero(): Int = this ?: 0

    private fun error(code: String, message: String): JSONObject = JSONObject()
        .put("error", JSONObject().put("code", code).put("message", message))

    private val SUPPORTED_PLUGINS = setOf(
        "Camera",
        "Geolocation",
        "Contacts",
        "Calendar",
        "LocalNotifications",
        "PushNotifications",
        "BackgroundRunner",
        "Audio",
    )
}
