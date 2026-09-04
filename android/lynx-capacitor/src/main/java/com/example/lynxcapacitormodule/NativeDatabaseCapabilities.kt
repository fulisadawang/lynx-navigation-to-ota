package com.example.lynxcapacitormodule

import android.app.Activity
import android.content.Context
import android.database.Cursor
import android.database.sqlite.SQLiteDatabase
import android.database.sqlite.SQLiteStatement
import android.util.Base64
import java.io.File
import java.util.Locale
import java.util.concurrent.ConcurrentHashMap
import org.json.JSONArray
import org.json.JSONObject

/**
 * 使用 Android framework SQLite 实现 CapacitorSQLite 的基础能力。
 *
 * 这里不创建 Capacitor Bridge，也不依赖 Capacitor 或第三方 SQLite/SQLCipher。
 * 方法返回能力本身的业务对象；失败只返回 error.code/error.message，不生成额外的
 * 回调封装。数据库 I/O 由上层 runtime 负责调度到后台线程。
 */
object NativeDatabaseCapabilities {
    private const val PLUGIN_ID = "CapacitorSQLite"
    private const val DEFAULT_VERSION = 1
    private const val DATABASE_ROOT_PROBE = "__lynx_database_root__"

    /** 数据库名到已打开句柄的映射；同一数据库只保留一个 native handle。 */
    private val connections = ConcurrentHashMap<String, SQLiteDatabase>()
    private val connectionLock = Any()

    /** 只处理 CapacitorSQLite，其余 pluginId 交给其他能力实现。 */
    fun dispatch(activity: Activity, pluginId: String, methodName: String, options: JSONObject): JSONObject? {
        if (pluginId != PLUGIN_ID) return null

        return try {
            when (methodName) {
                "echo" -> echo(options)
                "isAvailable" -> JSONObject().put("result", true)
                "createConnection" -> createConnection(activity, options)
                "open" -> open(options)
                "close" -> close(options)
                "execute" -> execute(options)
                "run" -> run(options)
                "query" -> query(options)
                else -> failure("UNSUPPORTED", "$PLUGIN_ID.$methodName 尚未接入当前 Android Module")
            }
        } catch (error: CapabilityException) {
            failure(error.code, error.message ?: "SQLite 参数错误")
        } catch (error: Exception) {
            failure("NATIVE_ERROR", error.message ?: "Android SQLite 操作失败")
        }
    }

    private fun echo(options: JSONObject): JSONObject = JSONObject().put(
        "value",
        options.opt("value") ?: JSONObject.NULL,
    )

    private fun createConnection(activity: Activity, options: JSONObject): JSONObject {
        val database = requireDatabaseName(activity, options)
        val version = requireVersion(options, DEFAULT_VERSION)

        synchronized(connectionLock) {
            connections[database]?.let { existing ->
                if (existing.isOpen) {
                    if (existing.version != version) existing.version = version
                    return connectionResult(database, existing.version, created = false)
                }
                connections.remove(database, existing)
            }

            // Context.openOrCreateDatabase 只能在 app 私有 databases 目录中创建该文件。
            val sqlite = activity.openOrCreateDatabase(database, Context.MODE_PRIVATE, null)
            try {
                sqlite.version = version
                connections[database] = sqlite
                return connectionResult(database, sqlite.version, created = true)
            } catch (error: Exception) {
                sqlite.close()
                throw error
            }
        }
    }

    private fun open(options: JSONObject): JSONObject {
        val database = requireDatabaseName(options)
        synchronized(connectionLock) {
            val sqlite = connections[database]
                ?: throw CapabilityException("CONNECTION_NOT_FOUND", "数据库连接不存在，请先调用 createConnection")
            if (!sqlite.isOpen) {
                connections.remove(database, sqlite)
                throw CapabilityException("CONNECTION_CLOSED", "数据库连接已关闭: $database")
            }
            return JSONObject()
                .put("database", database)
                .put("opened", true)
                .put("version", sqlite.version)
        }
    }

    private fun close(options: JSONObject): JSONObject {
        val database = requireDatabaseName(options)
        synchronized(connectionLock) {
            val sqlite = connections.remove(database)
                ?: throw CapabilityException("CONNECTION_NOT_FOUND", "数据库连接不存在: $database")
            try {
                if (sqlite.isOpen) sqlite.close()
            } finally {
                // remove 后再 close，失败时也不会把已经不可用的句柄留在 map 中。
                connections.remove(database, sqlite)
            }
            return JSONObject().put("database", database).put("closed", true)
        }
    }

