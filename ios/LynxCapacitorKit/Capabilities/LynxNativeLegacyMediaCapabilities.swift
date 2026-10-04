import Foundation
import UIKit

/** Shell 五方法只转换旧字段；选择与下载继续执行已有能力 adapter。 */
enum LynxNativeLegacyMediaCapabilities {
    typealias Completion = (LynxNativeCapabilityResult) -> Void
    private static let maximumBytes = LynxNativePayloadLimits.downloadedFileBytes
    private static let maximumBase64Bytes = 4 * ((maximumBytes + 2) / 3)

    static func parse(method: String, optionsJSON: String) -> LynxNativeCapabilityResult {
        guard ["chooseMedia", "uploadFile", "uploadImage", "downloadFile", "saveDataURL"].contains(method) else {
            return .failure("UNSUPPORTED", "未知旧媒体方法")
        }
        let budget = method == "saveDataURL" ? maximumBase64Bytes + 64 * 1024 : LynxNativePayloadLimits.inputJSONBytes
        guard optionsJSON.utf8.count <= budget else { return .failure("PAYLOAD_TOO_LARGE", "媒体参数超过大小上限") }
        do {
            guard let data = optionsJSON.data(using: .utf8),
                  let options = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                return .failure("INVALID_ARGUMENT", "media options 必须是 JSON 对象")
            }
            return .success(["options": options])
        } catch { return .failure("INVALID_ARGUMENT", "media options JSON 无效") }
    }

    static func receipt(for result: LynxNativeCapabilityResult) -> NSDictionary {
        if result.success { return ["code": 0, "msg": "ok", "data": result.data ?? [:]] }
        return ["code": -1, "msg": result.error?["message"] as? String ?? "媒体操作失败"]
    }

    static func dispatch(method: String, options: [String: Any], ownerID: String,
                         presenter: UIViewController?, completion: @escaping Completion) {
        switch method {
        case "chooseMedia": chooseMedia(options, ownerID: ownerID, presenter: presenter, completion: completion)
        case "uploadFile", "uploadImage": upload(options, ownerID: ownerID, completion: completion)
        case "downloadFile":
            var mapped: [String: Any] = ["url": options["url"] ?? "", "directory": "TEMPORARY",
                "path": "lynx-download-\(UUID().uuidString).\(safeExtension(options["extension"]))"]
            if let headers = options["header"] { mapped["headers"] = headers }
            let call = LynxNativeCapabilityCall(callbackId: "-1", pluginId: "FileTransfer", methodName: "downloadFile", options: mapped, ownerID: ownerID)
            _ = LynxNativeMediaCapabilities.dispatch(call, presenter: presenter) { result in
                guard result.success, let uri = result.data?["uri"] as? String, let httpCode = result.data?["httpCode"] as? Int else { completion(result); return }
                completion(.success(["httpCode": httpCode, "clientCode": 0, "filePath": uri]))
            }
        default: completion(.failure("UNSUPPORTED", "未知旧媒体方法"))
        }
    }

    private static func chooseMedia(_ options: [String: Any], ownerID: String, presenter: UIViewController?, completion: @escaping Completion) {
        let requested = options["mediaTypes"] as? [String] ?? ["image"]
        let valid = requested.filter { $0 == "image" || $0 == "video" }
        let media = valid.isEmpty ? ["image"] : valid
        let camera = options["sourceType"] as? String == "camera"
        let mixed = media.contains("image") && media.contains("video")
        let video = media.contains("video") && !media.contains("image")
        var count = 1
        for key in ["count", "maxCount"] {
            if let raw = options[key] {
                guard let parsed = LynxNativeMediaCapabilities.validSelectionCount(raw, minimum: 1) else {
                    completion(.failure("INVALID_ARGUMENT", "\(key) 必须是 1...16 的整数")); return
                }
                count = parsed
            }
        }
        let call = LynxNativeCapabilityCall(callbackId: "-1", pluginId: "Camera",
            methodName: camera ? (video ? "recordVideo" : "takePhoto") : "chooseFromGallery",
            options: ["mediaType": mixed ? 2 : (video ? 1 : 0), "limit": count, "resultType": "URI",
                      "legacyCameraMixed": camera && mixed], ownerID: ownerID)
        if let failure = LynxNativeUsageDescriptions.validate(call, info: Bundle.main.infoDictionary ?? [:],
                systemMajorVersion: ProcessInfo.processInfo.operatingSystemVersion.majorVersion) {
            completion(failure); return
        }
        _ = LynxNativeMediaCapabilities.dispatch(call, presenter: presenter) { result in
            guard result.success, let photos = result.data?["photos"] as? [[String: Any]] else { completion(result); return }
            let files = photos.map { photo -> [String: Any] in
                ["tempFilePath": photo["webPath"]!, "tempFileAbsolutePath": photo["path"]!, "size": photo["size"]!,
                 "mediaType": photo["mediaType"]!, "mimeType": photo["mimeType"]!]
            }
            completion(.success(["tempFiles": files]))
        }
    }

    private static func safeExtension(_ raw: Any?) -> String {
        guard let value = raw as? String else { return "bin" }
        let cleaned = value.trimmingCharacters(in: CharacterSet(charactersIn: "."))
        return cleaned.range(of: "^[A-Za-z0-9]{1,10}$", options: .regularExpression) == nil ? "bin" : cleaned.lowercased()
    }

    /** 与 JSON 解析共用一个后台 IO 工作单元，不把大 Base64 切片和解码投到主线程。 */
    static func saveDataURL(_ options: [String: Any], ownerID: String, cancellation: LynxNativeIOExecutor.Cancellation) -> LynxNativeCapabilityResult {
        guard !cancellation.isCancelled, LynxNativeOwnerScope.isActive(ownerID) else { return .failure("HOST_DESTROYED", "Data URL 落盘已取消") }
        guard let dataURL = options["dataURL"] as? String, let comma = dataURL.firstIndex(of: ","),
              dataURL.hasPrefix("data:"), dataURL[..<comma].hasSuffix(";base64") else {
            return .failure("INVALID_ARGUMENT", "dataURL 必须是合法的 Base64 Data URL")
        }
        let encoded = String(dataURL[dataURL.index(after: comma)...])
        guard encoded.utf8.count <= maximumBase64Bytes else { return .failure("PAYLOAD_TOO_LARGE", "Data URL 超过 20 MiB 限制") }
        guard !cancellation.isCancelled, LynxNativeOwnerScope.isActive(ownerID) else { return .failure("HOST_DESTROYED", "Data URL 解码已取消") }
        guard let decoded = Data(base64Encoded: encoded) else { return .failure("INVALID_ARGUMENT", "Data URL 解码失败") }
        guard decoded.count <= maximumBytes else { return .failure("PAYLOAD_TOO_LARGE", "Data URL 超过 20 MiB 限制") }
        let rawName = options["filename"] as? String ?? "lynx-file"
        let safeName = rawName.replacingOccurrences(of: "[^A-Za-z0-9._-]", with: "_", options: .regularExpression)
        let output = FileManager.default.temporaryDirectory.appendingPathComponent(safeName.isEmpty ? "lynx-file" : safeName)
            .appendingPathExtension(safeExtension(options["extension"]))
        do {
            try LynxNativeAtomicFile.write(decoded, to: output, ownerID: ownerID, cancellation: cancellation)
            return .success(["filePath": output.absoluteString])
        } catch is LynxNativeIOExecutor.Cancelled { return .failure("HOST_DESTROYED", "Data URL 落盘已取消") }
        catch { return .failure("WRITE_FAILED", "Data URL 落盘失败: \(error.localizedDescription)") }
    }

    private static func upload(_ options: [String: Any], ownerID: String, completion: @escaping Completion) {
        guard let rawURL = options["url"] as? String, let url = URL(string: rawURL), ["http", "https"].contains(url.scheme?.lowercased() ?? "") else {
            completion(.failure("INVALID_ARGUMENT", "上传 URL 无效")); return
        }
        guard let path = options["filePath"] as? String,
              let source = LynxNativeMediaCapabilities.validatedLocalFile(path: path) else {
            completion(.failure("NOT_FOUND", "上传文件必须是应用媒体目录中的现存本地文件")); return
        }
        LynxNativeIOExecutor.network.submitAsync(ownerID: ownerID, completion: completion) { cancellation, finish in
            let upload = Upload(ownerID: ownerID, rawURL: rawURL, cancellation: cancellation, completion: finish)
            do {
                let multipart = try upload.makeMultipart(source: source)
                var request = URLRequest(url: url)
                request.httpMethod = "POST"
                request.timeoutInterval = 60
                (options["header"] as? [String: Any])?.forEach { request.setValue(String(describing: $0.value), forHTTPHeaderField: $0.key) }
                request.setValue("multipart/form-data; boundary=\(upload.boundary)", forHTTPHeaderField: "Content-Type")
                upload.start(request: request, file: multipart)
            } catch is LynxNativeIOExecutor.Cancelled { upload.finish(.failure("HOST_DESTROYED", "上传已取消")) }
            catch let error as UploadError { upload.finish(.failure(error.code, error.message)) }
            catch { upload.finish(.failure("UPLOAD_FAILED", "上传文件准备失败: \(error.localizedDescription)")) }
        }
    }

    private struct UploadError: Error { let code: String; let message: String }

    private final class Upload: NSObject, URLSessionDataDelegate {
        let boundary = "LynxShell-\(UUID().uuidString)"
        let ownerID: String
        let rawURL: String
        let cancellation: LynxNativeIOExecutor.Cancellation
        let completion: Completion
        let resource: LynxNativeOwnedResource
        private let lock = NSLock()
        private var ended = false
        private var responseData = Data()
        private var httpCode = 0
        private var multipart: URL?
        private var session: URLSession?
        private var task: URLSessionUploadTask?

        init(ownerID: String, rawURL: String, cancellation: LynxNativeIOExecutor.Cancellation, completion: @escaping Completion) {
            self.ownerID = ownerID; self.rawURL = rawURL; self.cancellation = cancellation; self.completion = completion
            resource = LynxNativeOwnedResource(ownerID: ownerID)
            super.init()
        }

        func makeMultipart(source: URL) throws -> URL {
            let size = try source.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
            guard size <= maximumBytes else { throw UploadError(code: "UPLOAD_TOO_LARGE", message: "上传文件超过 20 MiB 限制") }
            let file = FileManager.default.temporaryDirectory.appendingPathComponent("lynx-upload-\(UUID().uuidString).part")
            multipart = file
            guard FileManager.default.createFile(atPath: file.path, contents: nil) else { throw UploadError(code: "WRITE_FAILED", message: "无法创建上传临时文件") }
            let input = try FileHandle(forReadingFrom: source)
            let output = try FileHandle(forWritingTo: file)
            defer { try? input.close(); try? output.close() }
            let filename = source.lastPathComponent.replacingOccurrences(of: "[\"\\r\\n]", with: "_", options: .regularExpression)
            try output.write(contentsOf: Data("--\(boundary)\r\nContent-Disposition: form-data; name=\"file\"; filename=\"\(filename)\"\r\nContent-Type: application/octet-stream\r\n\r\n".utf8))
            var total = 0
            while true {
                try cancellation.check()
                guard LynxNativeOwnerScope.isActive(ownerID) else { throw LynxNativeIOExecutor.Cancelled() }
                let chunk = try input.read(upToCount: 64 * 1024) ?? Data()
                if chunk.isEmpty { break }
                total += chunk.count
                guard total <= maximumBytes else { throw UploadError(code: "UPLOAD_TOO_LARGE", message: "上传文件超过 20 MiB 限制") }
                try output.write(contentsOf: chunk)
            }
            try output.write(contentsOf: Data("\r\n--\(boundary)--\r\n".utf8))
            try output.synchronize()
            return file
        }

        func start(request: URLRequest, file: URL) {
            lock.lock()
            guard !ended, !cancellation.isCancelled, LynxNativeOwnerScope.isActive(ownerID) else {
                lock.unlock(); finish(.failure("HOST_DESTROYED", "上传已取消")); return
            }
            let session = URLSession(configuration: .ephemeral, delegate: self, delegateQueue: nil)
            self.session = session
            task = session.uploadTask(with: request, fromFile: file)
            let task = self.task
            lock.unlock()
            resource.attach { [weak self] in self?.cancel() }
            guard !cancellation.isCancelled, LynxNativeOwnerScope.isActive(ownerID) else { cancel(); return }
            task?.resume()
        }

        func cancel() { cancellation.cancel(); finish(.failure("HOST_DESTROYED", "上传已取消")) }

        func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse,
                        completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
            let code = (response as? HTTPURLResponse)?.statusCode ?? 0
            guard (200..<300).contains(code) else { completionHandler(.cancel); finish(.failure("HTTP_ERROR", "上传失败，HTTP \(code)")); return }
            guard response.expectedContentLength <= LynxNativePayloadLimits.inlineFileBytes else {
                completionHandler(.cancel); finish(.failure("PAYLOAD_TOO_LARGE", "上传响应超过 512 KiB 限制")); return
            }
            lock.lock(); httpCode = code; let active = !ended; lock.unlock()
            completionHandler(active ? .allow : .cancel)
        }

        func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
            lock.lock()
            guard !ended else { lock.unlock(); return }
            guard data.count <= LynxNativePayloadLimits.inlineFileBytes - responseData.count else {
                lock.unlock(); finish(.failure("PAYLOAD_TOO_LARGE", "上传响应超过 512 KiB 限制")); return
            }
            responseData.append(data)
            lock.unlock()
        }

        func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
            if let error { finish(.failure("UPLOAD_FAILED", "上传失败: \(error.localizedDescription)")); return }
            lock.lock(); let data = responseData; let code = httpCode; let active = !ended; lock.unlock()
            guard active else { return }
            guard (200..<300).contains(code) else { finish(.failure("HTTP_ERROR", "上传失败，HTTP \(code)")); return }
            let response: Any = data.isEmpty ? [String: Any]() : ((try? JSONSerialization.jsonObject(with: data)) ?? (String(data: data, encoding: .utf8) ?? ""))
            finish(.success(["url": rawURL, "clientCode": 0, "response": response]))
        }

        func finish(_ result: LynxNativeCapabilityResult) {
            lock.lock()
            guard !ended else { lock.unlock(); return }
            ended = true
            let session = self.session
            let task = self.task
            let file = multipart
            self.session = nil; self.task = nil; multipart = nil; responseData.removeAll()
            lock.unlock()
            task?.cancel()
            session?.invalidateAndCancel()
            resource.finish()
            if let file { try? FileManager.default.removeItem(at: file) }
            completion(result)
        }
    }
}

