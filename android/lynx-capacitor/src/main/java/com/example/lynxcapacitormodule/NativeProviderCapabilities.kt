package com.example.lynxcapacitormodule

import android.Manifest
import android.app.Activity
import android.app.AlarmManager
import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.content.BroadcastReceiver
import android.content.ContentUris
import android.content.ContentValues
import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import android.content.pm.PackageManager
import android.graphics.Color
import android.location.Location
import android.location.LocationManager
import android.net.Uri
import android.os.Build
import android.provider.CalendarContract
import android.provider.ContactsContract
import java.time.Instant
import java.time.LocalDateTime
import java.time.OffsetDateTime
import java.time.ZoneId
import java.time.ZonedDateTime
import java.time.format.DateTimeFormatter
import java.util.TimeZone
import org.json.JSONArray
import org.json.JSONObject

/** 直接使用 Android framework provider 的联系人、日历、通知和定位能力。 */
object NativeProviderCapabilities {
    private const val CONTACTS_AUTHORITY = "com.android.contacts"
    private const val CALENDAR_AUTHORITY = "com.android.calendar"
    private const val PERMISSION_PREFS = "lynx-native-provider-permissions"
    private const val NOTIFICATION_PREFS = "lynx-native-local-notifications"
    private const val NOTIFICATION_INDEX = "pending"
    private const val NOTIFICATION_ACTION = "com.example.lynxcapacitormodule.LOCAL_NOTIFICATION"
    private const val NOTIFICATION_CHANNEL_ID = "lynx-native-local"
    private const val GEOLOCATION_REQUEST_CODE = 4101
    private const val LOCAL_NOTIFICATION_REQUEST_CODE = 4102
    private const val PUSH_NOTIFICATION_REQUEST_CODE = 4103

    private var localNotificationReceiverRegistered = false

    /**
     * 只处理本文件负责的能力域；其它 pluginId 返回 null，交给外层 dispatcher 继续处理。
     * 返回值是业务对象或带 error 的结构化错误对象，不添加外层结果包装。
     */
    fun dispatch(activity: Activity, pluginId: String, methodName: String, options: JSONObject): JSONObject? {
        if (pluginId !in SUPPORTED_PLUGINS) return null

        return runCatching {
            when (pluginId) {
                "Geolocation" -> geolocation(activity, methodName)
                "Contacts" -> contacts(activity, methodName, options)
                "Calendar" -> calendar(activity, methodName, options)
                "LocalNotifications" -> localNotifications(activity, methodName, options)
                "PushNotifications" -> pushNotifications(activity, methodName)
                "BackgroundRunner" -> unsupported("BackgroundRunner.$methodName 不在当前 Module 的 framework 能力范围内")
                else -> null
            }
        }.getOrElse { error ->
            when (error) {
                is SecurityException -> error("PERMISSION_DENIED", error.message ?: "Android provider 权限不足")
                else -> error("NATIVE_ERROR", error.message ?: "Android framework 调用失败")
            }
        }
    }

    private val SUPPORTED_PLUGINS = setOf(
        "Geolocation",
        "Contacts",
        "Calendar",
        "LocalNotifications",
        "PushNotifications",
        "BackgroundRunner",
    )

    private fun geolocation(activity: Activity, methodName: String): JSONObject = when (methodName) {
        "checkPermissions" -> JSONObject().put(
            "location",
            locationPermissionState(activity),
        )
        "requestPermissions" -> requestLocationPermissions(activity)
        "getCurrentPosition" -> getCurrentPosition(activity)
        else -> unsupported("Geolocation.$methodName 尚未接入当前 Android Module")
    }

    private fun locationPermissionState(activity: Activity): String {
        val granted = hasPermission(activity, Manifest.permission.ACCESS_FINE_LOCATION) ||
            hasPermission(activity, Manifest.permission.ACCESS_COARSE_LOCATION)
        if (granted) return "granted"
        return if (permissionWasRequested(activity, "location")) "denied" else "prompt"
    }

    private fun requestLocationPermissions(activity: Activity): JSONObject {
        if (hasPermission(activity, Manifest.permission.ACCESS_FINE_LOCATION) ||
            hasPermission(activity, Manifest.permission.ACCESS_COARSE_LOCATION)
        ) {
            return JSONObject().put("location", "granted")
        }

        markPermissionRequested(activity, "location")
        activity.requestPermissions(
            arrayOf(
                Manifest.permission.ACCESS_FINE_LOCATION,
                Manifest.permission.ACCESS_COARSE_LOCATION,
            ),
            GEOLOCATION_REQUEST_CODE,
        )
        return asyncError(
            "ASYNC_PERMISSION_REQUEST",
            "定位权限请求已发起；必须由 Activity 权限回调返回最终状态",
            GEOLOCATION_REQUEST_CODE,
        )
    }

    private fun getCurrentPosition(activity: Activity): JSONObject {
        if (!hasPermission(activity, Manifest.permission.ACCESS_FINE_LOCATION) &&
            !hasPermission(activity, Manifest.permission.ACCESS_COARSE_LOCATION)
        ) {
            return error("PERMISSION_DENIED", "未授予定位权限")
        }

        val manager = activity.getSystemService(Context.LOCATION_SERVICE) as? LocationManager
            ?: return error("NO_PROVIDER", "LocationManager 不可用")
        val providers = buildList {
            if (hasPermission(activity, Manifest.permission.ACCESS_FINE_LOCATION) &&
                manager.isProviderEnabled(LocationManager.GPS_PROVIDER)
            ) add(LocationManager.GPS_PROVIDER)
            if (manager.isProviderEnabled(LocationManager.NETWORK_PROVIDER)) add(LocationManager.NETWORK_PROVIDER)
        }
        if (providers.isEmpty()) return error("NO_PROVIDER", "没有可用的定位 provider")

        val location = providers.asSequence()
            .mapNotNull { provider -> runCatching { manager.getLastKnownLocation(provider) }.getOrNull() }
            .maxByOrNull { it.time }
            ?: return errorWithDetails(
                "NO_LOCATION_FIX",
                "当前没有可用的 Android last-known location；异步位置回调未在本单文件契约中闭合",
                JSONObject().put("asyncRequired", true).put("providers", JSONArray(providers)),
            )
        return locationResult(location)
    }

