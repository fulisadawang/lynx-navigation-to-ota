import XCTest

final class LynxShellUITests: XCTestCase {
    private var app: XCUIApplication!

    override func setUp() {
        super.setUp()
        continueAfterFailure = false
        app = XCUIApplication()
        app.launchArguments = ["--show-native-launcher"]
        if let token = Self.testOtaToken {
            app.launchEnvironment["LYNX_OTA_API_BASE_URL"] = Self.testOtaBaseURL
            app.launchEnvironment["LYNX_OTA_CLIENT_TOKEN"] = token
            app.launchEnvironment["LYNX_OTA_ENV"] = Self.testOtaEnvironment
            if Self.testOtaBaseURL.lowercased().hasPrefix("http://127.0.0.1") ||
                Self.testOtaBaseURL.lowercased().hasPrefix("http://localhost") {
                app.launchEnvironment["LYNX_OTA_ALLOW_LOCAL_HTTP"] = "1"
            }
            // UI suite 中由具体用例显式点击“刷新 OTA”；避免启动全量同步与故障/Tab断言竞争。
            app.launchEnvironment["LYNX_TEST_SKIP_STARTUP_SYNC"] = "1"
            // 当前外网可能不可达；OTA 成功语义通过 Debug mock 复现，F12 会显式关闭它。
            if !Self.useLiveOta {
                app.launchEnvironment["LYNX_TEST_MOCK_OTA"] = "1"
            }
        }
    }

    override func tearDown() {
        app?.terminate()
        super.tearDown()
    }

    func testNativeTabRoundTripKeepsBothTabsVisible() {
        launchApp()
        let tabDemo = app.buttons["打开原生 Tab 承载 Demo"]
        XCTAssertTrue(tabDemo.waitForExistence(timeout: 10))
        tabDemo.tap()

        let home = app.buttons["首页"]
        let settings = app.buttons["设置"]
        XCTAssertTrue(home.waitForExistence(timeout: 10))
        XCTAssertTrue(settings.waitForExistence(timeout: 10))

        for _ in 0..<10 {
            settings.tap()
            home.tap()
        }

        XCTAssertTrue(home.isSelected || home.value as? String == "1")
        XCTAssertTrue(settings.exists)
    }

    func testNativeTabSwitchingDoesNotReloadInstances() {
        launchApp(extraEnvironment: [
            "LYNX_UI_TEST_EXPOSE_RUNTIME_STATE": "1",
            "LYNX_TEST_OTA_V3_FIXTURE": "1",
        ])
        let tabDemo = app.buttons["打开原生 Tab 承载 Demo"]
        XCTAssertTrue(tabDemo.waitForExistence(timeout: 10))
        tabDemo.tap()

        let home = app.buttons["首页"]
        let settings = app.buttons["设置"]
        let state = app.staticTexts["lynx-debug-tab-state"]
        XCTAssertTrue(home.waitForExistence(timeout: 10))
        XCTAssertTrue(settings.waitForExistence(timeout: 10))
        XCTAssertTrue(state.waitForExistence(timeout: 10))

        settings.tap()
        home.tap()
        waitForLabel(state, containing: "home=instance=")
        waitForLabel(state, containing: "settings=instance=")

        if Self.testOtaToken != nil {
            let refresh = app.buttons["刷新 OTA"]
            XCTAssertTrue(refresh.waitForExistence(timeout: 10))
            refresh.tap()
            XCTAssertTrue(app.staticTexts["OTA 同步完成"].waitForExistence(timeout: 20))
            app.buttons["确定"].tap()
            settings.tap()
            home.tap()
            waitForLabel(state, containing: "home=instance=")
            waitForLabel(state, containing: "settings=instance=")
        }

        let before = state.label
        let beforeHTTPCount = debugHTTPCount(from: before)
        XCTAssertNotNil(beforeHTTPCount, "Tab Debug 状态必须暴露真实 HTTP 计数：\(before)")
        if Self.testOtaToken != nil {
            XCTAssertGreaterThan(beforeHTTPCount ?? 0, 0, "带 TEST OTA 配置时应观察到真实 HTTP 请求：\(before)")
        } else {
            XCTAssertEqual(beforeHTTPCount, 0, "无 OTA token 时 Tab 不应发出 HTTP 请求：\(before)")
        }

        for _ in 0..<10 {
            settings.tap()
            home.tap()
        }

        XCTAssertEqual(state.label, before, "切换 Tab 不应重新创建 LynxView 或增加 resolveCurrent：\(state.label)")
        XCTAssertEqual(
            debugHTTPCount(from: state.label),
            beforeHTTPCount,
            "切换 Tab 不应增加真实 ServerOtaAPIClient HTTP 请求：\(state.label)"
        )
    }

