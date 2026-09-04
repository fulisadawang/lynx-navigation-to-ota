import AVFoundation
import Foundation
import UIKit

/** AVAudioSession/AVAudioRecorder/AVAudioPlayer 对译 Android Audio 能力。 */
enum LynxNativeAudioCapabilities {
    typealias Completion = (LynxNativeCapabilityResult) -> Void

    private static let lock = NSLock()
    private static var recorder: AVAudioRecorder?
    private static var player: AVAudioPlayer?
    private static var recordingURL: URL?
    private static var playbackURL: URL?
    private static var state = "idle"
    private static var playerDelegate: AudioPlayerDelegate?
    private static var activeOwnerID: String?

    static func dispatch(
        _ call: LynxNativeCapabilityCall,
        presenter: UIViewController?,
        completion: @escaping Completion
    ) -> Bool {
        guard call.pluginId == "Audio" else { return false }
        lock.withLock { if activeOwnerID == nil { activeOwnerID = call.ownerID } }
        let run = {
            switch call.methodName {
            case "checkPermissions": completion(.success(permissionData()))
            case "requestPermissions": requestPermission(presenter: presenter, completion: completion)
            case "record": startRecording(completion: completion)
            case "stopRecording": stopRecording(completion: completion)
            case "play": startPlayback(call.options, completion: completion)
            case "stopPlayback": stopPlayback(completion: completion)
            case "getState": completion(.success(stateData()))
            default: completion(.failure("UNSUPPORTED", "Audio.\(call.methodName) 尚未接入当前 iOS Module"))
            }
        }
        if Thread.isMainThread { run() } else { DispatchQueue.main.async(execute: run) }
        return true
    }

    static func release(ownerID: String) {
        guard lock.withLock({ activeOwnerID == ownerID }) else { return }
        releaseResources()
    }

    static func releaseAll() {
        releaseResources()
    }

    private static func releaseResources() {
        stopRecorderSilently()
        stopPlayerSilently()
        lock.withLock {
            recorder = nil; player = nil; recordingURL = nil; playbackURL = nil; playerDelegate = nil; activeOwnerID = nil; state = "idle"
        }
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }

    private static func permissionData() -> [String: Any] {
        let session = AVAudioSession.sharedInstance()
        let value: String
        switch session.recordPermission {
        case .granted: value = "granted"
        case .denied: value = "denied"
        case .undetermined: value = "prompt"
        @unknown default: value = "unknown"
        }
        return ["audio": value, "record": value]
    }

    private static func requestPermission(presenter: UIViewController?, completion: @escaping Completion) {
        _ = presenter
        guard Bundle.main.object(forInfoDictionaryKey: "NSMicrophoneUsageDescription") as? String != nil else {
            completion(.failure("PERMISSION_NOT_DECLARED", "宿主未声明 NSMicrophoneUsageDescription")); return
        }
        AVAudioSession.sharedInstance().requestRecordPermission { _ in
            DispatchQueue.main.async { completion(.success(permissionData())) }
        }
    }

