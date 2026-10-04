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
    private let eventSequenceLock = NSLock()
    private var eventSequence = 0
    private let infoDictionary: () -> [String: Any]
    private let systemMajorVersion: Int

    init(infoDictionary: @escaping () -> [String: Any] = { Bundle.main.infoDictionary ?? [:] },
         systemMajorVersion: Int = ProcessInfo.processInfo.operatingSystemVersion.majorVersion) {
        self.infoDictionary = infoDictionary
        self.systemMajorVersion = systemMajorVersion
    }

    func setEventSender(_ sender: EventSender?) {
        lock.lock()
        eventSender = sender
        lock.unlock()
    }

    func dispatch(
        _ call: LynxNativeCapabilityCall,
        presenter: UIViewController?,
        host: AnyObject? = nil,
        completion: @escaping Completion
    ) {
        let run = {
            guard LynxNativeOwnerScope.isActive(call.ownerID) else {
                completion(.failure("HOST_DESTROYED", "页面已销毁")); return
            }
            // 先经过协议目录闸门，确保所有能力域在进入平台 adapter 前拥有相同的未声明/未实现语义。
            guard let spec = LynxNativeCapabilityCatalog.find(call.pluginId) else {
                completion(.failure("UNIMPLEMENTED", "Unknown native capability: \(call.pluginId)"))
                return
            }
            guard spec.methods.contains(call.methodName) else {
                completion(.failure("UNIMPLEMENTED", "Method \(call.methodName) is not registered on \(call.pluginId)"))
                return
            }
            let hostMethod = LynxNativeCapabilityCatalog.hostRequirements[call.pluginId]?.contains(call.methodName) == true
            guard spec.implementedMethods.contains(call.methodName) || (hostMethod && host != nil) else {
                completion(.failure("UNSUPPORTED", "\(call.pluginId).\(call.methodName) 尚未接入当前 iOS Module"))
                return
            }

            if let failure = LynxNativeUsageDescriptions.validate(call, info: self.infoDictionary(), systemMajorVersion: self.systemMajorVersion) {
                completion(failure)
                return
            }

            if LynxNativeInteractiveCapabilities.dispatch(call, presenter: presenter, completion: completion) { return }
            if LynxNativeMediaCapabilities.dispatch(call, presenter: presenter, eventSender: self.currentEventSender(), completion: completion) { return }
            if LynxNativeBarcodeCapabilities.dispatch(call, presenter: presenter, completion: completion) { return }
            if LynxNativeAudioCapabilities.dispatch(call, presenter: presenter, completion: completion) { return }
            if LynxNativeBiometricsCapabilities.dispatch(call, completion: completion) { return }
            if LynxNativeSystemCapabilities.dispatch(call, presenter: presenter, host: host, eventSender: self.currentEventSender(), completion: completion) { return }
            if LynxNativeProviderCapabilities.dispatch(call, presenter: presenter, eventSender: self.currentEventSender(), completion: completion) { return }
            if LynxNativeDatabaseCapabilities.dispatch(call, completion: completion) { return }

            completion(.failure("UNSUPPORTED", "\(call.pluginId).\(call.methodName) 尚未接入当前 iOS Module"))
        }

        if Thread.isMainThread {
            run()
        } else {
            DispatchQueue.main.async(execute: run)
        }
    }

    func sendEvent(_ value: [String: Any]) {
        var envelope = value
        if envelope["callbackId"] == nil { envelope["callbackId"] = "-1" }
        if envelope["eventName"] == nil, let methodName = envelope["methodName"] as? String {
            envelope["eventName"] = methodName
        }
        if envelope["success"] == nil { envelope["success"] = true }
        if envelope["save"] == nil { envelope["save"] = true }
        if var error = envelope["error"] as? [String: Any],
           error["reasonCode"] == nil,
           let code = error["code"] as? String {
            error["reasonCode"] = LynxCapabilitySemantics.errorReasonCode(for: code)
            envelope["error"] = error
        }
        eventSequenceLock.lock()
        eventSequence += 1
        envelope["sequence"] = eventSequence
        eventSequenceLock.unlock()
        guard let sender = currentEventSender(), let json = LynxNativeJSON.encode(envelope) else { return }
        sender(json)
    }

    private func currentEventSender() -> EventSender? {
        lock.lock()
        defer { lock.unlock() }
        return eventSender
    }
}

