import AudioToolbox
import CoreHaptics
import Foundation
import UIKit

/** UIKit/CoreHaptics 对译：Dialog、ActionSheet、Toast、Haptics、Share。 */
enum LynxNativeInteractiveCapabilities {
    typealias Completion = (LynxNativeCapabilityResult) -> Void

    private static let dialogIDs = Set(["Dialog", "ActionSheet"])
    private static let toastLock = NSLock()
    private static var toastView: UIView?
    private static var toastTimer: Timer?
    private static var hapticEngine: CHHapticEngine?
    private static var hapticPlayer: CHHapticPatternPlayer?
    private static var shareController: UIActivityViewController?

    static func dispatch(
        _ call: LynxNativeCapabilityCall,
        presenter: UIViewController?,
        completion: @escaping Completion
    ) -> Bool {
        guard dialogIDs.contains(call.pluginId)
            || call.pluginId == "Toast"
            || call.pluginId == "Haptics"
            || call.pluginId == "Share" else {
            return false
        }

        let run = {
            switch call.pluginId {
            case "Dialog": dispatchDialog(call, presenter: presenter, completion: completion)
            case "ActionSheet": dispatchActionSheet(call, presenter: presenter, completion: completion)
            case "Toast": dispatchToast(call, presenter: presenter, completion: completion)
            case "Haptics": dispatchHaptics(call, completion: completion)
            case "Share": dispatchShare(call, presenter: presenter, completion: completion)
            default: completion(.failure("UNSUPPORTED", "未知交互能力"))
            }
        }
        if Thread.isMainThread { run() } else { DispatchQueue.main.async(execute: run) }
        return true
    }

    static func release() {
        toastTimer?.invalidate()
        toastTimer = nil
        toastView?.removeFromSuperview()
        toastView = nil
        try? hapticPlayer?.stop(atTime: CHHapticTimeImmediate)
        hapticPlayer = nil
        hapticEngine?.stop(completionHandler: nil)
        hapticEngine = nil
        shareController = nil
    }

    // MARK: - Dialog / ActionSheet

    private static func dispatchDialog(
        _ call: LynxNativeCapabilityCall,
        presenter: UIViewController?,
        completion: @escaping Completion
    ) {
        guard let presenter, LynxNativeCapabilitySupport.isUsable(presenter) else {
            completion(.failure("SCENE_UNAVAILABLE", "没有可展示 Dialog 的前台 UIViewController"))
            return
        }
        let once = CompletionOnce(completion)
        let alert = UIAlertController(
            title: string(call.options["title"], default: ""),
            message: string(call.options["message"], default: ""),
            preferredStyle: .alert
        )
        switch call.methodName {
        case "alert":
            alert.addAction(UIAlertAction(
                title: string(call.options["buttonTitle"], default: "OK"),
                style: .default
            ) { _ in once.call(.success(["confirmed": true])) })
        case "confirm":
            alert.addAction(UIAlertAction(
                title: string(call.options["okButtonTitle"], default: "OK"),
                style: .default
            ) { _ in once.call(.success(["value": true])) })
            alert.addAction(UIAlertAction(
                title: string(call.options["cancelButtonTitle"], default: "Cancel"),
                style: .cancel
            ) { _ in once.call(.success(["value": false])) })
        case "prompt":
            let field: UITextField?
            if let existing = alert.textFields?.first {
                field = existing
            } else {
                alert.addTextField()
                field = alert.textFields?.last
            }
            field?.text = string(call.options["inputText"], default: "")
            field?.placeholder = string(call.options["inputPlaceholder"], default: "")
            alert.addAction(UIAlertAction(
                title: string(call.options["okButtonTitle"], default: "OK"),
                style: .default
            ) { _ in once.call(.success([
                "value": field?.text ?? "",
                "cancelled": false,
            ])) })
            alert.addAction(UIAlertAction(
                title: string(call.options["cancelButtonTitle"], default: "Cancel"),
                style: .cancel
            ) { _ in once.call(.success(["value": "", "cancelled": true])) })
        default:
            once.call(.failure("UNSUPPORTED", "Dialog.\(call.methodName) 尚未接入当前 iOS Module"))
            return
        }
        alert.view.accessibilityIdentifier = "lynx-native-dialog"
        presenter.present(alert, animated: true)
    }

