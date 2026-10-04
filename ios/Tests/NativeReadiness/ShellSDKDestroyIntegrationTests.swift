import XCTest
import UIKit
import Lynx
@testable import LynxShellKitE2ECore
@testable import LynxCapacitorKit

@MainActor
final class ShellSDKDestroyIntegrationTests: XCTestCase {
    func testActualShellViewDestroyReleasesCapHostExactlyOnce() async throws {
        let oldProvider = LynxCapacitorHostRegistry.current()
        let spy = DestroyHostSpy()
        LynxCapacitorModule.installHostProvider(spy)
        LynxRouter.registerNativeModule(LynxCapacitorModule.self, onViewDestroy: LynxCapacitorModule.destroy(for:))
        defer { LynxCapacitorModule.installHostProvider(oldProvider) }
        SDKDestroyProbe.reset()
        let origin = ProcessInfo.processInfo.environment["TEMPLATE_READINESS_ORIGIN"] ?? "http://127.0.0.1:60543"
        let url = URL(string: origin + "/files/HomePage.lynx.bundle")!
        let (bytes, response) = try await URLSession.shared.data(from: url)
        XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 200)
        XCTAssertGreaterThan(bytes.count, 0)
        let provider = ShellTemplateProvider(allowHTTPInDebug: true, onLoadError: { url, error in XCTFail("\(url): \(error.localizedDescription)") },
            prefetchedURL: url.absoluteString, prefetchedData: bytes)
        let config = LynxConfig(provider: provider)
        config.register(SDKDestroyProbe.self)
        let size = CGSize(width: 390, height: 844)
        let view = LynxView { builder in
            builder.config = config
            builder.screenSize = size
        }
        view.frame = CGRect(origin: .zero, size: size)
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let window = UIWindow(windowScene: scene)
        window.frame = view.frame
        let container = UIViewController()
        window.rootViewController = container
        container.view.addSubview(view)
        window.isHidden = false
        defer { LynxNativeRuntime.destroy(view: view); window.isHidden = true }
        LynxNativeRuntime.load(url: url.absoluteString, initData: [:], in: view)
        let constructed = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in SDKDestroyProbe.created == 1 }, object: nil)
        await fulfillment(of: [constructed], timeout: 15)
        XCTAssertEqual(SDKDestroyProbe.created, 1, "必须由真实模板调用触发 SDK Module 实例化")
        LynxNativeRuntime.destroy(view: view)
        XCTAssertEqual(spy.released, 1)
        LynxNativeRuntime.destroy(view: view)
        XCTAssertEqual(spy.released, 1)
    }
}

private final class DestroyHostSpy: LynxCapacitorHostProvider {
    let supportedMethods: [String: [String]] = [:]
    private(set) var released = 0
    func host(for context: LynxContext) -> AnyObject? { nil }
    func releaseHost(for context: LynxContext) { released += 1 }
}

/** 只在该测试 View 的 Config 替换 Shell transport；实际创建的 Cap 由 Shell teardown hook 释放。 */
@objcMembers
private final class SDKDestroyProbe: NSObject, LynxContextModule {
    private static let countLock = NSLock()
    private static var createCount = 0
    private static var destroyCount = 0
    private let cap: LynxCapacitorModule
    private var ended = false
    static var name: String { "LynxShellModule" }
    static var methodLookup: [String: String] { ["markOtaHealthy": NSStringFromSelector(#selector(markOtaHealthy(_:)))] }
    static var created: Int { countLock.withLock { createCount } }
    static var destroyed: Int { countLock.withLock { destroyCount } }
    static func reset() { countLock.withLock { createCount = 0; destroyCount = 0 } }
    required init(lynxContext: LynxContext) {
        cap = LynxCapacitorModule(lynxContext: lynxContext)
        super.init()
        Self.countLock.withLock { Self.createCount += 1 }
    }
    required init(lynxContext: LynxContext, withParam param: Any) {
        cap = LynxCapacitorModule(lynxContext: lynxContext, withParam: param)
        super.init()
        Self.countLock.withLock { Self.createCount += 1 }
    }
    init(param: Any) {
        cap = LynxCapacitorModule(param: param)
        super.init()
        Self.countLock.withLock { Self.createCount += 1 }
    }
    override init() {
        cap = LynxCapacitorModule()
        super.init()
        Self.countLock.withLock { Self.createCount += 1 }
    }
    func markOtaHealthy(_ completion: @escaping (NSDictionary) -> Void) {
        completion(["code": 0, "message": "", "data": ["confirmed": false, "reason": "not_candidate"]])
    }
    func destroy() {
        guard !ended else { return }
        ended = true
        cap.destroy()
        Self.countLock.withLock { Self.destroyCount += 1 }
    }
}
