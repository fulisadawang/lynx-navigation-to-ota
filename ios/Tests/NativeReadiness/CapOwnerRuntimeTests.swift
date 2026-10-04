import XCTest
import UIKit
import Lynx
@testable import LynxCapacitorKit

@MainActor
final class CapOwnerRuntimeTests: XCTestCase {
    private func payload(_ callback: String = "same", plugin: String = "Device", method: String = "getInfo") -> String {
        String(data: try! JSONSerialization.data(withJSONObject: ["callbackId": callback, "pluginId": plugin, "methodName": method]), encoding: .utf8)!
    }
    private func object(_ raw: String) -> [String: Any] { try! JSONSerialization.jsonObject(with: Data(raw.utf8)) as! [String: Any] }

    func testDestroyCompletesPendingOnceAndDropsLateSuccess() {
        var finish: ((LynxNativeCapabilityResult) -> Void)?
        let runtime = LynxNativeCapabilityRuntime(dispatch: { _, callback in finish = callback })
        var results: [[String: Any]] = []
        runtime.handleCall(payload()) { results.append(self.object($0)) }
        XCTAssertNotNil(finish)
        runtime.release()
        runtime.release()
        finish?(.success(["late": true]))
        XCTAssertEqual(results.count, 1)
        XCTAssertEqual((results[0]["error"] as? [String: Any])?["code"] as? String, "HOST_DESTROYED")
    }

    func testNaturalCompletionAndDuplicateCompletionHaveOneTerminal() {
        var finish: ((LynxNativeCapabilityResult) -> Void)?
        let runtime = LynxNativeCapabilityRuntime(dispatch: { _, callback in finish = callback })
        var results: [String] = []
        runtime.handleCall(payload()) { results.append($0) }
        finish?(.success(["value": 1]))
        finish?(.failure("CANCELLED", "重复取消"))
        runtime.release()
        XCTAssertEqual(results.count, 1)
        XCTAssertEqual(object(results[0])["success"] as? Bool, true)
    }

    func testSameCallbackIDDoesNotMixOwnersOrCalls() {
        var finishA: ((LynxNativeCapabilityResult) -> Void)?
        var finishB: ((LynxNativeCapabilityResult) -> Void)?
        let a = LynxNativeCapabilityRuntime(dispatch: { _, callback in finishA = callback })
        let b = LynxNativeCapabilityRuntime(dispatch: { _, callback in finishB = callback })
        var aResults: [String] = []
        var bResults: [String] = []
        a.handleCall(payload()) { aResults.append($0) }
        b.handleCall(payload()) { bResults.append($0) }
        a.release()
        finishA?(.success())
        finishB?(.success(["owner": "B"]))
        XCTAssertEqual(aResults.count, 1)
        XCTAssertEqual(bResults.count, 1)
        XCTAssertEqual((object(bResults[0])["data"] as? [String: Any])?["owner"] as? String, "B")
        b.release()
    }

    func testGenerationReplacementKeepsEventsAndRequestsSeparate() {
        let old = LynxNativeCapabilityRuntime()
        let replacement = LynxNativeCapabilityRuntime()
        var oldEvents: [String] = []
        var newEvents: [String] = []
        old.setEventSender { oldEvents.append($0) }
        replacement.setEventSender { newEvents.append($0) }
        old.release()
        old.emitAppURL("test://old")
        replacement.emitAppURL("test://new")
        XCTAssertTrue(oldEvents.isEmpty)
        XCTAssertEqual(newEvents.count, 1)
        replacement.release()
    }

    func testQueuedBackgroundResultIsCancelledBeforeMainDelivery() async {
        var finish: ((LynxNativeCapabilityResult) -> Void)?
        let runtime = LynxNativeCapabilityRuntime(dispatch: { _, callback in finish = callback })
        var results: [[String: Any]] = []
        runtime.handleCall(payload()) { results.append(self.object($0)) }
        let queued = DispatchSemaphore(value: 0)
        let callback = finish!
        DispatchQueue.global().async { callback(.success()); queued.signal() }
        XCTAssertEqual(queued.wait(timeout: .now() + 1), .success)
        runtime.release()
        let drained = expectation(description: "主线程排队结果处理完成")
        DispatchQueue.main.async { drained.fulfill() }
        await fulfillment(of: [drained], timeout: 2)
        XCTAssertEqual(results.count, 1)
        XCTAssertEqual((results[0]["error"] as? [String: Any])?["code"] as? String, "HOST_DESTROYED")
    }

