import AVKit
import Foundation
import Photos
import PhotosUI
import QuickLook
import UIKit
import UniformTypeIdentifiers

/**
 * UIKit/Photos/URLSession/QuickLook 对译：Clipboard、Filesystem、Camera、FileTransfer、FileViewer。
 *
 * 该文件只使用 iOS 系统 API。它保留 Android Module 的方法名和主要字段，系统无法提供
 * 完全相同语义时返回结构化错误，而不是返回一个伪造的成功值。
 */
enum LynxNativeMediaCapabilities {
    typealias Completion = (LynxNativeCapabilityResult) -> Void
    typealias EventSender = (String) -> Void

    private static let fileManager = FileManager.default
    private static let fileLock = NSLock()
    private static var activePicker: PickerRequest?
    private static var pickerDelegate: PickerDelegate?
    private static var transfers: [String: Transfer] = [:]
    private static var previewController: QLPreviewController?
    private static var previewDataSource: PreviewDataSource?

    static func dispatch(
        _ call: LynxNativeCapabilityCall,
        presenter: UIViewController?,
        eventSender: EventSender? = nil,
        completion: @escaping Completion
    ) -> Bool {
        switch call.pluginId {
        case "Clipboard": dispatchClipboard(call, completion: completion)
        case "Filesystem": dispatchFilesystem(call, completion: completion)
        case "Camera": dispatchCamera(call, presenter: presenter, completion: completion)
        case "FileTransfer": dispatchFileTransfer(call, eventSender: eventSender, completion: completion)
        case "FileViewer": dispatchFileViewer(call, presenter: presenter, completion: completion)
        default: return false
        }
        return true
    }

    static func release(ownerID: String) {
        let picker = fileLock.withLock { () -> PickerRequest? in
            guard activePicker?.call.ownerID == ownerID else { return nil }
            let current = activePicker
            activePicker = nil
            pickerDelegate = nil
            return current
        }
        picker?.completion(.failure("MODULE_DESTROYED", "iOS Native Module 已销毁，媒体请求已取消"))
        let operations = fileLock.withLock { () -> [Transfer] in
            let matching = transfers.filter { $0.value.call.ownerID == ownerID }
            matching.keys.forEach { transfers.removeValue(forKey: $0) }
            let values = Array(matching.values)
            return values
        }
        operations.forEach { $0.cancelFromModuleRelease() }
    }

    static func releaseAll() {
        let picker = fileLock.withLock { () -> PickerRequest? in
            let current = activePicker
            activePicker = nil
            pickerDelegate = nil
            return current
        }
        picker?.completion(.failure("MODULE_DESTROYED", "iOS Native Module 已销毁，媒体请求已取消"))
        let operations = fileLock.withLock { () -> [Transfer] in
            let values = Array(transfers.values)
            transfers.removeAll()
            return values
        }
        operations.forEach { $0.cancelFromModuleRelease() }
        previewController?.dismiss(animated: false)
        previewController = nil
        previewDataSource = nil
    }

    // MARK: - Clipboard

    private static func dispatchClipboard(_ call: LynxNativeCapabilityCall, completion: @escaping Completion) {
        let pasteboard = UIPasteboard.general
        switch call.methodName {
        case "write":
            let value = string(call.options["string"] ?? call.options["text"])
            pasteboard.string = value
            completion(.success(["written": true]))
        case "read":
            completion(.success([
                "type": pasteboard.hasStrings ? "text" : "",
                "value": pasteboard.string ?? "",
            ]))
        default:
            completion(.failure("UNSUPPORTED", "Clipboard.\(call.methodName) 尚未接入当前 iOS Module"))
        }
    }

    // MARK: - Filesystem

