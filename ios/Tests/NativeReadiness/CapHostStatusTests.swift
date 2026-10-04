import XCTest
import Lynx
import UIKit
import CoreMotion
@testable import LynxCapacitorKit

@MainActor
final class CapHostStatusTests: XCTestCase {
    private func domains(_ runtime: LynxNativeCapabilityRuntime) -> [[String: Any]] {
        try! JSONSerialization.jsonObject(with: Data(runtime.getCapabilityStatus().utf8)) as! [[String: Any]]
    }

    func testCatalogPreservesFortyDomainsAndOneHundredFortySixMethods() {
        let runtime = LynxNativeCapabilityRuntime()
        defer { runtime.release() }
        let values = domains(runtime)
        XCTAssertEqual(values.count, 40)
        XCTAssertEqual(values.flatMap { $0["methods"] as! [String] }.count, 146)
        XCTAssertEqual(values.map { $0["name"] as! String }, LynxNativeCapabilityCatalog.specs.map(\.id))
    }

    func testProviderSnapshotControlsMethodStatusAndDoesNotClaimPermissions() {
        let old = LynxCapacitorHostRegistry.current()
        defer { LynxCapacitorModule.installHostProvider(old) }
        LynxCapacitorModule.installHostProvider(nil)
        let runtime = LynxNativeCapabilityRuntime()
        defer { runtime.release() }
        let noHost = domains(runtime)
        let status = noHost.first { $0["name"] as? String == "StatusBar" }!
        XCTAssertEqual(status["state"] as? String, "partial")
        XCTAssertEqual(status["implementedMethods"] as? [String], ["getInfo"])
        XCTAssertEqual(status["hostConfigured"] as? Bool, false)
        XCTAssertEqual(status["runtimeAvailability"] as? String, "checkRequired")
        let orientation = noHost.first { $0["name"] as? String == "ScreenOrientation" }!
        XCTAssertEqual(orientation["implementedMethods"] as? [String], [])
        let provider = FakeHostProvider()
        provider.methods = ["StatusBar": ["setStyle", "hide", "show"], "SystemBars": ["setStyle"], "ScreenOrientation": ["orientation", "lock", "unlock"], "Keyboard": ["setStyle"]]
        LynxCapacitorModule.installHostProvider(provider)
        provider.methods = [:]
        let installed = domains(runtime)
        let installedStatus = installed.first { $0["name"] as? String == "StatusBar" }!
        XCTAssertEqual(installedStatus["state"] as? String, "partial")
        XCTAssertEqual(installedStatus["hostConfigured"] as? Bool, true)
        XCTAssertEqual(installedStatus["runtimeAvailability"] as? String, "checkRequired")
        XCTAssertEqual(installed.first { $0["name"] as? String == "ScreenOrientation" }?["reasonCode"] as? String, "RUNTIME_CONTEXT_REQUIRED")
        XCTAssertEqual(installed.first { $0["name"] as? String == "Keyboard" }?["reasonCode"] as? String, "RUNTIME_CONTEXT_REQUIRED")
        XCTAssertEqual(installed.first { $0["name"] as? String == "SystemBars" }?["scope"] as? String, "status_bar_only")
        XCTAssertEqual(provider.resolutions, 0)
        XCTAssertNil(installed.first?["permissions"])
    }

    func testSyncStatusQueryDoesNotResolveUIKitHostFromBackground() async {
        let old = LynxCapacitorHostRegistry.current()
        defer { LynxCapacitorModule.installHostProvider(old) }
        let provider = FakeHostProvider()
        LynxCapacitorModule.installHostProvider(provider)
        let runtime = LynxNativeCapabilityRuntime()
        defer { runtime.release() }
        let done = expectation(description: "后台同步查询完成")
        DispatchQueue.global().async {
            let values = try! JSONSerialization.jsonObject(with: Data(runtime.getCapabilityStatus().utf8)) as! [[String: Any]]
            XCTAssertEqual(values.count, 40)
            done.fulfill()
        }
        await fulfillment(of: [done], timeout: 2)
        XCTAssertEqual(provider.resolutions, 0)
    }