/** 大 Data URL 只允许一条活跃调用；owner 关闭时同时清掉尚未消费的排队输入。 */
final class LynxNativeLegacyMediaInput {
    private static let admissionLock = NSLock()
    private static var largeInputBusy = false
    private let lock = NSLock()
    private var value: String?
    private var options: [String: Any]?
    private let resource: LynxNativeOwnedResource
    private let large: Bool
    private var ended = false

    static func admitLargeInput() -> Bool {
        admissionLock.lock(); defer { admissionLock.unlock() }
        guard !largeInputBusy else { return false }
        largeInputBusy = true
        return true
    }

    init(_ value: String, ownerID: String?, large: Bool = false) {
        self.value = value; self.large = large
        resource = LynxNativeOwnedResource(ownerID: ownerID)
        resource.attach { [weak self] in self?.finish() }
    }

    func take() -> String? { lock.lock(); defer { lock.unlock() }; let input = value; value = nil; return input }

    func store(options: [String: Any]) -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard !ended else { return false }
        self.options = options
        return true
    }

    func takeOptions() -> [String: Any]? {
        lock.lock(); defer { lock.unlock() }
        let parsed = options; options = nil
        return parsed
    }

    func finish() {
        lock.lock()
        guard !ended else { lock.unlock(); return }
        ended = true; value = nil; options = nil
        lock.unlock()
        resource.finish()
        if large {
            Self.admissionLock.lock(); Self.largeInputBusy = false; Self.admissionLock.unlock()
        }
    }
}