    func testScopeResourceCleanupOnlyClosesItsOwnerAndIsIdempotent() {
        let a = LynxNativeOwnerScope()
        let b = LynxNativeOwnerScope()
        var closedA = 0
        var closedB = 0
        LynxNativeOwnerScope.retain(ownerID: a.id) { closedA += 1 }
        LynxNativeOwnerScope.retain(ownerID: b.id) { closedB += 1 }
        XCTAssertTrue(a.close())
        XCTAssertFalse(a.close())
        XCTAssertEqual(closedA, 1)
        XCTAssertEqual(closedB, 0)
        XCTAssertTrue(LynxNativeOwnerScope.isActive(b.id))
        b.close()
        XCTAssertEqual(closedB, 1)
    }

    func testKeepAwakeLastOwnerRestoresPreviousAppState() {
        var idleDisabled = false
        let leases = LynxNativeAppBooleanLeases(read: { idleDisabled }, write: { idleDisabled = $0 })
        leases.acquire(ownerID: "A")
        leases.acquire(ownerID: "B")
        leases.release(ownerID: "A")
        XCTAssertTrue(idleDisabled)
        leases.release(ownerID: "B")
        XCTAssertFalse(idleDisabled)
        idleDisabled = true
        leases.acquire(ownerID: "C")
        leases.release(ownerID: "C")
        XCTAssertTrue(idleDisabled)
        leases.release(ownerID: "C")
        XCTAssertTrue(idleDisabled)
    }

    func testIllegalTransportRejectsWithoutDispatch() {
        var dispatched = 0
        let runtime = LynxNativeCapabilityRuntime(dispatch: { _, _ in dispatched += 1 })
        var results: [[String: Any]] = []
        for payload in ["{", "{\"callbackId\":12,\"pluginId\":\"Device\",\"methodName\":\"getInfo\"}", "{\"pluginId\":\"Device\",\"methodName\":\"getInfo\",\"options\":[]}"] {
            runtime.handleCall(payload) { results.append(self.object($0)) }
        }
        XCTAssertEqual(dispatched, 0)
        XCTAssertEqual(results.count, 3)
        XCTAssertTrue(results.allSatisfy { $0["success"] as? Bool == false })
        runtime.release()
    }

    func testActualDispatcherRejectsUnknownDomainAndMethod() {
        let runtime = LynxNativeCapabilityRuntime()
        var codes: [String] = []
        for call in [payload(plugin: "Unknown"), payload(method: "unknown")] {
            runtime.handleCall(call) { codes.append((self.object($0)["error"] as! [String: Any])["code"] as! String) }
        }
        XCTAssertEqual(codes, ["UNIMPLEMENTED", "UNIMPLEMENTED"])
        runtime.release()
    }

    func testModuleRegistryCanCreateDestroyAndBroadcastAcrossThreads() async {
        let prior = LynxNativeCapabilityRuntime.globalLaunchURL()
        defer { LynxCapacitorModule.setLaunchUrl(prior) }
        let finished = expectation(description: "并发 Module 注册销毁与广播结束")
        DispatchQueue.global().async {
            DispatchQueue.concurrentPerform(iterations: 32) { index in
                let module = LynxCapacitorModule()
                LynxCapacitorModule.emitAppUrlOpen("test://warm/\(index)")
                LynxCapacitorModule.setLaunchUrl("test://launch/\(index)")
                module.destroy()
            }
            finished.fulfill()
        }
        await fulfillment(of: [finished], timeout: 4)
        LynxCapacitorModule.setLaunchUrl("test://final")
        let module = LynxCapacitorModule()
        XCTAssertEqual(LynxNativeCapabilityRuntime.globalLaunchURL(), "test://final")
        module.destroy()
    }

