import AVKit
import CoreFoundation
import Darwin
import Foundation
import ImageIO
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
    static let maximumSelectionCount = 16
    private static let fileLock = NSLock()
    private static var activePicker: PickerRequest?
    private static var pickerDelegate: PickerDelegate?
    private static var transfers: [String: Transfer] = [:]
    private static var previews: [String: (QLPreviewController, PreviewDataSource)] = [:]
    private static var pendingPreviews: [String: UUID] = [:]
    private static var players: [String: PlayerSession] = [:]

    static func dispatch(
        _ call: LynxNativeCapabilityCall,
        presenter: UIViewController?,
        eventSender: EventSender? = nil,
        completion: @escaping Completion
    ) -> Bool {
        guard LynxNativeOwnerScope.isActive(call.ownerID) else { completion(.failure("HOST_DESTROYED", "页面已销毁")); return true }
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
        picker?.controller?.dismiss(animated: false)
        picker?.finish(.failure("HOST_DESTROYED", "页面已销毁，媒体请求已取消"))
        pendingPreviews.removeValue(forKey: ownerID)
        let operations = fileLock.withLock { () -> [Transfer] in
            let matching = transfers.filter { $0.value.call.ownerID == ownerID }
            matching.keys.forEach { transfers.removeValue(forKey: $0) }
            let values = Array(matching.values)
            return values
        }
        operations.forEach { $0.cancelFromModuleRelease() }
        if let preview = previews.removeValue(forKey: ownerID) {
            preview.1.finish()
            preview.0.dismiss(animated: false)
        }
        players[ownerID]?.close()
    }

    static func releaseAll() {
        let picker = fileLock.withLock { () -> PickerRequest? in
            let current = activePicker
            activePicker = nil
            pickerDelegate = nil
            return current
        }
        picker?.controller?.dismiss(animated: false)
        picker?.finish(.failure("HOST_DESTROYED", "页面已销毁，媒体请求已取消"))
        pendingPreviews.removeAll()
        let operations = fileLock.withLock { () -> [Transfer] in
            let values = Array(transfers.values)
            transfers.removeAll()
            return values
        }
        operations.forEach { $0.cancelFromModuleRelease() }
        let visiblePreviews = Array(previews.values)
        previews.removeAll()
        visiblePreviews.forEach { $0.1.finish(); $0.0.dismiss(animated: false) }
        Array(players.values).forEach { $0.close() }
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
        LynxNativeIOExecutor.shared.submit(ownerID: call.ownerID, completion: completion) { cancellation in
            var result = LynxNativeCapabilityResult.failure("NATIVE_ERROR", "文件操作未返回结果")
            dispatchFilesystemWork(call, cancellation: cancellation) { result = $0 }
            return result
        }
    }

    private static func dispatchFilesystemWork(_ call: LynxNativeCapabilityCall, cancellation: LynxNativeIOExecutor.Cancellation, completion: Completion) {
        let root: URL
        do {
            root = try directoryRoot(string(call.options["directory"], default: "CACHE"))
        } catch is LynxNativeIOExecutor.Cancelled {
            completion(.failure("HOST_DESTROYED", "文件写入已取消")); return
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
            guard !cancellation.isCancelled else { throw MediaError("HOST_DESTROYED", "文件操作已取消") }
            switch call.methodName {
            case "writeFile":
                try fileManager.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
                let data = try decodeFileData(string(call.options["data"]), encoding: string(call.options["encoding"], default: "utf8"))
                guard !cancellation.isCancelled else { throw MediaError("HOST_DESTROYED", "文件写入已取消") }
                try LynxNativeAtomicFile.write(data, to: target, ownerID: call.ownerID, cancellation: cancellation)
                completion(.success(["uri": target.absoluteString, "path": target.path]))
            case "readFile":
                guard fileManager.fileExists(atPath: target.path) else { throw MediaError("NOT_FOUND", "文件不存在: \(path)") }
                let size = try target.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
                guard size <= LynxNativePayloadLimits.inlineFileBytes else { throw MediaError("PAYLOAD_TOO_LARGE", "文件超过内联上限，请使用 getUri") }
                let data = try Data(contentsOf: target)
                guard data.count <= LynxNativePayloadLimits.inlineFileBytes else { throw MediaError("PAYLOAD_TOO_LARGE", "文件超过内联上限") }
                guard !cancellation.isCancelled else { throw MediaError("HOST_DESTROYED", "文件读取已取消") }
                completion(.success(["data": try encodeFileData(data, encoding: string(call.options["encoding"], default: "utf8")), "uri": target.absoluteString]))
            case "readdir":
                guard fileManager.fileExists(atPath: target.path) else { throw MediaError("NOT_FOUND", "目录不存在: \(path)") }
                guard let values = try? fileManager.contentsOfDirectory(at: target, includingPropertiesForKeys: [.isDirectoryKey, .fileSizeKey], options: [.skipsHiddenFiles]) else { throw MediaError("READ_FAILED", "无法读取目录") }
                let files = values.compactMap(fileSummary)
                completion(.success(["files": files]))
            case "stat":
                guard fileManager.fileExists(atPath: target.path) else { throw MediaError("NOT_FOUND", "文件不存在: \(path)") }
                completion(.success(fileSummary(target) ?? ["uri": target.absoluteString]))
            case "mkdir":
                guard !cancellation.isCancelled, LynxNativeOwnerScope.isActive(call.ownerID) else { throw MediaError("HOST_DESTROYED", "目录创建已取消") }
                try fileManager.createDirectory(at: target, withIntermediateDirectories: bool(call.options["recursive"], default: true))
                completion(.success(["created": true, "uri": target.absoluteString]))
            case "getUri":
                completion(.success(["uri": target.absoluteString, "path": target.path]))
            default:
                completion(.failure("UNSUPPORTED", "Filesystem.\(call.methodName) 尚未接入当前 iOS Module"))
            }
        } catch is LynxNativeIOExecutor.Cancelled {
            completion(.failure("HOST_DESTROYED", "文件写入已取消"))
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
            guard let data = Data(base64Encoded: value) else { throw MediaError("INVALID_ARGUMENT", "data 不是合法 Base64") }
            guard data.count <= LynxNativePayloadLimits.inlineFileBytes else { throw MediaError("PAYLOAD_TOO_LARGE", "Base64 文件超过内联上限") }
            return data
        }
        guard let data = value.data(using: .utf8) else { throw MediaError("INVALID_ARGUMENT", "data 无法按 UTF-8 编码") }
        guard data.count <= LynxNativePayloadLimits.inlineFileBytes else { throw MediaError("PAYLOAD_TOO_LARGE", "文件超过内联上限") }
        return data
    }

    private static func encodeFileData(_ data: Data, encoding: String) throws -> String {
        if encoding.lowercased() == "base64" { return data.base64EncodedString() }
        guard let text = String(data: data, encoding: .utf8) else { throw MediaError("INVALID_ARGUMENT", "文件不是 UTF-8 文本，请指定 base64") }
        return text
    }

    // MARK: - Camera / Photos

    private static func dispatchCamera(_ call: LynxNativeCapabilityCall, presenter: UIViewController?, completion: @escaping Completion) {
        switch call.methodName {
        case "checkPermissions": completion(.success(cameraPermissionData()))
        case "requestPermissions": requestCameraPermissions(call: call, presenter: presenter, completion: completion)
        case "playVideo": playVideo(call, presenter: presenter, completion: completion)
        case "getPhoto", "pickImages", "chooseFromGallery", "takePhoto", "recordVideo":
            startPicker(call, presenter: presenter, completion: completion)
        default: completion(.failure("UNSUPPORTED", "Camera.\(call.methodName) 尚未接入当前 iOS Module"))
        }
    }

    private static func cameraPermissionData() -> [String: Any] {
        let camera = AVCaptureDevice.authorizationStatus(for: .video)
        let microphone = AVCaptureDevice.authorizationStatus(for: .audio)
        let photos = PHPhotoLibrary.authorizationStatus(for: .readWrite)
        let photosAdd = PHPhotoLibrary.authorizationStatus(for: .addOnly)
        return [
            "camera": authorizationState(camera),
            "photos": photoAuthorizationState(photos),
            "photosAdd": photoAuthorizationState(photosAdd),
            "video": authorizationState(camera),
            "microphone": authorizationState(microphone),
        ]
    }

    private static func requestCameraPermissions(call: LynxNativeCapabilityCall, presenter: UIViewController?, completion: @escaping Completion) {
        guard sceneAvailable(presenter) else { completion(.failure("SCENE_UNAVAILABLE", "没有前台 scene，无法请求媒体权限")); return }
        let options = call.options
        let source = string(options["source"], default: "PROMPT").uppercased()
        let needCamera = source == "CAMERA" || source == "PROMPT" || bool(options["includeCamera"], default: false)
        let needPhotos = source != "CAMERA" || bool(options["includePhotos"], default: true)
        let needPhotoAdd = bool(options["saveToGallery"], default: false)
        let needMicrophone = bool(options["includeMicrophone"], default: false)
            || (needCamera && (string(options["mediaType"]).lowercased() == "video" || int(options["mediaType"], default: 0) == 1))
        guard !needCamera || infoString("NSCameraUsageDescription") != nil else { completion(.failure("PERMISSION_NOT_DECLARED", "宿主未声明 NSCameraUsageDescription")); return }
        guard !needPhotos || infoString("NSPhotoLibraryUsageDescription") != nil else { completion(.failure("PERMISSION_NOT_DECLARED", "宿主未声明 NSPhotoLibraryUsageDescription")); return }
        guard !needPhotoAdd || infoString("NSPhotoLibraryAddUsageDescription") != nil else { completion(.failure("PERMISSION_NOT_DECLARED", "宿主未声明 NSPhotoLibraryAddUsageDescription")); return }
        guard !needMicrophone || infoString("NSMicrophoneUsageDescription") != nil else { completion(.failure("PERMISSION_NOT_DECLARED", "宿主未声明 NSMicrophoneUsageDescription")); return }
        let requestPhotos: (@escaping () -> Void) -> Void = { next in
            guard LynxNativeOwnerScope.isActive(call.ownerID) else { return }
            guard needPhotos else { next(); return }
            let status = PHPhotoLibrary.authorizationStatus(for: .readWrite)
            if status == .notDetermined {
                PHPhotoLibrary.requestAuthorization(for: .readWrite) { _ in DispatchQueue.main.async(execute: next) }
            } else { next() }
        }
        let requestPhotoAdd: (@escaping () -> Void) -> Void = { next in
            guard LynxNativeOwnerScope.isActive(call.ownerID) else { return }
            guard needPhotoAdd else { next(); return }
            let status = PHPhotoLibrary.authorizationStatus(for: .addOnly)
            if status == .notDetermined {
                PHPhotoLibrary.requestAuthorization(for: .addOnly) { _ in DispatchQueue.main.async(execute: next) }
            } else { next() }
        }
        let finish = { completion(.success(cameraPermissionData())) }
        let requestMicrophone = {
            guard LynxNativeOwnerScope.isActive(call.ownerID) else { return }
            if needMicrophone && AVCaptureDevice.authorizationStatus(for: .audio) == .notDetermined {
                AVCaptureDevice.requestAccess(for: .audio) { _ in DispatchQueue.main.async(execute: finish) }
            } else { finish() }
        }
        let requestAll = { requestPhotos { requestPhotoAdd(requestMicrophone) } }
        if needCamera && AVCaptureDevice.authorizationStatus(for: .video) == .notDetermined {
            AVCaptureDevice.requestAccess(for: .video) { _ in DispatchQueue.main.async(execute: requestAll) }
        } else { requestAll() }
    }

    private static func startPicker(_ call: LynxNativeCapabilityCall, presenter: UIViewController?, completion: @escaping Completion) {
        guard let presenter, sceneAvailable(presenter) else { completion(.failure("SCENE_UNAVAILABLE", "没有前台 scene，无法显示媒体选择器")); return }
        guard presenter.presentedViewController == nil else { completion(.failure("BUSY", "宿主正在显示其他原生界面")); return }
        let method = call.methodName
        let source = method == "takePhoto" || method == "recordVideo" ? "CAMERA" : string(call.options["source"], default: "PHOTOS").uppercased()
        guard ["PHOTOS", "CAMERA", "PROMPT"].contains(source) else { completion(.failure("INVALID_ARGUMENT", "source 必须是 PHOTOS、CAMERA 或 PROMPT")); return }
        if let raw = call.options["cameraDirection"] {
            guard let direction = raw as? String, ["FRONT", "BACK"].contains(direction.uppercased()) else {
                completion(.failure("INVALID_ARGUMENT", "cameraDirection 必须是 FRONT 或 BACK")); return
            }
        }
        var limit = maximumSelectionCount
        if let raw = call.options["limit"] {
            guard let parsed = validSelectionCount(raw, minimum: 0) else {
                completion(.failure("INVALID_ARGUMENT", "limit 必须是 0...16 的整数")); return
            }
            limit = parsed == 0 ? maximumSelectionCount : parsed
        }
        if method == "getPhoto" || call.options["allowMultipleSelection"] as? Bool == false { limit = 1 }
        let mediaType: Int
        if method == "recordVideo" { mediaType = 1 }
        else if method == "takePhoto" { mediaType = bool(call.options["legacyCameraMixed"], default: false) ? 2 : 0 }
        else if let raw = call.options["mediaType"] {
            if let number = raw as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID(),
               number.doubleValue.isFinite, number.doubleValue.rounded(.towardZero) == number.doubleValue,
               (0...2).contains(number.intValue) { mediaType = number.intValue }
            else if let value = raw as? String, ["image", "video"].contains(value.lowercased()) {
                mediaType = value.lowercased() == "video" ? 1 : 0
            } else { completion(.failure("INVALID_ARGUMENT", "mediaType 必须是 0、1 或 2")); return }
        } else { mediaType = 0 }
        let direction = string(call.options["cameraDirection"], default: "BACK").uppercased()
        guard ["FRONT", "BACK"].contains(direction) else { completion(.failure("INVALID_ARGUMENT", "cameraDirection 必须是 FRONT 或 BACK")); return }
        let request = PickerRequest(call: call, presenter: presenter, selectionLimit: limit, mediaType: mediaType, completion: completion)
        guard fileLock.withLock({ () -> Bool in
            guard activePicker == nil else { return false }
            activePicker = request
            pickerDelegate = PickerDelegate()
            return true
        }) else { completion(.failure("BUSY", "已有媒体请求正在进行")); return }
        request.resource.attach { [weak request] in
            guard let request else { return }
            finishPicker(with: .failure("HOST_DESTROYED", "页面已销毁，媒体请求已取消"), request: request)
        }
        // 只有 PROMPT 或混合拍摄需要来源菜单；业务可指定 PHOTOS/CAMERA 直接进入原生能力。
        if source == "PROMPT" || (source == "CAMERA" && mediaType == 2) {
            showMediaSourceMenu(request, includePhotos: source == "PROMPT")
        } else {
            preparePicker(request, camera: source == "CAMERA", mediaType: mediaType)
        }
    }

    private static func showMediaSourceMenu(_ request: PickerRequest, includePhotos: Bool) {
        guard fileLock.withLock({ activePicker === request }), let presenter = request.presenter, sceneAvailable(presenter) else {
            finishPicker(with: .failure("SCENE_UNAVAILABLE", "媒体选择器所属 scene 已销毁"), request: request); return
        }
        let options = request.call.options
        let header = string(options["promptLabelHeader"], default: "选择媒体来源")
        let sheet = UIAlertController(title: header, message: nil, preferredStyle: .actionSheet)
        let addSource: (String, Bool, Int) -> Void = { title, camera, mediaType in
            sheet.addAction(UIAlertAction(title: title, style: .default) { [weak sheet] _ in
                guard fileLock.withLock({ activePicker === request }) else { return }
                request.changingSource = true
                let continueSelection = {
                    guard fileLock.withLock({ activePicker === request }) else { return }
                    request.controller = nil
                    request.changingSource = false
                    preparePicker(request, camera: camera, mediaType: mediaType)
                }
                sheet?.dismiss(animated: true, completion: continueSelection)
            })
        }
        if includePhotos { addSource(string(options["promptLabelPhotos"], default: "从相册选择"), false, request.mediaType) }
        if request.mediaType != 1 { addSource(string(options["promptLabelTakePhoto"], default: "立即拍照"), true, 0) }
        if request.mediaType != 0 { addSource(string(options["promptLabelRecordVideo"], default: "立即录像"), true, 1) }
        sheet.addAction(UIAlertAction(title: string(options["promptLabelCancel"], default: "取消"), style: .cancel) { _ in
            finishPicker(with: .failure("CANCELLED", "用户取消了媒体来源选择"), request: request)
        })
        if let popover = sheet.popoverPresentationController {
            popover.sourceView = presenter.view
            popover.sourceRect = CGRect(x: presenter.view.bounds.midX, y: presenter.view.bounds.midY, width: 1, height: 1)
            popover.permittedArrowDirections = []
            popover.delegate = pickerDelegate
        }
        request.controller = sheet
        presenter.present(sheet, animated: true) {
            sheet.presentationController?.delegate = pickerDelegate
        }
    }

    private static func preparePicker(_ request: PickerRequest, camera: Bool, mediaType: Int) {
        guard fileLock.withLock({ activePicker === request }), LynxNativeOwnerScope.isActive(request.call.ownerID) else { return }
        guard let presenter = request.presenter, sceneAvailable(presenter) else {
            finishPicker(with: .failure("SCENE_UNAVAILABLE", "媒体选择器所属 scene 已销毁"), request: request); return
        }
        let options = request.call.options
        if camera {
            if mediaType == 1, options["includeMicrophone"] as? Bool == false {
                finishPicker(with: .failure("UNSUPPORTED", "iOS 系统录像不支持关闭音轨"), request: request); return
            }
            let device: UIImagePickerController.CameraDevice = string(options["cameraDirection"], default: "BACK").uppercased() == "FRONT" ? .front : .rear
            guard UIImagePickerController.isSourceTypeAvailable(.camera), UIImagePickerController.isCameraDeviceAvailable(device),
                  UIImagePickerController.availableMediaTypes(for: .camera)?.contains(mediaType == 1 ? UTType.movie.identifier : UTType.image.identifier) == true else {
                finishPicker(with: .failure("HARDWARE_UNAVAILABLE", "当前设备没有可用的拍摄能力"), request: request); return
            }
            guard infoString("NSCameraUsageDescription") != nil else {
                finishPicker(with: .failure("PERMISSION_NOT_DECLARED", "宿主未声明 NSCameraUsageDescription"), request: request); return
            }
            if mediaType == 1, infoString("NSMicrophoneUsageDescription") == nil {
                finishPicker(with: .failure("PERMISSION_NOT_DECLARED", "宿主未声明 NSMicrophoneUsageDescription"), request: request); return
            }
            let cameraStatus = AVCaptureDevice.authorizationStatus(for: .video)
            if cameraStatus == .notDetermined {
                AVCaptureDevice.requestAccess(for: .video) { _ in
                    DispatchQueue.main.async { preparePicker(request, camera: camera, mediaType: mediaType) }
                }
                return
            }
            guard cameraStatus == .authorized else {
                finishPicker(with: .failure("PERMISSION_DENIED", "未授予相机权限"), request: request); return
            }
            if mediaType == 1 {
                let microphoneStatus = AVCaptureDevice.authorizationStatus(for: .audio)
                if microphoneStatus == .notDetermined {
                    AVCaptureDevice.requestAccess(for: .audio) { _ in
                        DispatchQueue.main.async { preparePicker(request, camera: camera, mediaType: mediaType) }
                    }
                    return
                }
                guard microphoneStatus == .authorized else {
                    finishPicker(with: .failure("PERMISSION_DENIED", "未授予录像麦克风权限"), request: request); return
                }
            }
        }
        // 新媒体入口只保存拍摄结果；旧 Camera 显式保存选择结果的行为继续保留。
        if (camera || request.call.methodName != "chooseFromGallery") && bool(options["saveToGallery"], default: false) {
            guard infoString("NSPhotoLibraryAddUsageDescription") != nil else {
                finishPicker(with: .failure("PERMISSION_NOT_DECLARED", "宿主未声明 NSPhotoLibraryAddUsageDescription"), request: request); return
            }
            let status = PHPhotoLibrary.authorizationStatus(for: .addOnly)
            if status == .notDetermined {
                PHPhotoLibrary.requestAuthorization(for: .addOnly) { _ in
                    DispatchQueue.main.async { preparePicker(request, camera: camera, mediaType: mediaType) }
                }
                return
            }
            guard status == .authorized || status == .limited else {
                finishPicker(with: .failure("PERMISSION_DENIED", "未授予保存到系统相册的权限"), request: request); return
            }
        }
        guard presenter.presentedViewController == nil else {
            finishPicker(with: .failure("BUSY", "宿主正在显示其他原生界面"), request: request); return
        }
        let controller: UIViewController
        request.camera = camera
        if camera {
            request.selectionLimit = 1
            let picker = UIImagePickerController()
            picker.sourceType = .camera
            picker.cameraDevice = string(options["cameraDirection"], default: "BACK").uppercased() == "FRONT" ? .front : .rear
            picker.mediaTypes = [mediaType == 1 ? UTType.movie.identifier : UTType.image.identifier]
            picker.videoQuality = .typeHigh
            picker.delegate = pickerDelegate
            controller = picker
        } else {
            var configuration = PHPickerConfiguration(photoLibrary: .shared())
            configuration.selectionLimit = request.selectionLimit
            configuration.filter = mediaType == 1 ? .videos : mediaType == 2 ? .any(of: [.images, .videos]) : .images
            let picker = PHPickerViewController(configuration: configuration)
            picker.delegate = pickerDelegate
            controller = picker
        }
        request.controller = controller
        presenter.present(controller, animated: true) {
            controller.presentationController?.delegate = pickerDelegate
        }
    }

    private static func finishPicker(with result: LynxNativeCapabilityResult, request expected: PickerRequest) {
        let request = fileLock.withLock { () -> PickerRequest? in
            guard activePicker === expected else { return nil }
            let current = activePicker
            activePicker = nil
            pickerDelegate = nil
            return current
        }
        guard let request else { return }
        if let controller = request.controller, controller.presentingViewController != nil {
            controller.dismiss(animated: true) { request.finish(result) }
        } else {
            request.finish(result)
        }
    }

    private static func processPHPickerResults(_ results: [PHPickerResult], request: PickerRequest) {
        guard !results.isEmpty else { finishPicker(with: .failure("CANCELLED", "用户取消了媒体选择"), request: request); return }
        guard results.count <= request.selectionLimit else {
            finishPicker(with: .failure("PAYLOAD_TOO_LARGE", "媒体选择结果超过本次数量预算"), request: request); return
        }
        let group = DispatchGroup()
        let resultLock = NSLock()
        var files: [Int: (URL, Bool)] = [:]
        var firstFailure: LynxNativeCapabilityResult?
        for (index, result) in results.enumerated() {
            let provider = result.itemProvider
            group.enter()
            LynxNativeIOExecutor.shared.submitAsync(ownerID: request.call.ownerID, completion: { result in
                if !result.success { resultLock.withLock { if firstFailure == nil { firstFailure = result } } }
                group.leave()
            }) { cancellation, finish in
                let store: (URL, Bool) -> Void = { url, video in
                    guard !cancellation.isCancelled, LynxNativeOwnerScope.isActive(request.call.ownerID) else {
                        try? fileManager.removeItem(at: url)
                        finish(.failure("HOST_DESTROYED", "媒体读取已取消"))
                        return
                    }
                    resultLock.withLock { files[index] = (url, video) }
                    finish(.success())
                }
                if provider.hasItemConformingToTypeIdentifier(UTType.movie.identifier) {
                    let resource = LynxNativeOwnedResource(ownerID: request.call.ownerID)
                    let progress = provider.loadFileRepresentation(forTypeIdentifier: UTType.movie.identifier) { source, error in
                        resource.finish()
                        guard !cancellation.isCancelled else { finish(.failure("HOST_DESTROYED", "媒体读取已取消")); return }
                        guard let source, error == nil else { finish(.failure("MEDIA_READ_FAILED", "视频复制失败")); return }
                        do { store(try copyMediaFile(source, ext: "mov", ownerID: request.call.ownerID, cancellation: cancellation), true) }
                        catch { finish(imageFailure(error)) }
                    }
                    resource.attach { progress.cancel() }
                } else if provider.hasItemConformingToTypeIdentifier(UTType.image.identifier) {
                    let resource = LynxNativeOwnedResource(ownerID: request.call.ownerID)
                    let progress = provider.loadFileRepresentation(forTypeIdentifier: UTType.image.identifier) { source, error in
                        resource.finish()
                        guard !cancellation.isCancelled else { finish(.failure("HOST_DESTROYED", "媒体读取已取消")); return }
                        guard let source, error == nil else { finish(.failure("MEDIA_READ_FAILED", "无法读取图片文件表示")); return }
                        do { store(try writeImageFile(source), false) }
                        catch { finish(imageFailure(error)) }
                    }
                    resource.attach { progress.cancel() }
                } else if provider.canLoadObject(ofClass: UIImage.self) {
                    let resource = LynxNativeOwnedResource(ownerID: request.call.ownerID)
                    let progress = provider.loadObject(ofClass: UIImage.self) { object, error in
                        resource.finish()
                        guard !cancellation.isCancelled else { finish(.failure("HOST_DESTROYED", "媒体读取已取消")); return }
                        guard let image = object as? UIImage, error == nil else { finish(.failure("MEDIA_READ_FAILED", "无法读取图片对象")); return }
                        do { store(try writeImage(image), false) }
                        catch { finish(imageFailure(error)) }
                    }
                    resource.attach { progress.cancel() }
                } else { finish(.failure("MEDIA_READ_FAILED", "不支持所选媒体类型")) }
            }
        }
        group.notify(queue: .global(qos: .userInitiated)) {
            let outcome = resultLock.withLock { (files.keys.sorted().compactMap { files[$0] }, firstFailure) }
            if let failure = outcome.1 {
                outcome.0.forEach { try? fileManager.removeItem(at: $0.0) }
                DispatchQueue.main.async { finishPicker(with: failure, request: request) }
            } else {
                DispatchQueue.main.async {
                    guard !outcome.0.isEmpty else { finishPicker(with: .failure("MEDIA_READ_FAILED", "无法读取所选媒体"), request: request); return }
                    deliverMediaFiles(outcome.0, request: request)
                }
            }
        }
    }

    private static func processUIImagePicker(info: [UIImagePickerController.InfoKey: Any], request: PickerRequest) {
        LynxNativeIOExecutor.shared.submit(ownerID: request.call.ownerID, completion: { result in
            if !result.success { DispatchQueue.main.async { finishPicker(with: result, request: request) } }
        }) { cancellation in
            guard !cancellation.isCancelled else { return .failure("HOST_DESTROYED", "媒体转换已取消") }
            let file: (URL, Bool)?
            do {
                if let source = info[.mediaURL] as? URL { file = (try copyMediaFile(source, ext: "mov", ownerID: request.call.ownerID, cancellation: cancellation), true) }
                else if let source = info[.imageURL] as? URL { file = (try writeImageFile(source), false) }
                else if let image = info[.originalImage] as? UIImage { file = (try writeImage(image), false) }
                else { file = nil }
            } catch { return imageFailure(error) }
            guard let file else { return .failure("MEDIA_READ_FAILED", "无法读取相机输出") }
            guard !cancellation.isCancelled, LynxNativeOwnerScope.isActive(request.call.ownerID) else {
                try? fileManager.removeItem(at: file.0)
                return .failure("HOST_DESTROYED", "媒体转换已取消")
            }
            DispatchQueue.main.async { deliverMediaFiles([file], request: request) }
            return .success()
        }
    }

    private static func deliverMediaFiles(_ files: [(URL, Bool)], request: PickerRequest) {
        guard fileLock.withLock({ activePicker === request }), LynxNativeOwnerScope.isActive(request.call.ownerID) else {
            files.forEach { try? fileManager.removeItem(at: $0.0) }
            return
        }
        guard files.count <= request.selectionLimit else {
            files.forEach { try? fileManager.removeItem(at: $0.0) }
            finishPicker(with: .failure("PAYLOAD_TOO_LARGE", "媒体选择结果超过本次数量预算"), request: request)
            return
        }
        let includeMetadata = bool(request.call.options["includeMetadata"], default: false)
        let resultType = string(request.call.options["resultType"], default: "URI").uppercased()
        let saveToGallery = (request.camera || request.call.methodName != "chooseFromGallery")
            && bool(request.call.options["saveToGallery"], default: false)
        LynxNativeIOExecutor.shared.submit(ownerID: request.call.ownerID, completion: { result in
            DispatchQueue.main.async {
                guard fileLock.withLock({ activePicker === request }), LynxNativeOwnerScope.isActive(request.call.ownerID) else {
                    files.forEach { try? fileManager.removeItem(at: $0.0) }
                    return
                }
                let finish: (LynxNativeCapabilityResult) -> Void = { finishPicker(with: $0, request: request) }
                guard result.success else { files.forEach { try? fileManager.removeItem(at: $0.0) }; finish(result); return }
                let media = result.data?["photos"] as? [[String: Any]] ?? []
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
                            if let error { finish(.failure("PHOTO_SAVE_FAILED", error.localizedDescription)) }
                            else if !saved { finish(.failure("PHOTO_SAVE_FAILED", "系统相册未完成保存")) }
                            else if request.call.methodName == "getPhoto", var photo = media.first {
                                photo["savedToGallery"] = true
                                finish(.success(photo))
                            } else { finish(.success(["photos": media, "savedToGallery": true])) }
                        }
                    }
                } else if request.call.methodName == "getPhoto", let photo = media.first {
                    finish(.success(photo))
                } else {
                    finish(.success(["photos": media, "savedToGallery": false]))
                }
            }
        }) { cancellation in
            do {
                var media: [[String: Any]] = []
                for file in files {
                    guard !cancellation.isCancelled else { return .failure("HOST_DESTROYED", "媒体编码已取消") }
                    media.append(try mediaResult(url: file.0, video: file.1, resultType: resultType, includeMetadata: includeMetadata))
                }
                return .success(["photos": media])
            } catch let error as MediaError { return .failure(error.code, error.message) }
            catch { return .failure("MEDIA_READ_FAILED", error.localizedDescription) }
        }
    }

    private static func writeImage(_ image: UIImage) throws -> URL {
        let url = fileManager.temporaryDirectory.appendingPathComponent("lynx-photo-\(UUID().uuidString).jpg")
        try LynxNativeImageEncoding.writeImage(image, to: url)
        return url
    }

    private static func writeImageFile(_ source: URL) throws -> URL {
        let url = fileManager.temporaryDirectory.appendingPathComponent("lynx-photo-\(UUID().uuidString).jpg")
        try LynxNativeImageEncoding.writeFile(source, to: url)
        return url
    }

    private static func imageFailure(_ error: Error) -> LynxNativeCapabilityResult {
        if let error = error as? LynxNativeImageEncoding.EncodingError { return .failure(error.code, error.message) }
        if let error = error as? LynxNativeAtomicFile.WriteError { return .failure(error.code, error.message) }
        if error is LynxNativeIOExecutor.Cancelled { return .failure("HOST_DESTROYED", "媒体复制已取消") }
        return .failure("MEDIA_READ_FAILED", error.localizedDescription)
    }

    private static func copyMediaFile(_ source: URL, ext: String, ownerID: String?, cancellation: LynxNativeIOExecutor.Cancellation) throws -> URL {
        let fileExtension = source.pathExtension.isEmpty ? ext : source.pathExtension
        let target = fileManager.temporaryDirectory.appendingPathComponent("lynx-media-\(UUID().uuidString).\(fileExtension)")
        try LynxNativeAtomicFile.copy(source, to: target, ownerID: ownerID, cancellation: cancellation,
                                     maximumBytes: LynxNativePayloadLimits.downloadedFileBytes)
        return target
    }

    static func mediaResult(url: URL, video: Bool, resultType: String, includeMetadata: Bool) throws -> [String: Any] {
        let mimeType = video ? (UTType(filenameExtension: url.pathExtension)?.preferredMIMEType ?? "video/quicktime") : "image/jpeg"
        var result: [String: Any] = [
            "path": url.path,
            "webPath": url.absoluteString,
            "format": url.pathExtension,
            "mimeType": mimeType,
            "mediaType": video ? "video" : "image",
        ]
        let fileSize = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
        guard fileSize <= LynxNativePayloadLimits.downloadedFileBytes else { throw MediaError("MEDIA_TOO_LARGE", "媒体超过 20 MiB 限制") }
        result["size"] = fileSize
        if !video, includeMetadata {
            let dimensions = try LynxNativeImageEncoding.fileDimensions(url)
            result["width"] = dimensions.width
            result["height"] = dimensions.height
        }
        if resultType == "BASE64" || resultType == "DATA_URL" {
            let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
            guard size <= LynxNativePayloadLimits.inlineMediaBytes else { throw MediaError("PAYLOAD_TOO_LARGE", "媒体超过内联上限，请使用 URI") }
            let data = try Data(contentsOf: url)
            guard data.count <= LynxNativePayloadLimits.inlineMediaBytes else { throw MediaError("PAYLOAD_TOO_LARGE", "媒体超过内联上限") }
            let base64 = data.base64EncodedString()
            result["base64String"] = base64
            result["dataUrl"] = "data:\(mimeType);base64,\(base64)"
        }
        return result
    }

    private static func playVideo(_ call: LynxNativeCapabilityCall, presenter: UIViewController?, completion: @escaping Completion) {
        guard let presenter, sceneAvailable(presenter) else { completion(.failure("SCENE_UNAVAILABLE", "没有前台 scene，无法播放视频")); return }
        let options = call.options
        let key = call.ownerID ?? "-1"
        guard pendingPreviews[key] == nil, previews[key] == nil, players[key] == nil else { completion(.failure("BUSY", "本页面已有媒体预览正在显示")); return }
        guard let url = validatedLocalFile(path: string(options["uri"] ?? options["path"]), directory: string(options["directory"], default: "CACHE")) else { completion(.failure("NOT_FOUND", "视频必须是应用媒体目录中的现存本地文件")); return }
        let session = PlayerSession(url: url, ownerID: call.ownerID)
        let container = PlayerContainerController(session: session)
        let controller = UINavigationController(rootViewController: container)
        controller.modalPresentationStyle = .fullScreen
        session.controller = controller
        players[key] = session
        session.resource.attach { [weak session] in session?.close() }
        guard LynxNativeOwnerScope.isActive(call.ownerID) else { session.close(); return }
        presenter.present(controller, animated: true) {
            guard LynxNativeOwnerScope.isActive(call.ownerID) else { session.close(); return }
            controller.presentationController?.delegate = session
            session.playerController.player?.play()
            completion(.success(["played": true, "uri": url.absoluteString]))
        }
    }

    private final class PickerRequest {
        let call: LynxNativeCapabilityCall
        weak var presenter: UIViewController?
        weak var controller: UIViewController?
        let completion: Completion
        let resource: LynxNativeOwnedResource
        let mediaType: Int
        var selectionLimit: Int
        var changingSource = false
        var camera = false
        var processing = false
        private var finished = false
        init(call: LynxNativeCapabilityCall, presenter: UIViewController, selectionLimit: Int, mediaType: Int, completion: @escaping Completion) {
            self.call = call
            self.presenter = presenter
            self.completion = completion
            self.selectionLimit = selectionLimit
            self.mediaType = mediaType
            resource = LynxNativeOwnedResource(ownerID: call.ownerID)
        }
        func finish(_ result: LynxNativeCapabilityResult) {
            guard !finished else { return }
            finished = true
            resource.finish()
            completion(result)
        }
    }

    private final class PickerDelegate: NSObject, PHPickerViewControllerDelegate, UIImagePickerControllerDelegate, UINavigationControllerDelegate, UIPopoverPresentationControllerDelegate {
        func presentationControllerDidDismiss(_ presentationController: UIPresentationController) {
            guard let request = fileLock.withLock({ activePicker }), !request.changingSource,
                  request.controller === presentationController.presentedViewController else { return }
            finishPicker(with: .failure("CANCELLED", "用户关闭了媒体选择界面"), request: request)
        }

        func popoverPresentationControllerDidDismissPopover(_ popoverPresentationController: UIPopoverPresentationController) {
            presentationControllerDidDismiss(popoverPresentationController)
        }

        func picker(_ picker: PHPickerViewController, didFinishPicking results: [PHPickerResult]) {
            guard let request = fileLock.withLock({ activePicker }), request.controller === picker, !request.processing else { return }
            request.processing = true
            processPHPickerResults(results, request: request)
            _ = picker
        }

        func imagePickerControllerDidCancel(_ picker: UIImagePickerController) {
            guard let request = fileLock.withLock({ activePicker }), request.controller === picker else { return }
            finishPicker(with: .failure("CANCELLED", "用户取消了媒体选择"), request: request)
            _ = picker
        }

        func imagePickerController(_ picker: UIImagePickerController, didFinishPickingMediaWithInfo info: [UIImagePickerController.InfoKey: Any]) {
            guard let request = fileLock.withLock({ activePicker }), request.controller === picker, !request.processing else { return }
            request.processing = true
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
            guard !id.isEmpty, let transfer = fileLock.withLock({ transfers[transferKey(ownerID: call.ownerID, operationID: id)] }) else { completion(.failure("NOT_FOUND", "下载任务不存在")); return }
            completion(.success(transfer.status))
        case "cancel":
            let id = string(call.options["operationId"] ?? call.options["id"])
            guard let transfer = fileLock.withLock({ transfers[transferKey(ownerID: call.ownerID, operationID: id)] }) else { completion(.failure("NOT_FOUND", "下载任务不存在")); return }
            transfer.cancel(); completion(.success(["operationId": id, "cancelled": true, "state": "cancelled"]))
        default: completion(.failure("UNSUPPORTED", "FileTransfer.\(call.methodName) 尚未接入当前 iOS Module"))
        }
    }

    private static func transferKey(ownerID: String?, operationID: String) -> String { "\(ownerID ?? "-1"):\(operationID)" }

    private static func startTransfer(_ call: LynxNativeCapabilityCall, eventSender: EventSender?, completion: @escaping Completion) {
        LynxNativeIOExecutor.network.submitAsync(ownerID: call.ownerID, completion: completion) { cancellation, finish in
            guard !cancellation.isCancelled else { finish(.failure("HOST_DESTROYED", "下载请求已取消")); return }
            startTransferWork(call, cancellation: cancellation, eventSender: eventSender, completion: finish)
        }
    }

    private static func startTransferWork(_ call: LynxNativeCapabilityCall, cancellation: LynxNativeIOExecutor.Cancellation, eventSender: EventSender?, completion: @escaping Completion) {
        guard let url = URL(string: string(call.options["url"])), ["http", "https"].contains(url.scheme?.lowercased() ?? "") else { completion(.failure("INVALID_ARGUMENT", "downloadFile.url 必须是 http/https URL")); return }
        let operationID = string(call.options["operationId"] ?? call.options["id"], default: UUID().uuidString)
        let key = transferKey(ownerID: call.ownerID, operationID: operationID)
        guard fileLock.withLock({ transfers[key] == nil }) else { completion(.failure("BUSY", "下载任务已经存在")); return }
        let transfer = Transfer(operationID: operationID, call: call, cancellation: cancellation, eventSender: eventSender, completion: completion)
        guard fileLock.withLock({ () -> Bool in
            guard transfers[key] == nil, LynxNativeOwnerScope.isActive(call.ownerID) else { return false }
            transfers[key] = transfer
            return true
        }) else { completion(.failure("BUSY", "下载任务已经存在或页面已销毁")); return }
        let session = URLSession(configuration: .default, delegate: transfer, delegateQueue: nil)
        transfer.session = session
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        if let headers = call.options["headers"] as? [String: Any] { headers.forEach { request.setValue(string($0.value), forHTTPHeaderField: $0.key) } }
        transfer.task = session.downloadTask(with: request)
        transfer.status = ["operationId": operationID, "state": "pending", "progress": 0]
        guard LynxNativeOwnerScope.isActive(call.ownerID) else { transfer.cancelFromModuleRelease(); return }
        transfer.task?.resume()
    }

    private final class Transfer: NSObject, URLSessionDownloadDelegate {
        let operationID: String
        let call: LynxNativeCapabilityCall
        let cancellation: LynxNativeIOExecutor.Cancellation
        let eventSender: EventSender?
        let completion: Completion
        var session: URLSession?
        var task: URLSessionDownloadTask?
        private var storedStatus: [String: Any] = [:]
        var status: [String: Any] {
            get { stateLock.withLock { storedStatus } }
            set { stateLock.withLock { storedStatus = newValue } }
        }
        private let stateLock = NSLock()
        private var finished = false

        init(operationID: String, call: LynxNativeCapabilityCall, cancellation: LynxNativeIOExecutor.Cancellation, eventSender: EventSender?, completion: @escaping Completion) {
            self.operationID = operationID; self.call = call; self.cancellation = cancellation; self.eventSender = eventSender; self.completion = completion
            super.init()
        }

        func cancel() {
            cancellation.cancel()
            task?.cancel()
            session?.invalidateAndCancel()
            finish(.failure("CANCELLED", "下载任务已取消"))
        }

        func cancelFromModuleRelease() {
            cancellation.cancel()
            finish(.failure("HOST_DESTROYED", "下载任务已取消"))
            task?.cancel()
            session?.invalidateAndCancel()
        }

        func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64, totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
            guard LynxNativeOwnerScope.isActive(call.ownerID), !stateLock.withLock({ finished }) else { return }
            if totalBytesWritten > LynxNativePayloadLimits.downloadedFileBytes || totalBytesExpectedToWrite > LynxNativePayloadLimits.downloadedFileBytes {
                task?.cancel()
                finish(.failure("DOWNLOAD_TOO_LARGE", "下载文件超过 20 MiB 限制"))
                return
            }
            let progress = totalBytesExpectedToWrite > 0 ? Double(totalBytesWritten) / Double(totalBytesExpectedToWrite) : 0
            status = ["operationId": operationID, "state": "running", "progress": progress, "bytesWritten": totalBytesWritten, "totalBytes": totalBytesExpectedToWrite]
            guard let eventSender, let raw = LynxNativeJSON.encode([
                "callbackId": operationID,
                "pluginId": "FileTransfer",
                "methodName": "progress",
                "eventName": "progress",
                "operationId": operationID,
                "success": true,
                "data": status,
                "save": true,
            ]) else { return }
            eventSender(raw)
            _ = session; _ = downloadTask; _ = bytesWritten
        }

        func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
            guard LynxNativeOwnerScope.isActive(call.ownerID), !stateLock.withLock({ finished }) else { return }
            let httpCode = (downloadTask.response as? HTTPURLResponse)?.statusCode ?? 0
            guard (200..<300).contains(httpCode) else { finish(.failure("HTTP_ERROR", "下载失败，HTTP \(httpCode)")); return }
            let sourceSize = (try? location.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
            guard sourceSize <= LynxNativePayloadLimits.downloadedFileBytes else { finish(.failure("DOWNLOAD_TOO_LARGE", "下载文件超过 20 MiB 限制")); return }
            let directory = (try? LynxNativeMediaCapabilities.directoryRoot(LynxNativeMediaCapabilities.string(call.options["directory"], default: "CACHE")))
            let path = LynxNativeMediaCapabilities.string(call.options["path"], default: "lynx-download-\(UUID().uuidString).bin")
            guard let directory, let target = LynxNativeMediaCapabilities.safePath(path, under: directory) else { finish(.failure("INVALID_ARGUMENT", "下载目标路径无效")); return }
            do {
                try LynxNativeAtomicFile.copy(location, to: target, ownerID: call.ownerID, cancellation: cancellation,
                    maximumBytes: LynxNativePayloadLimits.downloadedFileBytes, publish: { part, destination in
                        try self.stateLock.withLock {
                            guard !self.finished else { throw LynxNativeIOExecutor.Cancelled() }
                            try LynxNativeOwnerScope.commit(ownerID: self.call.ownerID) {
                                try self.cancellation.commit { try LynxNativeAtomicFile.rename(part, to: destination) }
                            }
                        }
                    })
                finish(.success(["operationId": operationID, "state": "completed", "progress": 1, "path": target.path, "uri": target.absoluteString, "httpCode": httpCode]))
            } catch is LynxNativeIOExecutor.Cancelled { finish(.failure("HOST_DESTROYED", "下载发布已取消")) }
            catch let error as LynxNativeAtomicFile.WriteError { finish(.failure(error.code, error.message)) }
            catch { finish(.failure("DOWNLOAD_FAILED", error.localizedDescription)) }
        }

        func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
            if let error, !stateLock.withLock({ finished }) { finish(.failure((error as NSError).code == NSURLErrorCancelled ? "CANCELLED" : "DOWNLOAD_FAILED", error.localizedDescription)) }
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
            fileLock.withLock {
                let key = transferKey(ownerID: call.ownerID, operationID: operationID)
                if transfers[key] === self { transfers.removeValue(forKey: key) }
            }
            session?.finishTasksAndInvalidate()
            DispatchQueue.main.async { self.completion(result) }
        }
    }

    // MARK: - FileViewer

    private static func dispatchFileViewer(_ call: LynxNativeCapabilityCall, presenter: UIViewController?, completion: @escaping Completion) {
        guard call.methodName == "openDocumentFromLocalPath" else { completion(.failure("UNSUPPORTED", "FileViewer.\(call.methodName) 尚未接入当前 iOS Module")); return }
        guard let presenter, sceneAvailable(presenter) else { completion(.failure("SCENE_UNAVAILABLE", "没有前台 scene，无法打开文件预览")); return }
        let options = call.options
        let items: [[String: Any]]
        let imageList = options["items"] != nil
        let initialIndex: Int
        if imageList {
            guard options["path"] == nil, options["uri"] == nil, options["localPath"] == nil,
                  let entries = options["items"] as? [[String: Any]], !entries.isEmpty, entries.count <= maximumSelectionCount else {
                completion(.failure("INVALID_ARGUMENT", "items 必须是 1...16 项的图片列表，且不能同时提供单文件 path/uri/localPath")); return
            }
            items = entries
            if let raw = options["initialIndex"] {
                guard let parsed = validSelectionCount(raw, minimum: 0), parsed < entries.count else {
                    completion(.failure("INVALID_ARGUMENT", "initialIndex 必须是图片列表内的有效整数索引")); return
                }
                initialIndex = parsed
            } else { initialIndex = 0 }
        } else {
            guard options["initialIndex"] == nil else { completion(.failure("INVALID_ARGUMENT", "initialIndex 只能与 items 一起使用")); return }
            items = [options]
            initialIndex = 0
        }
        let key = call.ownerID ?? "-1"
        guard pendingPreviews[key] == nil, previews[key] == nil, players[key] == nil, presenter.presentedViewController == nil else {
            completion(.failure("BUSY", "本页面已有原生界面或媒体预览正在显示")); return
        }
        let requestID = UUID()
        pendingPreviews[key] = requestID
        // canonical 路径、真实图片类型和文件预算在受控 IO 中检查，Quick Look 只接收验证后的 URL。
        LynxNativeIOExecutor.shared.submit(ownerID: call.ownerID, completion: { result in
            DispatchQueue.main.async {
                guard pendingPreviews[key] == requestID else { return }
                pendingPreviews.removeValue(forKey: key)
                guard LynxNativeOwnerScope.isActive(call.ownerID) else { return }
                guard result.success else { completion(result); return }
                guard let values = result.data?["uris"] as? [String], values.count == items.count else {
                    completion(.failure("MEDIA_READ_FAILED", "本地预览校验未返回完整结果")); return
                }
                let urls = values.compactMap(URL.init(string:))
                guard urls.count == items.count else { completion(.failure("MEDIA_READ_FAILED", "本地预览 URL 无效")); return }
                guard sceneAvailable(presenter) else { completion(.failure("SCENE_UNAVAILABLE", "文件预览所属 scene 已销毁")); return }
                guard previews[key] == nil, players[key] == nil, presenter.presentedViewController == nil else {
                    completion(.failure("BUSY", "宿主正在显示其他原生界面")); return
                }
                guard urls.allSatisfy({ QLPreviewController.canPreview($0 as QLPreviewItem) }) else {
                    completion(.failure("NO_HANDLER", "Quick Look 没有可用的文件预览 handler")); return
                }
                let controller = makePreviewController(urls: urls, initialIndex: initialIndex, ownerID: call.ownerID)
                guard LynxNativeOwnerScope.isActive(call.ownerID) else { return }
                presenter.present(controller, animated: true) {
                    guard LynxNativeOwnerScope.isActive(call.ownerID) else { return }
                    controller.presentationController?.delegate = controller.delegate as? PreviewDataSource
                    var data: [String: Any] = ["opened": true, "uri": urls[initialIndex].absoluteString]
                    if imageList { data["initialIndex"] = initialIndex; data["itemCount"] = urls.count }
                    completion(.success(data))
                }
            }
        }) { cancellation in
            do {
                var urls: [URL] = []
                for item in items {
                    try cancellation.check()
                    var path = string(item["path"] ?? item["uri"])
                    if imageList {
                        guard (item["uri"] == nil || item["uri"] is String),
                              (item["path"] == nil || item["path"] is String),
                              (item["directory"] == nil || item["directory"] is String) else {
                            throw MediaError("INVALID_ARGUMENT", "图片 uri/path/directory 必须为字符串")
                        }
                        let locations = [item["uri"] as? String, item["path"] as? String]
                            .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
                        guard let selectedPath = locations.first(where: { !$0.isEmpty }) else {
                            throw MediaError("INVALID_ARGUMENT", "每张图片必须提供一个非空 uri 或 path")
                        }
                        path = selectedPath
                        if let raw = item["mimeType"] {
                            guard let mimeType = raw as? String, mimeType.lowercased().hasPrefix("image/") else {
                                throw MediaError("INVALID_ARGUMENT", "items 只接受图片 mimeType")
                            }
                        }
                    }
                    guard let url = validatedLocalFile(path: path, directory: string(item["directory"], default: "CACHE")) else {
                        throw MediaError("NOT_FOUND", "预览必须是应用媒体目录中的现存本地文件")
                    }
                    if imageList {
                        let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
                        guard size <= LynxNativePayloadLimits.downloadedFileBytes else { throw MediaError("MEDIA_TOO_LARGE", "预览图片超过 20 MiB 限制") }
                        guard let source = CGImageSourceCreateWithURL(url as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary),
                              let identifier = CGImageSourceGetType(source), let type = UTType(identifier as String), type.conforms(to: .image),
                              CGImageSourceGetCount(source) > 0 else { throw MediaError("INVALID_ARGUMENT", "items 中包含非图片或无效图片文件") }
                        _ = try LynxNativeImageEncoding.fileDimensions(url)
                    }
                    urls.append(url)
                }
                try cancellation.check()
                return .success(["uris": urls.map(\.absoluteString)])
            } catch is LynxNativeIOExecutor.Cancelled { return .failure("HOST_DESTROYED", "图片预览读取已取消") }
            catch let error as MediaError { return .failure(error.code, error.message) }
            catch { return imageFailure(error) }
        }
    }

    static var activePreviewCount: Int { previews.count }

    static func makePreviewController(url: URL, ownerID: String?) -> QLPreviewController {
        makePreviewController(urls: [url], initialIndex: 0, ownerID: ownerID)
    }

    private static func makePreviewController(urls: [URL], initialIndex: Int, ownerID: String?) -> QLPreviewController {
        let controller = QLPreviewController()
        let source = PreviewDataSource(urls: urls, ownerID: ownerID)
        source.onDismiss = { [weak controller] in
            let key = ownerID ?? "-1"
            if previews[key]?.0 === controller { previews.removeValue(forKey: key) }
        }
        controller.dataSource = source
        controller.delegate = source
        controller.currentPreviewItemIndex = initialIndex
        previews[ownerID ?? "-1"] = (controller, source)
        source.resource.attach { [weak controller, weak source] in
            source?.finish()
            controller?.dismiss(animated: false)
        }
        return controller
    }

    /** AVPlayerViewController 不支持子类化；系统播放器作为普通 UIKit 容器的子控制器。 */
    private final class PlayerContainerController: UIViewController {
        let session: PlayerSession
        init(session: PlayerSession) { self.session = session; super.init(nibName: nil, bundle: nil) }
        required init?(coder: NSCoder) { fatalError("不支持 storyboard 初始化") }
        override func viewDidLoad() {
            super.viewDidLoad()
            view.backgroundColor = .black
            navigationItem.rightBarButtonItem = UIBarButtonItem(barButtonSystemItem: .done, target: self, action: #selector(closePlayer))
            let player = session.playerController
            addChild(player)
            player.view.frame = view.bounds
            player.view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
            view.addSubview(player.view)
            player.didMove(toParent: self)
        }
        override func viewWillDisappear(_ animated: Bool) {
            super.viewWillDisappear(animated)
            if isBeingDismissed || navigationController?.isBeingDismissed == true || isMovingFromParent { session.finish() }
        }
        override func viewDidDisappear(_ animated: Bool) {
            super.viewDidDisappear(animated)
            if isBeingDismissed || navigationController?.isBeingDismissed == true || isMovingFromParent { session.finish() }
        }
        @objc private func closePlayer() { session.close() }
    }

    private final class PlayerSession: NSObject, AVPlayerViewControllerDelegate, UIAdaptivePresentationControllerDelegate {
        let playerController = AVPlayerViewController()
        let resource: LynxNativeOwnedResource
        weak var controller: UIViewController?
        let ownerID: String?
        private var finished = false
        init(url: URL, ownerID: String?) {
            self.ownerID = ownerID
            resource = LynxNativeOwnedResource(ownerID: ownerID)
            super.init()
            playerController.player = AVPlayer(url: url)
            playerController.delegate = self
        }
        func presentationControllerDidDismiss(_ presentationController: UIPresentationController) { finish() }
        func close() { finish(); controller?.dismiss(animated: false) }
        func finish() {
            guard !finished else { return }
            finished = true
            playerController.player?.pause()
            playerController.player = nil
            playerController.delegate = nil
            resource.finish()
            let key = ownerID ?? "-1"
            if players[key] === self { players.removeValue(forKey: key) }
        }
    }

    final class PreviewDataSource: NSObject, QLPreviewControllerDataSource, QLPreviewControllerDelegate, UIAdaptivePresentationControllerDelegate {
        var onDismiss: (() -> Void)?
        let urls: [URL]
        let resource: LynxNativeOwnedResource
        init(urls: [URL], ownerID: String?) { self.urls = urls; resource = LynxNativeOwnedResource(ownerID: ownerID) }
        func finish() { resource.finish(); let cleanup = onDismiss; onDismiss = nil; cleanup?() }
        func previewControllerDidDismiss(_ controller: QLPreviewController) { finish() }
        func presentationControllerDidDismiss(_ presentationController: UIPresentationController) { finish() }
        func numberOfPreviewItems(in controller: QLPreviewController) -> Int { _ = controller; return urls.count }
        func previewController(_ controller: QLPreviewController, previewItemAt index: Int) -> QLPreviewItem { _ = controller; return urls[index] as NSURL }
    }

    // MARK: - Helpers

    static func validSelectionCount(_ value: Any, minimum: Int) -> Int? {
        guard let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID() else { return nil }
        let count = number.doubleValue
        guard count.isFinite, count.rounded(.towardZero) == count,
              count >= Double(minimum), count <= Double(maximumSelectionCount) else { return nil }
        return Int(count)
    }

    /** canonical 路径同时阻止 file URL、绝对路径和符号链接越出应用媒体目录。 */
    static func validatedLocalFile(path: String, directory: String = "CACHE") -> URL? {
        guard !path.isEmpty else { return nil }
        let candidate: URL
        if path.hasPrefix("/") { candidate = URL(fileURLWithPath: path) }
        else if let url = URL(string: path), url.scheme != nil {
            guard url.isFileURL else { return nil }
            candidate = url
        } else {
            guard let root = try? directoryRoot(directory), let url = safePath(path, under: root) else { return nil }
            candidate = url
        }
        let canonical = candidate.standardizedFileURL.resolvingSymlinksInPath()
        let directories: [FileManager.SearchPathDirectory] = [.cachesDirectory, .documentDirectory, .applicationSupportDirectory, .libraryDirectory]
        let roots = [fileManager.temporaryDirectory] + directories.compactMap {
            fileManager.urls(for: $0, in: .userDomainMask).first
        }
        guard roots.contains(where: { root in
            let rootPath = root.standardizedFileURL.resolvingSymlinksInPath().path
            return canonical.path.hasPrefix(rootPath.hasSuffix("/") ? rootPath : rootPath + "/")
        }), (try? canonical.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true else { return nil }
        return canonical
    }

    private static func sceneAvailable(_ presenter: UIViewController?) -> Bool {
        // 异步权限/IO结束后仍须是原调用页的可见scene，不能借用其他前台窗口继续呈现。
        guard LynxNativeCapabilitySupport.isUsable(presenter),
              let scene = presenter?.viewIfLoaded?.window?.windowScene else { return false }
        return scene.activationState == .foregroundActive
    }

    private static func infoString(_ key: String) -> String? {
        guard let value = Bundle.main.object(forInfoDictionaryKey: key) as? String,
              !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        return value
    }
    private static func string(_ value: Any?, default defaultValue: String = "") -> String { guard let value, !(value is NSNull) else { return defaultValue }; return value as? String ?? String(describing: value) }
    private static func int(_ value: Any?, default defaultValue: Int) -> Int { if let value = value as? NSNumber { return value.intValue }; return Int(string(value)) ?? defaultValue }
    private static func bool(_ value: Any?, default defaultValue: Bool) -> Bool { guard let value, !(value is NSNull) else { return defaultValue }; if let value = value as? Bool { return value }; if let value = value as? NSNumber { return value.boolValue }; return ["true", "1", "yes"].contains(string(value).lowercased()) }
    private static func authorizationState(_ status: AVAuthorizationStatus) -> String { switch status { case .authorized: return "granted"; case .denied: return "denied"; case .restricted: return "restricted"; case .notDetermined: return "prompt"; @unknown default: return "unknown" } }
    private static func photoAuthorizationState(_ status: PHAuthorizationStatus) -> String { switch status { case .authorized: return "granted"; case .limited: return "limited"; case .denied: return "denied"; case .restricted: return "restricted"; case .notDetermined: return "prompt"; @unknown default: return "unknown" } }

    private struct MediaError: Error { let code: String; let message: String; init(_ code: String, _ message: String) { self.code = code; self.message = message } }
}

/** 文件表示先查元信息，再有界下采样；UIImage fallback 只检查已有像素，不新建无界画布。 */
enum LynxNativeImageEncoding {
    struct EncodingError: Error { let code: String; let message: String }

    static func validatePixelCount(_ pixels: Int) throws {
        guard pixels > 0, pixels <= LynxNativePayloadLimits.maxImagePixels else {
            throw EncodingError(code: "IMAGE_TOO_LARGE", message: "图片编码超过像素预算")
        }
    }

    static func validateDimensions(width: Int, height: Int) throws {
        guard width > 0, height > 0 else { throw EncodingError(code: "MEDIA_READ_FAILED", message: "图片尺寸无效") }
        guard width <= LynxNativePayloadLimits.maxImageDimension,
              height <= LynxNativePayloadLimits.maxImageDimension else {
            throw EncodingError(code: "IMAGE_TOO_LARGE", message: "图片编码超过 4096 最大边或 16 MiPixels 上限")
        }
        try validatePixelCount(width * height)
    }

    static func thumbnailEdge(width: Int, height: Int) throws -> Int {
        guard width > 0, height > 0 else { throw EncodingError(code: "MEDIA_READ_FAILED", message: "图片尺寸无效") }
        let pixelEdge = Int(sqrt(Double(LynxNativePayloadLimits.maxImagePixels)))
        let edge = min(max(width, height), LynxNativePayloadLimits.maxImageDimension, pixelEdge)
        // 解码前校验最坏的正方形输出；之后再检查 ImageIO 实际输出。
        try validateDimensions(width: edge, height: edge)
        return edge
    }

    static func fileDimensions(_ url: URL) throws -> (width: Int, height: Int) {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary) else {
            throw EncodingError(code: "MEDIA_READ_FAILED", message: "无法创建图片文件源")
        }
        return try dimensions(source)
    }

    private static func dimensions(_ source: CGImageSource) throws -> (width: Int, height: Int) {
        guard let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, [kCGImageSourceShouldCache: false] as CFDictionary) as? [String: Any],
              let width = (properties[kCGImagePropertyPixelWidth as String] as? NSNumber)?.intValue,
              let height = (properties[kCGImagePropertyPixelHeight as String] as? NSNumber)?.intValue,
              width > 0, height > 0 else {
            throw EncodingError(code: "MEDIA_READ_FAILED", message: "图片元信息无效")
        }
        return (width, height)
    }

    static func writeFile(_ sourceURL: URL, to target: URL) throws {
        guard let source = CGImageSourceCreateWithURL(sourceURL as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary) else {
            throw EncodingError(code: "MEDIA_READ_FAILED", message: "无法创建图片文件源")
        }
        let size = try dimensions(source)
        let edge = try thumbnailEdge(width: size.width, height: size.height)
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: edge,
            kCGImageSourceShouldCacheImmediately: true,
        ] as CFDictionary) else { throw EncodingError(code: "MEDIA_READ_FAILED", message: "图片下采样失败") }
        try validateDimensions(width: image.width, height: image.height)
        guard let destination = CGImageDestinationCreateWithURL(target as CFURL, UTType.jpeg.identifier as CFString, 1, nil) else {
            throw EncodingError(code: "MEDIA_WRITE_FAILED", message: "无法创建图片输出文件")
        }
        CGImageDestinationAddImage(destination, image, [kCGImageDestinationLossyCompressionQuality: 0.9] as CFDictionary)
        guard CGImageDestinationFinalize(destination) else {
            try? FileManager.default.removeItem(at: target)
            throw EncodingError(code: "MEDIA_WRITE_FAILED", message: "图片 JPEG 编码失败")
        }
    }

    static func writeImage(_ image: UIImage, to target: URL) throws {
        let width = image.size.width * image.scale
        let height = image.size.height * image.scale
        guard width.isFinite, height.isFinite, width > 0, height > 0,
              width <= CGFloat(LynxNativePayloadLimits.maxImageDimension),
              height <= CGFloat(LynxNativePayloadLimits.maxImageDimension) else {
            throw EncodingError(code: "IMAGE_TOO_LARGE", message: "图片对象编码超过最大边上限")
        }
        try validateDimensions(width: Int(ceil(width)), height: Int(ceil(height)))
        guard let data = image.jpegData(compressionQuality: 0.9) else {
            throw EncodingError(code: "MEDIA_READ_FAILED", message: "图片对象无法编码为 JPEG")
        }
        try data.write(to: target, options: .atomic)
    }
}