    func testStatusBarFallbackReadAndInstalledHostWriteUseActualAdapter() {
        let presenter = UIViewController()
        let get = LynxNativeCapabilityCall(callbackId: "get", pluginId: "StatusBar", methodName: "getInfo", options: [:])
        var read: LynxNativeCapabilityResult?
        XCTAssertTrue(LynxNativeSystemCapabilities.dispatch(get, presenter: presenter, eventSender: nil) { read = $0 })
        XCTAssertEqual(read?.success, true)
        let set = LynxNativeCapabilityCall(callbackId: "set", pluginId: "StatusBar", methodName: "setStyle", options: ["style": "DARK"])
        var missing: LynxNativeCapabilityResult?
        _ = LynxNativeSystemCapabilities.dispatch(set, presenter: presenter, eventSender: nil) { missing = $0 }
        XCTAssertEqual(missing?.error?["code"] as? String, "UNSUPPORTED_SYSTEM_UI")
        let adapter = FakeStatusHost()
        var changed: LynxNativeCapabilityResult?
        _ = LynxNativeSystemCapabilities.dispatch(set, presenter: presenter, host: adapter, eventSender: nil) { changed = $0 }
        XCTAssertEqual(changed?.success, true)
        XCTAssertEqual(adapter.style, "DARK")
    }

    func testOwnerOverlaysReleaseWithoutRemovingOtherPage() {
        let a = LynxNativeOwnerScope()
        let b = LynxNativeOwnerScope()
        let presenterA = UIViewController()
        let presenterB = UIViewController()
        presenterA.loadViewIfNeeded()
        presenterB.loadViewIfNeeded()
        let beforeA = presenterA.view.subviews.count
        let beforeB = presenterB.view.subviews.count
        for (scope, presenter) in [(a, presenterA), (b, presenterB)] {
            let show = LynxNativeCapabilityCall(callbackId: "same", pluginId: "SplashScreen", methodName: "show", options: [:], ownerID: scope.id)
            _ = LynxNativeSystemCapabilities.dispatch(show, presenter: presenter, eventSender: nil) { XCTAssertTrue($0.success) }
        }
        XCTAssertEqual(presenterA.view.subviews.count, beforeA + 1)
        XCTAssertEqual(presenterB.view.subviews.count, beforeB + 1)
        a.close()
        LynxNativeSystemCapabilities.release(ownerID: a.id)
        XCTAssertEqual(presenterA.view.subviews.count, beforeA)
        XCTAssertEqual(presenterB.view.subviews.count, beforeB + 1)
        b.close()
        LynxNativeSystemCapabilities.release(ownerID: b.id)
        XCTAssertEqual(presenterB.view.subviews.count, beforeB)
    }

    func testActualMotionRegistryKeepsSameIDAndStopOwnedByEachPage() {
        let manager = FakeMotionManager()
        let state = LynxNativeProviderCapabilities.MotionState(manager: manager)
        let a = LynxNativeOwnerScope()
        let b = LynxNativeOwnerScope()
        defer { a.close(); b.close(); state.stop(clearListeners: true) }
        let options: [String: Any] = ["eventName": "accel", "listenerId": "same"]
        XCTAssertTrue(state.addListener(options, eventSender: nil, ownerID: a.id).success)
        XCTAssertTrue(state.addListener(options, eventSender: nil, ownerID: b.id).success)
        XCTAssertEqual(state.start(ownerID: b.id).data?["listenerCount"] as? Int, 2)
        XCTAssertEqual(state.stop(ownerID: a.id).data?["listenerCount"] as? Int, 1)
        XCTAssertEqual(manager.stopCount, 0)
        XCTAssertEqual(state.removeAllListeners(ownerID: a.id).data?["removed"] as? Int, 1)
        XCTAssertEqual(state.removeListener(options, ownerID: b.id).data?["removed"] as? Bool, true)
        XCTAssertEqual(manager.stopCount, 1)
    }

