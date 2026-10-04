import XCTest
@testable import LynxCapacitorKit

@MainActor
final class CapHTTPDatabaseTests: XCTestCase {
    func testHTTPStreamEnforcesDeclaredResponseLengthBeforeBuffering() {
        for size in [LynxNativePayloadLimits.inlineFileBytes - 1, LynxNativePayloadLimits.inlineFileBytes, LynxNativePayloadLimits.inlineFileBytes + 1] {
            var results: [(Data, Error?)] = []
            let stream = LynxNativeHTTPStream(limit: LynxNativePayloadLimits.inlineFileBytes, disableRedirects: false) { data, _, error in results.append((data, error)) }
            let session = URLSession(configuration: .ephemeral)
            let url = URL(string: "https://example.invalid/test")!
            let task = session.dataTask(with: url)
            let response = URLResponse(url: url, mimeType: "application/octet-stream", expectedContentLength: size, textEncodingName: nil)
            var allowed = false
            stream.urlSession(session, dataTask: task, didReceive: response) { allowed = $0 == .allow }
            XCTAssertEqual(allowed, size <= LynxNativePayloadLimits.inlineFileBytes)
            if size > LynxNativePayloadLimits.inlineFileBytes {
                XCTAssertEqual(results.count, 1)
                XCTAssertEqual((results[0].1 as NSError?)?.domain, LynxNativeHTTPStream.errorDomain)
                XCTAssertTrue(results[0].0.isEmpty)
            }
            session.invalidateAndCancel()
        }
    }

    func testHTTPStreamStopsChunkedOverflowAndHasOneTerminal() {
        let limit = LynxNativePayloadLimits.inlineFileBytes
        for size in [limit - 1, limit, limit + 1] {
            var results: [(Data, Error?)] = []
            let stream = LynxNativeHTTPStream(limit: limit, disableRedirects: false) { data, _, error in results.append((data, error)) }
            let session = URLSession(configuration: .ephemeral)
            let task = session.dataTask(with: URL(string: "https://example.invalid/test")!)
            stream.urlSession(session, dataTask: task, didReceive: Data(repeating: 1, count: size / 2))
            stream.urlSession(session, dataTask: task, didReceive: Data(repeating: 2, count: size - size / 2))
            stream.urlSession(session, task: task, didCompleteWithError: nil)
            stream.urlSession(session, task: task, didCompleteWithError: NSError(domain: NSURLErrorDomain, code: NSURLErrorCancelled))
            XCTAssertEqual(results.count, 1)
            XCTAssertEqual(results[0].1 == nil, size <= limit)
            XCTAssertLessThanOrEqual(results[0].0.count, limit)
            session.invalidateAndCancel()
        }
    }

    func testSQLiteConnectionSurvivesOwnerExitAndBlobResultIsBounded() async throws {
        let name = "cap_readiness_\(UUID().uuidString.replacingOccurrences(of: "-", with: ""))"
        let first = LynxNativeCapabilityRuntime()
        var result = await sqlite(first, "createConnection", ["database": name, "version": 1])
        XCTAssertEqual(result["success"] as? Bool, true)
        result = await sqlite(first, "execute", ["database": name, "statements": "CREATE TABLE fixture (v BLOB); INSERT INTO fixture VALUES (zeroblob(\(LynxNativePayloadLimits.inlineFileBytes + 1))); "])
        XCTAssertEqual(result["success"] as? Bool, true)
        first.release()
        let replacement = LynxNativeCapabilityRuntime()
        result = await sqlite(replacement, "query", ["database": name, "statement": "SELECT COUNT(*) FROM fixture"])
        XCTAssertEqual(result["success"] as? Bool, true)
        result = await sqlite(replacement, "query", ["database": name, "statement": "SELECT v FROM fixture"])
        XCTAssertEqual((result["error"] as? [String: Any])?["code"] as? String, "PAYLOAD_TOO_LARGE")
        result = await sqlite(replacement, "close", ["database": name])
        XCTAssertEqual(result["success"] as? Bool, true)
        replacement.release()
        let database = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!.appendingPathComponent("LynxNativeSQLite").appendingPathComponent(name).appendingPathExtension("sqlite")
        try FileManager.default.removeItem(at: database)
    }

    private func sqlite(_ runtime: LynxNativeCapabilityRuntime, _ method: String, _ options: [String: Any]) async -> [String: Any] {
        let payload = String(data: try! JSONSerialization.data(withJSONObject: ["callbackId": "sqlite", "pluginId": "CapacitorSQLite", "methodName": method, "options": options]), encoding: .utf8)!
        return await withCheckedContinuation { continuation in
            runtime.handleCall(payload) { raw in
                XCTAssertTrue(Thread.isMainThread)
                continuation.resume(returning: try! JSONSerialization.jsonObject(with: Data(raw.utf8)) as! [String: Any])
            }
        }
    }

    func testSQLiteCancellationBeforeCommitRollsBackWithoutClosingSharedConnection() throws {
        let name = "cancel_\(UUID().uuidString.replacingOccurrences(of: "-", with: ""))"
        func execute(_ method: String, _ options: [String: Any], token: LynxNativeIOExecutor.Cancellation = .init(), beforeCommit: (() -> Void)? = nil) -> LynxNativeCapabilityResult {
            LynxNativeDatabaseCapabilities.dispatchSync(LynxNativeCapabilityCall(callbackId: "cancel", pluginId: "CapacitorSQLite", methodName: method, options: options), cancellation: token, beforeCommit: beforeCommit)
        }
        XCTAssertTrue(execute("createConnection", ["database": name, "version": 1]).success)
        defer {
            _ = execute("close", ["database": name])
            let url = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!.appendingPathComponent("LynxNativeSQLite/\(name).sqlite")
            try? FileManager.default.removeItem(at: url)
        }
        XCTAssertTrue(execute("execute", ["database": name, "statements": "CREATE TABLE fixture (v INTEGER); INSERT INTO fixture VALUES(1);"]).success)
        for method in ["execute", "run"] {
            let token = LynxNativeIOExecutor.Cancellation()
            let result = execute(method, ["database": name, "statements": "INSERT INTO fixture VALUES(2)", "statement": "INSERT INTO fixture VALUES(2)"], token: token, beforeCommit: { token.cancel() })
            XCTAssertEqual(result.error?["code"] as? String, "HOST_DESTROYED")
            let count = execute("query", ["database": name, "statement": "SELECT COUNT(*) FROM fixture"])
            XCTAssertEqual((count.data?["values"] as? [[NSNumber]])?.first?.first?.intValue, 1)
        }
        let cancelled = LynxNativeIOExecutor.Cancellation()
        cancelled.cancel()
        XCTAssertEqual(execute("close", ["database": name], token: cancelled).error?["code"] as? String, "HOST_DESTROYED")
        XCTAssertTrue(execute("query", ["database": name, "statement": "SELECT COUNT(*) FROM fixture"]).success)
        XCTAssertEqual(execute("createConnection", ["database": name + "_new", "version": 1], token: cancelled).error?["code"] as? String, "HOST_DESTROYED")
        let committed = LynxNativeIOExecutor.Cancellation()
        XCTAssertTrue(execute("run", ["database": name, "statement": "INSERT INTO fixture VALUES(3)"], token: committed).success)
        committed.cancel()
        let count = execute("query", ["database": name, "statement": "SELECT COUNT(*) FROM fixture"])
        XCTAssertEqual((count.data?["values"] as? [[NSNumber]])?.first?.first?.intValue, 2)
    }
}