    private fun locationResult(location: Location): JSONObject = JSONObject()
        .put(
            "coords",
            JSONObject()
                .put("latitude", location.latitude)
                .put("longitude", location.longitude)
                .put("accuracy", location.accuracy.toDouble())
                .put("altitude", if (location.hasAltitude()) location.altitude else JSONObject.NULL)
                .put("altitudeAccuracy", JSONObject.NULL)
                .put("heading", if (location.hasBearing()) location.bearing.toDouble() else JSONObject.NULL)
                .put("speed", if (location.hasSpeed()) location.speed.toDouble() else JSONObject.NULL),
        )
        .put("timestamp", location.time)

    private fun contacts(activity: Activity, methodName: String, options: JSONObject): JSONObject = when (methodName) {
        "save" -> saveContact(activity, options)
        "find" -> findContacts(activity, options)
        "remove" -> removeContact(activity, options)
        else -> unsupported("Contacts.$methodName 尚未接入当前 Android Module")
    }

    private fun saveContact(activity: Activity, options: JSONObject): JSONObject {
        val permissionError = requirePermission(activity, Manifest.permission.WRITE_CONTACTS, "写入联系人")
        if (permissionError != null) return permissionError
        val contact = options.optJSONObject("contact") ?: return error("INVALID_ARGUMENT", "contact 不能为空")
        if (!hasProvider(activity, CONTACTS_AUTHORITY)) return error("NO_PROVIDER", "Contacts provider 不可用")

        val resolver = activity.contentResolver
        val rawContactId = resolver.insert(
            ContactsContract.RawContacts.CONTENT_URI,
            ContentValues().apply {
                putNull(ContactsContract.RawContacts.ACCOUNT_NAME)
                putNull(ContactsContract.RawContacts.ACCOUNT_TYPE)
            },
        )?.lastPathSegment?.toLongOrNull()
            ?: return error("NO_PROVIDER", "Contacts provider 未返回 raw contact id")

        return try {
            insertContactData(resolver, rawContactId, contact)
            val contactId = resolver.query(
                ContactsContract.RawContacts.CONTENT_URI,
                arrayOf(ContactsContract.RawContacts.CONTACT_ID),
                "${ContactsContract.RawContacts._ID}=?",
                arrayOf(rawContactId.toString()),
                null,
            )?.use { cursor ->
                if (cursor.moveToFirst()) cursor.getString(0) else null
            }
            if (contactId.isNullOrEmpty()) {
                resolver.delete(
                    ContactsContract.RawContacts.CONTENT_URI,
                    "${ContactsContract.RawContacts._ID}=?",
                    arrayOf(rawContactId.toString()),
                )
                error("NO_PROVIDER", "Contacts provider 未返回 contact id")
            } else {
                JSONObject().put("id", contactId)
            }
        } catch (exception: SecurityException) {
            error("PERMISSION_DENIED", exception.message ?: "没有联系人写入权限")
        } catch (exception: Exception) {
            runCatching {
                resolver.delete(
                    ContactsContract.RawContacts.CONTENT_URI,
                    "${ContactsContract.RawContacts._ID}=?",
                    arrayOf(rawContactId.toString()),
                )
            }
            error("NATIVE_ERROR", exception.message ?: "保存联系人失败")
        }
    }

    private fun insertContactData(
        resolver: android.content.ContentResolver,
        rawContactId: Long,
        contact: JSONObject,
    ) {
        val name = contact.optJSONObject("name")
        if (name != null) {
            insertData(resolver, rawContactId, ContentValues().apply {
                put(ContactsContract.Data.MIMETYPE, ContactsContract.CommonDataKinds.StructuredName.CONTENT_ITEM_TYPE)
                put(ContactsContract.CommonDataKinds.StructuredName.GIVEN_NAME, name.optString("givenName"))
                put(ContactsContract.CommonDataKinds.StructuredName.FAMILY_NAME, name.optString("familyName"))
                put(ContactsContract.CommonDataKinds.StructuredName.MIDDLE_NAME, name.optString("middleName"))
                put(ContactsContract.CommonDataKinds.StructuredName.PREFIX, name.optString("prefix"))
                put(ContactsContract.CommonDataKinds.StructuredName.SUFFIX, name.optString("suffix"))
            })
        }

        val phones = contact.optJSONArray("phones") ?: contact.optJSONArray("phoneNumbers")
        if (phones != null) for (index in 0 until phones.length()) {
            val phone = phones.optJSONObject(index) ?: continue
            insertData(resolver, rawContactId, ContentValues().apply {
                put(ContactsContract.Data.MIMETYPE, ContactsContract.CommonDataKinds.Phone.CONTENT_ITEM_TYPE)
                put(ContactsContract.CommonDataKinds.Phone.NUMBER, phone.optString("number"))
                put(ContactsContract.CommonDataKinds.Phone.TYPE, phone.optInt("type", ContactsContract.CommonDataKinds.Phone.TYPE_OTHER))
                if (phone.has("label")) put(ContactsContract.CommonDataKinds.Phone.LABEL, phone.optString("label"))
            })
        }

        val emails = contact.optJSONArray("emails") ?: contact.optJSONArray("emailAddresses")
        if (emails != null) for (index in 0 until emails.length()) {
            val email = emails.optJSONObject(index) ?: continue
            insertData(resolver, rawContactId, ContentValues().apply {
                put(ContactsContract.Data.MIMETYPE, ContactsContract.CommonDataKinds.Email.CONTENT_ITEM_TYPE)
                put(ContactsContract.CommonDataKinds.Email.ADDRESS, email.optString("address"))
                put(ContactsContract.CommonDataKinds.Email.TYPE, email.optInt("type", ContactsContract.CommonDataKinds.Email.TYPE_OTHER))
                if (email.has("label")) put(ContactsContract.CommonDataKinds.Email.LABEL, email.optString("label"))
            })
        }

        val organization = contact.optJSONObject("organization")
        if (organization != null) {
            insertData(resolver, rawContactId, ContentValues().apply {
                put(ContactsContract.Data.MIMETYPE, ContactsContract.CommonDataKinds.Organization.CONTENT_ITEM_TYPE)
                put(ContactsContract.CommonDataKinds.Organization.COMPANY, organization.optString("company"))
                put(ContactsContract.CommonDataKinds.Organization.DEPARTMENT, organization.optString("department"))
                put(ContactsContract.CommonDataKinds.Organization.TITLE, organization.optString("jobTitle", organization.optString("title")))
            })
        }

        if (contact.has("note")) {
            insertData(resolver, rawContactId, ContentValues().apply {
                put(ContactsContract.Data.MIMETYPE, ContactsContract.CommonDataKinds.Note.CONTENT_ITEM_TYPE)
                put(ContactsContract.CommonDataKinds.Note.NOTE, contact.optString("note"))
            })
        }
    }

