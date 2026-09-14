import UIKit

/** iOS 单 Window/Scene 的 Lynx 布局快照；折叠业务字段按 capability 保留。 */
struct ShellLayoutSnapshot {
    struct Measurement: Equatable {
        let screenWidth: Double
        let screenHeight: Double
        let viewportWidth: Double
        let viewportHeight: Double
        let density: Double
        let safeAreaTop: Double
        let safeAreaRight: Double
        let safeAreaBottom: Double
        let safeAreaLeft: Double
        let orientation: String
        let windowMode: String

        var viewportSize: CGSize {
            CGSize(width: CGFloat(viewportWidth), height: CGFloat(viewportHeight))
        }

        var screenSize: CGSize {
            CGSize(width: CGFloat(screenWidth), height: CGFloat(screenHeight))
        }
    }

    let schemaVersion: Int = 1
    let revision: UInt64
    let timestampMillis: Int64
    let measurement: Measurement

    var viewportSize: CGSize {
        measurement.viewportSize
    }

    var screenSize: CGSize {
        measurement.screenSize
    }

    var dictionary: [String: Any] {
        [
            "schemaVersion": schemaVersion,
            "revision": revision,
            "timestampMillis": timestampMillis,
            "screenWidth": measurement.screenWidth,
            "screenHeight": measurement.screenHeight,
            "viewportWidth": measurement.viewportWidth,
            "viewportHeight": measurement.viewportHeight,
            "density": measurement.density,
            "orientation": measurement.orientation,
            "windowMode": measurement.windowMode,
            "safeAreaInsets": [
                "top": measurement.safeAreaTop,
                "right": measurement.safeAreaRight,
                "bottom": measurement.safeAreaBottom,
                "left": measurement.safeAreaLeft,
            ],
            "fold": [
                "isFoldable": false,
                "status": "unknown",
                "displayMode": "unknown",
                "foldAnglesDeg": [],
                "creaseRects": [],
            ],
            "capabilities": [
                "windowMetrics": "supported",
                "viewportMetrics": "supported",
                "foldStatus": "unsupported",
                "creaseGeometry": "unsupported",
                "partitionGeometry": "unsupported",
            ],
        ]
    }

    static func measure(for view: UIView, viewportSize: CGSize? = nil) -> Measurement {
        let window = view.window
        let screen = window?.screen ?? UIScreen.main
        let screenBounds = window?.bounds ?? screen.bounds
        let viewport = viewportSize ?? view.bounds.size
        let mounted = window != nil && !view.bounds.isEmpty
        let insets = mounted ? view.safeAreaInsets : .zero
        let orientation = interfaceOrientation(for: window?.windowScene)
        let windowMode = mode(for: window, screenBounds: screen.bounds)
        return Measurement(
            screenWidth: quantize(screenBounds.width),
            screenHeight: quantize(screenBounds.height),
            viewportWidth: quantize(max(viewport.width, 0)),
            viewportHeight: quantize(max(viewport.height, 0)),
            density: quantize(screen.scale),
            safeAreaTop: quantize(insets.top),
            safeAreaRight: quantize(insets.right),
            safeAreaBottom: quantize(insets.bottom),
            safeAreaLeft: quantize(insets.left),
            orientation: orientation,
            windowMode: windowMode
        )
    }

    static func make(
        measurement: Measurement,
        revision: UInt64,
        timestampMillis: Int64 = Int64(Date().timeIntervalSince1970 * 1000)
    ) -> ShellLayoutSnapshot {
        ShellLayoutSnapshot(
            revision: revision,
            timestampMillis: timestampMillis,
            measurement: measurement
        )
    }

    private static func quantize(_ value: CGFloat) -> Double {
        Double((value * 100).rounded() / 100)
    }

    private static func interfaceOrientation(for scene: UIWindowScene?) -> String {
        switch scene?.interfaceOrientation {
        case .portrait, .portraitUpsideDown: return "portrait"
        case .landscapeLeft, .landscapeRight: return "landscape"
        default: return "unknown"
        }
    }

    private static func mode(for window: UIWindow?, screenBounds: CGRect) -> String {
        guard let window else { return "unknown" }
        let bounds = window.bounds
        if abs(bounds.width - screenBounds.width) < 0.5,
           abs(bounds.height - screenBounds.height) < 0.5 {
            return "fullscreen"
        }
        if bounds.width < screenBounds.width || bounds.height < screenBounds.height {
            return "split"
        }
        return "floating"
    }
}

/** 只在下一次主线程 tick 采样一次，避免 updateViewport 触发 viewDidLayout 循环。 */
final class ShellLayoutUpdateCoordinator {
    private var lastMeasurement: ShellLayoutSnapshot.Measurement?
    private var revision: UInt64 = 0
    private var scheduled = false

    func schedule(
        for view: UIView,
        viewportSize: @escaping () -> CGSize,
        onUpdate: @escaping (ShellLayoutSnapshot) -> Void
    ) {
        guard Thread.isMainThread,
              view.window != nil,
              !view.bounds.isEmpty,
              !scheduled else { return }
        scheduled = true
        DispatchQueue.main.async { [weak self, weak view] in
            guard let self, let view else { return }
            self.scheduled = false
            guard view.window != nil, !view.bounds.isEmpty else { return }
            let measurement = ShellLayoutSnapshot.measure(
                for: view,
                viewportSize: viewportSize()
            )
            guard measurement != self.lastMeasurement else { return }
            self.lastMeasurement = measurement
            self.revision = self.revision == UInt64.max ? 1 : self.revision + 1
            onUpdate(
                ShellLayoutSnapshot(
                    revision: self.revision,
                    timestampMillis: Int64(Date().timeIntervalSince1970 * 1000),
                    measurement: measurement
                )
            )
        }
    }

    func invalidate() {
        lastMeasurement = nil
    }
}
