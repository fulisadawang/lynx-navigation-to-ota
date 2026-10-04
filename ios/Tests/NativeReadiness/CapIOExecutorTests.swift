import XCTest
import UIKit
import ImageIO
@testable import LynxCapacitorKit

@MainActor
final class CapIOExecutorTests: XCTestCase {
    private func payload(_ method: String, options: [String: Any]) -> String {
        String(data: try! JSONSerialization.data(withJSONObject: ["callbackId": "io", "pluginId": "Filesystem", "methodName": method, "options": options]), encoding: .utf8)!
    }
    private func object(_ raw: String) -> [String: Any] { try! JSONSerialization.jsonObject(with: Data(raw.utf8)) as! [String: Any] }

    func testExecutorDoesNotBlockMainHeartbeat() async {
        let executor = LynxNativeIOExecutor(concurrent: 1, queued: 1)
        let started = expectation(description: "后台工作开始")
        let finished = expectation(description: "后台工作完成")
        let latch = DispatchSemaphore(value: 0)
        var heartbeat = false
        executor.submit(ownerID: nil, completion: { _ in finished.fulfill() }) { _ in
            XCTAssertFalse(Thread.isMainThread)
            started.fulfill()
            XCTAssertEqual(latch.wait(timeout: .now() + 3), .success)
            return .success()
        }
        DispatchQueue.main.async { heartbeat = true; latch.signal() }
        await fulfillment(of: [started, finished], timeout: 4)
        XCTAssertTrue(heartbeat)
    }

    func testConcurrentAndQueuedCapacityRejectsOverflow() async {
        let executor = LynxNativeIOExecutor(concurrent: 2, queued: 1)
        let firstTwo = expectation(description: "两个工作占用并发槽")
        firstTwo.expectedFulfillmentCount = 2
        let thirdStarted = expectation(description: "排队工作随后开始")
        let completed = expectation(description: "全部终态")
        completed.expectedFulfillmentCount = 4
        let lock = NSLock()
        var active = 0
        var peak = 0
        var finishes: [(LynxNativeCapabilityResult) -> Void] = []
        var overflow = false
        for index in 0..<4 {
            executor.submitAsync(ownerID: nil, completion: { result in
                if !result.success { XCTAssertEqual(result.error?["code"] as? String, "BUSY"); lock.withLock { overflow = true } }
                completed.fulfill()
            }) { _, finish in
                lock.withLock {
                    active += 1
                    peak = max(peak, active)
                    finishes.append { result in lock.withLock { active -= 1 }; finish(result) }
                }
                if index < 2 { firstTwo.fulfill() } else { thirdStarted.fulfill() }
            }
        }
        await fulfillment(of: [firstTwo], timeout: 2)
        let (firstFinish, secondFinish) = lock.withLock { (finishes[0], finishes[1]) }
        firstFinish(.success())
        await fulfillment(of: [thirdStarted], timeout: 2)
        let thirdFinish = lock.withLock { finishes[2] }
        secondFinish(.success())
        thirdFinish(.success())
        await fulfillment(of: [completed], timeout: 2)
        XCTAssertEqual(peak, 2)
        XCTAssertTrue(overflow)
    }

    func testDestroySkipsQueuedWorkAndTerminatesInFlightOnce() async {
        let scope = LynxNativeOwnerScope()
        let executor = LynxNativeIOExecutor(concurrent: 1, queued: 1)
        let started = expectation(description: "首个工作开始")
        let completed = expectation(description: "两个取消终态")
        completed.expectedFulfillmentCount = 2
        let lock = NSLock()
        var finishFirst: ((LynxNativeCapabilityResult) -> Void)?
        var queuedRan = false
        let completion: (LynxNativeCapabilityResult) -> Void = { result in
            XCTAssertEqual(result.error?["code"] as? String, "HOST_DESTROYED")
            completed.fulfill()
        }
        executor.submitAsync(ownerID: scope.id, completion: completion) { _, finish in
            lock.withLock { finishFirst = finish }; started.fulfill()
        }
        executor.submit(ownerID: scope.id, completion: completion) { _ in queuedRan = true; return .success() }
        await fulfillment(of: [started], timeout: 2)
        scope.close()
        executor.cancel(ownerID: scope.id)
        let finish = lock.withLock { finishFirst! }
        finish(.success())
        finish(.success())
        await fulfillment(of: [completed], timeout: 2)
        XCTAssertFalse(queuedRan)
    }