    private fun insertData(
        resolver: android.content.ContentResolver,
        rawContactId: Long,
        values: ContentValues,
    ) {
        values.put(ContactsContract.Data.RAW_CONTACT_ID, rawContactId)
        if (resolver.insert(ContactsContract.Data.CONTENT_URI, values) == null) {
            throw IllegalStateException("Contacts provider 未写入 data row")
        }
    }

    private fun findContacts(activity: Activity, options: JSONObject): JSONObject {
        val permissionError = requirePermission(activity, Manifest.permission.READ_CONTACTS, "读取联系人")
        if (permissionError != null) return permissionError
        if (!hasProvider(activity, CONTACTS_AUTHORITY)) return error("NO_PROVIDER", "Contacts provider 不可用")

        val filter = options.optString("filter").trim()
        val exactId = filter.toLongOrNull()
        val uri = if (exactId == null && filter.isNotEmpty()) {
            Uri.withAppendedPath(ContactsContract.Contacts.CONTENT_FILTER_URI, Uri.encode(filter))
        } else {
            ContactsContract.Contacts.CONTENT_URI
        }
        val selection = if (exactId != null) "${ContactsContract.Contacts._ID}=?" else null
        val selectionArgs = exactId?.let { arrayOf(it.toString()) }
        val multiple = options.optBoolean("multiple", false)
        val requestedFields = stringArray(options.optJSONArray("fields")) +
            stringArray(options.optJSONArray("desiredFields"))
        val includeAll = requestedFields.isEmpty()
        val contacts = JSONArray()

        return try {
            val cursor = activity.contentResolver.query(
                uri,
                arrayOf(ContactsContract.Contacts._ID, ContactsContract.Contacts.DISPLAY_NAME),
                selection,
                selectionArgs,
                "${ContactsContract.Contacts.DISPLAY_NAME} COLLATE LOCALIZED ASC",
            ) ?: return error("NO_PROVIDER", "Contacts provider 查询未返回 cursor")
            cursor.use {
                while (cursor.moveToNext() && (multiple || contacts.length() == 0)) {
                    contacts.put(readContact(activity, cursor, includeAll, requestedFields))
                }
            }
            JSONObject().put("contacts", contacts)
        } catch (exception: SecurityException) {
            error("PERMISSION_DENIED", exception.message ?: "没有联系人读取权限")
        } catch (exception: Exception) {
            error("NO_PROVIDER", exception.message ?: "Contacts provider 查询失败")
        }
    }

    private fun readContact(
        activity: Activity,
        cursor: android.database.Cursor,
        includeAll: Boolean,
        requestedFields: List<String>,
    ): JSONObject {
        val id = cursor.getString(cursor.getColumnIndexOrThrow(ContactsContract.Contacts._ID))
        val displayName = cursor.getString(cursor.getColumnIndexOrThrow(ContactsContract.Contacts.DISPLAY_NAME)) ?: ""
        val result = JSONObject().put("id", id)
        if (includeAll || requestedFields.any { it.equals("displayName", true) }) result.put("displayName", displayName)
        if (includeAll || requestedFields.any { it.equals("name", true) }) {
            result.put("name", readContactName(activity, id))
        }
        if (includeAll || requestedFields.any { it.equals("phones", true) || it.equals("phoneNumbers", true) }) {
            result.put("phones", readPhones(activity, id))
        }
        if (includeAll || requestedFields.any { it.equals("emails", true) || it.equals("emailAddresses", true) }) {
            result.put("emails", readEmails(activity, id))
        }
        if (includeAll || requestedFields.any { it.equals("organization", true) }) {
            result.put("organization", readOrganization(activity, id))
        }
        return result
    }

    private fun readContactName(activity: Activity, contactId: String): JSONObject {
        val result = JSONObject()
        queryContactData(activity, contactId, ContactsContract.CommonDataKinds.StructuredName.CONTENT_ITEM_TYPE) { cursor ->
            putIfNotEmpty(result, "givenName", cursor.string(ContactsContract.CommonDataKinds.StructuredName.GIVEN_NAME))
            putIfNotEmpty(result, "familyName", cursor.string(ContactsContract.CommonDataKinds.StructuredName.FAMILY_NAME))
            putIfNotEmpty(result, "middleName", cursor.string(ContactsContract.CommonDataKinds.StructuredName.MIDDLE_NAME))
            putIfNotEmpty(result, "prefix", cursor.string(ContactsContract.CommonDataKinds.StructuredName.PREFIX))
            putIfNotEmpty(result, "suffix", cursor.string(ContactsContract.CommonDataKinds.StructuredName.SUFFIX))
        }
        return result
    }

    private fun readPhones(activity: Activity, contactId: String): JSONArray {
        val result = JSONArray()
        queryContactData(activity, contactId, ContactsContract.CommonDataKinds.Phone.CONTENT_ITEM_TYPE) { cursor ->
            result.put(JSONObject()
                .put("number", cursor.string(ContactsContract.CommonDataKinds.Phone.NUMBER) ?: "")
                .put("type", cursor.int(ContactsContract.CommonDataKinds.Phone.TYPE))
                .put("label", cursor.string(ContactsContract.CommonDataKinds.Phone.LABEL) ?: JSONObject.NULL))
        }
        return result
    }

    private fun readEmails(activity: Activity, contactId: String): JSONArray {
        val result = JSONArray()
        queryContactData(activity, contactId, ContactsContract.CommonDataKinds.Email.CONTENT_ITEM_TYPE) { cursor ->
            result.put(JSONObject()
                .put("address", cursor.string(ContactsContract.CommonDataKinds.Email.ADDRESS) ?: "")
                .put("type", cursor.int(ContactsContract.CommonDataKinds.Email.TYPE))
                .put("label", cursor.string(ContactsContract.CommonDataKinds.Email.LABEL) ?: JSONObject.NULL))
        }
        return result
    }

