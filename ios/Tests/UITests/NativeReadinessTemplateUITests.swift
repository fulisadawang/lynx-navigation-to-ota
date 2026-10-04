import XCTest

final class NativeReadinessTemplateUITests: XCTestCase {
    private var app: XCUIApplication!
    private var origin: String { ProcessInfo.processInfo.environment["TEMPLATE_READINESS_ORIGIN"] ?? "http://127.0.0.1:60543" }
    private let runId = "readiness-" + UUID().uuidString

    override func setUpWithError() throws {
        continueAfterFailure = false
        app = XCUIApplication()
        app.launchArguments = ["--show-native-launcher"]
        app.launchEnvironment = [
            "LYNX_OTA_API_BASE_URL": origin,
            "LYNX_OTA_CLIENT_TOKEN": "fixture-only-native-readiness",
            "LYNX_OTA_ENV": "TEST", "LYNX_OTA_ALLOW_LOCAL_HTTP": "1",
            "LYNX_OTA_VERSIONCODE": "150", "LYNX_OTA_TEST_STORE_ID": runId,
            "LYNX_UI_TEST_EXPOSE_RUNTIME_STATE": "1",
        ]
        _ = try control(["phase": "v1", "offline": false, "resetMetrics": true])
    }

    override func tearDownWithError() throws {
        app.terminate()
        _ = try control(["offline": false])
    }

    func testRealHomeBundleDownloadsAndRendersFromLocalIP() throws {
        app.launchEnvironment["LYNX_TEST_NATIVE_READINESS_MODE"] = "page"
        app.launchEnvironment["LYNX_OTA_CANDIDATE_MODE"] = "1"
        app.launch()
        XCTAssertTrue(app.staticTexts["边界清楚，按需组合"].waitForExistence(timeout: 30))
        let runtime = app.staticTexts["lynx-debug-ota-state"]
        wait(runtime, contains: "template-v1")
        wait(runtime, contains: "promoted")
        let state = try metrics()
        let requests = try XCTUnwrap(state["requests"] as? [String: Int])
        XCTAssertGreaterThanOrEqual(requests["/files/HomePage.lynx.bundle"] ?? 0, 1)
        XCTAssertGreaterThanOrEqual(requests["/files/OtaEcommercePage.lynx.bundle"] ?? 0, 1)
        XCTAssertEqual(state["asyncCount"] as? Int, 3)
        attach("real-template-home-downloaded-and-healthy")

        app.terminate()
        _ = try control(["offline": true, "resetMetrics": true])
        app.launch()
        XCTAssertTrue(app.staticTexts["边界清楚，按需组合"].waitForExistence(timeout: 30))
        wait(app.staticTexts["lynx-debug-ota-state"], contains: "template-v1")
        let offlineRequests = try XCTUnwrap(metrics()["requests"] as? [String: Int])
        XCTAssertEqual(offlineRequests["/files/HomePage.lynx.bundle"] ?? 0, 0)
        attach("real-template-home-offline-restart")
        app.terminate()
        app.launchEnvironment["LYNX_UI_TEST_EXPOSE_RUNTIME_STATE"] = "0"
        app.launch()
        let heading = app.staticTexts["生产级最小起点"]
        XCTAssertTrue(heading.waitForExistence(timeout: 30))
        let statusBar = app.statusBars.firstMatch
        if statusBar.exists { XCTAssertGreaterThanOrEqual(heading.frame.minY, statusBar.frame.maxY) }
        attach("real-template-home-clean-safe-area")
    }