    func testSlowNetworkPoolDoesNotBlockLocalIO() async {
        let occupied = expectation(description: "网络槽被占用")
        occupied.expectedFulfillmentCount = LynxNativePayloadLimits.concurrentOperations
        let networkDone = expectation(description: "网络工作清理")
        networkDone.expectedFulfillmentCount = LynxNativePayloadLimits.concurrentOperations
        let lock = NSLock()
        var finishes: [(LynxNativeCapabilityResult) -> Void] = []
        for _ in 0..<LynxNativePayloadLimits.concurrentOperations {
            LynxNativeIOExecutor.network.submitAsync(ownerID: nil, completion: { _ in networkDone.fulfill() }) { _, finish in
                lock.withLock { finishes.append(finish) }
                occupied.fulfill()
            }
        }
        await fulfillment(of: [occupied], timeout: 2)
        let localDone = expectation(description: "本地IO独立执行")
        LynxNativeIOExecutor.shared.submit(ownerID: nil, completion: { _ in localDone.fulfill() }) { _ in
            XCTAssertFalse(Thread.isMainThread)
            return .success()
        }
        await fulfillment(of: [localDone], timeout: 2)
        let cleanup = lock.withLock { finishes }
        cleanup.forEach { $0(.success()) }
        await fulfillment(of: [networkDone], timeout: 2)
    }

    func testCompletionEncodingRetainsExecutionSlotUntilItReturns() async {
        let executor = LynxNativeIOExecutor(concurrent: 1, queued: 1)
        let encoding = expectation(description: "回包编码正在执行")
        let completionFinished = expectation(description: "回包编码执行结束")
        let premature = expectation(description: "编码未结束时不能启动下一项")
        premature.isInverted = true
        let next = expectation(description: "编码结束后下一项执行")
        let latch = DispatchSemaphore(value: 0)
        let lock = NSLock()
        var released = false
        executor.submit(ownerID: nil, completion: { _ in
            encoding.fulfill()
            XCTAssertEqual(latch.wait(timeout: .now() + 3), .success)
            completionFinished.fulfill()
        }) { _ in .success() }
        await fulfillment(of: [encoding], timeout: 2)
        executor.submit(ownerID: nil, completion: { _ in next.fulfill() }) { _ in
            let early = lock.withLock { !released }
            if early { premature.fulfill() }
            return .success()
        }
        await fulfillment(of: [premature], timeout: 0.1)
        lock.withLock { released = true }
        latch.signal()
        await fulfillment(of: [completionFinished, next], timeout: 2)
    }