    func testOrientationWaitsForHostAndReturnsRejectionInsteadOfSuccess() {
        let host = DeferredOrientationHost()
        let presenter = UIViewController()
        let call = LynxNativeCapabilityCall(callbackId: "orientation", pluginId: "ScreenOrientation", methodName: "lock", options: ["orientation": "landscape"])
        var results: [LynxNativeCapabilityResult] = []
        _ = LynxNativeSystemCapabilities.dispatch(call, presenter: presenter, host: host, eventSender: nil) { results.append($0) }
        XCTAssertTrue(results.isEmpty)
        host.finish?(.failure(NSError(domain: "FakeGeometryRejected", code: 17, userInfo: [NSLocalizedDescriptionKey: "测试拒绝旋转"])))
        XCTAssertEqual(results.count, 1)
        XCTAssertEqual(results[0].success, false)
        XCTAssertEqual(results[0].error?["code"] as? String, "ORIENTATION_FAILED")
        let unlock = LynxNativeCapabilityCall(callbackId: "unlock", pluginId: "ScreenOrientation", methodName: "unlock", options: [:])
        results.removeAll()
        _ = LynxNativeSystemCapabilities.dispatch(unlock, presenter: presenter, host: host, eventSender: nil) { results.append($0) }
        XCTAssertTrue(results.isEmpty)
        host.finish?(.success(["unlocked": true, "applied": true]))
        XCTAssertEqual(results.first?.data?["applied"] as? Bool, true)
    }

    func testDestroyedOwnerCancelsOrientationOnceAndDropsLateHostSuccess() {
        let host = DeferredOrientationHost()
        let presenter = UIViewController()
        let runtime = LynxNativeCapabilityRuntime(dispatch: { call, callback in
            _ = LynxNativeSystemCapabilities.dispatch(call, presenter: presenter, host: host, eventSender: nil, completion: callback)
        })
        let payload = "{\"callbackId\":\"owner\",\"pluginId\":\"ScreenOrientation\",\"methodName\":\"lock\",\"options\":{\"orientation\":\"portrait\"}}"
        var results: [[String: Any]] = []
        runtime.handleCall(payload) { raw in results.append(try! JSONSerialization.jsonObject(with: Data(raw.utf8)) as! [String: Any]) }
        XCTAssertTrue(results.isEmpty)
        runtime.release()
        host.finish?(.success(["orientation": "portrait", "applied": true]))
        XCTAssertEqual(results.count, 1)
        XCTAssertEqual((results[0]["error"] as? [String: Any])?["code"] as? String, "HOST_DESTROYED")
    }

    func testMissingAndBlankUsageDescriptionFailBeforeSystemAdapter() {
        let call = LynxNativeCapabilityCall(callbackId: "privacy", pluginId: "Contacts", methodName: "requestPermissions", options: [:])
        for info in [[:], ["NSContactsUsageDescription": "  \n"]] {
            let dispatcher = LynxNativeCapabilityDispatcher(infoDictionary: { info }, systemMajorVersion: 17)
            var result: LynxNativeCapabilityResult?
            dispatcher.dispatch(call, presenter: nil) { result = $0 }
            XCTAssertEqual(result?.error?["code"] as? String, "HOST_CONFIGURATION_REQUIRED")
            XCTAssertEqual(result?.error?["missingKeys"] as? [String], ["NSContactsUsageDescription"])
        }
        XCTAssertNil(LynxNativeUsageDescriptions.validate(call, info: ["NSContactsUsageDescription": "读取你选择的联系人"], systemMajorVersion: 17))
    }

