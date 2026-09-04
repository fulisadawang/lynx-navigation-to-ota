import Foundation
import SQLite3
import CoreFoundation

/**
 * Android `NativeDatabaseCapabilities` 的 iOS libsqlite3 对译。
 *
 * 连接句柄只属于当前进程和应用沙盒；只使用系统 SQLite，不引入第三方数据库插件。
 * 所有阻塞数据库操作在后台队列执行，错误始终保留 code/message，不把 SQL 失败包装成成功。
 */
enum LynxNativeDatabaseCapabilities {
    typealias Completion = (LynxNativeCapabilityResult) -> Void

    private static let pluginID = "CapacitorSQLite"
    private static let defaultVersion = 1
    private static let rootLock = NSLock()
    private static var connections: [String: OpaquePointer] = [:]
    private static let databaseQueue = DispatchQueue(label: "lynx.native.sqlite", qos: .userInitiated)
    private static let transientDestructor = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

    static func dispatch(
        _ call: LynxNativeCapabilityCall,
        completion: @escaping Completion
    ) -> Bool {
        guard call.pluginId == pluginID else { return false }
        let work = {
            completion(dispatchSync(call))
        }
        if call.methodName == "echo" || call.methodName == "isAvailable" {
            work()
        } else {
            databaseQueue.async(execute: work)
        }
        return true
    }

    static func release() {
        let values: [OpaquePointer] = rootLock.withLock {
            let values = Array(connections.values)
            connections.removeAll()
            return values
        }
        values.forEach { sqlite3_close($0) }
    }

    private static func dispatchSync(_ call: LynxNativeCapabilityCall) -> LynxNativeCapabilityResult {
        do {
            switch call.methodName {
            case "echo":
                return .success(["value": call.options["value"] ?? NSNull()])
            case "isAvailable":
                return .success(["result": sqlite3_libversion_number() > 0])
            case "createConnection":
                return try createConnection(call.options)
            case "open":
                return try open(call.options)
            case "close":
                return try close(call.options)
            case "execute":
                return try execute(call.options)
            case "run":
                return try run(call.options)
            case "query":
                return try query(call.options)
            default:
                return .failure("UNSUPPORTED", "\(pluginID).\(call.methodName) 尚未接入当前 iOS Module")
            }
        } catch let error as DatabaseError {
            return .failure(error.code, error.message, details: error.details)
        } catch {
            return .failure("NATIVE_ERROR", error.localizedDescription)
        }
    }

    private static func createConnection(_ options: [String: Any]) throws -> LynxNativeCapabilityResult {
        let database = try requireDatabaseName(options)
        let version = try requireVersion(options)
        try ensureDatabaseDirectory()

        return try rootLock.withLock {
            if let existing = connections[database] {
                guard sqlite3_db_readonly(existing, nil) == 0 else {
                    throw DatabaseError("CONNECTION_READ_ONLY", "数据库连接是只读的")
                }
                try setUserVersion(existing, version: version)
                return .success(["database": database, "version": version, "created": false])
            }

            let url = try databaseURL(named: database)
            var handle: OpaquePointer?
            let result = sqlite3_open_v2(
                url.path,
                &handle,
                SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX,
                nil
            )
            guard result == SQLITE_OK, let handle else {
                let message = handle.map(sqliteMessage) ?? "无法打开 SQLite 数据库"
                if let handle { sqlite3_close(handle) }
                throw DatabaseError("OPEN_FAILED", message)
            }
            do {
                try setUserVersion(handle, version: version)
                connections[database] = handle
                return .success(["database": database, "version": version, "created": true])
            } catch {
                sqlite3_close(handle)
                throw error
            }
        }
    }

    private static func open(_ options: [String: Any]) throws -> LynxNativeCapabilityResult {
        let database = try requireDatabaseName(options)
        return try rootLock.withLock {
            guard let handle = connections[database] else {
                throw DatabaseError("CONNECTION_NOT_FOUND", "数据库连接不存在，请先调用 createConnection")
            }
            guard sqlite3_db_readonly(handle, nil) == 0 else {
                throw DatabaseError("CONNECTION_CLOSED", "数据库连接不可写: \(database)")
            }
            return .success([
                "database": database,
                "opened": true,
                "version": try userVersion(handle),
            ])
        }
    }