    func testFilesystemReadAndWriteInlineBoundariesAndCallbackThread() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("cap-boundary-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let runtime = LynxNativeCapabilityRuntime()
        defer { runtime.release() }
        for size in [0, LynxNativePayloadLimits.inlineFileBytes - 1, LynxNativePayloadLimits.inlineFileBytes, LynxNativePayloadLimits.inlineFileBytes + 1] {
            let path = directory.appendingPathComponent("read-\(size)")
            try Data(repeating: 65, count: size).write(to: path)
            let response = expectation(description: "读文件 \(size)")
            runtime.handleCall(payload("readFile", options: ["directory": "TEMP", "path": directory.lastPathComponent + "/" + path.lastPathComponent])) { raw in
                XCTAssertTrue(Thread.isMainThread)
                let result = self.object(raw)
                XCTAssertEqual(result["success"] as? Bool, size <= LynxNativePayloadLimits.inlineFileBytes)
                if size > LynxNativePayloadLimits.inlineFileBytes { XCTAssertEqual((result["error"] as? [String: Any])?["code"] as? String, "PAYLOAD_TOO_LARGE") }
                else { XCTAssertEqual(((result["data"] as? [String: Any])?["data"] as? String)?.utf8.count, size) }
                response.fulfill()
            }
            await fulfillment(of: [response], timeout: 3)
            let written = expectation(description: "写文件 \(size)")
            let targetName = "write-\(size)"
            runtime.handleCall(payload("writeFile", options: ["directory": "TEMP", "path": directory.lastPathComponent + "/" + targetName, "data": String(repeating: "A", count: size)])) { raw in
                XCTAssertTrue(Thread.isMainThread)
                XCTAssertEqual(self.object(raw)["success"] as? Bool, size <= LynxNativePayloadLimits.inlineFileBytes)
                written.fulfill()
            }
            await fulfillment(of: [written], timeout: 3)
            XCTAssertEqual(FileManager.default.fileExists(atPath: directory.appendingPathComponent(targetName).path), size <= LynxNativePayloadLimits.inlineFileBytes)
        }
    }

    func testBase64WriteLimitsAndInvalidDataFailWithoutTarget() async {
        let runtime = LynxNativeCapabilityRuntime()
        defer { runtime.release() }
        for (index, value) in [Data(repeating: 7, count: LynxNativePayloadLimits.inlineFileBytes).base64EncodedString(), Data(repeating: 7, count: LynxNativePayloadLimits.inlineFileBytes + 1).base64EncodedString(), "%%%"].enumerated() {
            let name = "cap-base64-\(UUID().uuidString)"
            let path = FileManager.default.temporaryDirectory.appendingPathComponent(name)
            defer { try? FileManager.default.removeItem(at: path) }
            let done = expectation(description: "Base64 \(index)")
            runtime.handleCall(payload("writeFile", options: ["directory": "TEMP", "path": name, "encoding": "base64", "data": value])) { raw in
                let result = self.object(raw)
                XCTAssertEqual(result["success"] as? Bool, index == 0)
                if index > 0 { XCTAssertEqual((result["error"] as? [String: Any])?["code"] as? String, index == 1 ? "PAYLOAD_TOO_LARGE" : "INVALID_ARGUMENT") }
                done.fulfill()
            }
            await fulfillment(of: [done], timeout: 3)
            XCTAssertEqual(FileManager.default.fileExists(atPath: path.path), index == 0)
        }
    }

    func testMediaURIHasNoInlineLimitAndBase64BoundaryRejectsExplicitly() throws {
        for size in [0, LynxNativePayloadLimits.inlineMediaBytes - 1, LynxNativePayloadLimits.inlineMediaBytes, LynxNativePayloadLimits.inlineMediaBytes + 1] {
            let url = FileManager.default.temporaryDirectory.appendingPathComponent("cap-media-\(UUID().uuidString).jpg")
            try Data(repeating: 65, count: size).write(to: url)
            defer { try? FileManager.default.removeItem(at: url) }
            let uri = try LynxNativeMediaCapabilities.mediaResult(url: url, video: false, resultType: "URI", includeMetadata: false)
            XCTAssertEqual(uri["path"] as? String, url.path)
            XCTAssertNil(uri["base64String"])
            if size <= LynxNativePayloadLimits.inlineMediaBytes {
                let inline = try LynxNativeMediaCapabilities.mediaResult(url: url, video: false, resultType: "BASE64", includeMetadata: false)
                XCTAssertEqual(Data(base64Encoded: inline["base64String"] as! String)?.count, size)
            } else { XCTAssertThrowsError(try LynxNativeMediaCapabilities.mediaResult(url: url, video: false, resultType: "BASE64", includeMetadata: false)) }
        }
    }