    func testCalendarUsageKeysFollowActualRequestAPIBySystemVersion() {
        let read = LynxNativeCapabilityCall(callbackId: "read", pluginId: "Calendar", methodName: "requestPermissions", options: ["permissions": ["read"]])
        let write = LynxNativeCapabilityCall(callbackId: "write", pluginId: "Calendar", methodName: "requestPermissions", options: ["permissions": ["write"]])
        XCTAssertEqual(LynxNativeUsageDescriptions.requiredKeys(read, systemMajorVersion: 16), ["NSCalendarsUsageDescription"])
        XCTAssertEqual(LynxNativeUsageDescriptions.requiredKeys(read, systemMajorVersion: 17), ["NSCalendarsFullAccessUsageDescription"])
        XCTAssertEqual(LynxNativeUsageDescriptions.requiredKeys(write, systemMajorVersion: 17), ["NSCalendarsWriteOnlyAccessUsageDescription"])
        XCTAssertNotNil(LynxNativeUsageDescriptions.validate(read, info: ["NSCalendarsUsageDescription": "旧键"], systemMajorVersion: 17))
        XCTAssertNotNil(LynxNativeUsageDescriptions.validate(read, info: ["NSCalendarsFullAccessUsageDescription": "新键"], systemMajorVersion: 16))
    }

    func testCameraAudioAndLocationUsageMappingMatchesActualMethods() {
        func keys(_ plugin: String, _ method: String, _ options: [String: Any] = [:]) -> [String] {
            LynxNativeUsageDescriptions.requiredKeys(LynxNativeCapabilityCall(callbackId: "privacy", pluginId: plugin, methodName: method, options: options), systemMajorVersion: 17)
        }
        XCTAssertEqual(keys("Camera", "recordVideo"), ["NSCameraUsageDescription", "NSMicrophoneUsageDescription"])
        XCTAssertEqual(keys("Camera", "getPhoto", ["source": "PHOTOS"]), [])
        XCTAssertEqual(keys("Camera", "getPhoto", ["source": "PHOTOS", "saveToGallery": true]), ["NSPhotoLibraryAddUsageDescription"])
        XCTAssertEqual(keys("Audio", "record"), ["NSMicrophoneUsageDescription"])
        XCTAssertEqual(keys("Geolocation", "requestPermissions", ["permissions": ["always"]]), ["NSLocationWhenInUseUsageDescription", "NSLocationAlwaysAndWhenInUseUsageDescription"])
    }
}

private final class FakeHostProvider: LynxCapacitorHostProvider {
    var methods: [String: [String]] = [:]
    var resolutions = 0
    var supportedMethods: [String: [String]] { methods }
    func host(for context: LynxContext) -> AnyObject? { precondition(Thread.isMainThread); resolutions += 1; return nil }
}

private final class FakeStatusHost: LynxCapacitorStatusBarHost {
    var style = "DEFAULT"
    func setCapacitorStatusBarVisible(_ visible: Bool) { }
    func setCapacitorStatusBarStyle(_ value: String) -> Bool { style = value; return true }
    func setCapacitorStatusBarColor(_ value: String) -> Bool { false }
    func setCapacitorStatusBarOverlay(_ overlay: Bool) { }
    func capacitorStatusBarInfo() -> [String: Any] { ["style": style, "visible": true] }
}

private final class FakeMotionManager: CMMotionManager {
    var active = false
    var stopCount = 0
    override var isDeviceMotionAvailable: Bool { true }
    override var isDeviceMotionActive: Bool { active }
    override func startDeviceMotionUpdates(to queue: OperationQueue, withHandler handler: @escaping CMDeviceMotionHandler) { active = true }
    override func stopDeviceMotionUpdates() { active = false; stopCount += 1 }
}

private final class DeferredOrientationHost: LynxCapacitorOrientationHost {
    var finish: ((Result<[String: Any], Error>) -> Void)?
    func applyCapacitorOrientation(_ value: String, completion: @escaping (Result<[String: Any], Error>) -> Void) { finish = completion }
    func clearCapacitorOrientation(completion: @escaping (Result<[String: Any], Error>) -> Void) { finish = completion }
}