    private fun readOrganization(activity: Activity, contactId: String): JSONObject {
        val result = JSONObject()
        queryContactData(activity, contactId, ContactsContract.CommonDataKinds.Organization.CONTENT_ITEM_TYPE) { cursor ->
            putIfNotEmpty(result, "company", cursor.string(ContactsContract.CommonDataKinds.Organization.COMPANY))
            putIfNotEmpty(result, "department", cursor.string(ContactsContract.CommonDataKinds.Organization.DEPARTMENT))
            putIfNotEmpty(result, "jobTitle", cursor.string(ContactsContract.CommonDataKinds.Organization.TITLE))
        }
        return result
    }

    private fun queryContactData(
        activity: Activity,
        contactId: String,
        mimeType: String,
        block: (android.database.Cursor) -> Unit,
    ) {
        activity.contentResolver.query(
            ContactsContract.Data.CONTENT_URI,
            null,
            "${ContactsContract.Data.CONTACT_ID}=? AND ${ContactsContract.Data.MIMETYPE}=?",
            arrayOf(contactId, mimeType),
            null,
        )?.use { cursor ->
            while (cursor.moveToNext()) block(cursor)
        }
    }

    private fun removeContact(activity: Activity, options: JSONObject): JSONObject {
        val permissionError = requirePermission(activity, Manifest.permission.WRITE_CONTACTS, "删除联系人")
        if (permissionError != null) return permissionError
        if (!hasProvider(activity, CONTACTS_AUTHORITY)) return error("NO_PROVIDER", "Contacts provider 不可用")
        val id = options.optString("id").trim()
        if (id.isEmpty()) return error("INVALID_ARGUMENT", "id 不能为空")
        return try {
            val deleted = activity.contentResolver.delete(
                ContactsContract.RawContacts.CONTENT_URI,
                "${ContactsContract.RawContacts.CONTACT_ID}=?",
                arrayOf(id),
            )
            JSONObject().put("removed", deleted > 0)
        } catch (exception: SecurityException) {
            error("PERMISSION_DENIED", exception.message ?: "没有联系人删除权限")
        } catch (exception: Exception) {
            error("NO_PROVIDER", exception.message ?: "Contacts provider 删除失败")
        }
    }

    private fun calendar(activity: Activity, methodName: String, options: JSONObject): JSONObject = when (methodName) {
        "checkPermissions" -> calendarPermissionStatus(activity)
        "listCalendars" -> listCalendars(activity)
        "createCalendar" -> createCalendar(activity, options)
        "createEvent" -> createEvent(activity, options)
        "findEvents" -> findEvents(activity, options)
        "deleteEvent" -> deleteEvent(activity, options)
        "deleteCalendar" -> deleteCalendar(activity, options)
        else -> unsupported("Calendar.$methodName 尚未接入当前 Android Module")
    }

    private fun calendarPermissionStatus(activity: Activity): JSONObject = JSONObject()
        .put("readCalendar", calendarPermissionState(activity, Manifest.permission.READ_CALENDAR, "calendar-read"))
        .put("writeCalendar", calendarPermissionState(activity, Manifest.permission.WRITE_CALENDAR, "calendar-write"))

    private fun calendarPermissionState(activity: Activity, permission: String, key: String): String {
        if (hasPermission(activity, permission)) return "granted"
        return if (permissionWasRequested(activity, key)) "denied" else "prompt"
    }

    private fun listCalendars(activity: Activity): JSONObject {
        val permissionError = requirePermission(activity, Manifest.permission.READ_CALENDAR, "读取日历")
        if (permissionError != null) return permissionError
        if (!hasProvider(activity, CALENDAR_AUTHORITY)) return error("NO_PROVIDER", "Calendar provider 不可用")
        val calendars = JSONArray()
        return try {
            val cursor = activity.contentResolver.query(
                CalendarContract.Calendars.CONTENT_URI,
                arrayOf(
                    CalendarContract.Calendars._ID,
                    CalendarContract.Calendars.NAME,
                    CalendarContract.Calendars.CALENDAR_DISPLAY_NAME,
                    CalendarContract.Calendars.ACCOUNT_NAME,
                    CalendarContract.Calendars.ACCOUNT_TYPE,
                    CalendarContract.Calendars.CALENDAR_COLOR,
                    CalendarContract.Calendars.CALENDAR_ACCESS_LEVEL,
                    CalendarContract.Calendars.VISIBLE,
                ),
                null,
                null,
                "${CalendarContract.Calendars.CALENDAR_DISPLAY_NAME} COLLATE LOCALIZED ASC",
            ) ?: return error("NO_PROVIDER", "Calendar provider 查询未返回 cursor")
            cursor.use {
                while (cursor.moveToNext()) {
                    calendars.put(JSONObject()
                        .put("id", cursor.string(CalendarContract.Calendars._ID) ?: "")
                        .put("name", cursor.string(CalendarContract.Calendars.CALENDAR_DISPLAY_NAME) ?: "")
                        .put("accountName", cursor.string(CalendarContract.Calendars.ACCOUNT_NAME) ?: JSONObject.NULL)
                        .put("accountType", cursor.string(CalendarContract.Calendars.ACCOUNT_TYPE) ?: JSONObject.NULL)
                        .put("color", cursor.intOrNull(CalendarContract.Calendars.CALENDAR_COLOR)?.let { colorToHex(it) } ?: JSONObject.NULL)
                        .put("accessLevel", cursor.intOrNull(CalendarContract.Calendars.CALENDAR_ACCESS_LEVEL) ?: JSONObject.NULL)
                        .put("visible", cursor.intOrNull(CalendarContract.Calendars.VISIBLE)?.let { it != 0 } ?: JSONObject.NULL))
                }
            }
            JSONObject().put("calendars", calendars)
        } catch (exception: SecurityException) {
            error("PERMISSION_DENIED", exception.message ?: "没有日历读取权限")
        } catch (exception: Exception) {
            error("NO_PROVIDER", exception.message ?: "Calendar provider 查询失败")
        }
    }