    private static func dispatchActionSheet(
        _ call: LynxNativeCapabilityCall,
        presenter: UIViewController?,
        completion: @escaping Completion
    ) {
        guard call.methodName == "showActions" else {
            completion(.failure("UNSUPPORTED", "ActionSheet.\(call.methodName) 尚未接入当前 iOS Module"))
            return
        }
        guard let presenter, LynxNativeCapabilitySupport.isUsable(presenter) else {
            completion(.failure("SCENE_UNAVAILABLE", "没有可展示 ActionSheet 的前台 UIViewController"))
            return
        }
        guard let rawOptions = call.options["options"] as? [[String: Any]], !rawOptions.isEmpty else {
            completion(.failure("INVALID_ARGUMENT", "ActionSheet.options 必须包含至少一个选项"))
            return
        }
        let once = CompletionOnce(completion)
        let sheet = UIAlertController(
            title: string(call.options["title"], default: ""),
            message: string(call.options["message"], default: ""),
            preferredStyle: .actionSheet
        )
        for (index, option) in rawOptions.enumerated() {
            let title = string(option["title"], default: "").trimmingCharacters(in: .whitespacesAndNewlines)
            guard !title.isEmpty else { continue }
            let style: UIAlertAction.Style = bool(option["destructive"], default: false) ? .destructive : .default
            let action = UIAlertAction(title: title, style: style) { _ in
                once.call(.success(["index": index, "cancelled": false]))
            }
            action.isEnabled = !bool(option["disabled"], default: false)
            sheet.addAction(action)
        }
        guard !sheet.actions.isEmpty else {
            completion(.failure("INVALID_ARGUMENT", "ActionSheet 没有可用选项"))
            return
        }
        sheet.addAction(UIAlertAction(
            title: string(call.options["cancelButtonTitle"], default: "Cancel"),
            style: .cancel
        ) { _ in once.call(.success(["index": -1, "cancelled": true])) })
        configurePopover(sheet, presenter: presenter)
        presenter.present(sheet, animated: true)
    }

    // MARK: - Toast

    private static func dispatchToast(
        _ call: LynxNativeCapabilityCall,
        presenter: UIViewController?,
        completion: @escaping Completion
    ) {
        switch call.methodName {
        case "show":
            guard let presenter else {
                completion(.failure("SCENE_UNAVAILABLE", "没有可展示 Toast 的前台 UIViewController"))
                return
            }
            let text = string(call.options["text"], default: "")
            guard !text.isEmpty else {
                completion(.failure("INVALID_ARGUMENT", "Toast.text 不能为空"))
                return
            }
            let durationName = string(call.options["duration"], default: "short").lowercased()
            let duration: TimeInterval
            switch durationName {
            case "short": duration = 2
            case "long": duration = 3.5
            default:
                completion(.failure("INVALID_ARGUMENT", "Toast.duration 只能是 short 或 long"))
                return
            }
            let position = string(call.options["position"], default: "bottom").lowercased()
            guard ["top", "center", "bottom"].contains(position) else {
                completion(.failure("INVALID_ARGUMENT", "Toast.position 只能是 top、center 或 bottom"))
                return
            }
            showToast(text: text, duration: duration, position: position, in: presenter)
            completion(.success([
                "shown": true,
                "position": position,
                "positionApplied": true,
                "systemToast": false,
                "implementation": "UIKitOverlay",
            ]))
        case "getCapabilities":
            completion(.success([
                "systemToast": false,
                "customOverlay": true,
                "positions": ["top", "center", "bottom"],
                "durations": ["short", "long"],
                "positionApplied": true,
            ]))
        case "cancel":
            cancelToast()
            completion(.success(["cancelled": true]))
        default:
            completion(.failure("UNSUPPORTED", "Toast.\(call.methodName) 尚未接入当前 iOS Module"))
        }
    }

