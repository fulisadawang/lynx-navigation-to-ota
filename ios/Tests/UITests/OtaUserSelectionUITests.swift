import XCTest

/** 独立测试只连接真实Server的loopback fixture，不继承旧mock OTA用例配置。 */
final class OtaUserSelectionUITests: XCTestCase {
    private var app: XCUIApplication!
    private var origin: URL!

    override func setUpWithError() throws {
        continueAfterFailure = false
        let environment = ProcessInfo.processInfo.environment
        guard let raw = environment["OTA_USER_FIXTURE_URL"] ?? environment["TEST_RUNNER_OTA_USER_FIXTURE_URL"],
              let url = URL(string: raw), url.scheme == "http", ["127.0.0.1", "localhost"].contains(url.host ?? "") else {
            throw XCTSkip("需要显式本地 OTA_USER_FIXTURE_URL")
        }
        origin = url
        app = XCUIApplication()
        app.launchArguments = ["--show-native-launcher"]
        app.launchEnvironment = [
            "LYNX_OTA_API_BASE_URL": raw,
            "LYNX_OTA_CLIENT_TOKEN": "ota-user-gray-local-client-token",
            "LYNX_OTA_ENV": "TEST",
            "LYNX_OTA_ALLOW_LOCAL_HTTP": "1",
            "LYNX_OTA_VERSIONCODE": "150",
            "LYNX_TEST_OTA_V3_FIXTURE": "1",
            "LYNX_TEST_OTA_USER_SELECTION": "1",
            "LYNX_UI_TEST_EXPOSE_RUNTIME_STATE": "1",
            "LYNX_OTA_TEST_STORE_ID": "user-selection-" + UUID().uuidString,
        ]
        _ = try control("reset", body: [:])
    }

    override func tearDown() { app?.terminate(); super.tearDown() }

    func testNativeBuildNumberDefaultAndInvalidConfigurationKeepsEmbedded() throws {
        app.launchEnvironment.removeValue(forKey: "LYNX_OTA_VERSIONCODE")
        app.launch()
        try waitForMetric("bundleSuccessCount", minimum: 100)
        let requests = try XCTUnwrap(control("metrics")["requests"] as? [[String: Any]])
        let query = try XCTUnwrap(requests.first { $0["kind"] as? String == "latest" })
        // Sample 的 Info-Debug.plist 真实 CFBundleVersion=1，versionName=1.0.0。
        XCTAssertEqual(query["versioncode"] as? String, "1")
        XCTAssertEqual(query["lynxSdkVersion"] as? String, "4.0.0")
        openTabs()
        let ids = try XCTUnwrap(control("state")["actualReleaseIds"] as? [String: String])
        waitForRelease(try XCTUnwrap(ids["full5"]))
        attach("native-01-real-CFBundleVersion")

        app.terminate()
        app.launchEnvironment["LYNX_OTA_VERSIONCODE"] = "1.2.3"
        app.launchEnvironment.removeValue(forKey: "LYNX_TEST_OTA_V3_FIXTURE")
        _ = try control("metrics/reset", body: [:])
        app.launch(); openTabs()
        waitForLabel(debugState, containing: "source=embedded_baseline")
        waitForLabel(debugState, containing: "error=ready")
        XCTAssertEqual(try metric("latestRequestCount"), 0, "非法构建号不能降级为无兼容门禁的请求")
        attach("native-02-invalid-code-keeps-embedded")
    }