/** 只校验当前 adapter 会使用的隐私入口；版本差异必须对应实际 EventKit 请求 API。 */
enum LynxNativeUsageDescriptions {
    static func requiredKeys(_ call: LynxNativeCapabilityCall, systemMajorVersion: Int) -> [String] {
        let options = call.options
        func flag(_ key: String, default value: Bool = false) -> Bool { options[key] as? Bool ?? value }
        switch (call.pluginId, call.methodName) {
        case ("Contacts", "requestPermissions"): return ["NSContactsUsageDescription"]
        case ("Audio", "requestPermissions"), ("Audio", "record"): return ["NSMicrophoneUsageDescription"]
        case ("CapacitorBarcodeScanner", "scanBarcode"): return ["NSCameraUsageDescription"]
        case ("Biometrics", "authenticate"): return ["NSFaceIDUsageDescription"]
        case ("Geolocation", "requestPermissions"):
            let permissions = (options["permissions"] as? [String] ?? ["wheninuse"]).map { $0.lowercased() }
            return permissions.contains("always") ? ["NSLocationWhenInUseUsageDescription", "NSLocationAlwaysAndWhenInUseUsageDescription"] : ["NSLocationWhenInUseUsageDescription"]
        case ("Geolocation", "getCurrentPosition"): return ["NSLocationWhenInUseUsageDescription"]
        case ("Calendar", "requestPermissions"):
            if systemMajorVersion < 17 { return ["NSCalendarsUsageDescription"] }
            let permissions = (options["permissions"] as? [String] ?? ["read", "write"]).map { $0.lowercased() }
            let read = permissions.contains { ["read", "calendar", "readcalendar"].contains($0) }
            return [read ? "NSCalendarsFullAccessUsageDescription" : "NSCalendarsWriteOnlyAccessUsageDescription"]
        case ("Camera", "requestPermissions"):
            let source = (options["source"] as? String ?? "PROMPT").uppercased()
            var keys: [String] = []
            if source == "CAMERA" || source == "PROMPT" || flag("includeCamera") { keys.append("NSCameraUsageDescription") }
            if source != "CAMERA" || flag("includePhotos", default: true) { keys.append("NSPhotoLibraryUsageDescription") }
            if flag("saveToGallery") { keys.append("NSPhotoLibraryAddUsageDescription") }
            if flag("includeMicrophone") || ((source == "CAMERA" || source == "PROMPT" || flag("includeCamera"))
                && ((options["mediaType"] as? String)?.lowercased() == "video" || (options["mediaType"] as? NSNumber)?.intValue == 1)) {
                keys.append("NSMicrophoneUsageDescription")
            }
            return keys
        case ("Camera", "chooseFromGallery"):
            // 新选择入口在实际拍摄后校验；相册不重复保存。
            return []
        case ("Camera", "getPhoto"), ("Camera", "pickImages"):
            // 保留旧单图/图片选择的显式保存语义，PROMPT 在选定来源后再检查。
            let source = (options["source"] as? String ?? "PHOTOS").uppercased()
            return source == "PHOTOS" && flag("saveToGallery") ? ["NSPhotoLibraryAddUsageDescription"] : []
        case ("Camera", "takePhoto"), ("Camera", "recordVideo"):
            // 系统录像不支持静音模式，交给能力返回 UNSUPPORTED，不校验不会使用的隐私入口。
            if call.methodName == "recordVideo", options["includeMicrophone"] as? Bool == false { return [] }
            // 旧 Shell 的混合拍摄同样先选择图片/视频，不预先阻塞拍照分支。
            if flag("legacyCameraMixed") { return [] }
            var keys: [String] = []
            keys.append("NSCameraUsageDescription")
            if call.methodName == "recordVideo" { keys.append("NSMicrophoneUsageDescription") }
            if flag("saveToGallery") { keys.append("NSPhotoLibraryAddUsageDescription") }
            // PHPicker 由系统提供用户选中项，不在选取时申请相册全库权限。
            return keys
        default: return []
        }
    }

    static func validate(_ call: LynxNativeCapabilityCall, info: [String: Any], systemMajorVersion: Int) -> LynxNativeCapabilityResult? {
        let missing = requiredKeys(call, systemMajorVersion: systemMajorVersion).filter {
            guard let text = info[$0] as? String else { return true }
            return text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
        guard !missing.isEmpty else { return nil }
        return .failure("HOST_CONFIGURATION_REQUIRED", "宿主缺少非空隐私用途文案", details: ["missingKeys": missing])
    }
}