    func testBatteryMonitoringLeaseDriverRestoresOnlyAfterLastOwner() {
        var monitoring = false
        var writes: [Bool] = []
        let leases = LynxNativeAppBooleanLeases(read: { monitoring }, write: { monitoring = $0; writes.append($0) })
        leases.acquire(ownerID: "battery-A")
        leases.acquire(ownerID: "battery-B")
        leases.release(ownerID: "battery-A")
        XCTAssertTrue(monitoring)
        leases.release(ownerID: "battery-B")
        XCTAssertFalse(monitoring)
        XCTAssertEqual(writes, [true, true, false])
        leases.release(ownerID: "battery-B")
        XCTAssertEqual(writes, [true, true, false])
        monitoring = true
        leases.acquire(ownerID: "battery-C")
        leases.release(ownerID: "battery-C")
        XCTAssertTrue(monitoring)
    }

    func testDeviceBatteryInfoReportsUnknownWhenRuntimeCannotMonitor() {
        let device = UIDevice.current
        let previous = device.isBatteryMonitoringEnabled
        defer { device.isBatteryMonitoringEnabled = previous }
        let scope = LynxNativeOwnerScope()
        defer { scope.close(); LynxNativeSystemCapabilities.release(ownerID: scope.id) }
        let call = LynxNativeCapabilityCall(callbackId: "battery", pluginId: "Device", methodName: "getBatteryInfo", options: [:], ownerID: scope.id)
        var result: LynxNativeCapabilityResult?
        _ = LynxNativeSystemCapabilities.dispatch(call, presenter: nil, eventSender: nil) { result = $0 }
        XCTAssertEqual(result?.success, true)
        if result?.data?["available"] as? Bool == true {
            XCTAssertTrue(device.isBatteryMonitoringEnabled)
            XCTAssertNotEqual(device.batteryState, .unknown)
            let level = (result?.data?["batteryLevel"] as? NSNumber)?.floatValue ?? -1
            XCTAssertTrue((0...1).contains(level))
        } else {
            XCTAssertEqual(result?.data?["available"] as? Bool, false)
            XCTAssertTrue(result?.data?["batteryLevel"] is NSNull)
            XCTAssertTrue(result?.data?["isCharging"] is NSNull)
            XCTAssertEqual(result?.data?["batteryState"] as? String, "unknown")
        }
    }

    func testPhysicalBatteryMonitoringLeaseRequiresDevice() throws {
        #if targetEnvironment(simulator)
        throw XCTSkip("BLOCKED：当前为 iOS Simulator，不能把模拟器监控开关或未知电量当作真机电池能力证明。")
        #else
        let device = UIDevice.current
        let previous = device.isBatteryMonitoringEnabled
        defer { device.isBatteryMonitoringEnabled = previous }
        device.isBatteryMonitoringEnabled = false
        let a = LynxNativeOwnerScope()
        let b = LynxNativeOwnerScope()
        defer { a.close(); b.close(); LynxNativeSystemCapabilities.release(ownerID: a.id); LynxNativeSystemCapabilities.release(ownerID: b.id) }
        for scope in [a, b] {
            let call = LynxNativeCapabilityCall(callbackId: "battery", pluginId: "Device", methodName: "getBatteryInfo", options: [:], ownerID: scope.id)
            _ = LynxNativeSystemCapabilities.dispatch(call, presenter: nil, eventSender: nil) { XCTAssertTrue($0.success) }
        }
        XCTAssertTrue(device.isBatteryMonitoringEnabled)
        LynxNativeSystemCapabilities.release(ownerID: a.id)
        XCTAssertTrue(device.isBatteryMonitoringEnabled)
        LynxNativeSystemCapabilities.release(ownerID: b.id)
        XCTAssertFalse(device.isBatteryMonitoringEnabled)
        #endif
    }

    func testExplicitContextDestroyKeepsOtherModuleAliveAndRejectsLateCreation() {
        let a = LynxContext()
        let b = LynxContext()
        let moduleA = LynxCapacitorModule(lynxContext: a)
        let moduleB = LynxCapacitorModule(lynxContext: b)
        defer { moduleA.destroy(); moduleB.destroy() }
        LynxCapacitorModule.destroy(for: a)
        var aResults: [[String: Any]] = []
        var bResults: [[String: Any]] = []
        moduleA.handleCall(payload()) { raw in aResults.append(self.object(raw as! String)) }
        moduleB.handleCall(payload()) { raw in bResults.append(self.object(raw as! String)) }
        XCTAssertEqual((aResults.first?["error"] as? [String: Any])?["code"] as? String, "HOST_DESTROYED")
        XCTAssertEqual(bResults.first?["success"] as? Bool, true)
        let late = LynxContext()
        late.hasLynxViewDestroyed = true
        let lateModule = LynxCapacitorModule(lynxContext: late)
        defer { lateModule.destroy() }
        var lateResults: [[String: Any]] = []
        lateModule.handleCall(payload()) { raw in lateResults.append(self.object(raw as! String)) }
        XCTAssertEqual((lateResults.first?["error"] as? [String: Any])?["code"] as? String, "HOST_DESTROYED")
    }