    private static func showToast(text: String, duration: TimeInterval, position: String, in presenter: UIViewController) {
        cancelToast()
        guard let container = presenter.viewIfLoaded?.window ?? presenter.viewIfLoaded else { return }
        let label = PaddingLabel()
        label.text = text
        label.textColor = .white
        label.backgroundColor = UIColor.black.withAlphaComponent(0.82)
        label.numberOfLines = 0
        label.textAlignment = .center
        label.layer.cornerRadius = 10
        label.clipsToBounds = true
        label.alpha = 0
        label.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(label)
        var constraints = [
            label.leadingAnchor.constraint(greaterThanOrEqualTo: container.leadingAnchor, constant: 24),
            label.trailingAnchor.constraint(lessThanOrEqualTo: container.trailingAnchor, constant: -24),
            label.centerXAnchor.constraint(equalTo: container.centerXAnchor),
        ]
        switch position {
        case "top": constraints.append(label.topAnchor.constraint(equalTo: container.safeAreaLayoutGuide.topAnchor, constant: 24))
        case "center": constraints.append(label.centerYAnchor.constraint(equalTo: container.centerYAnchor))
        default: constraints.append(label.bottomAnchor.constraint(equalTo: container.safeAreaLayoutGuide.bottomAnchor, constant: -32))
        }
        NSLayoutConstraint.activate(constraints)
        toastLock.withLock { toastView = label }
        UIView.animate(withDuration: 0.18) { label.alpha = 1 }
        toastTimer = Timer.scheduledTimer(withTimeInterval: duration, repeats: false) { _ in
            UIView.animate(withDuration: 0.18, animations: { label.alpha = 0 }) { _ in label.removeFromSuperview() }
            toastLock.withLock { if toastView === label { toastView = nil } }
        }
    }

    private static func cancelToast() {
        toastTimer?.invalidate()
        toastTimer = nil
        let current = toastLock.withLock { () -> UIView? in
            let current = toastView
            toastView = nil
            return current
        }
        current?.removeFromSuperview()
    }

    // MARK: - Haptics

    private static func dispatchHaptics(
        _ call: LynxNativeCapabilityCall,
        completion: @escaping Completion
    ) {
        switch call.methodName {
        case "impact":
            let style = string(call.options["style"], default: "MEDIUM").uppercased()
            let feedback: UIImpactFeedbackGenerator.FeedbackStyle
            switch style {
            case "LIGHT": feedback = .light
            case "HEAVY": feedback = .heavy
            case "RIGID": feedback = .rigid
            case "SOFT": feedback = .soft
            default: feedback = .medium
            }
            let generator = UIImpactFeedbackGenerator(style: feedback)
            generator.prepare()
            generator.impactOccurred()
            completion(.success(["fired": true, "style": style, "implementation": "UIKitFeedbackGenerator"]))
        case "notification":
            let type = string(call.options["type"], default: "SUCCESS").uppercased()
            let feedback: UINotificationFeedbackGenerator.FeedbackType
            switch type {
            case "WARNING": feedback = .warning
            case "ERROR": feedback = .error
            default: feedback = .success
            }
            let generator = UINotificationFeedbackGenerator()
            generator.prepare()
            generator.notificationOccurred(feedback)
            completion(.success(["fired": true, "type": type, "implementation": "UIKitFeedbackGenerator"]))
        case "selection":
            let generator = UISelectionFeedbackGenerator()
            generator.prepare()
            generator.selectionChanged()
            completion(.success(["fired": true, "implementation": "UIKitFeedbackGenerator"]))
        case "vibrate":
            let duration = max(1, min(10_000, int(call.options["duration"], default: 40)))
            completion(playHaptic(duration: Double(duration) / 1000, amplitude: double(call.options["amplitude"], default: 1)))
        case "vibrateLong":
            let duration = max(1, min(60_000, int(call.options["duration"], default: 1_500)))
            completion(playHaptic(duration: Double(duration) / 1000, amplitude: double(call.options["amplitude"], default: 1)))
        case "vibrateWaveform":
            completion(playWaveform(call.options))
        case "vibratePredefined":
            let effect = string(call.options["effectId"], default: "CLICK").uppercased()
            switch effect {
            case "CLICK", "TICK", "DOUBLE_CLICK":
                let generator = UIImpactFeedbackGenerator(style: effect == "DOUBLE_CLICK" ? .heavy : .light)
                generator.prepare(); generator.impactOccurred()
                if effect == "DOUBLE_CLICK" { DispatchQueue.main.asyncAfter(deadline: .now() + 0.08) { generator.impactOccurred() } }
                completion(.success(["fired": true, "effectId": effect, "implementation": "UIKitApproximation"]))
            case "SUCCESS", "WARNING", "ERROR":
                dispatchHaptics(LynxNativeCapabilityCall(callbackId: "", pluginId: "Haptics", methodName: "notification", options: ["type": effect]), completion: completion)
            default:
                completion(.failure("UNSUPPORTED_HAPTIC_EFFECT", "iOS 没有对应的 Android predefined effect: \(effect)"))
            }
        case "vibrateComposition":
            completion(playComposition(call.options))
        case "getCapabilities":
            let supports = CHHapticEngine.capabilitiesForHardware().supportsHaptics
            completion(.success([
                "supportsHaptics": supports,
                "supportsCoreHaptics": supports,
                "supportsWaveform": supports,
                "supportsComposition": supports,
                "supportsPredefined": true,
                "platform": "ios",
            ]))
        case "cancel":
            try? hapticPlayer?.stop(atTime: CHHapticTimeImmediate)
            hapticPlayer = nil
            hapticEngine?.stop(completionHandler: nil)
            completion(.success(["cancelled": true]))
        default:
            completion(.failure("UNSUPPORTED", "Haptics.\(call.methodName) 尚未接入当前 iOS Module"))
        }
    }