    func testLeftEdgeSwipeReturnsToNativeLauncher() {
        launchApp()
        let otaHome = app.buttons["打开 OTA 验收首页"].firstMatch
        XCTAssertTrue(otaHome.waitForExistence(timeout: 10))
        otaHome.tap()
        XCTAssertTrue(app.staticTexts["Bundle 跳转验收台"].waitForExistence(timeout: 10))

        let start = app.coordinate(withNormalizedOffset: CGVector(dx: 0.01, dy: 0.5))
        let end = app.coordinate(withNormalizedOffset: CGVector(dx: 0.92, dy: 0.5))
        start.press(forDuration: 0.05, thenDragTo: end, withVelocity: XCUIGestureVelocity.fast, thenHoldForDuration: 0)

        XCTAssertTrue(
            app.buttons["打开原生 Tab 承载 Demo"].waitForExistence(timeout: 10),
            "完整左边缘拖动后应回到原生 Launcher"
        )
    }

    func testTabRefreshFailureKeepsExistingTab() {
        launchApp(extraEnvironment: [
            "LYNX_UI_TEST_EXPOSE_RUNTIME_STATE": "1",
        ])
        let tabDemo = app.buttons["打开原生 Tab 承载 Demo"]
        XCTAssertTrue(tabDemo.waitForExistence(timeout: 10))
        tabDemo.tap()

        let home = app.buttons["首页"]
        let refresh = app.buttons["刷新 OTA"]
        XCTAssertTrue(home.waitForExistence(timeout: 10))
        XCTAssertTrue(refresh.waitForExistence(timeout: 10))

        let state = app.staticTexts["lynx-debug-tab-state"]
        XCTAssertTrue(state.waitForExistence(timeout: 10))
        waitForLabel(state, containing: "home=instance=")
        let before = state.label

        // 本用例默认不注入 OTA token，验证 embedded-only/网络失败时不替换 Tab 实例。
        if Self.testOtaToken == nil {
            refresh.tap()
            XCTAssertTrue(app.staticTexts["OTA 同步失败"].waitForExistence(timeout: 10))
            app.buttons["确定"].tap()
            XCTAssertTrue(home.exists)
            XCTAssertEqual(state.label, before, "刷新失败不应替换当前 Tab 实例：\(state.label)")
        }
    }

    func testMockedOtaRefreshSucceedsWhenTokenIsProvided() throws {
        guard !Self.useLiveOta else {
            throw XCTSkip("live OTA 模式由 testLiveOtaServerRefreshSmoke 单独执行")
        }
        launchApp(extraEnvironment: [
            "LYNX_UI_TEST_EXPOSE_RUNTIME_STATE": "1",
        ])
        guard Self.testOtaToken != nil else {
            throw XCTSkip("需要通过 LYNX_OTA_CLIENT_TOKEN 注入 TEST OTA 凭据")
        }
        let tabDemo = app.buttons["打开原生 Tab 承载 Demo"]
        XCTAssertTrue(tabDemo.waitForExistence(timeout: 10))
        tabDemo.tap()

        let refresh = app.buttons["刷新 OTA"]
        XCTAssertTrue(refresh.waitForExistence(timeout: 10))
        let state = app.staticTexts["lynx-debug-tab-state"]
        XCTAssertTrue(state.waitForExistence(timeout: 10))
        waitForLabel(state, containing: "home=instance=")
        let before = state.label
        refresh.tap()
        XCTAssertTrue(app.staticTexts["OTA 同步完成"].waitForExistence(timeout: 20))
        app.buttons["确定"].tap()
        XCTAssertTrue(app.buttons["首页"].exists)
        waitForLabelChange(state, from: before)
    }

    func testLiveOtaServerRefreshSmoke() throws {
        guard Self.testOtaToken != nil, Self.useLiveOta else {
            throw XCTSkip("仅在显式 LYNX_TEST_LIVE_OTA=1 时访问 OTA Server")
        }
        launchApp(extraEnvironment: [
            "LYNX_UI_TEST_EXPOSE_RUNTIME_STATE": "1",
            "LYNX_TEST_OTA_V3_FIXTURE": "1",
        ])
        let tabDemo = app.buttons["打开原生 Tab 承载 Demo"]
        XCTAssertTrue(tabDemo.waitForExistence(timeout: 10))
        tabDemo.tap()

        let refresh = app.buttons["刷新 OTA"]
        XCTAssertTrue(refresh.waitForExistence(timeout: 10))
        let state = app.staticTexts["lynx-debug-tab-state"]
        XCTAssertTrue(state.waitForExistence(timeout: 10))
        waitForLabel(state, containing: "home=instance=")
        let before = state.label
        let beforeHTTPCount = debugHTTPCount(from: before)
        refresh.tap()

        let success = app.staticTexts["OTA 同步完成"].waitForExistence(timeout: 25)
        if success {
            app.buttons["确定"].tap()
            XCTAssertTrue(app.buttons["首页"].exists)
            waitForLabelChange(state, from: before)
            XCTAssertGreaterThan(
                debugHTTPCount(from: state.label) ?? 0,
                beforeHTTPCount ?? 0,
                "live OTA 刷新成功后 HTTP 计数应增加：\(state.label)"
            )
            return
        }

        let unavailable = app.staticTexts["OTA 同步失败"].waitForExistence(timeout: 5)
        if unavailable {
            app.buttons["确定"].tap()
            throw XCTSkip("当前网络无法访问 OTA Server；客户端 mock suite 已覆盖同一协议")
        }
        throw XCTSkip("OTA Server 在限定时间内无响应；客户端 mock suite 已覆盖同一协议")
    }