    private fun execute(options: JSONObject): JSONObject {
        val database = requireDatabaseName(options)
        val statements = splitStatements(requireSql(options, "statements", "statement"))
        if (statements.isEmpty()) throw CapabilityException("INVALID_ARGUMENT", "statements 不能为空")

        return withConnection(database) { sqlite ->
            val values = values(options)
            if (statements.size > 1 && values.length() > 0) {
                throw CapabilityException("INVALID_ARGUMENT", "多个 statements 不能共用 values，请拆分调用")
            }

            sqlite.beginTransaction()
            try {
                statements.forEachIndexed { index, statement ->
                    if (index == 0 && values.length() > 0) {
                        sqlite.execSQL(statement, bindArguments(values))
                    } else {
                        sqlite.execSQL(statement)
                    }
                }
                sqlite.setTransactionSuccessful()
            } finally {
                sqlite.endTransaction()
            }
            JSONObject()
                .put("database", database)
                .put("statements", statements.size)
                .put("changes", JSONObject().put("changes", 0).put("lastId", -1))
        }
    }

    private fun run(options: JSONObject): JSONObject {
        val database = requireDatabaseName(options)
        val sql = requireSql(options, "statement", "statements")
        val bindValues = values(options)

        return withConnection(database) { sqlite ->
            val compiled = sqlite.compileStatement(sql)
            try {
                bind(compiled, bindValues)
                val normalized = sql.trimStart().uppercase(Locale.US)
                val isInsert = normalized.startsWith("INSERT") || normalized.startsWith("REPLACE")
                val insertedId = if (isInsert) {
                    compiled.executeInsert()
                } else {
                    -1L
                }
                // executeInsert 返回 -1 时也可能已经成功写入（例如 WITHOUT ROWID 表），不能重放语句。
                val changes = if (isInsert) {
                    if (insertedId >= 0L) 1 else 0
                } else {
                    compiled.executeUpdateDelete()
                }
                JSONObject()
                    .put("database", database)
                    .put(
                        "changes",
                        JSONObject()
                            .put("changes", changes)
                            .put("lastId", if (insertedId >= 0L) insertedId else -1),
                    )
            } finally {
                compiled.close()
            }
        }
    }

    private fun query(options: JSONObject): JSONObject {
        val database = requireDatabaseName(options)
        val sql = requireSql(options, "statement", "statements")
        val selectionArgs = values(options).let(::selectionArguments)

        return withConnection(database) { sqlite ->
            sqlite.rawQuery(sql, selectionArgs).use { cursor ->
                val columns = JSONArray()
                cursor.columnNames.forEach(columns::put)
                val rows = JSONArray()
                while (cursor.moveToNext()) {
                    val row = JSONArray()
                    for (index in cursor.columnIndices()) row.put(cursorValue(cursor, index))
                    rows.put(row)
                }
                JSONObject()
                    .put("columns", columns)
                    .put("values", rows)
            }
        }
    }

    /**
     * map 锁覆盖整个数据库操作，避免 close 在另一个线程拿到句柄后抢先执行。
     * 这样可以安全地由后续 runtime 在后台线程并发分发请求。
     */
    private fun <T> withConnection(database: String, action: (SQLiteDatabase) -> T): T {
        synchronized(connectionLock) {
            val sqlite = connections[database]
                ?: throw CapabilityException("CONNECTION_NOT_FOUND", "数据库连接不存在，请先调用 createConnection")
            if (!sqlite.isOpen) {
                connections.remove(database, sqlite)
                throw CapabilityException("CONNECTION_CLOSED", "数据库连接已关闭: $database")
            }
            return action(sqlite)
        }
    }

    private fun requireDatabaseName(activity: Activity, options: JSONObject): String {
        val database = requireDatabaseName(options)
        val root = activity.getDatabasePath(DATABASE_ROOT_PROBE).parentFile?.canonicalFile
            ?: throw CapabilityException("NATIVE_ERROR", "无法解析 app 私有 databases 目录")
        val target = activity.getDatabasePath(database).canonicalFile
        val rootPath = root.path + File.separator
        if (target.parentFile != root || !target.path.startsWith(rootPath)) {
            throw CapabilityException("INVALID_ARGUMENT", "database 必须位于 app 私有 databases 目录")
        }
        return database
    }

    private fun requireDatabaseName(options: JSONObject): String {
        val database = options.optString("database", "").trim()
        if (database.isEmpty()) throw CapabilityException("INVALID_ARGUMENT", "database 不能为空")
        if (database == "." || database == ".." || database.contains('/') || database.contains('\\')) {
            throw CapabilityException("INVALID_ARGUMENT", "database 名称不允许路径穿越")
        }
        if (File(database).isAbsolute) {
            throw CapabilityException("INVALID_ARGUMENT", "database 不允许使用绝对路径")
        }
        return database
    }