    private fun createCalendar(activity: Activity, options: JSONObject): JSONObject {
        val permissionError = requirePermission(activity, Manifest.permission.WRITE_CALENDAR, "创建日历")
        if (permissionError != null) return permissionError
        if (!hasProvider(activity, CALENDAR_AUTHORITY)) return error("NO_PROVIDER", "Calendar provider 不可用")
        val name = options.optString("name").trim()
        if (name.isEmpty()) return error("INVALID_ARGUMENT", "name 不能为空")
        val color = options.optString("color").takeIf { it.isNotBlank() }?.let { Color.parseColor(it) }
        return try {
            val id = activity.contentResolver.insert(
                CalendarContract.Calendars.CONTENT_URI.asSyncAdapter(activity.packageName, "com.example.lynx.calendar"),
                ContentValues().apply {
                    put(CalendarContract.Calendars.ACCOUNT_NAME, activity.packageName)
                    put(CalendarContract.Calendars.ACCOUNT_TYPE, "com.example.lynx.calendar")
                    put(CalendarContract.Calendars.NAME, name)
                    put(CalendarContract.Calendars.CALENDAR_DISPLAY_NAME, name)
                    put(CalendarContract.Calendars.OWNER_ACCOUNT, activity.packageName)
                    put(CalendarContract.Calendars.CALENDAR_TIME_ZONE, TimeZone.getDefault().id)
                    put(CalendarContract.Calendars.CALENDAR_ACCESS_LEVEL, CalendarContract.Calendars.CAL_ACCESS_OWNER)
                    put(CalendarContract.Calendars.VISIBLE, 1)
                    put(CalendarContract.Calendars.SYNC_EVENTS, 1)
                    if (color != null) put(CalendarContract.Calendars.CALENDAR_COLOR, color)
                },
            )?.lastPathSegment
            if (id.isNullOrEmpty()) error("NO_PROVIDER", "Calendar provider 未返回 calendar id")
            else JSONObject().put("id", id).put("name", name)
        } catch (exception: SecurityException) {
            error("PERMISSION_DENIED", exception.message ?: "没有日历写入权限")
        } catch (exception: Exception) {
            error("NO_PROVIDER", exception.message ?: "创建日历失败")
        }
    }

    private fun createEvent(activity: Activity, options: JSONObject): JSONObject {
        val permissionError = requirePermission(activity, Manifest.permission.WRITE_CALENDAR, "创建日历事件")
        if (permissionError != null) return permissionError
        if (!hasProvider(activity, CALENDAR_AUTHORITY)) return error("NO_PROVIDER", "Calendar provider 不可用")
        val title = options.optString("title").trim()
        val calendarId = options.optString("calendarId").trim()
        val startDate = epochMillis(options.opt("startDate"))
        val endDate = epochMillis(options.opt("endDate"))
        if (title.isEmpty() || calendarId.isEmpty() || startDate == null || endDate == null) {
            return error("INVALID_ARGUMENT", "title、calendarId、startDate 和 endDate 为必填项")
        }
        if (endDate < startDate) return error("INVALID_ARGUMENT", "endDate 不能早于 startDate")

        return try {
            val eventUri = activity.contentResolver.insert(
                CalendarContract.Events.CONTENT_URI,
                ContentValues().apply {
                    put(CalendarContract.Events.CALENDAR_ID, calendarId.toLongOrNull() ?: return error("INVALID_ARGUMENT", "calendarId 必须是数字"))
                    put(CalendarContract.Events.TITLE, title)
                    put(CalendarContract.Events.DESCRIPTION, options.optString("notes", options.optString("description")))
                    put(CalendarContract.Events.EVENT_LOCATION, options.optString("location"))
                    put(CalendarContract.Events.DTSTART, startDate)
                    put(CalendarContract.Events.DTEND, endDate)
                    put(CalendarContract.Events.EVENT_TIMEZONE, TimeZone.getDefault().id)
                    put(CalendarContract.Events.ALL_DAY, if (options.optBoolean("isAllDay", options.optBoolean("allDay", false))) 1 else 0)
                },
            ) ?: return error("NO_PROVIDER", "Calendar provider 未返回 event uri")
            val eventId = eventUri.lastPathSegment ?: return error("NO_PROVIDER", "Calendar provider 未返回 event id")
            options.optJSONArray("reminders")?.let { reminders ->
                for (index in 0 until reminders.length()) {
                    val reminder = reminders.optJSONObject(index) ?: continue
                    val minutes = reminder.optInt("minutes", -1)
                    if (minutes >= 0) {
                        activity.contentResolver.insert(
                            CalendarContract.Reminders.CONTENT_URI,
                            ContentValues().apply {
                                put(CalendarContract.Reminders.EVENT_ID, eventId.toLongOrNull() ?: 0L)
                                put(CalendarContract.Reminders.MINUTES, minutes)
                                put(CalendarContract.Reminders.METHOD, CalendarContract.Reminders.METHOD_ALERT)
                            },
                        )
                    }
                }
            }
            JSONObject().put("id", eventId)
        } catch (exception: SecurityException) {
            error("PERMISSION_DENIED", exception.message ?: "没有日历写入权限")
        } catch (exception: Exception) {
            error("NO_PROVIDER", exception.message ?: "创建日历事件失败")
        }
    }