    private static func playHaptic(duration: TimeInterval, amplitude: Double) -> LynxNativeCapabilityResult {
        guard CHHapticEngine.capabilitiesForHardware().supportsHaptics else {
            if duration <= 0.1 {
                AudioServicesPlaySystemSound(kSystemSoundID_Vibrate)
                return .success(["fired": true, "duration": duration * 1000, "implementation": "SystemVibrate"])
            }
            return .failure("HARDWARE_UNAVAILABLE", "当前 iOS 设备不支持 Core Haptics 长震动")
        }
        do {
            let engine = try ensureHapticEngine()
            let intensity = CHHapticEventParameter(parameterID: .hapticIntensity, value: Float(max(0, min(1, amplitude))))
            let sharpness = CHHapticEventParameter(parameterID: .hapticSharpness, value: 0.5)
            let event = CHHapticEvent(
                eventType: duration > 0.1 ? .hapticContinuous : .hapticTransient,
                parameters: [intensity, sharpness],
                relativeTime: 0,
                duration: duration > 0.1 ? duration : 0
            )
            let player = try engine.makePlayer(with: CHHapticPattern(events: [event], parameters: []))
            hapticPlayer = player
            try player.start(atTime: CHHapticTimeImmediate)
            return .success(["fired": true, "duration": duration * 1000, "implementation": "CoreHaptics"])
        } catch {
            return .failure("HAPTIC_START_FAILED", error.localizedDescription)
        }
    }