    func testRuleDisableFullPromotionAndPersistedEmbeddedDirective() throws {
        _ = try control("stage", body: ["stage": "gray8"])
        let ids = try XCTUnwrap(control("state")["actualReleaseIds"] as? [String: String])
        let gray8 = try XCTUnwrap(ids["gray8"]), full7 = try XCTUnwrap(ids["full7"])
        app.launchEnvironment["LYNX_OTA_USER_ID"] = "user_demo_A"
        _ = try control("metrics/reset", body: [:])
        app.launch()
        try waitForMetric("bundleSuccessCount", minimum: 100)
        XCTAssertEqual(try metric("latestRequestCount"), 1, "install 前身份一次启动同步，不先匿名再 A")
        openTabs(); waitForRelease(gray8)
        attach("policy-01-initial-A-gray8")

        _ = try control("rule", body: ["alias": "gray8", "enabled": false])
        _ = try control("metrics/reset", body: [:])
        refreshTabs(); waitForRelease(full7)
        XCTAssertEqual(try metric("bundleSuccessCount"), 1)
        attach("policy-02-disabled-rule-full7")

        _ = try control("rule", body: ["alias": "gray8", "enabled": true])
        _ = try control("metrics/reset", body: [:])
        refreshTabs(); waitForRelease(gray8)
        XCTAssertEqual(try metric("bundleSuccessCount"), 0, "上一灰度 CAS 对象应复用")
        _ = try control("publish", body: ["alias": "gray8", "type": "full"])
        _ = try control("metrics/reset", body: [:])
        refreshTabs(); waitForRelease(gray8)
        waitForLabel(debugState, containing: "kind=full")
        XCTAssertEqual(try metric("bundleSuccessCount"), 0, "同 release 全量化只更新选择元数据")
        chooseUser("用户 B（普通）"); waitForRelease(gray8)
        waitForLabel(debugState, containing: "kind=full")
        XCTAssertEqual(try metric("bundleSuccessCount"), 0)
        attach("policy-03-same-release-full-shared-by-B")

        chooseUser("用户 A（灰度）"); waitForRelease(gray8)
        _ = try control("fallback", body: ["enabled": true, "platforms": ["ios"]])
        refreshTabs()
        waitForLabel(debugState, containing: "没有 active Bundle")
        attach("policy-04-explicit-embedded-no-fixture-baseline")
        app.terminate()
        // 暂停所有 latest 返回，验证冷读直接遵守已持久化指令，而非等网络才移除旧远程。
        _ = try control("delay-latest", body: ["audience": "A", "count": 1, "milliseconds": 0])
        app.launchEnvironment["LYNX_OTA_USER_ID"] = "user_demo_A"
        app.launch()
        try waitForMetric("delayedLatestCount", minimum: 1)
        openTabs()
        waitForLabel(debugState, containing: "没有 active Bundle")
        XCTAssertFalse(debugState.label.contains("release=" + gray8))
        XCTAssertGreaterThan(try metric("pendingLatestCount"), 0, "本地读完时网络响应必须仍被挂起")
        attach("policy-05-cold-start-keeps-embedded-directive")
        _ = try control("release-delays", body: [:])
    }

    func testCandidateRequiresStandaloneFirstScreenBeforeTabConsumption() throws {
        let initial = try control("state")
        let ids = try XCTUnwrap(initial["actualReleaseIds"] as? [String: String])
        let full5 = try XCTUnwrap(ids["full5"]), gray6 = try XCTUnwrap(ids["gray6"])
        app.launch()
        try waitForMetric("bundleSuccessCount", minimum: 100)
        openTabs()
        waitForRelease(full5)
        app.terminate()

        _ = try control("stage", body: ["stage": "gray6"])
        _ = try control("metrics/reset", body: [:])
        app.launchEnvironment["LYNX_OTA_USER_ID"] = "user_demo_A"
        app.launchEnvironment["LYNX_OTA_CANDIDATE_MODE"] = "1"
        app.launch()
        try waitForMetric("bundleSuccessCount", minimum: 1)
        openTabs()
        waitForRelease(full5)
        attach("candidate-01-tab-stays-full5")

        chooseUser("独立打开测试 Bundle")
        let pageState = app.staticTexts["lynx-debug-ota-state"]
        XCTAssertTrue(pageState.waitForExistence(timeout: 15))
        waitForLabel(pageState, containing: "ready:\(gray6):ota_current:promoted")
        attach("candidate-02-real-first-screen-promoted", nativeState: pageState.label)
        let nav = app.navigationBars["灰度独立页面"]
        XCTAssertTrue(nav.waitForExistence(timeout: 10)); nav.buttons.firstMatch.tap()
        waitForRelease(full5)
        app.buttons["刷新 OTA"].tap()
        XCTAssertTrue(app.staticTexts["OTA 同步完成"].waitForExistence(timeout: 45)); app.buttons["确定"].tap()
        waitForRelease(gray6)
        attach("candidate-03-explicit-tab-refresh-gray6")
        chooseUser("退出登录（匿名）")
        waitForRelease(full5)
        attach("candidate-04-logout-full5")
    }