    private static func startRecording(completion: @escaping Completion) {
        guard AVAudioSession.sharedInstance().recordPermission == .granted else {
            completion(.failure("PERMISSION_DENIED", "未授予录音权限，请先调用 Audio.requestPermissions")); return
        }
        guard Bundle.main.object(forInfoDictionaryKey: "NSMicrophoneUsageDescription") as? String != nil else {
            completion(.failure("PERMISSION_NOT_DECLARED", "宿主未声明 NSMicrophoneUsageDescription")); return
        }
        guard lock.withLock({ state == "idle" }) else { completion(.failure("BUSY", "当前已有录音或播放操作")); return }
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("lynx-audio-\(UUID().uuidString).m4a")
        do {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.record, mode: .default, options: [.allowBluetooth])
            try session.setActive(true, options: [])
            let recorder = try AVAudioRecorder(url: url, settings: [
                AVFormatIDKey: Int(kAudioFormatMPEG4AAC),
                AVSampleRateKey: 44_100,
                AVNumberOfChannelsKey: 1,
                AVEncoderAudioQualityKey: AVAudioQuality.high.rawValue,
            ])
            recorder.prepareToRecord()
            guard recorder.record() else { completion(.failure("RECORDER_START_FAILED", "AVAudioRecorder 无法开始录音")); return }
            lock.withLock { self.recorder = recorder; recordingURL = url; state = "recording" }
            completion(.success(["recording": true, "state": "recording", "path": url.path, "uri": url.absoluteString]))
        } catch {
            completion(.failure("RECORDER_START_FAILED", error.localizedDescription))
        }
    }

    private static func stopRecording(completion: @escaping Completion) {
        guard let recorder = lock.withLock({ self.recorder }) else {
            completion(.success(["recording": false, "state": "idle", "path": recordingURL?.path ?? NSNull()])); return
        }
        recorder.stop()
        let url = lock.withLock { () -> URL? in
            self.recorder = nil
            state = "idle"
            return recordingURL
        }
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        completion(.success(["recording": false, "state": "idle", "path": url?.path ?? NSNull(), "uri": url?.absoluteString ?? NSNull()]))
    }

    private static func startPlayback(_ options: [String: Any], completion: @escaping Completion) {
        guard lock.withLock({ state == "idle" }) else { completion(.failure("BUSY", "当前已有录音或播放操作")); return }
        let path = string(options["path"] ?? options["uri"])
        guard let url = resolveURL(path: path, directory: string(options["directory"], default: "CACHE")), FileManager.default.fileExists(atPath: url.path) else {
            completion(.failure("NOT_FOUND", "播放文件不存在")); return
        }
        do {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.playback, mode: .default, options: [.allowBluetooth])
            try session.setActive(true, options: [])
            let player = try AVAudioPlayer(contentsOf: url)
            let delegate = AudioPlayerDelegate { success in
                lock.withLock { state = "idle"; self.player = nil; playerDelegate = nil }
                try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
                _ = success
            }
            player.delegate = delegate
            player.prepareToPlay()
            guard player.play() else { completion(.failure("PLAYER_START_FAILED", "AVAudioPlayer 无法开始播放")); return }
            lock.withLock { self.player = player; playerDelegate = delegate; playbackURL = url; state = "playing" }
            completion(.success(["playing": true, "state": "playing", "path": url.path, "uri": url.absoluteString]))
        } catch {
            completion(.failure("PLAYER_START_FAILED", error.localizedDescription))
        }
    }

    private static func stopPlayback(completion: @escaping Completion) {
        stopPlayerSilently()
        completion(.success(["playing": false, "state": "idle"]))
    }

    private static func stopRecorderSilently() { lock.withLock { recorder?.stop(); recorder = nil; state = state == "recording" ? "idle" : state } }
    private static func stopPlayerSilently() { lock.withLock { player?.stop(); player = nil; playerDelegate = nil; state = state == "playing" ? "idle" : state } }
    private static func stateData() -> [String: Any] { lock.withLock { ["state": state, "recording": state == "recording", "playing": state == "playing", "recordingPath": recordingURL?.path ?? NSNull(), "playbackPath": playbackURL?.path ?? NSNull()] } }

    private static func resolveURL(path: String, directory: String) -> URL? {
        if let url = URL(string: path), url.isFileURL { return url }
        if path.hasPrefix("/") { return URL(fileURLWithPath: path) }
        let root: URL?
        switch directory.uppercased() {
        case "CACHE": root = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
        case "DOCUMENTS", "FILES": root = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first
        case "TEMP", "TEMPORARY": root = FileManager.default.temporaryDirectory
        default: root = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
        }
        guard let root else { return nil }
        let target = root.appendingPathComponent(path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))).standardizedFileURL
        return target.path.hasPrefix(root.standardizedFileURL.path) ? target : nil
    }

    private static func string(_ value: Any?, default defaultValue: String = "") -> String { guard let value, !(value is NSNull) else { return defaultValue }; return value as? String ?? String(describing: value) }

    private final class AudioPlayerDelegate: NSObject, AVAudioPlayerDelegate {
        let callback: (Bool) -> Void
        init(callback: @escaping (Bool) -> Void) { self.callback = callback }
        func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) { _ = player; callback(flag) }
        func audioPlayerDecodeErrorDidOccur(_ player: AVAudioPlayer, error: Error?) { _ = player; _ = error; callback(false) }
    }
}

private extension NSLock {
    func withLock<T>(_ body: () throws -> T) rethrows -> T { lock(); defer { unlock() }; return try body() }
}