    private static func playWaveform(_ options: [String: Any]) -> LynxNativeCapabilityResult {
        guard CHHapticEngine.capabilitiesForHardware().supportsHaptics else {
            return .failure("HARDWARE_UNAVAILABLE", "当前 iOS 设备不支持 Core Haptics waveform")
        }
        let timings = arrayOfDouble(options["timings"])
        let amplitudes = arrayOfDouble(options["amplitudes"])
        guard !timings.isEmpty, timings.count == amplitudes.count else {
            return .failure("INVALID_ARGUMENT", "timings 和 amplitudes 必须是长度相同的非空数组")
        }
        var time = 0.0
        var events: [CHHapticEvent] = []
        for index in timings.indices {
            let delay = timings[index] / 1000
            guard delay >= 0, delay <= 60 else { return .failure("INVALID_ARGUMENT", "waveform timing 超出范围") }
            time += delay
            let amplitude = max(0, min(1, amplitudes[index] > 1 ? amplitudes[index] / 255 : amplitudes[index]))
            if amplitude > 0 {
                events.append(CHHapticEvent(
                    eventType: .hapticTransient,
                    parameters: [CHHapticEventParameter(parameterID: .hapticIntensity, value: Float(amplitude))],
                    relativeTime: time
                ))
            }
        }
        guard !events.isEmpty else { return .success(["fired": false, "eventCount": 0]) }
        do {
            let engine = try ensureHapticEngine()
            let player = try engine.makePlayer(with: CHHapticPattern(events: events, parameters: []))
            hapticPlayer = player
            try player.start(atTime: CHHapticTimeImmediate)
            return .success(["fired": true, "eventCount": events.count, "repeat": int(options["repeat"], default: -1) >= 0 ? false : true, "implementation": "CoreHapticsApproximation"])
        } catch {
            return .failure("HAPTIC_START_FAILED", error.localizedDescription)
        }
    }

    private static func playComposition(_ options: [String: Any]) -> LynxNativeCapabilityResult {
        guard CHHapticEngine.capabilitiesForHardware().supportsHaptics else {
            return .failure("HARDWARE_UNAVAILABLE", "当前 iOS 设备不支持 Core Haptics composition")
        }
        guard let primitives = options["primitives"] as? [[String: Any]], !primitives.isEmpty else {
            return .failure("INVALID_ARGUMENT", "primitives 必须是非空数组")
        }
        var events: [CHHapticEvent] = []
        var time = 0.0
        for primitive in primitives {
            time += max(0, double(primitive["delay"], default: 0) / 1000)
            let scale = max(0, min(1, double(primitive["scale"], default: 1)))
            let duration = max(0.01, min(1, double(primitive["duration"], default: 0.06)))
            events.append(CHHapticEvent(
                eventType: duration > 0.1 ? .hapticContinuous : .hapticTransient,
                parameters: [CHHapticEventParameter(parameterID: .hapticIntensity, value: Float(scale))],
                relativeTime: time,
                duration: duration > 0.1 ? duration : 0
            ))
            time += duration
        }
        do {
            let engine = try ensureHapticEngine()
            let player = try engine.makePlayer(with: CHHapticPattern(events: events, parameters: []))
            hapticPlayer = player
            try player.start(atTime: CHHapticTimeImmediate)
            return .success(["fired": true, "primitiveCount": primitives.count, "implementation": "CoreHapticsApproximation"])
        } catch {
            return .failure("HAPTIC_START_FAILED", error.localizedDescription)
        }
    }

    private static func ensureHapticEngine() throws -> CHHapticEngine {
        if let hapticEngine { return hapticEngine }
        let engine = try CHHapticEngine()
        engine.resetHandler = { hapticEngine = nil }
        engine.stoppedHandler = { _ in }
        try engine.start()
        hapticEngine = engine
        return engine
    }

    // MARK: - Share

    private static func dispatchShare(
        _ call: LynxNativeCapabilityCall,
        presenter: UIViewController?,
        completion: @escaping Completion
    ) {
        switch call.methodName {
        case "canShare":
            completion(.success(["value": presenter != nil && UIActivityViewController.self != nil]))
        case "share":
            guard let presenter, LynxNativeCapabilitySupport.isUsable(presenter) else {
                completion(.failure("SCENE_UNAVAILABLE", "没有可展示 Share Sheet 的前台 UIViewController"))
                return
            }
            var items: [Any] = []
            let title = string(call.options["title"], default: "")
            let text = string(call.options["text"], default: "")
            let urlString = string(call.options["url"], default: "")
            if !title.isEmpty { items.append(title) }
            if !text.isEmpty { items.append(text) }
            if let url = URL(string: urlString), !urlString.isEmpty { items.append(url) }
            let files = call.options["files"] as? [Any] ?? []
            for file in files {
                let raw = string(file, default: "")
                if let url = localOrRemoteURL(raw) { items.append(url) }
            }
            guard !items.isEmpty else {
                completion(.failure("INVALID_ARGUMENT", "Share 至少需要 title、text、url 或 files 之一"))
                return
            }
            let controller = UIActivityViewController(activityItems: items, applicationActivities: nil)
            controller.excludedActivityTypes = []
            configurePopover(controller, presenter: presenter)
            controller.completionWithItemsHandler = { activityType, completed, _, error in
                shareController = nil
                if let error {
                    completion(.failure("SHARE_FAILED", error.localizedDescription))
                } else {
                    completion(.success([
                        "completed": completed,
                        "activityType": activityType?.rawValue ?? NSNull(),
                    ]))
                }
            }
            shareController = controller
            presenter.present(controller, animated: true)
        default:
            completion(.failure("UNSUPPORTED", "Share.\(call.methodName) 尚未接入当前 iOS Module"))
        }
    }