    func testRealServerUserSelectionAndHundredBundleIncrement() throws {
        let initial = try control("state")
        XCTAssertEqual(initial["stage"] as? String, "full5", "每次设备验收需启动全新的 fixture adapter")
        let ids = try XCTUnwrap(initial["actualReleaseIds"] as? [String: String])
        let full5 = try XCTUnwrap(ids["full5"]), gray6 = try XCTUnwrap(ids["gray6"])
        let full7 = try XCTUnwrap(ids["full7"])
        _ = try control("metrics/reset", body: [:])
        app.launch()
        try waitForMetric("bundleSuccessCount", minimum: 100)
        XCTAssertEqual(try metric("latestRequestCount"), 1, "匿名启动仅执行一次全量查询")
        openTabs()
        waitForRelease(full5)
        attach("01-anonymous-full5")

        _ = try control("metrics/reset", body: [:])
        _ = try control("stage", body: ["stage": "gray6"])
        chooseUser("用户 A（灰度）")
        waitForRelease(gray6)
        XCTAssertEqual(try metric("bundleSuccessCount"), 1, "100 Bundle 只有050变化，应只下载一个新对象")
        attach("02-user-A-gray6-single-object")

        // 先使两个原生Tab均完成首屏，再检查切换不联网、不创建新实例。
        app.buttons["设置"].tap()
        app.buttons["首页"].tap()
        waitForBothTabs(gray6)
        let before = debugState.label
        _ = try control("metrics/reset", body: [:])
        for _ in 0..<3 { app.buttons["设置"].tap(); app.buttons["首页"].tap() }
        XCTAssertEqual(try metric("latestRequestCount"), 0)
        XCTAssertEqual(debugState.label, before)

        chooseUser("用户 B（普通）")
        waitForRelease(full5)
        try waitForMetric("latestCompletedCount", minimum: 1)
        XCTAssertEqual(try metric("bundleSuccessCount"), 0, "B 使用已有正式版本，应复用CAS")
        attach("03-user-B-full5-no-gray-leak")

        _ = try control("metrics/reset", body: [:])
        _ = try control("stage", body: ["stage": "full7"])
        chooseUser("用户 A（灰度）")
        waitForRelease(full7)
        XCTAssertEqual(try metric("bundleSuccessCount"), 1)
        attach("04-user-A-newer-full7-wins")

        _ = try control("metrics/reset", body: [:])
        chooseUser("用户 A（灰度）")
        XCTAssertEqual(try metric("latestRequestCount"), 0, "重复注册同一用户必须幂等")

        chooseUser("用户 B（普通）")
        waitForRelease(full7)
        try waitForMetric("latestCompletedCount", minimum: 1)
        _ = try control("stage", body: ["stage": "gray8"])
        _ = try control("metrics/reset", body: [:])
        _ = try control("delay-latest", body: ["audience": "A", "count": 1, "milliseconds": 0])
        chooseUser("用户 A（灰度）")
        try waitForMetric("delayedLatestCount", minimum: 1)
        chooseUser("用户 B（普通）")
        try waitForMetric("latestCompletedCount", minimum: 1)
        let delayedRequests = try XCTUnwrap(control("metrics")["requests"] as? [[String: Any]])
        XCTAssertTrue(delayedRequests.contains { $0["audience"] as? String == "B" && $0["completed"] as? Bool == true })
        _ = try control("release-delays", body: [:])
        waitForRelease(full7)
        XCTAssertFalse(debugState.label.contains("release=" + (ids["gray8"] ?? "unavailable")))
        attach("05-delayed-A-cannot-replace-B")

        chooseUser("退出登录（匿名）")
        waitForRelease(full7)
        attach("06-anonymous-after-logout")

        _ = try control("rollback", body: ["from": "full7", "target": "full5"])
        let refresh = app.buttons["刷新 OTA"]
        refresh.tap()
        XCTAssertTrue(app.staticTexts["OTA 同步完成"].waitForExistence(timeout: 45))
        app.buttons["确定"].tap()
        waitForRelease(full5)
        attach("07-server-rollback-to-older-full5")

        // 同一沙盒重启验证持久化选择，构建号升级不伪造兼容。
        app.terminate()
        app.launchEnvironment["LYNX_OTA_VERSIONCODE"] = "1000"
        _ = try control("metrics/reset", body: [:])
        app.launch()
        try waitForMetric("latestCompletedCount", minimum: 1)
        openTabs()
        waitForLabel(debugState, containing: "没有 active Bundle")
        XCTAssertFalse(debugState.label.contains("release=" + full5))
        attach("08-native-versioncode-incompatible")
    }

    private var debugState: XCUIElement { app.staticTexts["lynx-debug-tab-state"] }

    private func refreshTabs() {
        app.buttons["刷新 OTA"].tap()
        XCTAssertTrue(app.staticTexts["OTA 同步完成"].waitForExistence(timeout: 45))
        app.buttons["确定"].tap()
    }

    private func openTabs() {
        let button = app.buttons["打开原生 Tab 承载 Demo"]
        XCTAssertTrue(button.waitForExistence(timeout: 15)); button.tap()
        XCTAssertTrue(debugState.waitForExistence(timeout: 15))
    }