    private fun findEvents(activity: Activity, options: JSONObject): JSONObject {
        val permissionError = requirePermission(activity, Manifest.permission.READ_CALENDAR, "读取日历事件")
        if (permissionError != null) return permissionError
        if (!hasProvider(activity, CALENDAR_AUTHORITY)) return error("NO_PROVIDER", "Calendar provider 不可用")
        val now = System.currentTimeMillis()
        val startDate = epochMillis(options.opt("startDate")) ?: now - 86_400_000L
        val endDate = epochMillis(options.opt("endDate")) ?: now + 365L * 86_400_000L
        if (endDate <= startDate) return error("INVALID_ARGUMENT", "endDate 必须晚于 startDate")

        val selectionParts = mutableListOf<String>()
        val selectionArgs = mutableListOf<String>()
        options.optString("title").takeIf { it.isNotBlank() }?.let {
            selectionParts += "${CalendarContract.Instances.TITLE} LIKE ?"
            selectionArgs += "%$it%"
        }
        options.optString("calendarId").takeIf { it.isNotBlank() }?.let {
            selectionParts += "${CalendarContract.Instances.CALENDAR_ID}=?"
            selectionArgs += it
        }
        options.optString("calendarName").takeIf { it.isNotBlank() }?.let {
            selectionParts += "${CalendarContract.Instances.CALENDAR_DISPLAY_NAME}=?"
            selectionArgs += it
        }
        val events = JSONArray()
        return try {
            val uri = CalendarContract.Instances.CONTENT_URI.buildUpon()
                .appendPath(startDate.toString())
                .appendPath(endDate.toString())
                .build()
            val cursor = activity.contentResolver.query(
                uri,
                arrayOf(
                    CalendarContract.Instances.EVENT_ID,
                    CalendarContract.Instances.TITLE,
                    CalendarContract.Instances.DESCRIPTION,
                    CalendarContract.Instances.EVENT_LOCATION,
                    CalendarContract.Instances.BEGIN,
                    CalendarContract.Instances.END,
                    CalendarContract.Instances.ALL_DAY,
                    CalendarContract.Instances.CALENDAR_ID,
                    CalendarContract.Instances.CALENDAR_DISPLAY_NAME,
                ),
                selectionParts.joinToString(" AND ").ifEmpty { null },
                selectionArgs.toTypedArray().takeIf { it.isNotEmpty() },
                "${CalendarContract.Instances.BEGIN} ASC",
            ) ?: return error("NO_PROVIDER", "Calendar provider 查询未返回 cursor")
            cursor.use {
                while (cursor.moveToNext()) {
                    events.put(JSONObject()
                        .put("id", cursor.string(CalendarContract.Instances.EVENT_ID) ?: "")
                        .put("title", cursor.string(CalendarContract.Instances.TITLE) ?: "")
                        .put("notes", cursor.string(CalendarContract.Instances.DESCRIPTION) ?: JSONObject.NULL)
                        .put("location", cursor.string(CalendarContract.Instances.EVENT_LOCATION) ?: JSONObject.NULL)
                        .put("startDate", cursor.longOrNull(CalendarContract.Instances.BEGIN) ?: JSONObject.NULL)
                        .put("endDate", cursor.longOrNull(CalendarContract.Instances.END) ?: JSONObject.NULL)
                        .put("isAllDay", cursor.intOrNull(CalendarContract.Instances.ALL_DAY)?.let { it != 0 } ?: false)
                        .put("calendarId", cursor.string(CalendarContract.Instances.CALENDAR_ID) ?: "")
                        .put("calendarName", cursor.string(CalendarContract.Instances.CALENDAR_DISPLAY_NAME) ?: ""))
                }
            }
            JSONObject().put("events", events)
        } catch (exception: SecurityException) {
            error("PERMISSION_DENIED", exception.message ?: "没有日历读取权限")
        } catch (exception: Exception) {
            error("NO_PROVIDER", exception.message ?: "Calendar provider 查询失败")
        }
    }

    private fun deleteEvent(activity: Activity, options: JSONObject): JSONObject {
        val permissionError = requirePermission(activity, Manifest.permission.WRITE_CALENDAR, "删除日历事件")
        if (permissionError != null) return permissionError
        if (!hasProvider(activity, CALENDAR_AUTHORITY)) return error("NO_PROVIDER", "Calendar provider 不可用")
        val id = options.optString("id").trim()
        if (id.isEmpty()) return error("INVALID_ARGUMENT", "id 不能为空")
        return try {
            val deleted = activity.contentResolver.delete(
                CalendarContract.Events.CONTENT_URI,
                "${CalendarContract.Events._ID}=?",
                arrayOf(id),
            )
            JSONObject().put("deleted", deleted > 0)
        } catch (exception: SecurityException) {
            error("PERMISSION_DENIED", exception.message ?: "没有日历删除权限")
        } catch (exception: Exception) {
            error("NO_PROVIDER", exception.message ?: "删除日历事件失败")
        }
    }

    private fun deleteCalendar(activity: Activity, options: JSONObject): JSONObject {
        val permissionError = requirePermission(activity, Manifest.permission.WRITE_CALENDAR, "删除日历")
        if (permissionError != null) return permissionError
        if (!hasProvider(activity, CALENDAR_AUTHORITY)) return error("NO_PROVIDER", "Calendar provider 不可用")
        val id = options.optString("id").trim()
        val name = options.optString("name").trim()
        if (id.isEmpty() && name.isEmpty()) return error("INVALID_ARGUMENT", "id 或 name 至少需要一个")
        return try {
            val deleted = if (id.isNotEmpty()) {
                activity.contentResolver.delete(
                    ContentUris.withAppendedId(CalendarContract.Calendars.CONTENT_URI, id.toLongOrNull() ?: return error("INVALID_ARGUMENT", "id 必须是数字")),
                    null,
                    null,
                )
            } else {
                activity.contentResolver.delete(
                    CalendarContract.Calendars.CONTENT_URI,
                    "${CalendarContract.Calendars.CALENDAR_DISPLAY_NAME}=?",
                    arrayOf(name),
                )
            }
            JSONObject().put("deleted", deleted > 0)
        } catch (exception: SecurityException) {
            error("PERMISSION_DENIED", exception.message ?: "没有日历删除权限")
        } catch (exception: Exception) {
            error("NO_PROVIDER", exception.message ?: "删除日历失败")
        }
    }

    private fun localNotifications(activity: Activity, methodName: String, options: JSONObject): JSONObject = when (methodName) {
        "checkPermissions" -> notificationPermissionStatus(activity, "display")
        "requestPermissions" -> requestNotificationPermission(activity, LOCAL_NOTIFICATION_REQUEST_CODE, "display")
        "schedule" -> scheduleLocalNotifications(activity, options)
        "getPending" -> getPendingLocalNotifications(activity)
        else -> unsupported("LocalNotifications.$methodName 尚未接入当前 Android Module")
    }

    private fun pushNotifications(activity: Activity, methodName: String): JSONObject = when (methodName) {
        "checkPermissions" -> notificationPermissionStatus(activity, "receive")
        "requestPermissions" -> requestNotificationPermission(activity, PUSH_NOTIFICATION_REQUEST_CODE, "receive")
        "register" -> error("UNSUPPORTED", "Android Push provider 未配置；本 Module 不初始化第三方推送 SDK")
        else -> unsupported("PushNotifications.$methodName 尚未接入当前 Android Module")
    }

    private fun notificationPermissionStatus(activity: Activity, field: String): JSONObject {
        val manager = activity.getSystemService(Context.NOTIFICATION_SERVICE) as? NotificationManager
            ?: return error("NO_PROVIDER", "NotificationManager 不可用")
        val state = if (Build.VERSION.SDK_INT < Build.VERSION_CODES.TIRAMISU ||
            hasPermission(activity, Manifest.permission.POST_NOTIFICATIONS)
        ) {
            if (Build.VERSION.SDK_INT < Build.VERSION_CODES.N || manager.areNotificationsEnabled()) "granted" else "denied"
        } else if (permissionWasRequested(activity, field)) {
            "denied"
        } else {
            "prompt"
        }
        return JSONObject().put(field, state)
    }