    func testDeferredTabLoadCannotOverwriteNewGeneration() {
        launchApp(extraEnvironment: [
            "LYNX_UI_TEST_EXPOSE_RUNTIME_STATE": "1",
            "LYNX_TEST_TAB_DEFER_FIRST_RESOLVE_MS": "8000",
        ])
        let tabDemo = app.buttons["打开原生 Tab 承载 Demo"]
        XCTAssertTrue(tabDemo.waitForExistence(timeout: 10))
        tabDemo.tap()

        let rebuild = app.buttons["重建 Tab"]
        let state = app.staticTexts["lynx-debug-tab-state"]
        XCTAssertTrue(rebuild.waitForExistence(timeout: 10))
        XCTAssertTrue(state.waitForExistence(timeout: 10))
        rebuild.tap()

        waitForLabel(state, containing: "load=2;resolve=2;render=1", timeout: 15)
        XCTAssertTrue(state.label.contains("home=instance="), state.label)
        XCTAssertTrue(state.label.contains("load=2;resolve=2;render=1"), state.label)
        XCTAssertFalse(state.label.contains("Tab 加载失败"), state.label)
        // 让被取消但故意迟到的旧 resolve 完成，确认 generation 门禁仍不允许它覆盖新实例。
        Thread.sleep(forTimeInterval: 9)
        XCTAssertTrue(state.label.contains("load=2;resolve=2;render=1"), state.label)
    }

    func testFirstScreenFailureRollsBackToPreviousRelease() {
        launchApp(extraEnvironment: [
            "LYNX_TEST_FAULT_SCENARIO": "first_screen_previous",
            "LYNX_TEST_FORCE_FIRST_SCREEN_FAILURE": "1",
            "LYNX_UI_TEST_EXPOSE_RUNTIME_STATE": "1",
        ])
        openOtaAcceptanceHome()

        let state = app.staticTexts["lynx-debug-ota-state"]
        XCTAssertTrue(state.waitForExistence(timeout: 10))
        waitForLabel(state, containing: "ready:fault-v1:ota_current")
    }

    func testFirstScreenFailureFallsBackToEmbeddedBaselineWithoutPrevious() {
        launchApp(extraEnvironment: [
            "LYNX_TEST_FAULT_SCENARIO": "first_screen_embedded",
            "LYNX_TEST_FORCE_FIRST_SCREEN_FAILURE": "1",
            "LYNX_UI_TEST_EXPOSE_RUNTIME_STATE": "1",
        ])
        openOtaAcceptanceHome()

        let state = app.staticTexts["lynx-debug-ota-state"]
        XCTAssertTrue(state.waitForExistence(timeout: 10))
        waitForLabel(state, containing: "ready:")
        XCTAssertTrue(state.label.contains("rollback_fallback"), state.label)
    }