    private func chooseUser(_ title: String) {
        let button = app.buttons["ota-select-user"]
        XCTAssertTrue(button.waitForExistence(timeout: 10)); button.tap()
        let choice = app.buttons[title]
        XCTAssertTrue(choice.waitForExistence(timeout: 10)); choice.tap()
    }

    private func waitForRelease(_ id: String) {
        let predicate = NSPredicate { [weak self] _, _ in
            guard let value = self?.debugState.label.components(separatedBy: " | ").first else { return false }
            return value.contains("release=" + id) && value.contains("error=ready")
        }
        XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: predicate, object: nil)], timeout: 45), .completed,
                       "首页需要真实首屏 ready 与 release=\(id)，实际 \(debugState.label)")
    }

    private func waitForBothTabs(_ id: String) {
        let predicate = NSPredicate { [weak self] _, _ in
            guard let value = self?.debugState.label else { return false }
            return value.components(separatedBy: "release=" + id).count == 3 && value.components(separatedBy: "error=ready").count == 3
        }
        XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: predicate, object: nil)], timeout: 30), .completed)
    }

    private func waitForLabel(_ element: XCUIElement, containing value: String) {
        let predicate = NSPredicate { _, _ in element.exists && element.label.contains(value) }
        XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: predicate, object: nil)], timeout: 45), .completed,
                       "需要 \(value)，实际 \(element.label)")
    }

    private func attach(_ name: String, nativeState: String? = nil) {
        let currentState = nativeState ?? debugState.label
        let screenshot = XCTAttachment(screenshot: app.screenshot())
        screenshot.name = name; screenshot.lifetime = .keepAlways; add(screenshot)
        let state = XCTAttachment(string: currentState)
        state.name = name + "-state"; state.lifetime = .keepAlways; add(state)
        do {
            let metrics = try control("metrics")
            let requests = metrics["requests"] as? [[String: Any]] ?? []
            for request in requests where request["kind"] as? String == "latest" {
                XCTAssertEqual(request["platform"] as? String, "ios")
                XCTAssertEqual(request["versioncode"] as? String, app.launchEnvironment["LYNX_OTA_VERSIONCODE"] ?? "1")
                XCTAssertEqual(request["lynxSdkVersion"] as? String, "4.0.0")
            }
            let evidence: [String: Any] = [
                "metrics": metrics, "server": try control("state"),
                "nativeState": currentState,
                "storeId": app.launchEnvironment["LYNX_OTA_TEST_STORE_ID"] ?? "",
                "versioncode": app.launchEnvironment["LYNX_OTA_VERSIONCODE"] ?? "1",
            ]
            let data = try JSONSerialization.data(withJSONObject: evidence, options: [.prettyPrinted, .sortedKeys])
            let attachment = XCTAttachment(data: data, uniformTypeIdentifier: "public.json")
            attachment.name = name + "-evidence"; attachment.lifetime = .keepAlways; add(attachment)
        } catch { XCTFail("无法收集同一场景的请求和选择证据：\(error)") }
    }

    private func metric(_ name: String) throws -> Int {
        try XCTUnwrap((control("metrics")[name] as? NSNumber)?.intValue)
    }

    private func waitForMetric(_ name: String, minimum: Int) throws {
        let deadline = Date().addingTimeInterval(60)
        while Date() < deadline {
            if try metric(name) >= minimum { return }
            RunLoop.current.run(until: Date().addingTimeInterval(0.2))
        }
        XCTFail("Fixture \(name) 未达到 \(minimum)")
    }

    private func control(_ endpoint: String, body: [String: Any]? = nil) throws -> [String: Any] {
        var request = URLRequest(url: origin.appendingPathComponent("_fixture/" + endpoint))
        request.setValue("local-fixture-only", forHTTPHeaderField: "x-ota-fixture-control")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = 15
        if let body { request.httpMethod = "POST"; request.httpBody = try JSONSerialization.data(withJSONObject: body) }
        let done = expectation(description: "fixture " + endpoint)
        var received: Data?, failure: Error?, status: Int?
        URLSession.shared.dataTask(with: request) { data, response, error in
            received = data; failure = error; status = (response as? HTTPURLResponse)?.statusCode; done.fulfill()
        }.resume()
        wait(for: [done], timeout: 20)
        if let failure { throw failure }
        XCTAssertEqual(status, 200)
        return try XCTUnwrap(JSONSerialization.jsonObject(with: XCTUnwrap(received)) as? [String: Any])
    }
}
