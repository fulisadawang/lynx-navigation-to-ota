import Foundation
import UIKit

/**
 * 自有 iOS Module 的唯一能力派发器。
 *
 * 各能力域通过独立 adapter 文件注册，dispatcher 只负责保持和 Android 相同的
 * pluginId/methodName 路由、线程边界和 unsupported 语义。
 */
final class LynxNativeCapabilityDispatcher {
    typealias Completion = (LynxNativeCapabilityResult) -> Void
    typealias EventSender = (String) -> Void

    private let lock = NSLock()
    private var eventSender: EventSender?

    func setEventSender(_ sender: EventSender?) {
        lock.lock()
        eventSender = sender
        lock.unlock()
    }

    func dispatch(
        _ call: LynxNativeCapabilityCall,
        presenter: UIViewController?,
        completion: @escaping Completion
    ) {
        let run = {
            if LynxNativeInteractiveCapabilities.dispatch(call, presenter: presenter, completion: completion) { return }
            if LynxNativeMediaCapabilities.dispatch(call, presenter: presenter, eventSender: self.currentEventSender(), completion: completion) { return }
            if LynxNativeBarcodeCapabilities.dispatch(call, presenter: presenter, completion: completion) { return }
            if LynxNativeAudioCapabilities.dispatch(call, presenter: presenter, completion: completion) { return }
            if LynxNativeBiometricsCapabilities.dispatch(call, completion: completion) { return }
            if LynxNativeSystemCapabilities.dispatch(call, presenter: presenter, eventSender: self.currentEventSender(), completion: completion) { return }
            if LynxNativeProviderCapabilities.dispatch(call, presenter: presenter, eventSender: self.currentEventSender(), completion: completion) { return }
            if LynxNativeDatabaseCapabilities.dispatch(call, completion: completion) { return }

            guard let spec = LynxNativeCapabilityCatalog.find(call.pluginId) else {
                completion(.failure("UNIMPLEMENTED", "Unknown native capability: \(call.pluginId)"))
                return
            }
            guard spec.methods.contains(call.methodName) else {
                completion(.failure("UNIMPLEMENTED", "Method \(call.methodName) is not registered on \(call.pluginId)"))
                return
            }
            completion(.failure("UNSUPPORTED", "\(call.pluginId).\(call.methodName) 尚未接入当前 iOS Module"))
        }

        if Thread.isMainThread {
            run()
        } else {
            DispatchQueue.main.async(execute: run)
        }
    }

    func sendEvent(_ value: [String: Any]) {
        guard let sender = currentEventSender(), let json = LynxNativeJSON.encode(value) else { return }
        sender(json)
    }

    private func currentEventSender() -> EventSender? {
        lock.lock()
        defer { lock.unlock() }
        return eventSender
    }
}