    private static func close(_ options: [String: Any]) throws -> LynxNativeCapabilityResult {
        let database = try requireDatabaseName(options)
        return try rootLock.withLock {
            guard let handle = connections.removeValue(forKey: database) else {
                throw DatabaseError("CONNECTION_NOT_FOUND", "数据库连接不存在: \(database)")
            }
            let result = sqlite3_close(handle)
            guard result == SQLITE_OK else {
                connections[database] = handle
                throw DatabaseError("CLOSE_FAILED", sqliteMessage(handle))
            }
            return .success(["database": database, "closed": true])
        }
    }

    private static func execute(_ options: [String: Any]) throws -> LynxNativeCapabilityResult {
        let database = try requireDatabaseName(options)
        let rawSQL = stringValue(options["statements"] ?? options["statement"])
        let statements = splitStatements(rawSQL)
        guard !statements.isEmpty else { throw DatabaseError("INVALID_ARGUMENT", "statements 不能为空") }
        let values = try valuesArray(options)
        if statements.count > 1 && !values.isEmpty {
            throw DatabaseError("INVALID_ARGUMENT", "多个 statements 不能共用 values，请拆分调用")
        }

        return try withConnection(database) { handle in
            var totalChanges = 0
            var lastID: Int64 = -1
            try execSQL(handle, "BEGIN TRANSACTION")
            do {
                for (index, statement) in statements.enumerated() {
                    if index == 0 && !values.isEmpty {
                        let outcome = try preparedExecution(handle, sql: statement, values: values, returnsRows: false)
                        totalChanges += outcome.changes
                        if outcome.lastID >= 0 { lastID = outcome.lastID }
                    } else {
                        try execSQL(handle, statement)
                        totalChanges += Int(sqlite3_changes(handle))
                        let candidate = sqlite3_last_insert_rowid(handle)
                        if candidate >= 0 { lastID = candidate }
                    }
                }
                try execSQL(handle, "COMMIT")
            } catch {
                _ = try? execSQL(handle, "ROLLBACK")
                throw error
            }
            return .success([
                "database": database,
                "statements": statements.count,
                "changes": ["changes": totalChanges, "lastId": lastID],
            ])
        }
    }

    private static func run(_ options: [String: Any]) throws -> LynxNativeCapabilityResult {
        let database = try requireDatabaseName(options)
        let sql = try requireSQL(options, preferred: "statement", fallback: "statements")
        let values = try valuesArray(options)
        return try withConnection(database) { handle in
            let outcome = try preparedExecution(handle, sql: sql, values: values, returnsRows: false)
            return .success([
                "database": database,
                "changes": [
                    "changes": outcome.changes,
                    "lastId": outcome.lastID,
                ],
            ])
        }
    }

    private static func query(_ options: [String: Any]) throws -> LynxNativeCapabilityResult {
        let database = try requireDatabaseName(options)
        let sql = try requireSQL(options, preferred: "statement", fallback: "statements")
        let values = try valuesArray(options)
        return try withConnection(database) { handle in
            var statement: OpaquePointer?
            try prepare(handle, sql: sql, statement: &statement)
            guard let statement else { throw DatabaseError("PREPARE_FAILED", sqliteMessage(handle)) }
            defer { sqlite3_finalize(statement) }
            try bind(values, to: statement, handle: handle)

            let columnCount = Int(sqlite3_column_count(statement))
            var columns: [String] = []
            if columnCount > 0 {
                for index in 0..<columnCount {
                    columns.append(String(cString: sqlite3_column_name(statement, Int32(index))))
                }
            }
            var rows: [[Any]] = []
            while true {
                let step = sqlite3_step(statement)
                if step == SQLITE_ROW {
                    rows.append((0..<columnCount).map { sqliteValue(statement, index: Int32($0)) })
                } else if step == SQLITE_DONE {
                    break
                } else {
                    throw DatabaseError("QUERY_FAILED", sqliteMessage(handle))
                }
            }
            return .success(["columns": columns, "values": rows])
        }
    }

    private struct ExecutionOutcome {
        let changes: Int
        let lastID: Int64
    }