    private static func dispatchFilesystem(_ call: LynxNativeCapabilityCall, completion: @escaping Completion) {
        let root: URL
        do {
            root = try directoryRoot(string(call.options["directory"], default: "CACHE"))
        } catch let error as MediaError {
            completion(.failure(error.code, error.message)); return
        } catch {
            completion(.failure("NATIVE_ERROR", error.localizedDescription)); return
        }
        let path = string(call.options["path"])
        guard let target = safePath(path, under: root) else {
            completion(.failure("INVALID_ARGUMENT", "path 不允许路径穿越")); return
        }
        do {
            switch call.methodName {
            case "writeFile":
                try fileManager.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
                let data = try decodeFileData(string(call.options["data"]), encoding: string(call.options["encoding"], default: "utf8"))
                try data.write(to: target, options: .atomic)
                completion(.success(["uri": target.absoluteString, "path": target.path]))
            case "readFile":
                guard fileManager.fileExists(atPath: target.path) else { throw MediaError("NOT_FOUND", "文件不存在: \(path)") }
                let data = try Data(contentsOf: target)
                completion(.success(["data": encodeFileData(data, encoding: string(call.options["encoding"], default: "utf8")), "uri": target.absoluteString]))
            case "readdir":
                guard fileManager.fileExists(atPath: target.path) else { throw MediaError("NOT_FOUND", "目录不存在: \(path)") }
                guard let values = try? fileManager.contentsOfDirectory(at: target, includingPropertiesForKeys: [.isDirectoryKey, .fileSizeKey], options: [.skipsHiddenFiles]) else { throw MediaError("READ_FAILED", "无法读取目录") }
                let files = values.compactMap(fileSummary)
                completion(.success(["files": files]))
            case "stat":
                guard fileManager.fileExists(atPath: target.path) else { throw MediaError("NOT_FOUND", "文件不存在: \(path)") }
                completion(.success(fileSummary(target) ?? ["uri": target.absoluteString]))
            case "mkdir":
                try fileManager.createDirectory(at: target, withIntermediateDirectories: bool(call.options["recursive"], default: true))
                completion(.success(["created": true, "uri": target.absoluteString]))
            case "getUri":
                completion(.success(["uri": target.absoluteString, "path": target.path]))
            default:
                completion(.failure("UNSUPPORTED", "Filesystem.\(call.methodName) 尚未接入当前 iOS Module"))
            }
        } catch let error as MediaError {
            completion(.failure(error.code, error.message))
        } catch {
            completion(.failure("NATIVE_ERROR", error.localizedDescription))
        }
    }

    private static func directoryRoot(_ name: String) throws -> URL {
        switch name.uppercased() {
        case "CACHE": return try requiredURL(.cachesDirectory)
        case "DATA", "APPLICATION_SUPPORT": return try requiredURL(.applicationSupportDirectory)
        case "DOCUMENTS", "FILES": return try requiredURL(.documentDirectory)
        case "LIBRARY": return try requiredURL(.libraryDirectory)
        case "TEMPORARY", "TEMP": return fileManager.temporaryDirectory
        default: throw MediaError("INVALID_ARGUMENT", "不支持的 directory: \(name)")
        }
    }

