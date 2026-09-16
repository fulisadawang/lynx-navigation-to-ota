import LynxShellKit
import UIKit

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
        LynxShell.bootstrap()
#if DEBUG
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