    private fun requestNotificationPermission(activity: Activity, requestCode: Int, field: String): JSONObject {
        val manager = activity.getSystemService(Context.NOTIFICATION_SERVICE) as? NotificationManager
            ?: return error("NO_PROVIDER", "NotificationManager 不可用")
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.TIRAMISU ||
            hasPermission(activity, Manifest.permission.POST_NOTIFICATIONS)
        ) {
            return if (Build.VERSION.SDK_INT < Build.VERSION_CODES.N || manager.areNotificationsEnabled()) {
                JSONObject().put(field, "granted")
            } else {
                error("PERMISSION_DENIED", "系统通知已被关闭")
            }
        }
        markPermissionRequested(activity, field)
        activity.requestPermissions(arrayOf(Manifest.permission.POST_NOTIFICATIONS), requestCode)
        return asyncError(
            "ASYNC_PERMISSION_REQUEST",
            "通知权限请求已发起；必须由 Activity 权限回调返回最终状态",
            requestCode,
        )
    }

    private fun scheduleLocalNotifications(activity: Activity, options: JSONObject): JSONObject {
        val permission = notificationPermissionStatus(activity, "display")
        if (permission.has("error")) return permission
        if (permission.optString("display") != "granted") return error("PERMISSION_DENIED", "未授予通知权限")
        val alarmManager = activity.getSystemService(Context.ALARM_SERVICE) as? AlarmManager
            ?: return error("NO_PROVIDER", "AlarmManager 不可用")
        val manager = activity.getSystemService(Context.NOTIFICATION_SERVICE) as? NotificationManager
            ?: return error("NO_PROVIDER", "NotificationManager 不可用")
        val notifications = options.optJSONArray("notifications")
            ?: return error("INVALID_ARGUMENT", "notifications 不能为空")
        if (notifications.length() == 0) return error("INVALID_ARGUMENT", "notifications 不能为空")
        if (!ensureNotificationReceiver(activity.applicationContext)) {
            return error("ASYNC_SCHEDULING_UNAVAILABLE", "无法注册本地通知 receiver；Manifest 未声明 receiver，当前仅允许动态调度")
        }
        val results = JSONArray()
        val pending = readPendingNotifications(activity)
        return try {
            createNotificationChannel(manager)
            for (index in 0 until notifications.length()) {
                val notification = notifications.optJSONObject(index)
                    ?: return error("INVALID_ARGUMENT", "notifications[$index] 必须是对象")
                val id = intValue(notification.opt("id"))
                    ?: return error("INVALID_ARGUMENT", "notifications[$index].id 必须是整数")
                val triggerAt = notificationTriggerAt(notification)
                    ?: return error("INVALID_ARGUMENT", "notifications[$index].schedule.at/in 无法解析")
                val intent = Intent(NOTIFICATION_ACTION).setPackage(activity.packageName)
                    .putExtra("notification", notification.toString())
                val pendingIntent = PendingIntent.getBroadcast(
                    activity,
                    id,
                    intent,
                    PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
                )
                val exact = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) alarmManager.canScheduleExactAlarms() else true
                if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.M) {
                    if (exact) alarmManager.setExactAndAllowWhileIdle(AlarmManager.RTC_WAKEUP, triggerAt, pendingIntent)
                    else alarmManager.setAndAllowWhileIdle(AlarmManager.RTC_WAKEUP, triggerAt, pendingIntent)
                } else {
                    @Suppress("DEPRECATION")
                    alarmManager.setExact(AlarmManager.RTC_WAKEUP, triggerAt, pendingIntent)
                }
                val record = JSONObject(notification.toString()).put("triggerAt", triggerAt)
                pending.removeAll { it.optInt("id", Int.MIN_VALUE) == id }
                pending.add(record)
                results.put(JSONObject().put("id", id).put("triggerAt", triggerAt).put("exact", exact))
            }
            writePendingNotifications(activity, pending)
            JSONObject()
                .put("notifications", results)
                .put("scheduledBy", "AlarmManager")
                .put("deliveryBoundary", "dynamic_receiver_process_alive")
        } catch (exception: SecurityException) {
            error("PERMISSION_DENIED", exception.message ?: "系统拒绝通知调度")
        } catch (exception: Exception) {
            error("NATIVE_ERROR", exception.message ?: "本地通知调度失败")
        }
    }

    private fun getPendingLocalNotifications(activity: Activity): JSONObject {
        val permission = notificationPermissionStatus(activity, "display")
        if (permission.has("error")) return permission
        val now = System.currentTimeMillis()
        val pending = readPendingNotifications(activity)
        val active = pending.filter { it.optLong("triggerAt", 0L) > now }
        if (active.size != pending.size) writePendingNotifications(activity, active)
        val notifications = JSONArray().apply { active.forEach { put(JSONObject(it.toString()).remove("triggerAt")) } }
        return JSONObject().put("notifications", notifications)
    }

    private fun ensureNotificationReceiver(context: Context): Boolean {
        if (localNotificationReceiverRegistered) return true
        return synchronized(this) {
            if (localNotificationReceiverRegistered) {
                true
            } else {
                runCatching {
                    val filter = IntentFilter(NOTIFICATION_ACTION)
                    if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
                        context.registerReceiver(localNotificationReceiver, filter, Context.RECEIVER_NOT_EXPORTED)
                    } else {
                        @Suppress("DEPRECATION")
                        context.registerReceiver(localNotificationReceiver, filter)
                    }
                    localNotificationReceiverRegistered = true
                }.isSuccess
            }
        }
    }

    private val localNotificationReceiver = object : BroadcastReceiver() {
        override fun onReceive(context: Context, intent: Intent) {
            val raw = intent.getStringExtra("notification") ?: return
            val notification = runCatching { JSONObject(raw) }.getOrNull() ?: return
            val id = intValue(notification.opt("id")) ?: return
            val manager = context.getSystemService(Context.NOTIFICATION_SERVICE) as? NotificationManager ?: return
            createNotificationChannel(manager)
            val builder = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                Notification.Builder(context, NOTIFICATION_CHANNEL_ID)
            } else {
                @Suppress("DEPRECATION")
                Notification.Builder(context)
            }
            val title = notification.optString("title", "")
            val body = notification.optString("body", notification.optString("subtitle", ""))
            val shown = builder
                .setSmallIcon(android.R.drawable.ic_dialog_info)
                .setContentTitle(title)
                .setContentText(body)
                .setAutoCancel(true)
                .build()
            manager.notify(id, shown)
            val pending = readPendingNotifications(context).filterNot { it.optInt("id", Int.MIN_VALUE) == id }
            writePendingNotifications(context, pending)
        }
    }

    private fun createNotificationChannel(manager: NotificationManager) {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            manager.createNotificationChannel(
                NotificationChannel(
                    NOTIFICATION_CHANNEL_ID,
                    "Lynx 本地通知",
                    NotificationManager.IMPORTANCE_DEFAULT,
                ),
            )
        }
    }

    private fun readPendingNotifications(context: Context): MutableList<JSONObject> {
        val raw = context.getSharedPreferences(NOTIFICATION_PREFS, Context.MODE_PRIVATE)
            .getString(NOTIFICATION_INDEX, null) ?: return mutableListOf()
        val result = mutableListOf<JSONObject>()
        runCatching {
            val array = JSONArray(raw)
            for (index in 0 until array.length()) array.optJSONObject(index)?.let(result::add)
        }
        return result
    }

    private fun writePendingNotifications(context: Context, notifications: List<JSONObject>) {
        val array = JSONArray().apply { notifications.forEach { put(it) } }
        context.getSharedPreferences(NOTIFICATION_PREFS, Context.MODE_PRIVATE)
            .edit()
            .putString(NOTIFICATION_INDEX, array.toString())
            .apply()
    }

    private fun notificationTriggerAt(notification: JSONObject): Long? {
        val schedule = notification.optJSONObject("schedule") ?: return null
        schedule.opt("at")?.let { value -> epochMillis(value)?.let { return it } }
        schedule.opt("in")?.let { value ->
            val seconds = when (value) {
                is Number -> value.toDouble()
                is String -> value.toDoubleOrNull()
                else -> null
            }
            if (seconds != null && seconds.isFinite() && seconds >= 0) {
                return System.currentTimeMillis() + (seconds * 1000.0).toLong()
            }
        }
        return null
    }

    private fun epochMillis(value: Any?): Long? {
        when (value) {
            null, JSONObject.NULL -> return null
            is Number -> return value.toDouble().takeIf(Double::isFinite)?.toLong()
            is String -> {
                val text = value.trim()
                text.toLongOrNull()?.let { return it }
                runCatching { return Instant.parse(text).toEpochMilli() }
                runCatching { return OffsetDateTime.parse(text, DateTimeFormatter.ISO_DATE_TIME).toInstant().toEpochMilli() }
                runCatching { return ZonedDateTime.parse(text, DateTimeFormatter.ISO_DATE_TIME).toInstant().toEpochMilli() }
                runCatching {
                    return LocalDateTime.parse(text, DateTimeFormatter.ISO_DATE_TIME)
                        .atZone(ZoneId.systemDefault()).toInstant().toEpochMilli()
                }
            }
        }
        return null
    }

    private fun requirePermission(activity: Activity, permission: String, description: String): JSONObject? {
        return if (hasPermission(activity, permission)) null else error("PERMISSION_DENIED", "未授予${description}权限")
    }

    private fun hasPermission(activity: Activity, permission: String): Boolean =
        activity.checkSelfPermission(permission) == PackageManager.PERMISSION_GRANTED

    private fun hasProvider(activity: Activity, authority: String): Boolean =
        activity.packageManager.resolveContentProvider(authority, 0) != null

    private fun permissionWasRequested(activity: Activity, key: String): Boolean =
        activity.getSharedPreferences(PERMISSION_PREFS, Context.MODE_PRIVATE).getBoolean(key, false)

    private fun markPermissionRequested(activity: Activity, key: String) {
        activity.getSharedPreferences(PERMISSION_PREFS, Context.MODE_PRIVATE).edit().putBoolean(key, true).apply()
    }

    private fun unsupported(message: String): JSONObject = error("UNSUPPORTED", message)

    private fun asyncError(code: String, message: String, requestCode: Int): JSONObject =
        errorWithDetails(code, message, JSONObject().put("pending", true).put("requestCode", requestCode))

    private fun error(code: String, message: String): JSONObject =
        JSONObject().put("error", JSONObject().put("code", code).put("message", message))

    private fun errorWithDetails(code: String, message: String, details: JSONObject): JSONObject {
        val body = JSONObject().put("code", code).put("message", message)
        val keys = details.keys()
        while (keys.hasNext()) {
            val key = keys.next()
            body.put(key, details.opt(key))
        }
        return JSONObject().put("error", body)
    }

    private fun stringArray(array: JSONArray?): List<String> {
        if (array == null) return emptyList()
        return buildList { for (index in 0 until array.length()) array.optString(index).takeIf(String::isNotBlank)?.let(::add) }
    }

    private fun intValue(value: Any?): Int? = when (value) {
        is Number -> value.toDouble().takeIf { it.isFinite() && it % 1.0 == 0.0 }?.toInt()
        is String -> value.trim().toIntOrNull()
        else -> null
    }

    private fun putIfNotEmpty(target: JSONObject, key: String, value: String?) {
        if (!value.isNullOrEmpty()) target.put(key, value)
    }

    private fun colorToHex(color: Int): String = String.format("#%08X", color)

    private fun android.database.Cursor.string(column: String): String? {
        val index = getColumnIndex(column)
        return if (index >= 0 && !isNull(index)) getString(index) else null
    }

    private fun android.database.Cursor.int(column: String): Int = intOrNull(column) ?: 0

    private fun android.database.Cursor.intOrNull(column: String): Int? {
        val index = getColumnIndex(column)
        return if (index >= 0 && !isNull(index)) getInt(index) else null
    }

    private fun android.database.Cursor.longOrNull(column: String): Long? {
        val index = getColumnIndex(column)
        return if (index >= 0 && !isNull(index)) getLong(index) else null
    }
}

private fun Uri.asSyncAdapter(accountName: String, accountType: String): Uri = buildUpon()
    .appendQueryParameter(CalendarContract.CALLER_IS_SYNCADAPTER, "true")
    .appendQueryParameter(CalendarContract.Calendars.ACCOUNT_NAME, accountName)
    .appendQueryParameter(CalendarContract.Calendars.ACCOUNT_TYPE, accountType)
    .build()