    func testInputJSONExactLimitAndOutputLargeResult() {
        var dispatches = 0
        let runtime = LynxNativeCapabilityRuntime(dispatch: { _, completion in dispatches += 1; completion(.success()) })
        defer { runtime.release() }
        let prefix = "{\"callbackId\":\"boundary\",\"pluginId\":\"Device\",\"methodName\":\"getInfo\",\"options\":{\"padding\":\""
        let suffix = "\"}}"
        for size in [LynxNativePayloadLimits.inputJSONBytes - 1, LynxNativePayloadLimits.inputJSONBytes, LynxNativePayloadLimits.inputJSONBytes + 1] {
            let input = prefix + String(repeating: "A", count: size - prefix.utf8.count - suffix.utf8.count) + suffix
            XCTAssertEqual(input.utf8.count, size)
            runtime.handleCall(input) { raw in
                XCTAssertEqual(self.object(raw)["success"] as? Bool, size <= LynxNativePayloadLimits.inputJSONBytes)
            }
        }
        XCTAssertEqual(dispatches, 2)
        let call = LynxNativeCapabilityCall(callbackId: "large", pluginId: "Device", methodName: "getInfo", options: [:])
        let overhead = LynxNativeCapabilityResult.success(["value": ""]).envelope(for: call).utf8.count
        for size in [LynxNativePayloadLimits.outputJSONBytes - 1, LynxNativePayloadLimits.outputJSONBytes, LynxNativePayloadLimits.outputJSONBytes + 1] {
            let value = LynxNativeCapabilityResult.success(["value": String(repeating: "A", count: size - overhead)])
            XCTAssertEqual(value.envelope(for: call).utf8.count, size)
            XCTAssertEqual(object(value.boundedEnvelope(for: call))["success"] as? Bool, size <= LynxNativePayloadLimits.outputJSONBytes)
        }
        let huge = LynxNativeCapabilityResult.success(["value": String(repeating: "A", count: LynxNativePayloadLimits.outputJSONBytes + 1)])
        let result = object(huge.boundedEnvelope(for: call))
        XCTAssertEqual((result["error"] as? [String: Any])?["code"] as? String, "PAYLOAD_TOO_LARGE")
        XCTAssertEqual(result["callbackId"] as? String, "large")
    }