    private fun requireVersion(options: JSONObject, default: Int): Int {
        if (!options.has("version") || options.isNull("version")) return default
        val value = options.opt("version")
        val version = when (value) {
            is Number -> value.toLong().takeIf {
                it in 1..Int.MAX_VALUE && it.toDouble() == value.toDouble()
            }?.toInt()
            else -> null
        }
        if (version == null || version <= 0) {
            throw CapabilityException("INVALID_ARGUMENT", "version 必须是正整数")
        }
        return version
    }

    private fun requireSql(options: JSONObject, preferred: String, fallback: String): String {
        val preferredValue = options.opt(preferred)
        val fallbackValue = options.opt(fallback)
        val value = when {
            preferredValue is String -> preferredValue
            fallbackValue is String -> fallbackValue
            else -> ""
        }.trim()
        if (value.isEmpty()) throw CapabilityException("INVALID_ARGUMENT", "$preferred 不能为空")
        return value
    }

    private fun values(options: JSONObject): JSONArray {
        val value = options.opt("values")
        if (value == null || value === JSONObject.NULL) return JSONArray()
        if (value !is JSONArray) throw CapabilityException("INVALID_ARGUMENT", "values 必须是数组")
        return value
    }

    private fun bindArguments(values: JSONArray): Array<Any?> = Array(values.length()) { index ->
        jsonValue(values.opt(index))
    }

    private fun bind(statement: SQLiteStatement, values: JSONArray) {
        for (index in 0 until values.length()) {
            when (val value = jsonValue(values.opt(index))) {
                null -> statement.bindNull(index + 1)
                is ByteArray -> statement.bindBlob(index + 1, value)
                is Double -> statement.bindDouble(index + 1, value)
                is Float -> statement.bindDouble(index + 1, value.toDouble())
                is Long -> statement.bindLong(index + 1, value)
                is Int -> statement.bindLong(index + 1, value.toLong())
                else -> statement.bindString(index + 1, value.toString())
            }
        }
    }

    private fun selectionArguments(values: JSONArray): Array<String?> = Array(values.length()) { index ->
        when (val value = values.opt(index)) {
            null, JSONObject.NULL -> null
            is Boolean -> if (value) "1" else "0"
            else -> value.toString()
        }
    }

    private fun jsonValue(value: Any?): Any? = when (value) {
        null, JSONObject.NULL -> null
        is Boolean -> if (value) 1L else 0L
        is Int, is Long, is Float, is Double, is String, is ByteArray -> value
        else -> value.toString()
    }

    private fun Cursor.columnIndices(): IntRange = 0 until columnCount

    private fun cursorValue(cursor: Cursor, index: Int): Any = when (cursor.getType(index)) {
        Cursor.FIELD_TYPE_NULL -> JSONObject.NULL
        Cursor.FIELD_TYPE_INTEGER -> cursor.getLong(index)
        Cursor.FIELD_TYPE_FLOAT -> cursor.getDouble(index)
        Cursor.FIELD_TYPE_BLOB -> Base64.encodeToString(cursor.getBlob(index), Base64.NO_WRAP)
        else -> cursor.getString(index) ?: JSONObject.NULL
    }

    /** 按 SQL 引号和注释跳过分号，避免字符串中的分号被错误拆开。 */
    private fun splitStatements(sql: String): List<String> {
        val statements = mutableListOf<String>()
        var start = 0
        var quote = '\u0000'
        var lineComment = false
        var blockComment = false
        var index = 0

        while (index < sql.length) {
            val current = sql[index]
            val next = sql.getOrNull(index + 1)
            when {
                lineComment -> {
                    if (current == '\n') lineComment = false
                }
                blockComment -> {
                    if (current == '*' && next == '/') {
                        blockComment = false
                        index++
                    }
                }
                quote != '\u0000' -> {
                    if (current == quote) {
                        if (next == quote && quote != ']') {
                            index++
                        } else {
                            quote = '\u0000'
                        }
                    }
                }
                current == '-' && next == '-' -> {
                    lineComment = true
                    index++
                }
                current == '/' && next == '*' -> {
                    blockComment = true
                    index++
                }
                current == '\'' || current == '"' || current == '`' || current == '[' -> {
                    quote = if (current == '[') ']' else current
                }
                current == ';' -> {
                    sql.substring(start, index).trim().takeIf(String::isNotEmpty)?.let(statements::add)
                    start = index + 1
                }
            }
            index++
        }

        sql.substring(start).trim().takeIf(String::isNotEmpty)?.let(statements::add)
        return statements
    }

    private fun connectionResult(database: String, version: Int, created: Boolean): JSONObject = JSONObject()
        .put("database", database)
        .put("version", version)
        .put("created", created)

    private fun failure(code: String, message: String): JSONObject = JSONObject()
        .put("error", JSONObject().put("code", code).put("message", message))

    private class CapabilityException(val code: String, message: String) : IllegalArgumentException(message)
}