    func testRollbackRecoversAfterProcessTermination() throws {
        guard Self.testOtaToken != nil else {
            throw XCTSkip("F12 需要 TEST OTA 配置以准备真实 downloaded current/previous")
        }
        launchApp(extraEnvironment: [
            "LYNX_TEST_PAUSE_AFTER_ROLLBACK_COMMIT": "1",
            "LYNX_TEST_RESET_PROCESS_FAULT_MARKER": "1",
            "LYNX_TEST_FORCE_FIRST_SCREEN_FAILURE": "1",
            "LYNX_TEST_SKIP_STARTUP_SYNC": "1",
            "LYNX_TEST_MOCK_OTA": "0",
            "LYNX_UI_TEST_EXPOSE_RUNTIME_STATE": "1",
        ])

        let prepare = app.buttons["准备 F12 回滚进程测试"]
        let f12Status = app.staticTexts["lynx-debug-f12-status"]
        XCTAssertTrue(prepare.waitForExistence(timeout: 10))
        XCTAssertTrue(f12Status.waitForExistence(timeout: 10))
        prepare.tap()
        let prepareAlert = app.alerts.firstMatch
        XCTAssertTrue(
            prepareAlert.waitForExistence(timeout: 90),
            "F12 准备没有返回结果，当前阶段：\(f12Status.label)"
        )
        XCTAssertEqual(prepareAlert.label, "F12 准备完成", prepareAlert.debugDescription)
        prepareAlert.buttons["确定"].tap()
        openOtaAcceptanceHome()

        let marker = app.staticTexts["lynx-debug-rollback-marker"]
        let otaState = app.staticTexts["lynx-debug-ota-state"]
        XCTAssertTrue(marker.waitForExistence(timeout: 10))
        waitForLabel(
            marker,
            containing: "rollback_marker:after_rollback_commit",
            timeout: 25,
            context: otaState
        )

        app.terminate()
        app.launchEnvironment["LYNX_TEST_PAUSE_AFTER_ROLLBACK_COMMIT"] = "0"
        app.launchEnvironment["LYNX_TEST_RESET_PROCESS_FAULT_MARKER"] = "0"
        app.launchEnvironment["LYNX_TEST_FORCE_FIRST_SCREEN_FAILURE"] = "0"
        app.launch()
        openOtaAcceptanceHome()

        let recoveredState = app.staticTexts["lynx-debug-ota-state"]
        XCTAssertTrue(recoveredState.waitForExistence(timeout: 10))
        waitForLabel(recoveredState, containing: "ready:", timeout: 20)
        XCTAssertFalse(recoveredState.label.contains("failure:"), recoveredState.label)
        XCTAssertTrue(app.staticTexts["Bundle 跳转验收台"].waitForExistence(timeout: 15))
    }

    private func launchApp(extraEnvironment: [String: String] = [:]) {
        extraEnvironment.forEach { app.launchEnvironment[$0.key] = $0.value }
        app.launch()
    }

    private func openOtaAcceptanceHome() {
        let otaHome = app.buttons["打开 OTA 验收首页"].firstMatch
        XCTAssertTrue(otaHome.waitForExistence(timeout: 10))
        otaHome.tap()
    }

    private func waitForLabel(
        _ element: XCUIElement,
        containing expected: String,
        timeout: TimeInterval = 15,
        context: XCUIElement? = nil
    ) {
        let predicate = NSPredicate(format: "label CONTAINS %@", expected)
        let expectation = XCTNSPredicateExpectation(predicate: predicate, object: element)
        let result = XCTWaiter.wait(for: [expectation], timeout: timeout)
        let contextLabel = context.map { ", context=\($0.label)" } ?? ""
        XCTAssertEqual(result, .completed, "等待状态包含 \(expected)，实际：\(element.label)\(contextLabel)")
    }

    private func waitForLabelChange(
        _ element: XCUIElement,
        from previous: String,
        timeout: TimeInterval = 15
    ) {
        let predicate = NSPredicate(format: "label != %@", previous)
        let expectation = XCTNSPredicateExpectation(predicate: predicate, object: element)
        let result = XCTWaiter.wait(for: [expectation], timeout: timeout)
        XCTAssertEqual(result, .completed, "等待 Tab 实例状态变化，实际：\(element.label)")
    }

    private func debugHTTPCount(from label: String) -> Int? {
        guard let value = label.components(separatedBy: "http=").last else { return nil }
        let number = value.split { $0 == "|" || $0 == "\n" || $0 == " " }.first
        return number.flatMap { Int($0) }
    }

    private static var testOtaToken: String? {
        ProcessInfo.processInfo.environment["LYNX_OTA_CLIENT_TOKEN"]
            ?? ProcessInfo.processInfo.environment["TEST_RUNNER_LYNX_OTA_CLIENT_TOKEN"]
    }

    private static var testOtaBaseURL: String {
        ProcessInfo.processInfo.environment["LYNX_TEST_OTA_BASE_URL"]
            ?? ProcessInfo.processInfo.environment["TEST_RUNNER_LYNX_TEST_OTA_BASE_URL"]
            ?? "https://lynx-ota-server.test.huangbaoche.com"
    }

    private static var testOtaEnvironment: String {
        ProcessInfo.processInfo.environment["LYNX_TEST_OTA_ENV"]
            ?? ProcessInfo.processInfo.environment["TEST_RUNNER_LYNX_TEST_OTA_ENV"]
            ?? "TEST"
    }

    private static var useLiveOta: Bool {
        let environment = ProcessInfo.processInfo.environment
        return [
            environment["LYNX_TEST_LIVE_OTA"],
            environment["TEST_RUNNER_LYNX_TEST_LIVE_OTA"],
        ]
        .compactMap { $0?.lowercased() }
        .contains { ["1", "true", "yes", "on"].contains($0) }
    }
}