    func testImagePixelAndEdgeBoundariesWithoutAllocatingLargeBitmaps() throws {
        let pixels = LynxNativePayloadLimits.maxImagePixels
        for value in [pixels - 1, pixels] { XCTAssertNoThrow(try LynxNativeImageEncoding.validatePixelCount(value)) }
        XCTAssertThrowsError(try LynxNativeImageEncoding.validatePixelCount(pixels + 1)) { error in
            XCTAssertEqual((error as? LynxNativeImageEncoding.EncodingError)?.code, "IMAGE_TOO_LARGE")
        }
        let edge = LynxNativePayloadLimits.maxImageDimension
        XCTAssertNoThrow(try LynxNativeImageEncoding.validateDimensions(width: edge - 1, height: 1))
        XCTAssertNoThrow(try LynxNativeImageEncoding.validateDimensions(width: edge, height: edge))
        XCTAssertThrowsError(try LynxNativeImageEncoding.validateDimensions(width: edge + 1, height: 1))
        XCTAssertEqual(try LynxNativeImageEncoding.thumbnailEdge(width: 48_000, height: 36_000), edge)
        let target = FileManager.default.temporaryDirectory.appendingPathComponent("cap-image-limit-\(UUID().uuidString).jpg")
        let metadataOnly = OversizedDimensionsImage()
        XCTAssertThrowsError(try LynxNativeImageEncoding.writeImage(metadataOnly, to: target)) { error in
            XCTAssertEqual((error as? LynxNativeImageEncoding.EncodingError)?.code, "IMAGE_TOO_LARGE")
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: target.path))
    }

    func testSmallUIImageActuallyEncodesInIOPool() async throws {
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        let image = UIGraphicsImageRenderer(size: CGSize(width: 32, height: 24), format: format).image { context in
            UIColor.blue.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 32, height: 24))
        }
        let target = FileManager.default.temporaryDirectory.appendingPathComponent("cap-image-small-\(UUID().uuidString).jpg")
        defer { try? FileManager.default.removeItem(at: target) }
        let done = expectation(description: "实际后台 JPEG 编码")
        LynxNativeIOExecutor.shared.submit(ownerID: nil, completion: { result in XCTAssertTrue(result.success); done.fulfill() }) { _ in
            XCTAssertFalse(Thread.isMainThread)
            do { try LynxNativeImageEncoding.writeImage(image, to: target); return .success() }
            catch { return .failure("TEST_ENCODE_FAILED", error.localizedDescription) }
        }
        await fulfillment(of: [done], timeout: 3)
        let size = try LynxNativeImageEncoding.fileDimensions(target)
        XCTAssertEqual(size.width, 32)
        XCTAssertEqual(size.height, 24)
    }

    func testImageIOFilePathDownsamplesLongThinImageBeforeJPEG() async throws {
        let source = FileManager.default.temporaryDirectory.appendingPathComponent("cap-image-source-\(UUID().uuidString).png")
        let target = FileManager.default.temporaryDirectory.appendingPathComponent("cap-image-thumb-\(UUID().uuidString).jpg")
        defer { try? FileManager.default.removeItem(at: source); try? FileManager.default.removeItem(at: target) }
        let width = LynxNativePayloadLimits.maxImageDimension + 64
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        // 只有约 16 KiB 像素；真实文件长边越界，不分配 48 MP 原图来验证边界。
        let image = UIGraphicsImageRenderer(size: CGSize(width: CGFloat(width), height: 1), format: format).image { context in
            UIColor.red.setFill()
            context.fill(CGRect(x: 0, y: 0, width: CGFloat(width), height: 1))
        }
        try XCTUnwrap(image.pngData()).write(to: source)
        XCTAssertEqual(try LynxNativeImageEncoding.fileDimensions(source).width, width)
        let done = expectation(description: "ImageIO 文件下采样")
        LynxNativeIOExecutor.shared.submit(ownerID: nil, completion: { result in XCTAssertTrue(result.success); done.fulfill() }) { _ in
            XCTAssertFalse(Thread.isMainThread)
            do { try LynxNativeImageEncoding.writeFile(source, to: target); return .success() }
            catch { return .failure("TEST_ENCODE_FAILED", error.localizedDescription) }
        }
        await fulfillment(of: [done], timeout: 3)
        let size = try LynxNativeImageEncoding.fileDimensions(target)
        XCTAssertLessThanOrEqual(size.width, LynxNativePayloadLimits.maxImageDimension)
        XCTAssertGreaterThan(size.width, 0)
        XCTAssertLessThanOrEqual(size.width * size.height, LynxNativePayloadLimits.maxImagePixels)
    }

    func testCorruptImageFileFailsWithoutJPEGOutput() throws {
        let source = FileManager.default.temporaryDirectory.appendingPathComponent("cap-image-corrupt-\(UUID().uuidString).png")
        let target = FileManager.default.temporaryDirectory.appendingPathComponent("cap-image-corrupt-out-\(UUID().uuidString).jpg")
        defer { try? FileManager.default.removeItem(at: source); try? FileManager.default.removeItem(at: target) }
        try Data([0, 1, 2, 3]).write(to: source)
        XCTAssertThrowsError(try LynxNativeImageEncoding.writeFile(source, to: target)) { error in
            XCTAssertEqual((error as? LynxNativeImageEncoding.EncodingError)?.code, "MEDIA_READ_FAILED")
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: target.path))
    }

    func testCancelledPreferencesWritesPreserveOldValueAndCommittedWrite() {
        let key = "cancel-\(UUID().uuidString)"
        let storedKey = "lynx.native." + key
        UserDefaults.standard.set("old", forKey: storedKey)
        defer { UserDefaults.standard.removeObject(forKey: storedKey) }
        let cancelled = LynxNativeIOExecutor.Cancellation()
        cancelled.cancel()
        for method in ["set", "remove"] {
            let call = LynxNativeCapabilityCall(callbackId: "prefs", pluginId: "Preferences", methodName: method, options: ["key": key, "value": "new"])
            var result: LynxNativeCapabilityResult?
            LynxNativeSystemCapabilities.dispatchPreferencesWork(call, cancellation: cancelled) { result = $0 }
            XCTAssertEqual(result?.error?["code"] as? String, "HOST_DESTROYED")
            XCTAssertEqual(UserDefaults.standard.string(forKey: storedKey), "old")
        }
        let completed = LynxNativeIOExecutor.Cancellation()
        let write = LynxNativeCapabilityCall(callbackId: "committed", pluginId: "Preferences", methodName: "set", options: ["key": key, "value": "committed"])
        LynxNativeSystemCapabilities.dispatchPreferencesWork(write, cancellation: completed) { XCTAssertTrue($0.success) }
        completed.cancel()
        XCTAssertEqual(UserDefaults.standard.string(forKey: storedKey), "committed")
    }

    func testCancelledProviderMutationsRejectBeforeCallingSystemStore() {
        let token = LynxNativeIOExecutor.Cancellation()
        token.cancel()
        let results = [
            LynxNativeProviderCapabilities.saveContact([:], cancellation: token),
            LynxNativeProviderCapabilities.removeContact([:], cancellation: token),
            LynxNativeProviderCapabilities.createCalendar([:], cancellation: token),
            LynxNativeProviderCapabilities.createEvent([:], cancellation: token),
            LynxNativeProviderCapabilities.deleteEvent([:], cancellation: token),
            LynxNativeProviderCapabilities.deleteCalendar([:], cancellation: token),
        ]
        XCTAssertTrue(results.allSatisfy { $0.error?["code"] as? String == "HOST_DESTROYED" })
    }

    func testCancelledPartCopyAndWritePreserveExistingTarget() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("cap-part-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let source = folder.appendingPathComponent("source")
        let target = folder.appendingPathComponent("target")
        let sentinel = Data("old".utf8)
        try Data(repeating: 7, count: 256 * 1024).write(to: source)
        try sentinel.write(to: target)
        let scope = LynxNativeOwnerScope()
        let token = LynxNativeIOExecutor.Cancellation()
        XCTAssertThrowsError(try LynxNativeAtomicFile.copy(source, to: target, ownerID: scope.id, cancellation: token, maximumBytes: 512 * 1024, beforeCommit: { part in
            XCTAssertTrue(FileManager.default.fileExists(atPath: part.path))
            scope.close()
            token.cancel()
        })) { XCTAssertTrue($0 is LynxNativeIOExecutor.Cancelled) }
        XCTAssertEqual(try Data(contentsOf: target), sentinel)
        let writeToken = LynxNativeIOExecutor.Cancellation()
        XCTAssertThrowsError(try LynxNativeAtomicFile.write(Data("new".utf8), to: target, ownerID: nil, cancellation: writeToken, beforeCommit: { _ in writeToken.cancel() }))
        XCTAssertEqual(try Data(contentsOf: target), sentinel)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: folder.path).sorted(), ["source", "target"])
        let committed = LynxNativeIOExecutor.Cancellation()
        try LynxNativeAtomicFile.write(Data("committed".utf8), to: target, ownerID: nil, cancellation: committed)
        committed.cancel()
        XCTAssertEqual(try String(contentsOf: target, encoding: .utf8), "committed")
    }
}

private final class OversizedDimensionsImage: UIImage {
    override var size: CGSize { CGSize(width: CGFloat(LynxNativePayloadLimits.maxImageDimension + 1), height: 1) }
    override var scale: CGFloat { 1 }
}
