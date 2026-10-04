#if LYNX_SHELL_E2E_CORE_ONLY
import LynxShellKitE2ECore
#else
import LynxShellKit
#endif
#if canImport(LynxMapKit)
import LynxMapKit
#endif
#if DEBUG && canImport(LynxShellDebugKit)
import LynxShellDebugKit
#endif
import UIKit
import LynxCapacitorKit

/** Sample 启动时通过显式 Module Interface 准备 Lynx Runtime。 */
@main
final class AppDelegate: UIResponder, UIApplicationDelegate {
#if DEBUG
    private var diagnosticProvider: LynxMonitorDiagnosticProvider?
    private var diagnosticSnapshotTimer: DispatchSourceTimer?
    private var lastDiagnosticSnapshot = ""
#endif

    func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil
    ) -> Bool {
        LynxRouter.registerNativeModule(LynxCapacitorModule.self, onViewDestroy: LynxCapacitorModule.destroy(for:))
        LynxRouter.installMediaHandler { context, method, optionsJSON, callback in
            LynxCapacitorModule.handleLegacyMedia(for: context, method: method, optionsJSON: optionsJSON, callback: callback)
        }
        LynxCapacitorModule.installHostProvider(LynxCapacitorSampleHost())
        LynxCapacitorModule.setLaunchUrl((launchOptions?[.url] as? URL)?.absoluteString)
        LynxShell.bootstrap()
#if DEBUG
#if canImport(LynxMapKit)
        // 模拟器验收通过显式启动参数打开高德授权；生产启动不默认同意隐私协议。
        if ProcessInfo.processInfo.arguments.contains("--lynx-map-consent-granted"),
           let apiKey = Bundle.main.object(forInfoDictionaryKey: "LynxMapAPIKey") as? String,
           !apiKey.isEmpty,
           !apiKey.contains("$(") {
            LynxMapModuleRuntime.configureAMap(apiKey: apiKey, privacyAgreed: true)
        }
#endif
#if canImport(LynxShellDebugKit)
        LynxDebugTool.install()
#endif
        if ProcessInfo.processInfo.arguments.contains("--lynx-monitor-diagnostic") {
            let provider = LynxMonitorDiagnosticProvider()
            diagnosticProvider = provider
            let result = LynxMonitor.install(
                LynxMonitorConfig(enabled: true, provider: provider, performanceSampleRate: 1)
            )
            NSLog("[LynxMonitor] 本地诊断 Provider 安装结果：%@", String(describing: result))
            startDiagnosticSnapshotLogging()
        }
#endif
        return true
    }

    func applicationWillTerminate(_ application: UIApplication) {
#if DEBUG
        stopDiagnosticSnapshotLogging()
#endif
    }

    func application(
        _ application: UIApplication,
        configurationForConnecting connectingSceneSession: UISceneSession,
        options: UIScene.ConnectionOptions
    ) -> UISceneConfiguration {
        UISceneConfiguration(name: "Default Configuration", sessionRole: connectingSceneSession.role)
    }

    /** APNs 的真实成功或失败结果转发给已订阅的能力模块；不伪造 token。 */
    func application(_ application: UIApplication, didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data) {
        LynxCapacitorModule.emitPushRegistration(token: deviceToken.map { String(format: "%02x", $0) }.joined())
    }

    func application(_ application: UIApplication, didFailToRegisterForRemoteNotificationsWithError error: Error) {
        LynxCapacitorModule.emitPushRegistrationError(error.localizedDescription)
    }

    func application(
        _ application: UIApplication,
        didReceiveRemoteNotification userInfo: [AnyHashable: Any],
        fetchCompletionHandler completionHandler: @escaping (UIBackgroundFetchResult) -> Void
    ) {
        LynxCapacitorModule.emitPushNotification(userInfo)
        completionHandler(.noData)
    }

#if DEBUG
    /** 只在显式诊断启动参数下输出有界快照摘要，证明 Provider 实际收到事件。 */
    private func startDiagnosticSnapshotLogging() {
        stopDiagnosticSnapshotLogging()
        let timer = DispatchSource.makeTimerSource(queue: DispatchQueue(label: "com.lynxshell.monitor.snapshot"))
        timer.schedule(deadline: .now() + .milliseconds(500), repeating: .milliseconds(500))
        timer.setEventHandler { [weak self] in
            guard let self, let provider = self.diagnosticProvider else { return }
            let events = provider.snapshot()
            let grouped = Dictionary(grouping: events, by: { $0.eventType.rawValue })
                .map { "\($0.key)=\($0.value.count)" }
                .sorted()
                .joined(separator: ",")
            let diagnostics = LynxMonitor.diagnostics()
            let summary = "provider=ios.local_diagnostic;state=\(diagnostics.state);events=\(events.count);types=\(grouped.isEmpty ? "none" : grouped)"
            guard summary != self.lastDiagnosticSnapshot else { return }
            self.lastDiagnosticSnapshot = summary
            NSLog("[LynxMonitor] snapshot %@", summary)
            if ProcessInfo.processInfo.environment["LYNX_TEST_OTA_SIDECAR_REPORT"] == "1" {
                // 本地 sidecar 验收显式启用；仅保存监控层已脱敏的有界事件，不保存请求头。
                do {
                    let destination = FileManager.default.temporaryDirectory.appendingPathComponent("ota-sidecar-monitor.json")
                    try JSONEncoder().encode(events).write(to: destination, options: .atomic)
                } catch {
                    NSLog("[LynxMonitor] 本地 sidecar 报告写入失败")
                }
            }
        }
        diagnosticSnapshotTimer = timer
        timer.resume()
    }

    private func stopDiagnosticSnapshotLogging() {
        diagnosticSnapshotTimer?.cancel()
        diagnosticSnapshotTimer = nil
        lastDiagnosticSnapshot = ""
    }
#endif
}