/** 本次 part 与目标同目录；长拷贝可取消，只有原子 rename 在 owner 提交门禁内执行。 */
enum LynxNativeAtomicFile {
    struct WriteError: Error { let code: String; let message: String }

    static func write(_ data: Data, to target: URL, ownerID: String?, cancellation: LynxNativeIOExecutor.Cancellation,
                      beforeCommit: ((URL) -> Void)? = nil) throws {
        try cancellation.check()
        guard LynxNativeOwnerScope.isActive(ownerID) else { throw LynxNativeIOExecutor.Cancelled() }
        try FileManager.default.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
        let part = target.deletingLastPathComponent().appendingPathComponent(".lynx-\(UUID().uuidString).part")
        defer { try? FileManager.default.removeItem(at: part) }
        try data.write(to: part)
        beforeCommit?(part)
        try LynxNativeOwnerScope.commit(ownerID: ownerID) {
            try cancellation.commit { try rename(part, to: target) }
        }
    }

    static func copy(_ source: URL, to target: URL, ownerID: String?, cancellation: LynxNativeIOExecutor.Cancellation,
                     maximumBytes: Int, beforeCommit: ((URL) -> Void)? = nil,
                     publish: ((URL, URL) throws -> Void)? = nil) throws {
        try cancellation.check()
        guard LynxNativeOwnerScope.isActive(ownerID) else { throw LynxNativeIOExecutor.Cancelled() }
        try FileManager.default.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
        let part = target.deletingLastPathComponent().appendingPathComponent(".lynx-\(UUID().uuidString).part")
        defer { try? FileManager.default.removeItem(at: part) }
        guard FileManager.default.createFile(atPath: part.path, contents: nil) else { throw WriteError(code: "DOWNLOAD_FAILED", message: "无法创建本次下载临时文件") }
        let input = try FileHandle(forReadingFrom: source)
        let output = try FileHandle(forWritingTo: part)
        defer { try? input.close(); try? output.close() }
        var count = 0
        while true {
            try cancellation.check()
            guard LynxNativeOwnerScope.isActive(ownerID) else { throw LynxNativeIOExecutor.Cancelled() }
            let bytes = try input.read(upToCount: 64 * 1024) ?? Data()
            if bytes.isEmpty { break }
            count += bytes.count
            guard count <= maximumBytes else { throw WriteError(code: "DOWNLOAD_TOO_LARGE", message: "下载文件超过大小上限") }
            try output.write(contentsOf: bytes)
        }
        try output.synchronize()
        beforeCommit?(part)
        if let publish { try publish(part, target) }
        else {
            try LynxNativeOwnerScope.commit(ownerID: ownerID) {
                try cancellation.commit { try rename(part, to: target) }
            }
        }
    }

    static func rename(_ part: URL, to target: URL) throws {
        let status = part.path.withCString { source in target.path.withCString { destination in Darwin.rename(source, destination) } }
        guard status == 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
    }
}

private extension NSLock {
    func withLock<T>(_ body: () throws -> T) rethrows -> T { lock(); defer { unlock() }; return try body() }
}