    private static func preparedExecution(
        _ handle: OpaquePointer,
        sql: String,
        values: [Any],
        returnsRows: Bool
    ) throws -> ExecutionOutcome {
        _ = returnsRows
        var statement: OpaquePointer?
        try prepare(handle, sql: sql, statement: &statement)
        guard let statement else { throw DatabaseError("PREPARE_FAILED", sqliteMessage(handle)) }
        defer { sqlite3_finalize(statement) }
        try bind(values, to: statement, handle: handle)
        let step = sqlite3_step(statement)
        guard step == SQLITE_DONE || step == SQLITE_ROW else {
            throw DatabaseError("SQL_EXECUTION_FAILED", sqliteMessage(handle))
        }
        return ExecutionOutcome(
            changes: Int(sqlite3_changes(handle)),
            lastID: sqlite3_last_insert_rowid(handle)
        )
    }

    private static func withConnection<T>(_ name: String, _ action: (OpaquePointer) throws -> T) throws -> T {
        try rootLock.withLock {
            guard let handle = connections[name] else {
                throw DatabaseError("CONNECTION_NOT_FOUND", "数据库连接不存在，请先调用 createConnection")
            }
            return try action(handle)
        }
    }

    private static func prepare(
        _ handle: OpaquePointer,
        sql: String,
        statement: inout OpaquePointer?
    ) throws {
        let result = sqlite3_prepare_v2(handle, sql, -1, &statement, nil)
        guard result == SQLITE_OK else { throw DatabaseError("PREPARE_FAILED", sqliteMessage(handle)) }
    }

    private static func execSQL(_ handle: OpaquePointer, _ sql: String) throws {
        var errorPointer: UnsafeMutablePointer<Int8>?
        let result = sqlite3_exec(handle, sql, nil, nil, &errorPointer)
        defer { sqlite3_free(errorPointer) }
        guard result == SQLITE_OK else {
            let message = errorPointer.map { String(cString: $0) } ?? sqliteMessage(handle)
            throw DatabaseError("SQL_EXECUTION_FAILED", message)
        }
    }

    private static func bind(_ values: [Any], to statement: OpaquePointer, handle: OpaquePointer) throws {
        for (offset, value) in values.enumerated() {
            let index = Int32(offset + 1)
            let result: Int32
            if value is NSNull {
                result = sqlite3_bind_null(statement, index)
            } else if let bool = value as? Bool {
                result = sqlite3_bind_int64(statement, index, bool ? 1 : 0)
            } else if let number = value as? NSNumber {
                if CFGetTypeID(number) == CFBooleanGetTypeID() {
                    result = sqlite3_bind_int64(statement, index, number.boolValue ? 1 : 0)
                } else if number.doubleValue.rounded() == number.doubleValue {
                    result = sqlite3_bind_int64(statement, index, number.int64Value)
                } else {
                    result = sqlite3_bind_double(statement, index, number.doubleValue)
                }
            } else if let data = value as? Data {
                result = data.withUnsafeBytes { bytes in
                    sqlite3_bind_blob(statement, index, bytes.baseAddress, Int32(data.count), transientDestructor)
                }
            } else {
                let string = stringValue(value)
                result = string.withCString {
                    sqlite3_bind_text(statement, index, $0, -1, transientDestructor)
                }
            }
            guard result == SQLITE_OK else { throw DatabaseError("BIND_FAILED", sqliteMessage(handle)) }
        }
    }

    private static func sqliteValue(_ statement: OpaquePointer, index: Int32) -> Any {
        switch sqlite3_column_type(statement, index) {
        case SQLITE_INTEGER:
            return sqlite3_column_int64(statement, index)
        case SQLITE_FLOAT:
            return sqlite3_column_double(statement, index)
        case SQLITE_BLOB:
            let length = Int(sqlite3_column_bytes(statement, index))
            guard let pointer = sqlite3_column_blob(statement, index), length > 0 else { return "" }
            return Data(bytes: pointer, count: length).base64EncodedString()
        case SQLITE_NULL:
            return NSNull()
        default:
            guard let pointer = sqlite3_column_text(statement, index) else { return NSNull() }
            return String(cString: pointer)
        }
    }

    private static func requireDatabaseName(_ options: [String: Any]) throws -> String {
        let database = stringValue(options["database"]).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !database.isEmpty else { throw DatabaseError("INVALID_ARGUMENT", "database 不能为空") }
        guard database != ".", database != "..", !database.contains("/"), !database.contains("\\"), !database.hasPrefix("/") else {
            throw DatabaseError("INVALID_ARGUMENT", "database 名称不允许路径穿越")
        }
        return database
    }