    func testRealTemplateTabsKeepInstancesAndUseDownloadedAsyncResources() throws {
        app.launchEnvironment["LYNX_TEST_NATIVE_READINESS_MODE"] = "tabs"
        app.launchEnvironment["LYNX_OTA_CANDIDATE_MODE"] = "1"
        app.launch()
        XCTAssertTrue(app.staticTexts["边界清楚，按需组合"].waitForExistence(timeout: 30))
        let homeState = app.staticTexts["lynx-debug-tab-state"]
        wait(homeState, contains: "template-v1")
        let homeInstance = homeState.label.components(separatedBy: " | ").first
        let requestsBefore = try XCTUnwrap(metrics()["requests"] as? [String: Int])
        app.tabBars.buttons["设置"].tap()
        XCTAssertTrue(app.staticTexts["给肌肤一段慢下来的时间"].waitForExistence(timeout: 15))
        attach("real-template-ecommerce-tab")
        let productButton = app.buttons["探索系列"].exists ? app.buttons["探索系列"] : app.staticTexts["探索系列"]
        XCTAssertTrue(productButton.waitForExistence(timeout: 10))
        productButton.tap()
        XCTAssertTrue(app.staticTexts["绿茶舒润精华露"].waitForExistence(timeout: 15))
        attach("real-template-lazy-product-detail")
        for _ in 0..<3 {
            app.tabBars.buttons["首页"].tap()
            XCTAssertTrue(app.staticTexts["边界清楚，按需组合"].waitForExistence(timeout: 5))
            app.tabBars.buttons["设置"].tap()
        }
        app.tabBars.buttons["首页"].tap()
        XCTAssertEqual(homeState.label.components(separatedBy: " | ").first, homeInstance)
        let requestsAfter = try XCTUnwrap(metrics()["requests"] as? [String: Int])
        XCTAssertEqual(requestsAfter["/api/ota/v1/releases/latest-bundle-list"], requestsBefore["/api/ota/v1/releases/latest-bundle-list"])
        XCTAssertEqual(requestsAfter["/files/HomePage.lynx.bundle"], requestsBefore["/files/HomePage.lynx.bundle"])
        attach("real-template-tab-switch-keeps-instance")
    }

    func testActualProcessTerminationDuringTemplateTrialRestoresStableOffline() throws {
        app.launchEnvironment["LYNX_TEST_NATIVE_READINESS_MODE"] = "page"
        app.launchEnvironment["LYNX_OTA_CANDIDATE_MODE"] = "1"
        app.launch()
        XCTAssertTrue(app.staticTexts["边界清楚，按需组合"].waitForExistence(timeout: 30))
        wait(app.staticTexts["lynx-debug-ota-state"], contains: "template-v1:ota_current:promoted")
        app.terminate()
        _ = try control(["phase": "v2", "offline": false])
        app.launchEnvironment["LYNX_TEST_HOLD_OTA_HEALTH"] = "1"
        app.launch()
        XCTAssertTrue(app.staticTexts["边界清楚，按需组合"].waitForExistence(timeout: 30))
        wait(app.staticTexts["lynx-debug-ota-state"], contains: "ready:template-v2:candidate_trial")
        attach("real-template-v2-trial-before-process-termination")
        app.terminate()
        _ = try control(["offline": true, "resetMetrics": true])
        app.launchEnvironment.removeValue(forKey: "LYNX_TEST_HOLD_OTA_HEALTH")
        app.launch()
        XCTAssertTrue(app.staticTexts["边界清楚，按需组合"].waitForExistence(timeout: 30))
        wait(app.staticTexts["lynx-debug-ota-state"], contains: "ready:template-v1:ota_snapshot")
        let requests = try XCTUnwrap(metrics()["requests"] as? [String: Int])
        XCTAssertEqual(requests["/files/HomePage.lynx.bundle"] ?? 0, 0)
        attach("real-template-trial-process-restart-restores-v1-offline")
    }

    private func wait(_ element: XCUIElement, contains text: String) {
        XCTAssertTrue(element.waitForExistence(timeout: 30))
        let condition = NSPredicate(format: "label CONTAINS %@", text)
        let result = XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: condition, object: element)], timeout: 30)
        XCTAssertEqual(result, .completed, element.label)
    }

    private func attach(_ name: String) {
        let value = XCTAttachment(screenshot: app.screenshot())
        value.name = name; value.lifetime = .keepAlways
        add(value)
    }

    private func metrics() throws -> [String: Any] { try request(path: "/_readiness/state", body: nil) }
    private func control(_ body: [String: Any]) throws -> [String: Any] { try request(path: "/_readiness/control", body: body) }
    private func request(path: String, body: [String: Any]?) throws -> [String: Any] {
        var request = URLRequest(url: URL(string: origin + path)!)
        if let body {
            request.httpMethod = "POST"; request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try JSONSerialization.data(withJSONObject: body)
        }
        let done = expectation(description: "本地模板 fixture 响应")
        var result: Result<[String: Any], Error>?
        URLSession.shared.dataTask(with: request) { data, response, error in
            if let error { result = .failure(error) }
            else {
                result = Result {
                    guard let response = response as? HTTPURLResponse, response.statusCode == 200,
                          let data else { throw NSError(domain: "NativeReadinessFixture", code: 1) }
                    return try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
                }
            }
            done.fulfill()
        }.resume()
        wait(for: [done], timeout: 10)
        return try XCTUnwrap(result).get()
    }
}