    private static func configurePopover(_ controller: UIViewController, presenter: UIViewController) {
        guard let popover = controller.popoverPresentationController else { return }
        popover.sourceView = presenter.view
        popover.sourceRect = presenter.view.bounds
        popover.permittedArrowDirections = []
    }

    private static func localOrRemoteURL(_ value: String) -> URL? {
        if let url = URL(string: value), url.scheme != nil { return url }
        let fileManager = FileManager.default
        let roots = [
            fileManager.urls(for: .cachesDirectory, in: .userDomainMask).first,
            fileManager.urls(for: .documentDirectory, in: .userDomainMask).first,
            fileManager.temporaryDirectory,
        ].compactMap { $0 }
        for root in roots {
            let candidate = root.appendingPathComponent(value.trimmingCharacters(in: CharacterSet(charactersIn: "/")))
            if fileManager.fileExists(atPath: candidate.path) { return candidate }
        }
        return nil
    }

    // MARK: - Helpers

    private final class CompletionOnce {
        private let lock = NSLock()
        private var completed = false
        private let completion: Completion

        init(_ completion: @escaping Completion) { self.completion = completion }

        func call(_ result: LynxNativeCapabilityResult) {
            let shouldCall = lock.withLock { () -> Bool in
                guard !completed else { return false }
                completed = true
                return true
            }
            if shouldCall { completion(result) }
        }
    }

    private final class PaddingLabel: UILabel {
        var padding = UIEdgeInsets(top: 10, left: 14, bottom: 10, right: 14)
        override func drawText(in rect: CGRect) { super.drawText(in: rect.inset(by: padding)) }
        override var intrinsicContentSize: CGSize {
            let size = super.intrinsicContentSize
            return CGSize(width: size.width + padding.left + padding.right, height: size.height + padding.top + padding.bottom)
        }
    }

    private static func string(_ value: Any?, default defaultValue: String) -> String {
        guard let value, !(value is NSNull) else { return defaultValue }
        if let value = value as? String { return value }
        return String(describing: value)
    }

    private static func bool(_ value: Any?, default defaultValue: Bool) -> Bool {
        guard let value, !(value is NSNull) else { return defaultValue }
        if let value = value as? Bool { return value }
        if let value = value as? NSNumber { return value.boolValue }
        return ["true", "1", "yes", "on"].contains(string(value, default: "").lowercased())
    }

    private static func int(_ value: Any?, default defaultValue: Int) -> Int {
        if let value = value as? Int { return value }
        if let value = value as? NSNumber { return value.intValue }
        return Int(string(value, default: "")) ?? defaultValue
    }

    private static func double(_ value: Any?, default defaultValue: Double) -> Double {
        if let value = value as? Double { return value }
        if let value = value as? NSNumber { return value.doubleValue }
        return Double(string(value, default: "")) ?? defaultValue
    }

    private static func arrayOfDouble(_ value: Any?) -> [Double] {
        (value as? [Any] ?? []).map { double($0, default: -1) }
    }
}

private extension NSLock {
    func withLock<T>(_ body: () throws -> T) rethrows -> T {
        lock()
        defer { unlock() }
        return try body()
    }
}