    private static func requiredURL(_ directory: FileManager.SearchPathDirectory) throws -> URL {
        guard let url = fileManager.urls(for: directory, in: .userDomainMask).first else { throw MediaError("NATIVE_ERROR", "无法解析应用沙盒目录") }
        try fileManager.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private static func safePath(_ rawPath: String, under root: URL) -> URL? {
        let relative = rawPath.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        let target = root.appendingPathComponent(relative).standardizedFileURL
        let rootPath = root.standardizedFileURL.path.hasSuffix("/") ? root.standardizedFileURL.path : root.standardizedFileURL.path + "/"
        return target.path == root.standardizedFileURL.path || target.path.hasPrefix(rootPath) ? target : nil
    }

    private static func fileSummary(_ url: URL) -> [String: Any]? {
        guard let values = try? url.resourceValues(forKeys: [.isDirectoryKey, .fileSizeKey]) else { return nil }
        return [
            "name": url.lastPathComponent,
            "type": values.isDirectory == true ? "directory" : "file",
            "size": values.fileSize ?? 0,
            "uri": url.absoluteString,
            "path": url.path,
        ]
    }

    private static func decodeFileData(_ value: String, encoding: String) throws -> Data {
        if encoding.lowercased() == "base64" {
            guard let data = Data(base64Encoded: value, options: [.ignoreUnknownCharacters]) else { throw MediaError("INVALID_ARGUMENT", "data 不是合法 Base64") }
            return data
        }
        guard let data = value.data(using: .utf8) else { throw MediaError("INVALID_ARGUMENT", "data 无法按 UTF-8 编码") }
        return data
    }

    private static func encodeFileData(_ data: Data, encoding: String) -> String {
        encoding.lowercased() == "base64" ? data.base64EncodedString() : String(data: data, encoding: .utf8) ?? ""
    }

    // MARK: - Camera / Photos

    private static func dispatchCamera(_ call: LynxNativeCapabilityCall, presenter: UIViewController?, completion: @escaping Completion) {
        switch call.methodName {
        case "checkPermissions": completion(.success(cameraPermissionData()))
        case "requestPermissions": requestCameraPermissions(options: call.options, presenter: presenter, completion: completion)
        case "playVideo": playVideo(call.options, presenter: presenter, completion: completion)
        case "getPhoto", "pickImages", "chooseFromGallery", "takePhoto", "recordVideo":
            startPicker(call, presenter: presenter, completion: completion)
        default: completion(.failure("UNSUPPORTED", "Camera.\(call.methodName) 尚未接入当前 iOS Module"))
        }
    }

    private static func cameraPermissionData() -> [String: Any] {
        let camera = AVCaptureDevice.authorizationStatus(for: .video)
        let photos = PHPhotoLibrary.authorizationStatus(for: .readWrite)
        let photosAdd = PHPhotoLibrary.authorizationStatus(for: .addOnly)
        return [
            "camera": authorizationState(camera),
            "photos": photoAuthorizationState(photos),
            "photosAdd": photoAuthorizationState(photosAdd),
            "video": authorizationState(camera),
        ]
    }

    private static func requestCameraPermissions(options: [String: Any], presenter: UIViewController?, completion: @escaping Completion) {
        guard sceneAvailable(presenter) else { completion(.failure("SCENE_UNAVAILABLE", "没有前台 scene，无法请求媒体权限")); return }
        let source = string(options["source"], default: "PROMPT").uppercased()
        let needCamera = source == "CAMERA" || source == "PROMPT" || bool(options["includeCamera"], default: false)
        let needPhotos = source != "CAMERA" || bool(options["includePhotos"], default: true)
        let needPhotoAdd = bool(options["saveToGallery"], default: false)
        guard !needCamera || infoString("NSCameraUsageDescription") != nil else { completion(.failure("PERMISSION_NOT_DECLARED", "宿主未声明 NSCameraUsageDescription")); return }
        guard !needPhotos || infoString("NSPhotoLibraryUsageDescription") != nil else { completion(.failure("PERMISSION_NOT_DECLARED", "宿主未声明 NSPhotoLibraryUsageDescription")); return }
        guard !needPhotoAdd || infoString("NSPhotoLibraryAddUsageDescription") != nil else { completion(.failure("PERMISSION_NOT_DECLARED", "宿主未声明 NSPhotoLibraryAddUsageDescription")); return }
        let requestPhotos: (@escaping () -> Void) -> Void = { next in
            guard needPhotos else { next(); return }
            let status = PHPhotoLibrary.authorizationStatus(for: .readWrite)
            if status == .notDetermined {
                PHPhotoLibrary.requestAuthorization(for: .readWrite) { _ in DispatchQueue.main.async(execute: next) }
            } else { next() }
        }
        let requestPhotoAdd: (@escaping () -> Void) -> Void = { next in
            guard needPhotoAdd else { next(); return }
            let status = PHPhotoLibrary.authorizationStatus(for: .addOnly)
            if status == .notDetermined {
                PHPhotoLibrary.requestAuthorization(for: .addOnly) { _ in DispatchQueue.main.async(execute: next) }
            } else { next() }
        }
        let finish = { completion(.success(cameraPermissionData())) }
        let requestAll = { requestPhotos { requestPhotoAdd(finish) } }
        if needCamera && AVCaptureDevice.authorizationStatus(for: .video) == .notDetermined {
            AVCaptureDevice.requestAccess(for: .video) { _ in DispatchQueue.main.async(execute: requestAll) }
        } else { requestAll() }
    }

    private static func startPicker(_ call: LynxNativeCapabilityCall, presenter: UIViewController?, completion: @escaping Completion) {
        guard let presenter, sceneAvailable(presenter) else { completion(.failure("SCENE_UNAVAILABLE", "没有前台 scene，无法显示媒体选择器")); return }
        let method = call.methodName
        let source = string(call.options["source"], default: method == "takePhoto" || method == "recordVideo" ? "CAMERA" : "PHOTOS").uppercased()
        if (method == "takePhoto" || method == "recordVideo" || (method == "getPhoto" && source == "CAMERA")) && AVCaptureDevice.authorizationStatus(for: .video) != .authorized {
            completion(.failure("PERMISSION_DENIED", "未授予相机权限，请先调用 Camera.requestPermissions")); return
        }
        let needsCamera = method == "takePhoto" || method == "recordVideo" || (method == "getPhoto" && source == "CAMERA")
        if needsCamera && !UIImagePickerController.isSourceTypeAvailable(.camera) {
            completion(.failure("HARDWARE_UNAVAILABLE", "当前设备没有可用相机")); return
        }
        if method == "pickImages" || method == "chooseFromGallery" || (method == "getPhoto" && source != "CAMERA"),
           PHPhotoLibrary.authorizationStatus(for: .readWrite) == .denied {
            completion(.failure("PERMISSION_DENIED", "未授予照片权限，请先调用 Camera.requestPermissions")); return
        }
        let isVideo = method == "recordVideo" || string(call.options["mediaType"]).lowercased() == "video"
        let request = PickerRequest(call: call, presenter: presenter, completion: completion)
        guard fileLock.withLock({ () -> Bool in
            guard activePicker == nil else { return false }
            activePicker = request
            pickerDelegate = PickerDelegate()
            return true
        }) else { completion(.failure("BUSY", "已有媒体选择器正在显示")); return }

        if method == "pickImages" || method == "chooseFromGallery" || (method == "getPhoto" && source != "CAMERA") {
            var configuration = PHPickerConfiguration(photoLibrary: .shared())
            configuration.selectionLimit = method == "getPhoto" ? 1 : max(0, int(call.options["limit"], default: 0))
            let mediaType = int(call.options["mediaType"], default: 0)
            if isVideo || mediaType == 1 { configuration.filter = .videos }
            else if mediaType == 2 { configuration.filter = .any(of: [.images, .videos]) }
            else { configuration.filter = .images }
            let picker = PHPickerViewController(configuration: configuration)
            picker.delegate = pickerDelegate
            presenter.present(picker, animated: true)
        } else {
            let picker = UIImagePickerController()
            picker.sourceType = .camera
            picker.mediaTypes = [isVideo ? UTType.movie.identifier : UTType.image.identifier]
            picker.videoQuality = .typeHigh
            picker.delegate = pickerDelegate
            presenter.present(picker, animated: true)
        }
    }

    private static func finishPicker(with result: LynxNativeCapabilityResult) {
        let request = fileLock.withLock { () -> PickerRequest? in
            let current = activePicker
            activePicker = nil
            pickerDelegate = nil
            return current
        }
        guard let request else { return }
        let presenter = request.presenter
        if let presenter {
            presenter.dismiss(animated: true) {
                request.completion(result)
            }
        } else {
            request.completion(.failure("SCENE_UNAVAILABLE", "媒体选择器所属 scene 已销毁"))
        }
    }

    private static func processPHPickerResults(_ results: [PHPickerResult], request: PickerRequest) {
        guard !results.isEmpty else { finishPicker(with: .failure("CANCELLED", "用户取消了媒体选择")); return }
        let group = DispatchGroup()
        let resultLock = NSLock()
        var files: [(URL, Bool)] = []
        for result in results {
            let provider = result.itemProvider
            if provider.canLoadObject(ofClass: UIImage.self) {
                group.enter()
                provider.loadObject(ofClass: UIImage.self) { object, error in
                    defer { group.leave() }
                    guard let image = object as? UIImage, error == nil, let url = writeImage(image) else { return }
                    resultLock.withLock { files.append((url, false)) }
                }
            } else if provider.hasItemConformingToTypeIdentifier(UTType.movie.identifier) {
                group.enter()
                provider.loadFileRepresentation(forTypeIdentifier: UTType.movie.identifier) { source, _ in
                    defer { group.leave() }
                    guard let source, let url = copyMediaFile(source, ext: "mov") else { return }
                    resultLock.withLock { files.append((url, true)) }
                }
            }
        }
        group.notify(queue: .main) {
            guard !files.isEmpty else { finishPicker(with: .failure("MEDIA_READ_FAILED", "无法读取所选媒体")); return }
            deliverMediaFiles(files, request: request)
        }
    }

    private static func processUIImagePicker(info: [UIImagePickerController.InfoKey: Any], request: PickerRequest) {
        if let image = info[.originalImage] as? UIImage, let url = writeImage(image) {
            deliverMediaFiles([(url, false)], request: request)
            return
        }
        if let source = info[.mediaURL] as? URL, let url = copyMediaFile(source, ext: "mov") {
            deliverMediaFiles([(url, true)], request: request)
            return
        }
        finishPicker(with: .failure("MEDIA_READ_FAILED", "无法读取相机输出"))
    }

    private static func deliverMediaFiles(_ files: [(URL, Bool)], request: PickerRequest) {
        let includeMetadata = bool(request.call.options["includeMetadata"], default: false)
        let resultType = string(request.call.options["resultType"], default: "URI").uppercased()
        let saveToGallery = bool(request.call.options["saveToGallery"], default: false)
        let media = files.map { mediaResult(url: $0.0, video: $0.1, resultType: resultType, includeMetadata: includeMetadata) }
        let finish: (LynxNativeCapabilityResult) -> Void = { result in finishPicker(with: result) }
        if saveToGallery {
            guard infoString("NSPhotoLibraryAddUsageDescription") != nil else { finish(.failure("PERMISSION_NOT_DECLARED", "宿主未声明 NSPhotoLibraryAddUsageDescription")); return }
            let status = PHPhotoLibrary.authorizationStatus(for: .addOnly)
            guard status == .authorized || status == .limited else { finish(.failure("PERMISSION_DENIED", "未授予保存到系统相册的权限")); return }
            PHPhotoLibrary.shared().performChanges {
                files.forEach { url, video in
                    if video { PHAssetChangeRequest.creationRequestForAssetFromVideo(atFileURL: url) }
                    else { PHAssetChangeRequest.creationRequestForAssetFromImage(atFileURL: url) }
                }
            } completionHandler: { saved, error in
                DispatchQueue.main.async {
                    if let error { finish(.failure("PHOTO_SAVE_FAILED", error.localizedDescription)); return }
                    finish(.success(["photos": media, "savedToGallery": saved]))
                }
            }
        } else if request.call.methodName == "getPhoto" {
            finish(.success(media.first ?? [:]))
        } else {
            finish(.success(["photos": media, "savedToGallery": false]))
        }
    }

    private static func writeImage(_ image: UIImage) -> URL? {
        guard let data = image.jpegData(compressionQuality: 0.9) else { return nil }
        let url = fileManager.temporaryDirectory.appendingPathComponent("lynx-photo-\(UUID().uuidString).jpg")
        return (try? data.write(to: url, options: .atomic)).map { url }
    }

    private static func copyMediaFile(_ source: URL, ext: String) -> URL? {
        let target = fileManager.temporaryDirectory.appendingPathComponent("lynx-media-\(UUID().uuidString).\(ext)")
        do { try fileManager.copyItem(at: source, to: target); return target } catch { return nil }
    }

    private static func mediaResult(url: URL, video: Bool, resultType: String, includeMetadata: Bool) -> [String: Any] {
        var result: [String: Any] = [
            "path": url.path,
            "webPath": url.absoluteString,
            "format": url.pathExtension,
            "mimeType": video ? "video/quicktime" : "image/jpeg",
        ]
        if !video, includeMetadata, let image = UIImage(contentsOfFile: url.path) {
            result["width"] = image.size.width * image.scale
            result["height"] = image.size.height * image.scale
        }
        if resultType == "BASE64" || resultType == "DATA_URL" {
            if let data = try? Data(contentsOf: url) {
                let base64 = data.base64EncodedString()
                result["base64String"] = base64
                result["dataUrl"] = "data:\(video ? "video/quicktime" : "image/jpeg");base64,\(base64)"
            }
        }
        return result
    }

    private static func playVideo(_ options: [String: Any], presenter: UIViewController?, completion: @escaping Completion) {
        guard let presenter, sceneAvailable(presenter) else { completion(.failure("SCENE_UNAVAILABLE", "没有前台 scene，无法播放视频")); return }
        guard let url = resolveFileURL(path: string(options["uri"] ?? options["path"]), directory: string(options["directory"], default: "CACHE")) else { completion(.failure("NOT_FOUND", "视频文件不存在")); return }
        let controller = AVPlayerViewController()
        controller.player = AVPlayer(url: url)
        presenter.present(controller, animated: true) {
            controller.player?.play()
            completion(.success(["played": true, "uri": url.absoluteString]))
        }
    }

    private final class PickerRequest {
        let call: LynxNativeCapabilityCall
        weak var presenter: UIViewController?
        let completion: Completion
        init(call: LynxNativeCapabilityCall, presenter: UIViewController, completion: @escaping Completion) {
            self.call = call
            self.presenter = presenter
            self.completion = completion
        }
    }

    private final class PickerDelegate: NSObject, PHPickerViewControllerDelegate, UIImagePickerControllerDelegate, UINavigationControllerDelegate {
        func picker(_ picker: PHPickerViewController, didFinishPicking results: [PHPickerResult]) {
            guard let request = fileLock.withLock({ activePicker }) else { return }
            processPHPickerResults(results, request: request)
            _ = picker
        }

        func imagePickerControllerDidCancel(_ picker: UIImagePickerController) {
            finishPicker(with: .failure("CANCELLED", "用户取消了媒体选择"))
            _ = picker
        }

        func imagePickerController(_ picker: UIImagePickerController, didFinishPickingMediaWithInfo info: [UIImagePickerController.InfoKey: Any]) {
            guard let request = fileLock.withLock({ activePicker }) else { return }
            processUIImagePicker(info: info, request: request)
            _ = picker
        }
    }

    // MARK: - FileTransfer

    private static func dispatchFileTransfer(_ call: LynxNativeCapabilityCall, eventSender: EventSender?, completion: @escaping Completion) {
        switch call.methodName {
        case "downloadFile": startTransfer(call, eventSender: eventSender, completion: completion)
        case "getStatus":
            let id = string(call.options["operationId"] ?? call.options["id"])
            guard !id.isEmpty, let transfer = fileLock.withLock({ transfers[id] }) else { completion(.failure("NOT_FOUND", "下载任务不存在")); return }
            completion(.success(transfer.status))
        case "cancel":
            let id = string(call.options["operationId"] ?? call.options["id"])
            guard let transfer = fileLock.withLock({ transfers[id] }) else { completion(.failure("NOT_FOUND", "下载任务不存在")); return }
            transfer.cancel(); completion(.success(["operationId": id, "cancelled": true, "state": "cancelled"]))
        default: completion(.failure("UNSUPPORTED", "FileTransfer.\(call.methodName) 尚未接入当前 iOS Module"))
        }
    }

    private static func startTransfer(_ call: LynxNativeCapabilityCall, eventSender: EventSender?, completion: @escaping Completion) {
        guard let url = URL(string: string(call.options["url"])), ["http", "https"].contains(url.scheme?.lowercased() ?? "") else { completion(.failure("INVALID_ARGUMENT", "downloadFile.url 必须是 http/https URL")); return }
        let operationID = string(call.options["operationId"] ?? call.options["id"], default: UUID().uuidString)
        guard fileLock.withLock({ transfers[operationID] == nil }) else { completion(.failure("BUSY", "下载任务已经存在")); return }
        let transfer = Transfer(operationID: operationID, call: call, eventSender: eventSender, completion: completion)
        fileLock.withLock { transfers[operationID] = transfer }
        let session = URLSession(configuration: .default, delegate: transfer, delegateQueue: nil)
        transfer.session = session
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        if let headers = call.options["headers"] as? [String: Any] { headers.forEach { request.setValue(string($0.value), forHTTPHeaderField: $0.key) } }
        transfer.task = session.downloadTask(with: request)
        transfer.status = ["operationId": operationID, "state": "pending", "progress": 0]
        transfer.task?.resume()
    }

    private final class Transfer: NSObject, URLSessionDownloadDelegate {
        let operationID: String
        let call: LynxNativeCapabilityCall
        let eventSender: EventSender?
        let completion: Completion
        var session: URLSession?
        var task: URLSessionDownloadTask?
        var status: [String: Any] = [:]
        private let stateLock = NSLock()
        private var finished = false

        init(operationID: String, call: LynxNativeCapabilityCall, eventSender: EventSender?, completion: @escaping Completion) {
            self.operationID = operationID; self.call = call; self.eventSender = eventSender; self.completion = completion
            super.init()
        }

        func cancel() {
            task?.cancel()
            status = ["operationId": operationID, "state": "cancelled", "progress": status["progress"] ?? 0]
        }

        func cancelFromModuleRelease() {
            finish(.failure("MODULE_DESTROYED", "下载任务已取消"))
            task?.cancel()
            session?.invalidateAndCancel()
        }

        func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64, totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
            let progress = totalBytesExpectedToWrite > 0 ? Double(totalBytesWritten) / Double(totalBytesExpectedToWrite) : 0
            status = ["operationId": operationID, "state": "running", "progress": progress, "bytesWritten": totalBytesWritten, "totalBytes": totalBytesExpectedToWrite]
            guard let eventSender, let raw = LynxNativeJSON.encode(["callbackId": operationID, "pluginId": "FileTransfer", "methodName": "progress", "success": true, "data": status, "save": true]) else { return }
            eventSender(raw)
            _ = session; _ = downloadTask; _ = bytesWritten
        }

        func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
            let directory = (try? LynxNativeMediaCapabilities.directoryRoot(LynxNativeMediaCapabilities.string(call.options["directory"], default: "CACHE")))
            let path = LynxNativeMediaCapabilities.string(call.options["path"], default: "lynx-download-\(operationID).bin")
            guard let directory, let target = LynxNativeMediaCapabilities.safePath(path, under: directory) else { finish(.failure("INVALID_ARGUMENT", "下载目标路径无效")); return }
            do {
                try LynxNativeMediaCapabilities.fileManager.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
                if LynxNativeMediaCapabilities.fileManager.fileExists(atPath: target.path) { try LynxNativeMediaCapabilities.fileManager.removeItem(at: target) }
                try LynxNativeMediaCapabilities.fileManager.copyItem(at: location, to: target)
                let size = try target.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
                guard size <= 20 * 1024 * 1024 else {
                    try? LynxNativeMediaCapabilities.fileManager.removeItem(at: target)
                    finish(.failure("DOWNLOAD_TOO_LARGE", "下载文件超过 20 MB 限制")); return
                }
                finish(.success(["operationId": operationID, "state": "completed", "progress": 1, "path": target.path, "uri": target.absoluteString]))
            } catch { finish(.failure("DOWNLOAD_FAILED", error.localizedDescription)) }
        }