    private static func requireVersion(_ options: [String: Any]) throws -> Int {
        guard let value = options["version"], !(value is NSNull) else { return defaultVersion }
        guard let number = intValue(value), number > 0 else { throw DatabaseError("INVALID_ARGUMENT", "version 必须是正整数") }
        return number
    }

    private static func requireSQL(_ options: [String: Any], preferred: String, fallback: String) throws -> String {
        let value = stringValue(options[preferred].flatMap { $0 is NSNull ? nil : $0 } ?? options[fallback])
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { throw DatabaseError("INVALID_ARGUMENT", "\(preferred) 不能为空") }
        return value
    }

    private static func valuesArray(_ options: [String: Any]) throws -> [Any] {
        guard let raw = options["values"], !(raw is NSNull) else { return [] }
        guard let values = raw as? [Any] else { throw DatabaseError("INVALID_ARGUMENT", "values 必须是数组") }
        return values
    }

    private static func ensureDatabaseDirectory() throws {
        let directory = try databaseDirectory()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    private static func databaseDirectory() throws -> URL {
        guard let directory = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else {
            throw DatabaseError("NATIVE_ERROR", "无法解析应用私有数据库目录")
        }
        return directory.appendingPathComponent("LynxNativeSQLite", isDirectory: true)
    }

    private static func databaseURL(named name: String) throws -> URL {
        try databaseDirectory().appendingPathComponent(name).appendingPathExtension("sqlite")
    }

    private static func userVersion(_ handle: OpaquePointer) throws -> Int {
        var statement: OpaquePointer?
        try prepare(handle, sql: "PRAGMA user_version", statement: &statement)
        guard let statement else { throw DatabaseError("SQL_EXECUTION_FAILED", sqliteMessage(handle)) }
        defer { sqlite3_finalize(statement) }
        guard sqlite3_step(statement) == SQLITE_ROW else { throw DatabaseError("SQL_EXECUTION_FAILED", sqliteMessage(handle)) }
        return Int(sqlite3_column_int64(statement, 0))
    }

    private static func setUserVersion(_ handle: OpaquePointer, version: Int) throws {
        try execSQL(handle, "PRAGMA user_version = \(version)")
    }

    private static func sqliteMessage(_ handle: OpaquePointer) -> String {
        String(cString: sqlite3_errmsg(handle))
    }

    private static func stringValue(_ value: Any?) -> String {
        guard let value, !(value is NSNull) else { return "" }
        if let value = value as? String { return value }
        return String(describing: value)
    }

    private static func intValue(_ value: Any?) -> Int? {
        if let value = value as? Int { return value }
        if let value = value as? NSNumber, value.doubleValue.rounded() == value.doubleValue { return Int(exactly: value.int64Value) }
        return Int(stringValue(value))
    }

    private static func splitStatements(_ sql: String) -> [String] {
        var result: [String] = []
        var start = sql.startIndex
        var quote: Character?
        var index = sql.startIndex
        while index < sql.endIndex {
            let character = sql[index]
            if let activeQuote = quote {
                if character == activeQuote {
                    let next = sql.index(after: index)
                    if next < sql.endIndex, sql[next] == activeQuote {
                        index = sql.index(after: next)
                        continue
                    }
                    quote = nil
                }
            } else if character == "'" || character == "\"" || character == "`" {
                quote = character
            } else if character == ";" {
                let piece = String(sql[start..<index]).trimmingCharacters(in: .whitespacesAndNewlines)
                if !piece.isEmpty { result.append(piece) }
                start = sql.index(after: index)
            }
            index = sql.index(after: index)
        }
        let piece = String(sql[start...]).trimmingCharacters(in: .whitespacesAndNewlines)
        if !piece.isEmpty { result.append(piece) }
        return result
    }

    private struct DatabaseError: Error {
        let code: String
        let message: String
        let details: [String: Any]

        init(_ code: String, _ message: String, details: [String: Any] = [:]) {
            self.code = code
            self.message = message
            self.details = details
        }
    }
}

private extension NSLock {
    func withLock<T>(_ body: () throws -> T) rethrows -> T {
        lock()
        defer { unlock() }
        return try body()
    }
}