    func testFirstCallAfterContextDestroyedClosesExistingRuntime() {
        let context = LynxContext()
        let runtime = LynxNativeCapabilityRuntime(lynxContext: context)
        XCTAssertTrue(runtime.isActive)
        context.hasLynxViewDestroyed = true
        var results: [[String: Any]] = []
        runtime.handleCall(payload()) { results.append(self.object($0)) }
        XCTAssertFalse(runtime.isActive)
        XCTAssertEqual((results.first?["error"] as? [String: Any])?["code"] as? String, "HOST_DESTROYED")
    }

    func testOwnedProgressTicketsReturnOnFinishAndHandleEarlyCompletion() {
        let scope = LynxNativeOwnerScope()
        var cancelled = 0
        for _ in 0..<3 {
            let resource = LynxNativeOwnedResource(ownerID: scope.id)
            resource.attach { cancelled += 1 }
            XCTAssertEqual(scope.resourceCount, 1)
            resource.finish()
            XCTAssertEqual(scope.resourceCount, 0)
        }
        let early = LynxNativeOwnedResource(ownerID: scope.id)
        early.finish()
        early.attach { cancelled += 1 }
        XCTAssertEqual(scope.resourceCount, 0)
        scope.close()
        XCTAssertEqual(cancelled, 0)
    }

    func testNormalVideoAndPreviewDismissReturnOnlyTheirOwnResources() {
        let a = LynxNativeOwnerScope()
        let b = LynxNativeOwnerScope()
        defer { a.close(); b.close(); LynxNativeMediaCapabilities.release(ownerID: a.id); LynxNativeMediaCapabilities.release(ownerID: b.id) }
        let videoResource = LynxNativeOwnedResource(ownerID: a.id)
        videoResource.attach { }
        let video = LynxNativeMediaCapabilities.OwnedPlayerController()
        video.resource = videoResource
        video.presentationControllerDidDismiss(UIPresentationController(presentedViewController: video, presenting: UIViewController()))
        XCTAssertEqual(a.resourceCount, 0)
        let before = LynxNativeMediaCapabilities.activePreviewCount
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("test-preview.txt")
        let previewA = LynxNativeMediaCapabilities.makePreviewController(url: url, ownerID: a.id)
        let previewB = LynxNativeMediaCapabilities.makePreviewController(url: url, ownerID: b.id)
        XCTAssertEqual(LynxNativeMediaCapabilities.activePreviewCount, before + 2)
        (previewA.delegate as? LynxNativeMediaCapabilities.PreviewDataSource)?.previewControllerDidDismiss(previewA)
        XCTAssertEqual(LynxNativeMediaCapabilities.activePreviewCount, before + 1)
        (previewB.delegate as? LynxNativeMediaCapabilities.PreviewDataSource)?.previewControllerDidDismiss(previewB)
        XCTAssertEqual(LynxNativeMediaCapabilities.activePreviewCount, before)
    }

    func testNetworkStatusCompletionReturnsTimeoutResource() async {
        let scope = LynxNativeOwnerScope()
        defer { scope.close(); LynxNativeSystemCapabilities.release(ownerID: scope.id) }
        let completed = expectation(description: "实际网络状态查询终止并归还资源")
        let call = LynxNativeCapabilityCall(callbackId: "network", pluginId: "Network", methodName: "getStatus", options: [:], ownerID: scope.id)
        _ = LynxNativeSystemCapabilities.dispatch(call, presenter: nil, eventSender: nil) { _ in
            XCTAssertEqual(scope.resourceCount, 0)
            completed.fulfill()
        }
        await fulfillment(of: [completed], timeout: 4)
    }
}