        func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
            if let error, !finished { finish(.failure((error as NSError).code == NSURLErrorCancelled ? "CANCELLED" : "DOWNLOAD_FAILED", error.localizedDescription)) }
            _ = session; _ = task
        }

        private func finish(_ result: LynxNativeCapabilityResult) {
            let shouldFinish = stateLock.withLock { () -> Bool in
                guard !finished else { return false }
                finished = true
                return true
            }
            guard shouldFinish else { return }
            status = result.success ? ["operationId": operationID, "state": "completed", "progress": 1] : ["operationId": operationID, "state": "failed"]
            fileLock.withLock { transfers.removeValue(forKey: operationID) }
            session?.finishTasksAndInvalidate()
            DispatchQueue.main.async { self.completion(result) }
        }
    }

    // MARK: - FileViewer

    private static func dispatchFileViewer(_ call: LynxNativeCapabilityCall, presenter: UIViewController?, completion: @escaping Completion) {
        guard call.methodName == "openDocumentFromLocalPath" else { completion(.failure("UNSUPPORTED", "FileViewer.\(call.methodName) 尚未接入当前 iOS Module")); return }
        guard let presenter, sceneAvailable(presenter) else { completion(.failure("SCENE_UNAVAILABLE", "没有前台 scene，无法打开文件预览")); return }
        guard let url = resolveFileURL(path: string(call.options["path"] ?? call.options["uri"]), directory: string(call.options["directory"], default: "CACHE")), fileManager.fileExists(atPath: url.path) else { completion(.failure("NOT_FOUND", "文件不存在")); return }
        guard QLPreviewController.canPreview(url as QLPreviewItem) else { completion(.failure("NO_HANDLER", "Quick Look 没有可用的文件预览 handler")); return }
        let controller = QLPreviewController()
        let source = PreviewDataSource(url: url)
        controller.dataSource = source
        previewController = controller
        previewDataSource = source
        presenter.present(controller, animated: true) { completion(.success(["opened": true, "uri": url.absoluteString])) }
    }

    private final class PreviewDataSource: NSObject, QLPreviewControllerDataSource {
        let url: URL
        init(url: URL) { self.url = url }
        func numberOfPreviewItems(in controller: QLPreviewController) -> Int { _ = controller; return 1 }
        func previewController(_ controller: QLPreviewController, previewItemAt index: Int) -> QLPreviewItem { _ = controller; _ = index; return url as NSURL }
    }

    // MARK: - Helpers

    private static func resolveFileURL(path: String, directory: String) -> URL? {
        if let url = URL(string: path), url.isFileURL { return url }
        guard let root = try? directoryRoot(directory) else { return nil }
        return safePath(path, under: root)
    }

    private static func sceneAvailable(_ presenter: UIViewController?) -> Bool {
        if let scene = presenter?.viewIfLoaded?.window?.windowScene { return scene.activationState == .foregroundActive }
        return UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.contains { $0.activationState == .foregroundActive }
    }

    private static func infoString(_ key: String) -> String? { Bundle.main.object(forInfoDictionaryKey: key) as? String }
    private static func string(_ value: Any?, default defaultValue: String = "") -> String { guard let value, !(value is NSNull) else { return defaultValue }; return value as? String ?? String(describing: value) }
    private static func int(_ value: Any?, default defaultValue: Int) -> Int { if let value = value as? NSNumber { return value.intValue }; return Int(string(value)) ?? defaultValue }
    private static func bool(_ value: Any?, default defaultValue: Bool) -> Bool { guard let value, !(value is NSNull) else { return defaultValue }; if let value = value as? Bool { return value }; if let value = value as? NSNumber { return value.boolValue }; return ["true", "1", "yes"].contains(string(value).lowercased()) }
    private static func authorizationState(_ status: AVAuthorizationStatus) -> String { switch status { case .authorized: return "granted"; case .denied: return "denied"; case .restricted: return "restricted"; case .notDetermined: return "prompt"; @unknown default: return "unknown" } }
    private static func photoAuthorizationState(_ status: PHAuthorizationStatus) -> String { switch status { case .authorized: return "granted"; case .limited: return "limited"; case .denied: return "denied"; case .restricted: return "restricted"; case .notDetermined: return "prompt"; @unknown default: return "unknown" } }

    private struct MediaError: Error { let code: String; let message: String; init(_ code: String, _ message: String) { self.code = code; self.message = message } }
}

private extension NSLock {
    func withLock<T>(_ body: () throws -> T) rethrows -> T { lock(); defer { unlock() }; return try body() }
}
